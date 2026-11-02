"""VillageSQL + the vsql_vector extension (SVECTOR type, HNSW custom index).

VillageSQL is a MySQL 8.4 server, so the connector, account, load threading
and churn machinery are `MySQLFamilyDriver`'s. The vector index is not part of
the server: it is an extension built against the server's tree, and every
difference from the template follows from that.

* **The column is `SVECTOR(N)` and the index is a separate statement**,
  `CREATE INDEX vi ON t1 (v hnsw_<metric>) USING EXTENDED(hnsw) WITH (M = ..,
  ef_construction = ..)`, issued right after CREATE TABLE so the graph is
  maintained on every INSERT, as MHNSW's and VIDX's are.
* **`ef_construction` is a real build knob**, capped by the extension at
  `32 * M` (`MAX_EF_CONSTRUCTION_FACTOR` in src/index/hnsw/storage.h); a
  larger value fails CREATE INDEX. The driver clamps and records both values
  rather than let a small-M build fail.
* **Vectors are bound as the text literal `'[a,b,...]'`.** SVECTOR has no raw
  float32 input path, so the binary binding the other MySQL-family drivers
  use is not available.
* **Each load batch is one multi-row INSERT**, not `executemany`. MariaDB
  Connector/Python bulks `executemany` only for binary parameters; with a text
  parameter it sends one INSERT per row (measured: `Com_insert` equal to the
  row count). Building the VALUES list here sends one statement per batch,
  which is the round-trip shape the other MySQL-family drivers already get.
* **The query vector is inlined into the SQL**, not bound. The extension
  serves `ORDER BY <DIST>(v, '<literal>') LIMIT k` and documents that a
  placeholder or user variable in the literal's place fails with ERROR 3219.
* **The plan is read as a TREE.** The routed scan is an iterator,
  `Custom index distance scan on vi`, and iterators are what the tree format
  prints. The format is spelled out for the reason the base class gives for
  spelling out TRADITIONAL. The classic optimizer routes the scan at this
  pin; no hypergraph build or switch is involved.
* **`ef_search` is a session variable** (`vsql_vector.ef_search`), set per
  connection as MariaDB's `mhnsw_ef_search` is.
* **Filtered search and churn are declined** -- see `FILTERED_DECLINED` and
  `CHURN_DECLINED`.
"""

from __future__ import annotations

import time
from typing import Any, Dict, List, Optional, Sequence, Tuple, Union

import numpy

from .base import (DATABASE, FILTER_CTAG, FILTER_TAG, TABLE, ConnectionSpec,
                   IndexSpec, RowAttrs, checked_filter_column)
from .mysql_family import PROGRESS_INTERVAL_S, MySQLDialect, MySQLFamilyDriver

#: vsql-vector's ceiling on ef_construction, per unit of M.
MAX_EF_CONSTRUCTION_FACTOR = 32
DEFAULT_EF_CONSTRUCTION = 200

#: Rows per INSERT statement. Sized by statement length, not by the 500 the
#: binary path uses: a text vector is ~8 bytes per dimension, so 1000 rows of
#: 784 dimensions is ~6 MB, well under the max_allowed_packet the engine config
#: sets.
LOAD_BATCH = 1000

FILTERED_DECLINED = (
    "vsql_vector at the pinned commit post-filters: the HNSW scan returns its "
    "top max(ef_search, LIMIT) candidates and a `WHERE tag < t` is applied to "
    "those, so a selective predicate returns fewer than k rows even when "
    "enough matching rows exist (README, 'Filtering with a WHERE clause'). "
    "Measuring that would publish post-filtered recall as filtered search.")

CHURN_DECLINED = (
    "vsql_vector at the pinned commit refuses DELETE of a row in an "
    "HNSW-indexed table (README, 'Supported statements on an HNSW-indexed "
    "table'), so churn's delete-and-reinsert cannot run.")

#: metric -> (index modifier, distance function, ORDER BY direction).
METRICS: Dict[str, Tuple[str, str, str]] = {
    "l2": ("hnsw_l2", "L2_DISTANCE", "ASC"),
    "cosine": ("hnsw_cosine", "COSINE_DISTANCE", "ASC"),
}


def to_text_bracket(vector) -> str:
    """'[a,b,...]', the form SVECTOR parses. `repr` keeps float32 exact."""
    return "[" + ",".join(repr(float(x))
                          for x in numpy.asarray(vector, dtype="<f4")) + "]"


def effective_ef_construction(requested: int, m: int) -> int:
    return min(int(requested), MAX_EF_CONSTRUCTION_FACTOR * int(m))


VILLAGESQL_DIALECT = MySQLDialect(
    name="villagesql",
    session_setup=("SET SESSION default_storage_engine = InnoDB",),
    # Preview extensions and INSTALL EXTENSION are done once, when the image
    # entrypoint bootstraps the datadir; repeating INSTALL would error.
    global_setup=(),
    set_ef_search="SET SESSION vsql_vector.ef_search = {ef_search}",
    index_name="vi",
    # The graph is InnoDB pages inside the table's own tablespace; there is no
    # separate file to glob.
    index_file_globs=(),
    metric_names={"angular": "cosine", "euclidean": "l2"},
    plan_marker="Custom index distance scan",
    ef_construction=DEFAULT_EF_CONSTRUCTION,
)


class VillageSQLDriver(MySQLFamilyDriver):
    """VillageSQL + vsql_vector. See the module docstring."""

    dialect = VILLAGESQL_DIALECT
    name = "villagesql"
    incremental_index = True
    # Left at the base class's "not verified" values: what the graph pages
    # hold of the vectors has not been read out of the pinned extension, and
    # `index_bytes` here counts the whole table, rows included.
    index_vector_format = "unknown"
    index_includes_vectors = None

    declined_workloads: Tuple[Tuple[str, str], ...] = (
        ("filtered", FILTERED_DECLINED),
        ("churn", CHURN_DECLINED),
    )

    def __init__(self, spec: ConnectionSpec,
                 dialect: Optional[MySQLDialect] = None):
        super().__init__(spec, dialect)
        self._ef_construction: Optional[int] = None
        self._ef_construction_requested: Optional[int] = None

    def _metric(self) -> Tuple[str, str, str]:
        assert self._index is not None, "create_schema must run before querying"
        return METRICS[self.dialect.metric_names[self._index.metric]]

    # -- schema ---------------------------------------------------------

    def _vector_column(self, index: IndexSpec) -> str:
        return f"v SVECTOR({index.dim}) NOT NULL"

    def create_schema(self, index: IndexSpec) -> None:
        self._index = index
        ddl = self._create_table_ddl(index, with_index=False)
        print(f"[{self.name}] {ddl}")
        self._cur.execute(ddl)

        requested = (index.ef_construction if index.ef_construction is not None
                     else self.dialect.ef_construction)
        self._ef_construction_requested = int(requested)
        self._ef_construction = effective_ef_construction(requested, index.m)
        if self._ef_construction != self._ef_construction_requested:
            print(f"[{self.name}] ef_construction {requested} exceeds the "
                  f"extension's maximum of {MAX_EF_CONSTRUCTION_FACTOR} * M "
                  f"for M={index.m}; building at {self._ef_construction}")
        modifier = self._metric()[0]
        index_ddl = (
            f"CREATE INDEX {self.dialect.index_name} ON {TABLE} "
            f"(v {modifier}) USING EXTENDED(hnsw) "
            f"WITH (M = {int(index.m)}, "
            f"ef_construction = {self._ef_construction})"
        )
        print(f"[{self.name}] {index_ddl}")
        self._cur.execute(index_ddl)

    def create_index(self, index: IndexSpec) -> None:
        # Created in create_schema, before the load: the graph is maintained
        # on every INSERT, as MHNSW's and VIDX's are.
        self._index = index

    # -- data -----------------------------------------------------------

    @staticmethod
    def _insert_batch(cur, rows: List[Tuple[Any, ...]]) -> None:
        if not rows:
            return
        values = ",".join(["(%s, %s, %s, %s)"] * len(rows))
        cur.execute(
            f"INSERT INTO {TABLE} (id, {FILTER_TAG}, {FILTER_CTAG}, v) "
            f"VALUES {values}",
            [field for row in rows for field in row])

    def _load_range(self, cur, vectors, attrs: RowAttrs, start_id: int,
                    lo: int, hi: int,
                    batch: int = LOAD_BATCH, report: bool = False) -> None:
        rows: List[Tuple[Any, ...]] = []
        total = hi - lo
        started = time.perf_counter()
        next_report = started + PROGRESS_INTERVAL_S
        for i in range(lo, hi):
            rows.append((start_id + i, *attrs.row(i),
                         to_text_bracket(vectors[i])))
            if len(rows) >= batch:
                self._insert_batch(cur, rows)
                rows = []
                now = time.perf_counter()
                if report and now >= next_report:
                    done = i - lo + 1
                    rate = done / max(now - started, 1e-9)
                    eta = (total - done) / max(rate, 1e-9)
                    print(f"[{self.name}]   {done:,}/{total:,} rows, "
                          f"{rate:,.0f} rows/s, ETA {eta / 60:.1f} min",
                          flush=True)
                    next_report = now + PROGRESS_INTERVAL_S
        self._insert_batch(cur, rows)
        cur.execute("COMMIT")

    def insert_rows(self, ids: Sequence[int], vectors: numpy.ndarray,
                    attrs: Union[RowAttrs, Sequence[int], numpy.ndarray]
                    ) -> None:
        attrs = RowAttrs.coerce(attrs)
        rows = [(int(row_id), *attrs.row(i), to_text_bracket(vectors[i]))
                for i, row_id in enumerate(ids)]
        for start in range(0, len(rows), LOAD_BATCH):
            self._insert_batch(self._cur, rows[start:start + LOAD_BATCH])
        self._cur.execute("COMMIT")

    # -- query ----------------------------------------------------------

    def _knn_sql(self, vector, k: int) -> str:
        _modifier, fn, order = self._metric()
        literal = "'" + to_text_bracket(vector) + "'"
        return (f"SELECT id FROM {TABLE} "
                f"ORDER BY {fn}(v, {literal}) {order} LIMIT {int(k)}")

    def query(self, vector, k: int) -> List[int]:
        self._cur.execute(self._knn_sql(vector, k))
        return [row[0] for row in self._cur.fetchall()]

    def query_filtered(self, vector, k: int, threshold: int,
                       column: str = FILTER_TAG) -> List[int]:
        checked_filter_column(column)
        raise NotImplementedError(FILTERED_DECLINED)

    def explain_uses_vector_index(self, vector, k: int,
                                  tag_threshold: Optional[int] = None,
                                  column: str = FILTER_TAG) -> bool:
        checked_filter_column(column)
        if tag_threshold is not None:
            print(f"[{self.name}] no filtered plan to check: {FILTERED_DECLINED}")
            return False
        try:
            self._cur.execute("EXPLAIN FORMAT=TREE " + self._knn_sql(vector, k))
            plan = " | ".join(str(c) for row in self._cur.fetchall() for c in row)
        except Exception as exc:
            print(f"[{self.name}] EXPLAIN failed: {exc}")
            return False
        # The marker names the index it scans ("... on vi"), so both are
        # checked, as the base class checks access type and key together.
        used = (self.dialect.plan_marker in plan
                and self.dialect.index_name in plan)
        if not used:
            print(f"[{self.name}] WARNING: vector index NOT used (k={k}); "
                  f"looked for {self.dialect.plan_marker!r} on "
                  f"{self.dialect.index_name!r}. Plan: {plan}")
        return used

    # -- sizing ---------------------------------------------------------

    def index_bytes(self) -> int:
        """The table's whole InnoDB footprint, NOT the graph alone.

        The HNSW graph is pages inside the table's own tablespace, beside the
        rows, so no file or catalog figure separates the two. This is
        therefore an upper bound on the index, and not comparable to the
        graph-only figures MariaDB and AliSQL report from their companion
        tables.
        """
        return self.table_bytes()

    def capabilities(self) -> Dict[str, Any]:
        caps: Dict[str, Any] = {"incremental_index": True,
                                "ef_construction_tunable": True,
                                "index_bytes_includes_table": True,
                                **self.index_format()}
        if self._ef_construction is not None:
            caps["ef_construction"] = self._ef_construction
            caps["ef_construction_requested"] = self._ef_construction_requested
        return caps
