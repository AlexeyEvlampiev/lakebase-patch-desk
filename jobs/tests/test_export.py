"""The export job's database half without a database: the batch document is
checked, a copy with a different row count gets every product, and a login
that may not mark fails the run."""

from __future__ import annotations

import json

import pytest
from patch_desk_job import (
    ExportBatch,
    mark_exported,
    parse_export_batch,
    read_export_batch,
)

PRODUCT = {"product_code": "P-1002", "name": "Orange juice 1 l", "category": "DRINKS", "unit_price": "2.49",
           "active": True, "updated_at": "2026-11-11T10:00:00+00:00", "patch_id": "p1",
           "approved_by": "ann@example.com", "approved_at": "2026-11-11T10:00:00+00:00"}


def batch(patch_ids=("p1",), products=(PRODUCT,), count=25) -> dict:
    return {"patch_ids": list(patch_ids), "products": list(products), "product_count": count}


class FakeConn:
    """Answers each SQL text from a table; records what ran."""

    def __init__(self, answers: dict[str, object]):
        self.answers, self.ran = answers, []

    def run(self, sql: str, **params):
        self.ran.append((sql, params))
        return [[self.answers[sql]]]


def test_parse_reads_the_three_parts():
    got = parse_export_batch(batch())
    assert got == ExportBatch(("p1",), (PRODUCT,), 25)


def test_parse_accepts_a_json_string():
    assert parse_export_batch(json.dumps(batch(patch_ids=(), products=()))) == ExportBatch((), (), 25)


@pytest.mark.parametrize("value", [
    None,
    [],
    {"patch_ids": ["p1"], "products": []},                             # no count
    {"patch_ids": "p1", "products": [], "product_count": 1},           # ids not a list
    {"patch_ids": [1], "products": [], "product_count": 1},            # id not text
    {"patch_ids": [], "products": [{"name": "x"}], "product_count": 1},  # product without a code
    {"patch_ids": [], "products": [], "product_count": True},
    {"patch_ids": [], "products": [], "product_count": -1},
])
def test_parse_refuses_another_shape(value):
    with pytest.raises((RuntimeError, TypeError)):
        parse_export_batch(value)


PARTIAL = "SELECT api.job_patch_export_batch(false)"
FULL = "SELECT api.job_patch_export_batch(true)"


def test_same_row_count_reads_only_the_patched_products():
    conn = FakeConn({PARTIAL: batch(count=25)})
    got, full = read_export_batch(conn, delta_count=25)
    assert (got.patch_ids, full) == (("p1",), False)
    assert [sql for sql, _ in conn.ran] == [PARTIAL]


@pytest.mark.parametrize("delta_count", [0, 24, 26])
def test_another_row_count_copies_every_product(delta_count):
    every = batch(products=[PRODUCT, {**PRODUCT, "product_code": "P-1003", "patch_id": None}], count=25)
    conn = FakeConn({PARTIAL: batch(count=25), FULL: every})
    got, full = read_export_batch(conn, delta_count=delta_count)
    assert full and len(got.products) == 2
    assert [sql for sql, _ in conn.ran] == [PARTIAL, FULL]


MARK = "SELECT api.job_patch_mark_exported(CAST(:ids AS uuid[]))"


def test_mark_returns_the_count_and_sends_the_ids():
    conn = FakeConn({MARK: 2})
    assert mark_exported(conn, ("p1", "p2")) == 2
    assert conn.ran == [(MARK, {"ids": ["p1", "p2"]})]


def test_mark_by_an_unregistered_login_fails_the_run():
    with pytest.raises(RuntimeError, match="no registered service principal"):
        mark_exported(FakeConn({MARK: None}), ("p1",))
