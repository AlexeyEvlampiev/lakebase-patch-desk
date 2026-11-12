"""provision-principals against a real database deployed from db/.

Runs only with PATCH_DESK_DB_URL set to a postgresql:// URL of such a
database, as the deploy login (db/local-check.sh sets it: a non-superuser
with CREATEROLE, CREATEDB and BYPASSRLS, as on Lakebase). Without it the
tests skip. People are local login roles with a password, so each one connects
as themselves; on Lakebase databricks_create_role makes them instead.

db/local-check.sh runs `-k fresh` after the first deploy and `-k redeployed`
after the second deploy on top of it.
"""

from __future__ import annotations

import json
import os
import urllib.parse

import pytest
from patch_desk_job import create_login_roles, provision_principals_in

URL = os.environ.get("PATCH_DESK_DB_URL", "")
pytestmark = pytest.mark.skipif(not URL, reason="PATCH_DESK_DB_URL is not set")

UMA, ANN, BOB, CID = (f"pp-{n}@example.com" for n in ("uma", "ann", "bob", "cid"))
PASSWORD = "local"
WHOAMI = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "patch.whoami", "params": {}})


def connect(user: str | None = None):
    import pg8000.native

    url = urllib.parse.urlsplit(URL)
    return pg8000.native.Connection(
        user=user or urllib.parse.unquote(url.username), password=PASSWORD if user else urllib.parse.unquote(url.password),
        host=url.hostname, port=url.port or 5432, database=url.path.lstrip("/"))


@pytest.fixture
def deployer():
    conn = connect()
    for person in (UMA, ANN, BOB, CID):
        if not conn.run("SELECT FROM pg_roles WHERE rolname = :r", r=person):
            conn.run(f'CREATE ROLE "{person}" LOGIN PASSWORD \'{PASSWORD}\'')
    yield conn
    conn.close()


def whoami(person: str) -> dict:
    """The patch desk's who-am-I method, called over RPC by the person's own login."""
    conn = connect(person)
    try:
        status, content = conn.run(
            """SELECT r.status_code, r.content
               FROM api.rpc_invoke(api.rpc_resolve('patch.whoami'), ''::extensions.hstore,
                                   convert_to(:body, 'UTF8')) r""", body=WHOAMI)[0]
    finally:
        conn.close()
    assert status == 200, content
    return json.loads(bytes(content))["result"]


def cannot_connect(person: str) -> bool:
    import pg8000.exceptions

    try:
        connect(person).close()
    except pg8000.exceptions.DatabaseError as e:
        return e.args[0].get("C") == "42501"
    return False


def kernel_rows(conn, sql: str, **params) -> list:
    database = conn.run("SELECT current_database()")[0][0]
    conn.run(f'SET ROLE "{database}_kernel"')
    try:
        return conn.run(sql, **params)
    finally:
        conn.run("RESET ROLE")


def current_roles(conn, person: str) -> set[str]:
    return {row[0] for row in kernel_rows(
        conn, """SELECT ra.role_id FROM membership.database_login dl
                 JOIN membership.organization o ON o.slug = 'demo'
                 JOIN membership.organization_membership m
                   ON m.organization_object_id = o.object_id AND m.principal_object_id = dl.principal_object_id
                  AND upper_inf(m.valid_during)
                 JOIN membership.role_assignment ra ON ra.membership_object_id = m.object_id AND upper_inf(ra.valid_during)
                 WHERE dl.database_role = :login""", login=person)}


def test_fresh_database_provisioning(deployer):
    assert not kernel_rows(deployer, "SELECT FROM membership.organization WHERE slug = 'demo'"), \
        "run this on a freshly deployed database"

    # No approver yet: no organization, nobody mapped, nothing granted.
    assert provision_principals_in(deployer, {UMA}, set()) == 0
    assert not kernel_rows(deployer, "SELECT FROM membership.organization WHERE slug = 'demo'")
    assert cannot_connect(UMA)

    # One uploader, two approvers: the first approver by user name owns the organization.
    assert provision_principals_in(deployer, {UMA}, {BOB, ANN}) > 0
    assert current_roles(deployer, ANN) == {"org.owner", "patch.approver"}
    assert current_roles(deployer, BOB) == {"patch.approver"}
    assert current_roles(deployer, UMA) == {"patch.uploader"}
    uma = whoami(UMA)
    assert (uma["actor_kind"], uma["can_submit"], uma["can_decide"]) == ("human", True, False)
    bob = whoami(BOB)
    assert (bob["actor_kind"], bob["can_submit"], bob["can_decide"]) == ("human", True, True)
    assert uma["principal_id"] != bob["principal_id"]
    assert provision_principals_in(deployer, {UMA}, {BOB, ANN}) == 0

    # Bob moves to the uploaders, Uma and Ann (the owner) leave, Cid joins.
    assert provision_principals_in(deployer, {BOB}, {CID}) > 0
    assert current_roles(deployer, BOB) == {"patch.uploader"}
    assert whoami(BOB)["can_decide"] is False
    assert whoami(CID)["can_decide"] is True
    assert cannot_connect(UMA)
    assert current_roles(deployer, UMA) == set()
    assert cannot_connect(ANN)
    assert current_roles(deployer, ANN) == {"org.owner", "patch.approver"}, "the owner keeps the membership"
    assert provision_principals_in(deployer, {BOB}, {CID}) == 0

    # Roles that exist are not made again, and the provider extension that
    # makes them never lands in this database.
    assert create_login_roles(deployer, [UMA, ANN, BOB, CID]) == 0
    assert not deployer.run("SELECT FROM pg_extension WHERE extname = 'databricks_auth'")

    # The deploy login names no one; it is registered once as the export
    # job's service principal (attribution only).
    assert not kernel_rows(deployer, "SELECT FROM membership.database_login WHERE database_role = session_user")
    assert kernel_rows(deployer, "SELECT id FROM membership.service_principal WHERE database_role = session_user") \
        == [["service.patch_export"]]


def test_redeployed_database_keeps_everyone(deployer):
    assert provision_principals_in(deployer, {BOB}, {CID}) == 0
    bob, cid = whoami(BOB), whoami(CID)
    assert (bob["actor_kind"], bob["can_decide"], cid["can_decide"]) == ("human", False, True)
    assert cannot_connect(UMA) and cannot_connect(ANN)
