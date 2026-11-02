"""VillageSQL + vsql_vector (SVECTOR type, HNSW custom index), driven by
ann-benchmarks.

New module; upstream ann-benchmarks has no VillageSQL support. The ops-harness
driver, `harness/drivers/villagesql.py`, carries the reasoning for each
difference; this module follows it and shares none of its code, because the
bench container mounts `overlay/` and the harness container mounts `harness/`.

What differs from `VBMySQLBase`:

* **Two DDL statements.** The column is `SVECTOR(N)` and the index is created
  separately, `CREATE INDEX vi ON t1 (v hnsw_<metric>) USING EXTENDED(hnsw)
  WITH (M = .., ef_construction = ..)`, so `fit` issues both before the load.
* **ef_construction is a build knob**, capped by the extension at 32 * M; the
  value is clamped and both values reach `get_additional`.
* **Vectors are bound as '[..]' text** (`encode_vector`): SVECTOR has no raw
  float32 input path.
* **The query vector is inlined.** The extension serves `ORDER BY <DIST>(v,
  '<literal>') LIMIT k` only with a string literal (a placeholder fails with
  ERROR 3219), so every query path here builds its own SQL.
* **`ef_search` is a session variable**, so the batch workers' own
  connections set it too.
* **The plan is read with EXPLAIN FORMAT=TREE**: the routed scan is an
  iterator, `Custom index distance scan on vi`, which only the tree format
  prints.
"""

from __future__ import annotations

import sys
import time
from multiprocessing.pool import ThreadPool
from typing import Any, Dict, List, Optional

import numpy

from ...vb_mysql import DATABASE, TABLE, WARMUP_QUERIES, Dialect, VBMySQLBase

#: vsql-vector's ceiling on ef_construction, per unit of M
#: (`MAX_EF_CONSTRUCTION_FACTOR` in src/index/hnsw/storage.h).
MAX_EF_CONSTRUCTION_FACTOR = 32
DEFAULT_EF_CONSTRUCTION = 200
#: The routed custom scan's line in a TREE plan: "-> Custom index distance scan
#: on vi". Without it the query was answered some other way.
PLAN_MARKER = "Custom index distance scan"

#: metric -> (index modifier, distance function, ORDER BY direction).
METRICS = {
    "l2": ("hnsw_l2", "L2_DISTANCE", "ASC"),
    "cosine": ("hnsw_cosine", "COSINE_DISTANCE", "ASC"),
}


def to_text_bracket(vector) -> str:
    """'[a,b,...]', the form SVECTOR parses. `repr` keeps float32 exact."""
    return "[" + ",".join(repr(float(x))
                          for x in numpy.asarray(vector, dtype="<f4")) + "]"


VILLAGESQL = Dialect(
    name="villagesql",
    # Preview extensions and INSTALL EXTENSION are done once by the image
    # entrypoint; repeating INSTALL would error.
    global_setup=(),
    session_setup=("SET SESSION default_storage_engine = InnoDB",),
    # A session variable: every connection that queries sets its own.
    set_ef_search="SET SESSION vsql_vector.ef_search = {ef_search}",
    index_name="vi",
    # The graph is pages in the table's own tablespace, beside the rows, so the
    # only file to measure is the table's: an upper bound on the index, as the
    # ops driver's `index_bytes` is.
    index_file_globs=("t1*.ibd",),
    metric_names={"angular": "cosine", "euclidean": "l2"},
    verify_index_used=True,
)


class VillageSQL(VBMySQLBase):
    dialect = VILLAGESQL

    def __init__(self, metric: str, method_param: Dict[str, Any]):
        self._ef_construction_requested = int(
            method_param.get("efConstruction", DEFAULT_EF_CONSTRUCTION))
        super().__init__(metric, method_param)
        ceiling = MAX_EF_CONSTRUCTION_FACTOR * self._m
        self._ef_construction = min(self._ef_construction_requested, ceiling)
        if self._ef_construction != self._ef_construction_requested:
            print(f"[vb] villagesql: ef_construction "
                  f"{self._ef_construction_requested} exceeds the extension's "
                  f"maximum of {ceiling} for M={self._m}; building at "
                  f"{self._ef_construction}", file=sys.stderr)
        self._modifier, self._distance_fn, self._order = METRICS[self._metric]

    def encode_vector(self, vector) -> str:
        return to_text_bracket(vector)

    # ------------------------------------------------------------------
    # Fit: the base load, behind two DDL statements instead of one
    # ------------------------------------------------------------------

    def fit(self, X: numpy.ndarray) -> None:
        self._keep_warmup_sample(X)
        dim = int(X.shape[1])
        self._dim = dim
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
            f"(v {self._modifier}) USING EXTENDED(hnsw) "
            f"WITH (M = {self._m}, ef_construction = {self._ef_construction})"
        )
        print(f"[vb] {index_ddl}", file=sys.stderr)
        cur.execute(index_ddl)

        print(f"[vb] loading {len(X):,} x {dim} vectors "
              f"with {self._insert_threads} thread(s)", file=sys.stderr)
        start = time.time()
        if self._insert_threads > 1:
            self._insert_parallel(X)
        else:
            self._insert_serial(cur, X)
        self._ingest_seconds = time.time() - start
        print(f"[vb] load complete in {self._ingest_seconds:.1f}s "
              f"({len(X) / max(self._ingest_seconds, 1e-9):,.0f} rows/s)",
              file=sys.stderr)
        # Built incrementally on INSERT, as MHNSW and VIDX are.
        self._build_seconds = self._ingest_seconds
        self._index_bytes = self._measure_index_bytes()

    # ------------------------------------------------------------------
    # Queries: every path inlines the vector
    # ------------------------------------------------------------------

    def _knn_sql(self, vector, k: int) -> str:
        literal = "'" + to_text_bracket(vector) + "'"
        return (f"SELECT id FROM {TABLE} "
                f"ORDER BY {self._distance_fn}(v, {literal}) {self._order} "
                f"LIMIT {int(k)}")

    def query(self, v, n: int) -> List[int]:
        self._cur.execute(self._knn_sql(v, n))
        return [row[0] for row in self._cur.fetchall()]

    def batch_query(self, X, n: int) -> None:
        threads = self._insert_threads

        def worker(chunk):
            conn = self._connect()
            cur = conn.cursor()
            cur.execute(f"USE {DATABASE}")
            for stmt in self.dialect.session_setup:
                cur.execute(stmt)
            cur.execute(self.dialect.set_ef_search.format(
                ef_search=self._ef_search))
            out = []
            for v in chunk:
                cur.execute(self._knn_sql(v, n))
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

        merged: List[Optional[List[int]]] = [None] * len(X)
        for c, chunk_results in enumerate(results):
            for j, res in enumerate(chunk_results):
                merged[c + j * threads] = res
        self._batch_results = [r if r is not None else [] for r in merged]

    def _warm_cache(self) -> None:
        """The base class's random-vector warm-up, with inlined vectors."""
        if WARMUP_QUERIES <= 0:
            return
        try:
            dim = self._dim_from_table()
        except Exception:
            return
        rng = numpy.random.RandomState(0)
        for _ in range(WARMUP_QUERIES):
            try:
                self._cur.execute(self._knn_sql(
                    rng.normal(size=dim).astype("<f4"), 10))
                self._cur.fetchall()
            except Exception:
                return

    def _verify_plan(self, k: int = 10) -> bool:
        try:
            probe = numpy.zeros(self._dim_from_table(), dtype="<f4")
            self._cur.execute("EXPLAIN FORMAT=TREE " + self._knn_sql(probe, k))
            plan = " | ".join(str(c) for row in self._cur.fetchall() for c in row)
        except Exception as exc:  # pragma: no cover
            # False, not None: the value lands in get_additional, and
            # ann-benchmarks writes every attribute into HDF5, which has no
            # None -- a None here fails the whole result file after the
            # queries have run.
            print(f"[vb] WARNING: could not EXPLAIN the query plan: {exc}",
                  file=sys.stderr)
            return False
        used = PLAN_MARKER in plan and self.dialect.index_name in plan
        if used:
            print(f"[vb] plan check OK: custom index in use ({plan})",
                  file=sys.stderr)
        else:
            print("[vb] WARNING: the custom vector index is NOT in the query "
                  "plan. This measures a brute-force scan, not ANN search.\n"
                  f"[vb] plan: {plan}", file=sys.stderr)
        return used

    def _dim_from_table(self) -> int:
        """The dimension `fit` built the table with.

        Remembered rather than read back: `information_schema.COLUMNS` does not
        carry the SVECTOR dimension in COLUMN_TYPE, and parsing it there gave 1,
        so the plan check probed with a one-element vector the server rejects.
        """
        return int(getattr(self, "_dim", 0) or 1)

    def get_additional(self) -> Dict[str, Any]:
        extra = super().get_additional()
        extra["ef_construction"] = self._ef_construction
        extra["ef_construction_requested"] = self._ef_construction_requested
        return extra

    def __str__(self) -> str:
        return (f"VillageSQL(M={self._m}, ef_construction={self._ef_construction}, "
                f"engine={self._storage_engine}, ef_search={self._ef_search})")
