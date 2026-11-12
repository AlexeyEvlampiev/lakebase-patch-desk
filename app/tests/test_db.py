import datetime

import pytest

import db


def test_token_comes_from_the_forwarded_header():
    assert db.user_token({"x-forwarded-access-token": "user-token"}) == "user-token"


@pytest.mark.parametrize("headers", [{}, {"x-forwarded-access-token": ""}, {"authorization": "Bearer x"}])
def test_no_forwarded_token_means_not_in_app(headers):
    with pytest.raises(db.NotInApp):
        db.user_token(headers)


def test_client_uses_the_user_token_even_with_app_credentials_in_the_environment(monkeypatch):
    # The Apps runtime puts the app principal's OAuth client in the environment.
    # No network in tests: skip the SDK's host-metadata probe, and no local
    # config file.
    from databricks.sdk.config import Config

    monkeypatch.setattr(Config, "_resolve_host_metadata", lambda self: None)
    monkeypatch.setenv("DATABRICKS_CONFIG_FILE", "/nonexistent/.databrickscfg")
    monkeypatch.setenv("DATABRICKS_HOST", "https://example.invalid")
    monkeypatch.setenv("DATABRICKS_CLIENT_ID", "app-principal")
    monkeypatch.setenv("DATABRICKS_CLIENT_SECRET", "app-secret")
    w = db.user_client("user-token")
    assert w.config.auth_type == "pat"
    assert w.config.token == "user-token"
    assert w.config.authenticate()["Authorization"] == "Bearer user-token"


def test_login_repr_hides_the_password():
    login = db.Login(host="h", user="u", password="secret-token", database="d")
    assert "secret-token" not in repr(login)
    assert "secret-token" not in str(login)


def test_login_refused_codes():
    import pg8000.native

    assert db.is_login_refused(pg8000.native.DatabaseError({"C": "28000", "M": "no role"}))
    assert db.is_login_refused(pg8000.native.DatabaseError({"C": "28P01", "M": "bad password"}))
    # no CONNECT on the database: the person is not (or no longer) in a patch desk group
    assert db.is_login_refused(pg8000.native.DatabaseError({"C": "42501", "M": "permission denied for database"}))
    assert not db.is_login_refused(pg8000.native.DatabaseError({"C": "42P01", "M": "no such table"}))


class FakeMe:
    def __init__(self, error=None):
        self.error = error

    def me(self):
        if self.error:
            raise self.error
        return type("User", (), {"user_name": "token.owner@example.com"})()


class FakeClient:
    def __init__(self, error=None):
        self.current_user = FakeMe(error)


def test_user_name_comes_from_the_token_when_the_scope_allows():
    assert db.user_name(FakeClient(), "header@example.com") == "token.owner@example.com"


def test_user_name_falls_back_to_the_forwarded_email_when_me_is_refused():
    from databricks.sdk.errors import PermissionDenied

    assert db.user_name(FakeClient(PermissionDenied("scope")), "header@example.com") == "header@example.com"
    with pytest.raises(RuntimeError):
        db.user_name(FakeClient(PermissionDenied("scope")), None)


def test_refusal_reason_drops_the_sdk_debug_details():
    raw = (
        "This API is disabled for users without the workspace-access entitlement. Contact your administrator "
        "for more information. [ReqId: 6183bfc3]. Config: host=https://example.invalid, account_id=a, "
        "client_id=c, client_secret=, auth_type=pat. Env: DATABRICKS_HOST"
    )
    reason = db.refusal_reason(Exception(raw))
    assert reason.startswith("This API is disabled for users without the workspace-access entitlement.")
    for leaked in ("Config:", "host=", "account_id", "client_id", "ReqId", "Env:"):
        assert leaked not in reason


def test_the_client_has_time_limits(monkeypatch):
    from databricks.sdk.config import Config

    monkeypatch.setattr(Config, "_resolve_host_metadata", lambda self: None)
    monkeypatch.setenv("DATABRICKS_CONFIG_FILE", "/nonexistent/.databrickscfg")
    w = db.user_client("user-token", host="https://example.invalid")
    assert w.config.http_timeout_seconds == db.HTTP_TIMEOUT_S
    assert w.config.retry_timeout_seconds == db.RETRY_TIMEOUT_S


def test_a_network_failure_while_logging_in_is_unavailable_not_a_crash():
    class Stalled:
        class current_user:
            @staticmethod
            def me():
                raise TimeoutError("read timed out")

    with pytest.raises(db.Unavailable):
        db.user_login(Stalled(), "projects/p/branches/b/endpoints/e", "d")


POLICY = {"transaction_isolation": "read committed", "transaction_read_only": False, "transaction_deferrable": False}


def test_the_transaction_follows_the_route_policy():
    assert db.begin_sql(POLICY) == "START TRANSACTION ISOLATION LEVEL READ COMMITTED READ WRITE"
    strict = {"transaction_isolation": "serializable", "transaction_read_only": True, "transaction_deferrable": True}
    assert db.begin_sql(strict) == "START TRANSACTION ISOLATION LEVEL SERIALIZABLE READ ONLY DEFERRABLE"
    assert db.begin_sql(None) == "START TRANSACTION"  # no such route: rest_invoke answers 404
    no_floor = {**POLICY, "transaction_isolation": None}
    assert db.begin_sql(no_floor) == "START TRANSACTION READ WRITE"  # the server's default level


def test_a_policy_outside_the_known_levels_never_reaches_sql():
    with pytest.raises(ValueError):
        db.begin_sql({**POLICY, "transaction_isolation": "read committed; DROP TABLE x"})


def test_timestamps_become_datetimes():
    row = db.with_times({"submitted_at": "2026-11-11T10:15:00.123456+00:00", "decided_at": None, "file_name": "a"})
    assert row["submitted_at"] == datetime.datetime(2026, 11, 11, 10, 15, 0, 123456, tzinfo=datetime.UTC)
    assert row["decided_at"] is None and row["file_name"] == "a"


def test_only_a_uuid_reaches_a_route_path():
    pid = "6f1c2a8e-1b2c-4d3e-8f40-0a1b2c3d4e5f"
    assert db.patch_path(pid, "approve") == f"/patches/{pid}/approve"
    with pytest.raises(ValueError):
        db.patch_path("../patch-desk/me", "approve")


class ScriptedConn:
    """A pg8000 connection that answers from a script; records each statement."""

    def __init__(self, answers):
        self.answers = list(answers)
        self.sql = []
        self.params = []
        self.columns = []

    def run(self, sql, **params):
        self.sql.append(" ".join(sql.split()))
        self.params.append(params)
        answer = self.answers.pop(0) if self.answers else ([], [])
        if isinstance(answer, Exception):
            raise answer
        names, rows = answer
        self.columns = [{"name": n} for n in names]
        return rows

    def close(self):
        pass


def scripted_desk(conn):
    desk = db.Desk.__new__(db.Desk)
    desk._conn, desk._policies, desk._me, desk.user = conn, {}, None, "someone@example.com"
    desk.connect = lambda: (_ for _ in ()).throw(AssertionError("no reconnect expected"))
    return desk


POLICY_ROW = (list(POLICY), [list(POLICY.values())])
OK = (["status_code", "content"], [[200, '{"items": [], "total": 0}']])


def test_a_call_opens_the_policy_transaction_then_invokes_then_commits():
    conn = ScriptedConn([POLICY_ROW, ([], []), OK, ([], [])])
    assert scripted_desk(conn).history() == []
    assert [s.split(" ")[0] for s in conn.sql] == ["SELECT", "START", "SELECT", "COMMIT"]
    assert "api.rest_route_policy" in conn.sql[0] and "api.rest_invoke" in conn.sql[2]


def test_a_serialization_failure_runs_the_call_again_as_a_new_transaction():
    import pg8000.native

    conflict = pg8000.native.DatabaseError({"C": "40001", "M": "could not serialize access"})
    conn = ScriptedConn([POLICY_ROW, ([], []), conflict, ([], []), ([], []), OK, ([], [])])
    assert scripted_desk(conn).history() == []
    assert [s.split(" ")[0] for s in conn.sql] == ["SELECT", "START", "SELECT", "ROLLBACK", "START", "SELECT", "COMMIT"]


def test_another_database_error_is_rolled_back_and_raised():
    import pg8000.native

    conn = ScriptedConn([POLICY_ROW, ([], []), pg8000.native.DatabaseError({"C": "XX000", "M": "boom"})])
    with pytest.raises(pg8000.native.DatabaseError):
        scripted_desk(conn).history()
    assert conn.sql[-1] == "ROLLBACK"


def test_a_lost_connection_during_a_write_is_never_repeated():
    import pg8000.native

    conn = ScriptedConn([POLICY_ROW, ([], []), pg8000.native.InterfaceError("network")])
    with pytest.raises(db.ConnectionLost):
        scripted_desk(conn).approve("6f1c2a8e-1b2c-4d3e-8f40-0a1b2c3d4e5f", None)
    assert sum("rest_invoke" in s for s in conn.sql) == 1


def answer(status, body):
    import json

    return (["status_code", "content"], [[status, json.dumps(body)]])


def test_an_unmapped_login_has_no_access():
    conn = ScriptedConn([POLICY_ROW, ([], []), answer(401, {"code": "pgmi.unauthenticated"}), ([], [])])
    desk = scripted_desk(conn)
    assert desk.has_access() is False


def test_a_login_without_the_caller_role_has_no_access():
    import pg8000.native

    conn = ScriptedConn([pg8000.native.DatabaseError({"C": "42501", "M": "permission denied for schema api"})])
    assert scripted_desk(conn).has_access() is False


def test_who_am_i_decides_access_and_the_review_page(capsys):
    me = {"actor_kind": "human", "name": "ann@example.com", "can_submit": True, "can_decide": False}
    conn = ScriptedConn([POLICY_ROW, ([], []), answer(200, me), ([], [])])
    desk = scripted_desk(conn)
    assert (desk.has_access(), desk.is_approver()) == (True, False)
    assert sum("rest_invoke" in s for s in conn.sql) == 1  # read once per session
    logged = capsys.readouterr().out
    assert "the database acts as ann, actor kind human" in logged
    assert "@" not in logged


def test_a_decision_answers_the_refusal_code():
    pid = "6f1c2a8e-1b2c-4d3e-8f40-0a1b2c3d4e5f"
    for status, body, code in [
        (200, {"state": "approved"}, None),
        (409, {"code": "core.patch.stale"}, "core.patch.stale"),
        (403, {"code": "pgmi.forbidden"}, "core.patch.not_approver"),
    ]:
        conn = ScriptedConn([POLICY_ROW, ([], []), answer(status, body), ([], [])])
        assert scripted_desk(conn).approve(pid, "ok") == code
        assert conn.params[2] == {"method": "POST", "url": f"/patches/{pid}/approve", "body": '{"note": "ok"}'}


def test_a_decision_without_a_note_sends_an_empty_object():
    conn = ScriptedConn([POLICY_ROW, ([], []), answer(200, {}), ([], [])])
    scripted_desk(conn).reject("6f1c2a8e-1b2c-4d3e-8f40-0a1b2c3d4e5f", "")
    assert conn.params[2]["body"] == "{}"
