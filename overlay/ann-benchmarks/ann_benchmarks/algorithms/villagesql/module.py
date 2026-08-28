"""VillageSQL SVECTOR + HNSW custom index, driven by ann-benchmarks.

New module — upstream ann-benchmarks has no VillageSQL support, and VillageSQL's
vector surface differs enough from MariaDB/AliSQL that it overrides several
VBMySQLBase hooks rather than only supplying a Dialect:

1. **Column type is SVECTOR(N)**, not VECTOR(N), and the index is a *custom*
   index created separately: `CREATE INDEX ix ON t (v hnsw_l2) USING
   EXTENDED(hnsw) WITH (M=.., ef_construction=..)`. So create_table() emits the
   table then the index, and does not use the inline `VECTOR INDEX` form.

2. **Vectors bind as a '[..]' text literal**, not raw float32 binary; SVECTOR
   parses the string (implicit conversion). encode_vector() returns the text.

3. **The query vector must be INLINED into the SQL**, not passed as a bound `%s`
   parameter. The custom-index optimizer matches on the exact shape
   `ORDER BY <DIST>(<indexed_col>, '<literal>') LIMIT k`; a bound parameter is
   not recognised the same way and the scan would fall back to brute force.
   This is verified against the reference harness in vector-dev-bench.

4. **ef_construction is a real, honoured build knob** (unlike MHNSW/VIDX), passed
   in the WITH(...) clause. efConstruction < M is rejected by the server.

5. **Plan verification is observational only.** There is no stable EXPLAIN marker
   for the custom scan and no usable FORCE INDEX hint; the optimizer selects the
   index on its own. Index usage is confirmed behaviourally (recall < 1.0 that
   rises with ef_search vs an exact-1.0 brute-force scan), so _verify_plan logs
   EXPLAIN but never forces or fails.

Exactly ONE extension that registers the SVECTOR type may be installed; the
image installs vsql_vector and nothing else (two would make type resolution
assert). The mandatory gates (preview extensions, hypergraph optimizer) are set
by the image entrypoint's init.sql and re-asserted per session here.
"""

from __future__ import annotations

import sys
from typing import List

import numpy

from ...vb_mysql import (
    DATABASE,
    TABLE,
    Dialect,
    VBMySQLBase,
    to_text_bracket,
)


# metric key -> (index modifier, distance function, order direction)
_METRICS = {
    "l2": ("hnsw_l2", "L2_DISTANCE", "ASC"),
    "cosine": ("hnsw_cosine", "COSINE_DISTANCE", "ASC"),
    "l1": ("hnsw_l1", "L1_DISTANCE", "ASC"),
    # INNER_PRODUCT is a similarity: nearest = largest dot, so order DESC.
    "ip": ("hnsw_inner_product", "INNER_PRODUCT", "DESC"),
}


VILLAGESQL = Dialect(
    name="villagesql",
    # Preview + hypergraph are PERSISTed by the entrypoint; repeated per session
    # so the module also works against a server someone else started. INSTALL
    # EXTENSION is done once by the entrypoint (persists in the catalog), not
    # here — re-installing would error "already installed".
    global_setup=(),
    session_setup=(
        "SET SESSION default_storage_engine = InnoDB",
        "SET SESSION optimizer_switch = 'hypergraph_optimizer=on'",
    ),
    # ef_search is a GLOBAL-only sysvar on this build: a session-scope SET is
    # rejected with ER_GLOBAL_VARIABLE (1229). It is namespaced and unquoted.
    set_ef_search="SET GLOBAL vsql_vector.ef_search = {ef_search}",
    index_name="idx_v",
    # SVECTOR columnar storage lives in the InnoDB tablespace of its own table,
    # not a separate index file, so an index-file glob would measure nothing.
    # Index size is left to the ops harness / information_schema; report 0 here
    # rather than a misleading partial number.
    index_file_globs=(),
    # angular -> cosine, euclidean -> l2 (ann-benchmarks metric names).
    metric_names={"angular": "cosine", "euclidean": "l2"},
    verify_index_used=True,
    force_index_hint="",
)


class VillageSQL(VBMySQLBase):
    dialect = VILLAGESQL

    # vsql-vector caps ef_construction at MAX_EF_CONSTRUCTION_FACTOR * M
    # (src/index/hnsw/storage.cc: max_ef_construction = M * 32). A request above
    # that cap is rejected at CREATE INDEX ("ef_construction exceeds maximum
    # allowed value ... for M="), which for small M (e.g. M=6 -> max 192) fails a
    # grid that asks for ef_construction=200. Clamp to the per-M maximum so every
    # M value benchmarks; the effective value is recorded in get_additional()
    # (see _ef_construction_requested) so results stay honest about what ran.
    _MAX_EF_CONSTRUCTION_FACTOR = 32

    def __init__(self, metric, method_param):
        # method_param carries M and (VillageSQL only) ef_construction.
        self._ef_construction_requested = int(method_param.get("ef_construction", 200))
        super().__init__(metric, method_param)  # sets self._m
        max_ef = self._MAX_EF_CONSTRUCTION_FACTOR * self._m
        self._ef_construction = min(self._ef_construction_requested, max_ef)
        if self._ef_construction != self._ef_construction_requested:
            print(f"[vb] villagesql: ef_construction {self._ef_construction_requested} "
                  f"exceeds max {max_ef} for M={self._m}; clamped to {self._ef_construction}",
                  file=sys.stderr)
        mod, fn, order = _METRICS[self._metric]  # self._metric is the mapped key
        self._idx_modifier = mod
        self._distance_fn = fn
        self._order = order

    # --- vector encoding: text literal, not binary --------------------------

    def encode_vector(self, vector) -> str:
        return to_text_bracket(vector)

    # --- query setup: set ef_search, log EXPLAIN once, warm cache -----------

    def set_query_arguments(self, ef_search: int) -> None:
        self._ef_search = int(ef_search)
        self._cur.execute(self.dialect.set_ef_search.format(ef_search=self._ef_search))
        if not getattr(self, "_explain_logged", False):
            # Record the result so get_additional() reports vector_index_used,
            # exactly as the MariaDB/AliSQL path does.
            self._plan_verified = self._verify_plan()
            self._explain_logged = True
        self._warm_cache()

    # --- DDL + load ---------------------------------------------------------
    # VillageSQL needs TWO DDL statements (table, then a separate custom index),
    # so it overrides fit() rather than the single-statement dialect.create_table
    # the base uses. The rest mirrors the base: batched load, then record ingest
    # = build (the graph is maintained incrementally per insert).

    def fit(self, X: numpy.ndarray) -> None:
        import time
        dim = int(X.shape[1])
        cur = self._cur

        cur.execute(f"DROP DATABASE IF EXISTS {DATABASE}")
        cur.execute(f"CREATE DATABASE {DATABASE}")
        cur.execute(f"USE {DATABASE}")
        for stmt in self.dialect.session_setup:
            cur.execute(stmt)

        cur.execute(
            f"CREATE TABLE {TABLE} (\n"
            f"  id INT PRIMARY KEY,\n"
            f"  tag INT NOT NULL,\n"
            f"  v SVECTOR({dim}) NOT NULL\n"
            f") ENGINE={self._storage_engine}"
        )
        index_ddl = (
            f"CREATE INDEX {self.dialect.index_name} ON {TABLE} "
            f"(v {self._idx_modifier}) USING EXTENDED(hnsw) "
            f"WITH (M = {self._m}, ef_construction = {self._ef_construction})"
        )
        print(f"[vb] {index_ddl}", file=sys.stderr)
        cur.execute(index_ddl)

        print(
            f"[vb] loading {len(X):,} x {dim} vectors "
            f"with {self._insert_threads} thread(s)",
            file=sys.stderr,
        )
        start = time.time()
        if self._insert_threads > 1:
            self._insert_parallel(X)
        else:
            self._insert_serial(cur, X)
        self._ingest_seconds = time.time() - start
        self._build_seconds = self._ingest_seconds
        self._index_bytes = self._measure_index_bytes()
        print(
            f"[vb] load complete in {self._ingest_seconds:.1f}s "
            f"({len(X) / max(self._ingest_seconds, 1e-9):,.0f} rows/s)",
            file=sys.stderr,
        )

    # --- insert: bind text literal via %s (batched by the base loader) ------
    # The base _insert_serial builds rows as (id, tag, encode_vector(x)) and
    # executes "INSERT ... VALUES (%s,%s,%s)". A '[..]' string bound as %s is
    # fine here — only the *query* vector needs literal inlining for routing.

    # --- query: inline the vector literal for the optimizer to route --------

    def _query_sql(self, k: int, vector=None, force_index: bool = False) -> str:
        # The query vector is inlined as a quoted literal, not %s: the custom
        # index only routes when it sees ORDER BY DIST(col, '<lit>') LIMIT k.
        if vector is None:
            lit = "'[]'"
        else:
            lit = "'" + self.encode_vector(vector) + "'"
        return (
            f"SELECT id FROM {TABLE} "
            f"ORDER BY {self._distance_fn}(v, {lit}) {self._order} LIMIT {k}"
        )

    def query(self, v, n: int) -> List[int]:
        self._cur.execute(self._query_sql(n, vector=v))
        return [row[0] for row in self._cur.fetchall()]

    def batch_query(self, X, n: int) -> None:
        # Mirror the base's threaded batch, but inline the query literal (no %s)
        # so each query routes to the custom index.
        from multiprocessing.pool import ThreadPool

        threads = self._insert_threads

        def worker(chunk):
            conn = self._connect()
            cur = conn.cursor()
            cur.execute(f"USE {DATABASE}")
            cur.execute(self.dialect.set_ef_search.format(ef_search=self._ef_search))
            out = []
            for v in chunk:
                cur.execute(self._query_sql(n, vector=v))
                out.append([row[0] for row in cur.fetchall()])
            cur.close()
            conn.close()
            return out

        chunks = [X[i::threads] for i in range(threads)]
        pool = ThreadPool(threads)
        try:
            results = pool.map(worker, chunks)
        finally:
            pool.close()
            pool.join()

        merged = [None] * len(X)
        for c, chunk_results in enumerate(results):
            for j, res in enumerate(chunk_results):
                merged[c + j * threads] = res
        self._batch_results = [r if r is not None else [] for r in merged]

    def _warm_cache(self) -> None:
        # Same intent as the base (warm with random vectors, never the query
        # set), but with inlined literals rather than bound params.
        from ...vb_mysql import WARMUP_QUERIES
        if WARMUP_QUERIES <= 0:
            return
        try:
            dim = self._dim_from_table()
        except Exception:
            return
        rng = numpy.random.RandomState(0)
        for _ in range(WARMUP_QUERIES):
            probe = rng.normal(size=dim).astype("<f4")
            try:
                self._cur.execute(self._query_sql(10, vector=probe))
                self._cur.fetchall()
            except Exception:
                return

    # The routed custom KNN scan prints this in EXPLAIN (observed on a live
    # server): "-> Custom index distance scan on <ixname>". If it is absent the
    # optimizer fell back to a full scan, which returns exact results and would
    # measure brute force at 100% recall — the silent failure the guard exists
    # to catch.
    PLAN_MARKER = "Custom index distance scan"

    def _verify_plan(self, k: int = 10) -> Optional[bool]:
        try:
            dim = self._dim_from_table()
            probe = numpy.zeros(dim, dtype="<f4")
            self._cur.execute("EXPLAIN " + self._query_sql(k, vector=probe))
            rows = self._cur.fetchall()
        except Exception as exc:  # pragma: no cover
            print(f"[vb] note: could not EXPLAIN vsql query plan: {exc}", file=sys.stderr)
            return None
        plan = " | ".join(str(col) for row in rows for col in row)
        used = self.PLAN_MARKER in plan
        if used:
            print(f"[vb] plan check OK: custom index in use ({plan})", file=sys.stderr)
        else:
            print(
                "[vb] WARNING: the custom vector index is NOT in the query plan. "
                "This measures a brute-force scan, not ANN search.\n"
                f"[vb] plan: {plan}",
                file=sys.stderr,
            )
        return used

    def _dim_from_table(self) -> int:
        # SVECTOR(N) dimension. Prefer the extension's own function; fall back to
        # parsing COLUMN_TYPE if that ever changes.
        try:
            self._cur.execute(
                f"SELECT VECTOR_DIMENSION(v) FROM {TABLE} LIMIT 1"
            )
            row = self._cur.fetchone()
            if row and row[0]:
                return int(row[0])
        except Exception:
            pass
        self._cur.execute(
            "SELECT COLUMN_TYPE FROM information_schema.COLUMNS "
            "WHERE TABLE_SCHEMA=%s AND TABLE_NAME=%s AND COLUMN_NAME='v'",
            (DATABASE, TABLE),
        )
        row = self._cur.fetchone()
        if row and row[0]:
            # e.g. "svector(784)"
            txt = str(row[0])
            digits = "".join(c for c in txt if c.isdigit())
            if digits:
                return int(digits)
        return 1

    @staticmethod
    def _image_march() -> str:
        try:
            with open("/opt/villagesql/.march") as fh:
                return fh.read().strip()
        except OSError:
            return "unknown"

    def get_additional(self) -> dict:
        # Extend the base record with the ef_construction actually used vs what
        # the grid requested, so a clamp (ef_construction > 32*M for small M) is
        # visible in the results rather than silently altering the build knob.
        extra = super().get_additional()
        extra["ef_construction"] = self._ef_construction
        extra["ef_construction_requested"] = self._ef_construction_requested
        return extra

    def __str__(self) -> str:
        return (
            f"VillageSQL(M={self._m}, ef_construction={self._ef_construction}, "
            f"engine={self._storage_engine}, ef_search={self._ef_search})"
        )
