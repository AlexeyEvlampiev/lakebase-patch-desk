"""db.Desk against a real database deployed from db/, people as their own logins.

Runs only with PATCH_DESK_DB_URL set to a postgresql:// URL of such a
database, as the deploy login, after the provisioning test's redeployed phase
(jobs/tests/test_provision_principals_db.py): Bob is mapped as an uploader,
Cid as an approver, Uma lost CONNECT. db/local-check.sh runs it there.
Without the URL the tests skip.

Only the Databricks part of the login is replaced: the person's role and a
local password instead of generate_database_credential. Everything after
that is the app's own code over the REST routes.
"""

from __future__ import annotations

import datetime
import os
import types
import urllib.parse
from decimal import Decimal

import pytest

import db
import messages

URL = os.environ.get("PATCH_DESK_DB_URL", "")
pytestmark = pytest.mark.skipif(not URL, reason="PATCH_DESK_DB_URL is not set")

UMA, BOB, CID = (f"pp-{n}@example.com" for n in ("uma", "bob", "cid"))
PASSWORD = "local"
PRODUCT = "P-1004"


def deployer():
    import pg8000.native

    url = urllib.parse.urlsplit(URL)
    return pg8000.native.Connection(
        user=urllib.parse.unquote(url.username), password=urllib.parse.unquote(url.password),
        host=url.hostname, port=url.port or 5432, database=url.path.lstrip("/"))


@pytest.fixture
def desk_for(monkeypatch):
    """desk_for(person): a db.Desk logged in as that person's own role."""
    url = urllib.parse.urlsplit(URL)
    monkeypatch.setattr(db, "user_client", lambda token: None)
    monkeypatch.setattr(db, "PORT", url.port or 5432)
    monkeypatch.setattr(
        db, "user_login",
        lambda w, endpoint, database, email=None: db.Login(host=url.hostname, user=email, password=PASSWORD,
                                                           database=database))
    # local server without TLS; only db's reference, pg8000 keeps the real ssl module
    monkeypatch.setattr(db, "ssl", types.SimpleNamespace(create_default_context=lambda: None))
    opened = []

    def make(person: str) -> db.Desk:
        desk = db.Desk("unused", forwarded_email=person, endpoint="local", database=url.path.lstrip("/"))
        opened.append(desk)
        return desk

    yield make
    for desk in opened:
        desk.close()


def price_now() -> Decimal:
    conn = deployer()
    try:
        return conn.run("SELECT unit_price FROM core.product WHERE product_code = :c", c=PRODUCT)[0][0]
    finally:
        conn.close()


def line(new_value: str, product: str = PRODUCT) -> dict[str, object]:
    return {"line_no": 2, "product_code": product, "field": "unit_price", "new_value": new_value, "reason": "price list"}


def test_a_login_without_connect_has_no_access(desk_for):
    with pytest.raises(db.NoAccess):
        desk_for(UMA).connect()


def test_uploader_submits_and_approver_decides_each_as_themselves(desk_for):
    bob, cid = desk_for(BOB), desk_for(CID)
    assert (bob.has_access(), bob.is_approver()) == (True, False)
    assert (cid.has_access(), cid.is_approver()) == (True, True)
    me = bob.whoami()
    assert (me["actor_kind"], me["name"]) == ("human", BOB)
    assert cid.whoami()["principal_id"] != me["principal_id"]

    # Bob submits a clean file: pending, his, with its lines.
    new_price = str(price_now() + 1)
    patch = bob.submit_patch("prices.xlsx", [line(new_price)])
    assert patch["state"] == "pending" and patch["submitted_by"] == BOB
    assert isinstance(patch["submitted_at"], datetime.datetime)
    assert [(r["product_code"], r["new_value"], r["problem"]) for r in bob.patch_lines(patch["patch_id"])] == [
        (PRODUCT, new_price, None)
    ]
    mine = bob.my_patches()
    assert mine[0]["patch_id"] == patch["patch_id"]
    assert isinstance(mine[0]["submitted_at"], datetime.datetime)

    # A line with a problem is stored as invalid, its code has a message;
    # a file without lines is refused.
    bad = bob.submit_patch("bad.xlsx", [line("1.00", product="NO-SUCH")])
    assert bad["state"] == "invalid"
    assert bob.patch_lines(bad["patch_id"])[0]["problem"] in messages.PROBLEMS
    assert bob.submit_patch("empty.xlsx", []) is None

    # Bob may not decide, not even his own.
    assert bob.approve(patch["patch_id"], None) == "core.patch.not_approver"
    assert bob.reject(patch["patch_id"], None) == "core.patch.not_approver"

    # The database sees each person's own login, never a shared one.
    conn = deployer()
    try:
        seen = {r[0] for r in conn.run(
            "SELECT usename FROM pg_stat_activity WHERE datname = current_database() AND application_name = 'patch-desk'")}
    finally:
        conn.close()
    assert seen == {BOB, CID}

    # Cid sees it pending, not his own, and approves it once.
    pending = {p["patch_id"]: p for p in cid.pending_patches()}
    assert pending[patch["patch_id"]]["own"] is False
    assert pending[patch["patch_id"]]["approve_problem"] is None
    assert cid.approve(patch["patch_id"], "fine") is None
    assert cid.approve(patch["patch_id"], None) == "core.patch.not_pending"
    assert price_now() == Decimal(new_price)

    # The history names who did what.
    events = [(e["event"], e["actor"]) for e in cid.history() if e["patch_id"] == patch["patch_id"]]
    assert events == [("approved", CID), ("submitted", BOB)]
    assert isinstance(cid.history()[0]["at"], datetime.datetime)
    decided = {p["patch_id"]: p for p in bob.my_patches()}[patch["patch_id"]]
    assert (decided["state"], decided["decided_by"], decided["decision_note"]) == ("approved", CID, "fine")


def test_an_approver_cannot_decide_their_own_or_an_unknown_patch(desk_for):
    cid = desk_for(CID)
    own = cid.submit_patch("own.xlsx", [line(str(price_now() + 2))])
    assert cid.approve(own["patch_id"], None) == "core.patch.own_patch"
    assert cid.reject(own["patch_id"], None) == "core.patch.own_patch"
    assert cid.approve("00000000-0000-4000-8000-000000000000", None) == "core.patch.not_found"
    assert cid.patch_lines("00000000-0000-4000-8000-000000000000") == []
    assert desk_for(BOB).reject(own["patch_id"], None) == "core.patch.not_approver"
