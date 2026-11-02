"""VillageSQL + vsql_vector: the driver behaviours that keep it honest.

No server is started here. What is pinned is what fails SILENTLY against a
real server: a bound query vector that the optimizer does not route to the
custom index (exact answers, slowly, indistinguishable from a good index), a
load that sends one statement per row, and a filtered or churn measurement of
something the extension does not do.
"""

from __future__ import annotations

import os
import sys
from typing import Any, List

import numpy
import pytest

VB_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, VB_ROOT)

from harness.drivers.base import ConnectionSpec, IndexSpec, RowAttrs  # noqa: E402
from harness.drivers import villagesql as vs  # noqa: E402


class Cursor:
    def __init__(self, explain=None):
        self.statements: List[str] = []
        self.params: List[Any] = []
        self.many: List[str] = []
        self.explain = explain or []
        self._rows: List[tuple] = []

    def execute(self, sql, params=None):
        self.statements.append(sql)
        self.params.append(params)
        self._rows = list(self.explain) if sql.startswith("EXPLAIN") else []

    def executemany(self, sql, rows):
        self.many.append(sql)

    def fetchall(self):
        rows, self._rows = self._rows, []
        return rows

    def fetchone(self):
        rows = self.fetchall()
        return rows[0] if rows else None


def driver(m=16, metric="euclidean", dim=4, ef_construction=200, **cursor):
    d = vs.VillageSQLDriver(ConnectionSpec(host="h", port=1))
    d._cur = Cursor(**cursor)
    d._index = IndexSpec(dim=dim, m=m, metric=metric,
                         ef_construction=ef_construction)
    return d


def attrs(n):
    return RowAttrs(tag=numpy.arange(n) % 100, ctag=numpy.arange(n) % 7)


class TestSchema:
    def test_the_column_is_svector_and_the_index_a_separate_statement(self):
        d = driver(dim=784)
        d.create_schema(d._index)
        table, index = d._cur.statements
        assert "v SVECTOR(784) NOT NULL" in table
        assert "VECTOR INDEX" not in table and "USING EXTENDED" not in table
        assert index == ("CREATE INDEX vi ON t1 (v hnsw_l2) USING EXTENDED(hnsw) "
                         "WITH (M = 16, ef_construction = 200)")

    def test_the_metric_picks_the_modifier(self):
        d = driver(metric="angular")
        d.create_schema(d._index)
        assert "(v hnsw_cosine)" in d._cur.statements[1]

    def test_ef_construction_is_clamped_to_the_extensions_ceiling(self):
        """vsql-vector refuses ef_construction > 32 * M at CREATE INDEX, so
        M=6 at 200 would fail the build. Both values are recorded."""
        d = driver(m=6, ef_construction=200)
        d.create_schema(d._index)
        assert "ef_construction = 192" in d._cur.statements[1]
        caps = d.capabilities()
        assert caps["ef_construction"] == 192
        assert caps["ef_construction_requested"] == 200


class TestLoad:
    def test_one_statement_per_batch_not_per_row(self):
        """executemany with a text parameter is one INSERT per row in
        Connector/Python; the driver builds the multi-row VALUES itself."""
        n = 2 * vs.LOAD_BATCH + 3
        d = driver()
        cur = d._cur
        d._load_range(cur, numpy.ones((n, 4), dtype="<f4"), attrs(n), 0, 0, n)
        inserts = [s for s in cur.statements if s.startswith("INSERT")]
        assert len(inserts) == 3
        assert cur.many == []
        assert "(id, tag, ctag, v)" in inserts[0]
        first = cur.params[0]
        assert len(first) == 4 * vs.LOAD_BATCH
        assert first[:4] == [0, 0, 0, "[1.0,1.0,1.0,1.0]"]
        assert cur.statements[-1] == "COMMIT"

    def test_the_text_literal_keeps_float32_exact(self):
        v = numpy.array([0.1, -2.5, 3e-8], dtype="<f4")
        parsed = numpy.array(vs.to_text_bracket(v)[1:-1].split(","),
                             dtype="<f4")
        assert numpy.array_equal(parsed, v)


class TestQuery:
    def test_the_query_vector_is_inlined_not_bound(self):
        """The extension serves the KNN shape only with a string literal; a
        bound %s fails with ERROR 3219."""
        d = driver()
        d.query(numpy.zeros(4, dtype="<f4"), 10)
        sql, params = d._cur.statements[-1], d._cur.params[-1]
        assert params is None
        assert "%s" not in sql
        assert sql == ("SELECT id FROM t1 ORDER BY "
                       "L2_DISTANCE(v, '[0.0,0.0,0.0,0.0]') ASC LIMIT 10")

    def test_ef_search_is_set_per_session(self):
        """A session variable at this pin: SET GLOBAL would change only the
        default for connections opened afterwards, and every already-open
        concurrency client would keep searching at the old width."""
        d = driver()
        d.set_ef_search(80)
        assert d._cur.statements[-1] == \
            "SET SESSION vsql_vector.ef_search = 80"

    def test_the_plan_is_read_as_a_tree(self):
        d = driver(explain=[("-> Limit: 10 row(s)\n"
                             "    -> Custom index distance scan on vi",)])
        assert d.explain_uses_vector_index(numpy.zeros(4), 10) is True
        assert d._cur.statements[-1].startswith("EXPLAIN FORMAT=TREE ")

    def test_a_full_scan_is_not_the_index(self):
        d = driver(explain=[("-> Limit: 10 row(s)\n    -> Sort: ...\n"
                             "        -> Table scan on t1",)])
        assert d.explain_uses_vector_index(numpy.zeros(4), 10) is False


class TestDeclined:
    def test_filtered_and_churn_are_declined_with_reasons(self):
        declined = dict(vs.VillageSQLDriver.declined_workloads)
        assert set(declined) == {"filtered", "churn"}
        assert all(len(reason) > 40 for reason in declined.values())

    def test_a_filtered_query_raises_rather_than_answering_unfiltered(self):
        with pytest.raises(NotImplementedError):
            driver().query_filtered(numpy.zeros(4), 10, 50)


class TestAnnModule:
    def test_both_march_readers_know_the_image(self):
        """One reader per measurement path; an engine missing from either
        records `march: unknown`, the field that exists to catch a mixed
        build."""
        for rel in ("harness/main.py",
                    "overlay/ann-benchmarks/ann_benchmarks/vb_mysql.py"):
            with open(os.path.join(VB_ROOT, rel)) as fh:
                assert "/opt/villagesql/.march" in fh.read(), rel

    def test_the_module_inlines_the_query_vector_on_every_path(self):
        """`query`, `batch_query`, the warm-up and the plan check must all
        build the routed shape; a bound %s fails with ERROR 3219."""
        with open(os.path.join(VB_ROOT, "overlay", "ann-benchmarks",
                               "ann_benchmarks", "algorithms", "villagesql",
                               "module.py")) as fh:
            source = fh.read()
        assert "_query_sql(" not in source
        assert source.count("self._knn_sql(") >= 4
        assert '"EXPLAIN FORMAT=TREE "' in source
        # ef_search is per session, so the batch workers' connections must
        # set it or they search at the default width.
        worker = source.split("def worker")[1].split("chunks =")[0]
        assert "self.dialect.set_ef_search" in worker
