"""The patch desk's database connection, as the signed-in user.

Databricks Apps forwards the user's token in the x-forwarded-access-token
header. With it the app asks Lakebase for a one-hour database login for that
user, and connects as the user's own Postgres role (named by their email) to
the database lakebase_apps. The database maps that login to the person's
principal (db/README.md), so every call acts as them; row-level security
does the filtering. The app's own service principal is never used: its
credentials are in the environment, so the client is built from the header
token alone.

Every patch desk call is one REST route of the database (db/README.md),
called the way a gateway calls it: api.rest_route_policy for the
transaction to open, then api.rest_invoke in that transaction. The app has
no web server; Streamlit calls the database directly.

One connection per Streamlit session, kept in st.session_state by the
caller. Never cache a Desk with st.cache_resource or st.cache_data: those
are shared by every user of the app.
"""

from __future__ import annotations

import datetime
import json
import os
import ssl
import uuid
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

import pg8000.native
from databricks.sdk import WorkspaceClient
from databricks.sdk.config import Config
from databricks.sdk.errors import PermissionDenied, Unauthenticated

TOKEN_HEADER = "x-forwarded-access-token"
EMAIL_HEADER = "x-forwarded-email"
PORT = 5432
# Time limits, so a stalled network or a waking database shows a message
# instead of a page that spins forever. Lakebase compute resumes from
# scale-to-zero within seconds; queries here are small.
HTTP_TIMEOUT_S = 30
RETRY_TIMEOUT_S = 60
DB_TIMEOUT_S = 60
# Postgres refused the login: invalid authorization, wrong password, or no
# CONNECT on the database (db/deploy/bootstrap.sql revokes it from PUBLIC; provisioning
# grants it to the people in the patch desk groups).
LOGIN_REFUSED = {"28000", "28P01", "42501"}
DATABASE = "lakebase_apps"
# A serialization failure or deadlock rolled the whole transaction back, so
# the call runs again as a new transaction (gateways/PROTOCOL.md of the
# template).
RETRYABLE = {"40001", "40P01"}
ATTEMPTS = 3
# The only transaction characteristics the policy may name; anything else is
# refused before it reaches SQL.
ISOLATION_LEVELS = {"read committed", "repeatable read", "serializable"}
PAGE_LIMIT = 500  # the largest page the list routes answer
HISTORY_LIMIT = 200
TIMESTAMPS = ("submitted_at", "decided_at", "exported_at", "at")


class NotInApp(Exception):
    """No forwarded token: the app was not opened through Databricks."""


class SignInExpired(Exception):
    """The user's Databricks token no longer works; a reload brings a new one."""


class ConnectionLost(Exception):
    """The connection dropped during a write; it may or may not have committed."""


class Unavailable(Exception):
    """Databricks or the database did not answer in time; trying again later may work."""


class DatabricksRefused(Exception):
    """Databricks refused the user a database login (for example a missing
    workspace entitlement). The message is Databricks' own, without tokens."""


class NoAccess(Exception):
    """The user has no database login, no CONNECT, or no caller role."""


class DatabaseAnswer(Exception):
    """The database answered a status the app does not expect; never shown
    with its body, which may name people."""


def user_token(headers: Mapping[str, str]) -> str:
    """The user's token, from the forwarded header and nowhere else."""
    token = headers.get(TOKEN_HEADER)
    if not token:
        raise NotInApp
    return token


def user_client(token: str, host: str | None = None) -> WorkspaceClient:
    """A workspace client that acts as the user. auth_type="pat" makes the
    SDK use exactly this token, not the app principal's client ID and secret
    from the environment."""
    return WorkspaceClient(
        config=Config(
            host=host or os.environ["DATABRICKS_HOST"],
            token=token,
            auth_type="pat",
            http_timeout_seconds=HTTP_TIMEOUT_S,
            retry_timeout_seconds=RETRY_TIMEOUT_S,
        )
    )


@dataclass(frozen=True)
class Login:
    host: str
    user: str
    password: str  # a one-hour database token; never print it
    database: str

    def __repr__(self) -> str:  # keeps the token out of logs and tracebacks
        return f"Login(host={self.host!r}, user={self.user!r}, database={self.database!r})"


def user_name(w: WorkspaceClient, forwarded_email: str | None) -> str:
    """Who the token belongs to. current_user.me() answers exactly, but needs
    the iam.current-user:read scope, which an app may not request next to
    postgres; when it is refused, the X-Forwarded-Email header the Apps
    proxy sets is used. The role name must match the Databricks user name
    (provision_principals uses it), or Postgres refuses the login."""
    try:
        name = w.current_user.me().user_name
        print("identity: current_user.me()", flush=True)
    except PermissionDenied:
        name = forwarded_email
        print("identity: X-Forwarded-Email header (current_user.me() refused)", flush=True)
    if not name:
        raise RuntimeError("no user name for the signed-in user")
    return name


def user_login(w: WorkspaceClient, endpoint: str, database: str, forwarded_email: str | None = None) -> Login:
    """The user's database login: their user name (email) as the role, a
    fresh database token as the password, and the endpoint's direct host
    (not the pooler, which serves only password roles)."""
    try:
        user = user_name(w, forwarded_email)
        host = w.postgres.get_endpoint(name=endpoint).status.hosts.host
        password = w.postgres.generate_database_credential(endpoint=endpoint).token
    except Unauthenticated as e:
        raise SignInExpired from e
    except (TimeoutError, OSError) as e:  # requests' errors are OSErrors
        raise Unavailable(type(e).__name__) from e
    if not host or not password:
        raise RuntimeError("incomplete database login (host or token missing)")
    return Login(host=host, user=user, password=password, database=database)


def refusal_reason(e: Exception) -> str:
    """Databricks' own sentence, without the SDK's appended debug details
    (host, account and client IDs), which users need not see."""
    return str(e).split(". Config:", 1)[0].split(" [ReqId:", 1)[0].strip()


def sqlstate(e: Exception) -> str | None:
    """The SQLSTATE of a Postgres error, or None."""
    if isinstance(e, pg8000.native.DatabaseError) and e.args and isinstance(e.args[0], dict):
        return e.args[0].get("C")
    return None


def is_login_refused(e: Exception) -> bool:
    return sqlstate(e) in LOGIN_REFUSED


def begin_sql(policy: Mapping[str, Any] | None) -> str:
    """The statement that opens the transaction a route's policy names. Built
    from fixed words only; a value outside them is refused."""
    if policy is None:  # no such route: defaults, and rest_invoke answers 404
        return "START TRANSACTION"
    words = ["START TRANSACTION"]
    isolation = policy["transaction_isolation"]
    if isolation is not None:  # None: the route sets no floor, the server default holds
        if isolation not in ISOLATION_LEVELS:
            raise ValueError(f"unexpected transaction isolation {isolation!r}")
        words += ["ISOLATION LEVEL", isolation.upper()]
    words.append("READ ONLY" if policy["transaction_read_only"] else "READ WRITE")
    if policy["transaction_deferrable"]:
        words.append("DEFERRABLE")
    return " ".join(words)


def with_times(row: dict[str, Any]) -> dict[str, Any]:
    """A patch, line or event with its timestamps as datetimes (JSON has text)."""
    return {
        k: datetime.datetime.fromisoformat(v) if k in TIMESTAMPS and isinstance(v, str) else v for k, v in row.items()
    }


def patch_path(patch_id: uuid.UUID | str, tail: str) -> str:
    """/patches/<id>/<tail>; the id must be a uuid, so nothing else reaches the path."""
    return f"/patches/{uuid.UUID(str(patch_id))}/{tail}"


@dataclass(frozen=True)
class Answer:
    status: int
    body: Any  # the JSON document, or None

    @property
    def code(self) -> str | None:
        return self.body.get("code") if isinstance(self.body, dict) else None


class Desk:
    """One user's connection to the patch desk."""

    def __init__(
        self,
        token: str,
        *,
        forwarded_email: str | None = None,
        endpoint: str | None = None,
        database: str | None = None,
    ) -> None:
        self._w = user_client(token)
        self._forwarded_email = forwarded_email
        self._endpoint = endpoint or os.environ["ENDPOINT_NAME"]
        self._database = database or os.environ.get("PGDATABASE", DATABASE)
        self._conn: pg8000.native.Connection | None = None
        self._policies: dict[tuple[str, str], dict[str, Any] | None] = {}
        self._me: dict[str, Any] | None = None
        self.user = ""

    def connect(self) -> None:
        """Open the connection. NoAccess when Postgres refuses the login
        (a fresh token was just issued, so the role or CONNECT is missing);
        SignInExpired when Databricks no longer accepts the user's token."""
        try:
            login = user_login(self._w, self._endpoint, self._database, self._forwarded_email)
        except PermissionDenied as e:
            # Databricks, not Postgres, refused: show its reason, which names
            # what is missing (for example the workspace-access entitlement).
            raise DatabricksRefused(refusal_reason(e)) from e
        try:
            self._conn = pg8000.native.Connection(
                user=login.user,
                password=login.password,
                host=login.host,
                port=PORT,
                database=login.database,
                ssl_context=ssl.create_default_context(),
                application_name="patch-desk",
                timeout=DB_TIMEOUT_S,
            )
        except pg8000.native.DatabaseError as e:
            if is_login_refused(e):
                raise NoAccess from e
            raise
        except (pg8000.native.InterfaceError, OSError) as e:
            raise Unavailable(type(e).__name__) from e
        self.user = login.user

    def close(self) -> None:
        if self._conn is not None:
            try:
                self._conn.close()
            except pg8000.native.InterfaceError:
                pass
            self._conn = None

    def _run(self, sql: str, **params: Any) -> list[dict[str, Any]]:
        if self._conn is None:
            self.connect()
        assert self._conn is not None
        rows = self._conn.run(sql, **params)
        names = [c["name"] for c in self._conn.columns or []]
        return [dict(zip(names, row, strict=True)) for row in rows or []]

    def _policy(self, method: str, route: str, url: str) -> dict[str, Any] | None:
        """The transaction a route wants, looked up once per session."""
        key = (method, route)
        if key not in self._policies:
            rows = self._run(
                """SELECT transaction_isolation, transaction_read_only, transaction_deferrable
                   FROM api.rest_route_policy(:method, :url)""",
                method=method,
                url=url,
            )
            self._policies[key] = rows[0] if rows else None
        return self._policies[key]

    def _invoke(self, method: str, route: str, url: str, body: Any) -> Answer:
        """One request in the transaction its policy names; a serialization
        failure or deadlock runs it again as a new transaction."""
        for attempt in range(1, ATTEMPTS + 1):
            begin = begin_sql(self._policy(method, route, url))
            try:
                self._run(begin)
                if body is None:
                    rows = self._run(
                        """SELECT r.status_code, convert_from(r.content, 'UTF8') AS content
                           FROM api.rest_invoke(:method, :url) r""",
                        method=method,
                        url=url,
                    )
                else:
                    rows = self._run(
                        """SELECT r.status_code, convert_from(r.content, 'UTF8') AS content
                           FROM api.rest_invoke(:method, :url, NULL, CAST(:body AS jsonb)) r""",
                        method=method,
                        url=url,
                        body=json.dumps(body),
                    )
                self._run("COMMIT")
            except pg8000.native.DatabaseError as e:
                self._rollback()
                if sqlstate(e) in RETRYABLE and attempt < ATTEMPTS:
                    continue
                raise
            content = rows[0]["content"]
            return Answer(rows[0]["status_code"], json.loads(content) if content else None)
        raise AssertionError("unreachable")

    def _rollback(self) -> None:
        if self._conn is not None:
            try:
                self._conn.run("ROLLBACK")
            except pg8000.native.InterfaceError:
                self.close()

    def read(self, route: str, url: str) -> Answer:
        """A GET. A lost connection is reopened once and the call repeated."""
        try:
            return self._invoke("GET", route, url, None)
        except pg8000.native.InterfaceError:
            self.close()
            return self._invoke("GET", route, url, None)

    def write(self, route: str, url: str, body: Any) -> Answer:
        """A POST is never repeated after a lost connection: it may have committed."""
        try:
            return self._invoke("POST", route, url, body)
        except pg8000.native.InterfaceError as e:
            self.close()
            raise ConnectionLost from e

    def _items(self, route: str, url: str) -> list[dict[str, Any]]:
        answer = self.read(route, url)
        if answer.status != 200:
            raise DatabaseAnswer(f"GET {route}: {answer.status} {answer.code}")
        return [with_times(item) for item in answer.body["items"]]

    # --- the patch desk API -------------------------------------------------

    def whoami(self) -> dict[str, Any] | None:
        """Who the database says this session acts as (GET /patch-desk/me),
        read once per session; None when the login is not mapped to a person
        or lacks the caller role. The log gets the part of the name before
        the @ and the actor kind, never the email or the token."""
        if self._me is None:
            try:
                answer = self.read("/patch-desk/me", "/patch-desk/me")
            except pg8000.native.DatabaseError as e:
                if sqlstate(e) == "42501":  # no caller role: no USAGE on schema api
                    return None
                raise
            if answer.status == 401:
                return None
            if answer.status != 200:
                raise DatabaseAnswer(f"GET /patch-desk/me: {answer.status} {answer.code}")
            self._me = answer.body
            name = (self._me.get("name") or "").split("@", 1)[0]
            print(
                f"identity: the database acts as {name or '(no name)'}, actor kind {self._me.get('actor_kind')}, "
                f"can submit {self._me.get('can_submit')}, can decide {self._me.get('can_decide')}",
                flush=True,
            )
        return self._me

    def has_access(self) -> bool:
        me = self.whoami()
        return bool(me and me.get("can_submit"))

    def is_approver(self) -> bool:
        """Whether to show the Review page. The database checks again on
        every decision."""
        me = self.whoami()
        return bool(me and me.get("can_decide"))

    def submit_patch(self, file_name: str, lines: list[dict[str, object]]) -> dict[str, Any] | None:
        """Store a file's lines; the stored patch (pending, or invalid when a
        line has a problem), or None when the database refused the file: 400
        when the body breaks the route's schema (no lines, a name too long),
        422 core.patch.file_invalid when the handler refuses it."""
        answer = self.write("/patches", "/patches", {"file_name": file_name, "lines": lines})
        if answer.status == 201:
            return with_times(answer.body)
        if answer.status in (400, 422):
            return None
        raise DatabaseAnswer(f"POST /patches: {answer.status} {answer.code}")

    def patch_lines(self, patch_id: uuid.UUID | str) -> list[dict[str, Any]]:
        """The lines of a patch the user may see, in file order; none when
        they may not see it."""
        answer = self.read("/patches/{patchId}/lines", patch_path(patch_id, "lines"))
        if answer.status == 404:
            return []
        if answer.status != 200:
            raise DatabaseAnswer(f"GET /patches/{{patchId}}/lines: {answer.status} {answer.code}")
        return answer.body["lines"]

    def my_patches(self) -> list[dict[str, Any]]:
        """The user's own patches, newest first."""
        return self._items("/patches/mine", f"/patches/mine?limit={PAGE_LIMIT}")

    def pending_patches(self) -> list[dict[str, Any]]:
        """Patches waiting for a decision, oldest first, each with the reason
        it may not be approved (None when it may)."""
        return self._items("/patches/pending", f"/patches/pending?limit={PAGE_LIMIT}")

    def history(self, limit: int = HISTORY_LIMIT) -> list[dict[str, Any]]:
        """Events on the patches the user may see, newest first."""
        return self._items("/patch-events", f"/patch-events?limit={int(limit)}")

    def _decide(self, verb: str, patch_id: uuid.UUID | str, note: str | None) -> str | None:
        answer = self.write(
            f"/patches/{{patchId}}/{verb}", patch_path(patch_id, verb), {"note": note} if note else {}
        )
        if answer.status == 200:
            return None
        if answer.code == "pgmi.forbidden":  # the route's permission check: no patch.decide
            return "core.patch.not_approver"
        return answer.code or "core.patch.not_found"

    def approve(self, patch_id: uuid.UUID | str, note: str | None) -> str | None:
        """Approve; None when done, else the refusal code."""
        return self._decide("approve", patch_id, note)

    def reject(self, patch_id: uuid.UUID | str, note: str | None) -> str | None:
        """Reject; None when done, else the refusal code."""
        return self._decide("reject", patch_id, note)
