"""The patch desk's jobs on the demo: database deploy, people, export.

One script with three subcommands, one per job task. (Serverless runs a
Python task file through exec(), so a sibling module cannot be imported by
path: the shared code lives here.) All run as the deploy service principal,
which deployed the bundle and owns the Lakebase project.

  pgmi             download the pgmi release asset for this machine's
                   architecture (serverless runs on aarch64 or x86_64), check
                   its SHA-256, and run `pgmi deploy` with the connection
                   string only in the environment. pgmi connects to the
                   maintenance database and creates the target database when
                   it is missing. --param values go to deploy.sql as given;
                   --admin-password generates the advanced template's
                   database_admin_password for the run and passes it only in
                   the environment (PGMI_PARAM_DATABASE_ADMIN_PASSWORD);
                   --workspace-oidc-issuer adds oidc_issuers with the job's
                   own workspace's issuer, <workspace-host>/oidc.
  provision-principals
                   every member of the uploaders and approvers groups in the
                   database (db/): a Postgres login role named by their
                   email when it is missing, made in the maintenance
                   database (CREATE EXTENSION databricks_auth and
                   databricks_create_role(<email>, 'USER') run there, never
                   in db/'s database, whose guards would refuse the
                   extension's functions; roles belong to the whole branch),
                   then in the database CONNECT and the <database>_caller
                   role for it, a
                   template user principal by email, membership in the demo
                   organization with patch.approver or patch.uploader
                   (approver wins), and the login mapped to
                   the principal (membership.fn_map_database_login). The
                   template's kernels do the membership writes, as the kernel
                   role. The first run creates the demo organization, owned
                   by the first approver by user name; with no approver yet
                   it does nothing. People who left both groups lose CONNECT,
                   the caller role and their membership (the owner keeps the
                   membership: the template never ends it). The deploy
                   principal is never mapped; it is registered once as the
                   template service principal service.patch_export, which
                   names it in the export's audit trail (attribution only).
                   Prints the number of changes. Per-person login roles,
                   not a shared one: session_user then names the person.
                   The principal reads the groups as their manager
                   (scripts/deploy.* grants it Manage on both).
  export           the patch_export job: merge the products changed by
                   approved, not yet exported patches into the Delta table
                   <catalog>.patch_desk.product, then mark those patches
                   exported. It reads and marks only through the database's
                   two job routines (api.job_patch_export_batch,
                   api.job_patch_mark_exported), never the tables. A copy
                   with a different number of rows (the first run, too) gets
                   every product. Marking only after the merge makes a failed
                   run safe to repeat: the merge sets the same values again.

Each returns normally on success and raises on failure. Neither calls
sys.exit: in a serverless Python task even sys.exit(0) marks the task failed.
"""

from __future__ import annotations

import argparse
import datetime
import decimal
import hashlib
import json
import os
import platform
import secrets
import ssl
import subprocess
import tarfile
import tempfile
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from databricks.sdk import WorkspaceClient

PGMI_VERSION = "0.14.1"
RELEASE_URL = f"https://github.com/vvka-141/pgmi/releases/download/v{PGMI_VERSION}"
ASSETS = {
    "aarch64": f"pgmi_{PGMI_VERSION}_linux_arm64.tar.gz",
    "x86_64": f"pgmi_{PGMI_VERSION}_linux_amd64.tar.gz",
}
DOWNLOAD_TIMEOUT_S = 60
ACCOUNT_SCIM = "/api/2.0/account/scim/v2"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="command", required=True)
    for name in ("pgmi", "provision-principals", "export"):
        s = sub.add_parser(name)
        s.add_argument("--endpoint", required=True, help="projects/<p>/branches/<b>/endpoints/<e>")
        s.add_argument("--database", required=True, help="the Postgres database")
        if name in ("pgmi", "provision-principals"):
            s.add_argument("--maintenance-database", default="databricks_postgres",
                           help="pgmi: the database it connects to first and creates --database from; "
                                "provision-principals: the database where missing login roles are made")
        if name == "pgmi":
            s.add_argument("--db-dir", required=True, help="the pgmi project folder (db/)")
            s.add_argument("--env", required=True, help="the env parameter for deploy.sql")
            s.add_argument("--param", action="append", default=[], metavar="KEY=VALUE",
                           help="another deploy.sql parameter; repeatable; never a secret")
            s.add_argument("--admin-password", action="store_true",
                           help="generate database_admin_password for this run (advanced template)")
            s.add_argument("--workspace-oidc-issuer", action="store_true",
                           help="pass oidc_issuers with this workspace's issuer, <workspace-host>/oidc")
        elif name == "provision-principals":
            s.add_argument("--uploaders-group", required=True)
            s.add_argument("--approvers-group", required=True)
        else:
            s.add_argument("--catalog", required=True,
                           help="the Unity Catalog catalog to write to; empty: the workspace's default")
        if name == "export":
            s.add_argument("--agent-app-id", default="",
                           help="the AI agent's service principal application ID; empty: no agent")
    return p.parse_args()


# --- Lakebase login --------------------------------------------------------

PORT = 5432


@dataclass(frozen=True)
class Login:
    host: str
    user: str
    password: str  # a one-hour database token; never print it
    database: str

    def __repr__(self) -> str:  # keeps the token out of logs and tracebacks
        return f"Login(host={self.host!r}, user={self.user!r}, database={self.database!r})"

    def connection_string(self) -> str:
        q = urllib.parse.quote
        return (
            f"postgresql://{q(self.user, safe='')}:{q(self.password, safe='')}"
            f"@{self.host}:{PORT}/{q(self.database, safe='')}?sslmode=require"
        )


def login(w: WorkspaceClient, endpoint: str, database: str) -> Login:
    """A direct (not pooled) login: the pooler serves only password roles,
    not OAuth roles. The token is the password and lasts one hour."""
    host = w.postgres.get_endpoint(name=endpoint).status.hosts.host
    if not host:
        raise RuntimeError(f"endpoint {endpoint} has no direct host")
    user = w.current_user.me().user_name
    if not user:
        raise RuntimeError("the job identity has no user name")
    token = w.postgres.generate_database_credential(endpoint=endpoint).token
    if not token:
        raise RuntimeError("no database token returned")
    # The principal's application ID: an identifier, not a secret.
    print(f"Connecting as {user} to {host}/{database}")
    return Login(host=host, user=user, password=token, database=database)


def connect(creds: Login):
    """A pg8000 connection (pure Python, so it runs on aarch64 and x86_64)."""
    import pg8000.native  # only the subcommands that query Postgres need it

    return pg8000.native.Connection(user=creds.user, password=creds.password, host=creds.host,
                                    port=PORT, database=creds.database,
                                    ssl_context=ssl.create_default_context())


# --- pgmi -------------------------------------------------------------------

def asset_for(machine: str) -> str:
    try:
        return ASSETS[machine]
    except KeyError:
        raise RuntimeError(f"no pgmi release asset for architecture {machine!r}") from None


def expected_sha256(checksums: str, asset: str) -> str:
    """The SHA-256 for `asset` in a checksums.txt (`<sha256>  <file name>` lines)."""
    for line in checksums.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].lstrip("*") == asset:
            return parts[0].lower()
    raise RuntimeError(f"{asset} is not listed in checksums.txt")


def download(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=DOWNLOAD_TIMEOUT_S) as r:
        return r.read()


def install_pgmi(dest: Path) -> Path:
    asset = asset_for(platform.machine())
    print(f"Downloading {asset} (pgmi {PGMI_VERSION}, {platform.machine()})")
    archive = download(f"{RELEASE_URL}/{asset}")
    want = expected_sha256(download(f"{RELEASE_URL}/checksums.txt").decode(), asset)
    got = hashlib.sha256(archive).hexdigest()
    if got != want:
        raise RuntimeError(f"checksum mismatch for {asset}: want {want}, got {got}")

    tar_path = dest / asset
    tar_path.write_bytes(archive)
    with tarfile.open(tar_path) as tar:
        tar.extractall(dest, filter="data")
    binary = dest / "pgmi"
    if not binary.is_file():
        raise RuntimeError(f"{asset} has no pgmi binary at its top level")
    binary.chmod(0o755)
    return binary


ADMIN_PASSWORD_ENV = "PGMI_PARAM_DATABASE_ADMIN_PASSWORD"


def workspace_oidc_issuer_param(host: str) -> str:
    """oidc_issuers naming the workspace's own issuer, <host>/oidc (the
    issuer its /oidc/.well-known/oauth-authorization-server names)."""
    host = host.rstrip("/")
    if not host.startswith("https://"):
        raise RuntimeError(f"the workspace host must be an https URL, got {host!r}")
    return "oidc_issuers=" + json.dumps([f"{host}/oidc"])


def pgmi_command(pgmi: str, db_dir: str, database: str, env: str, params: list[str]) -> list[str]:
    """The pgmi deploy command line. Holds no secret: it is printed."""
    for param in params:
        key, sep, _ = param.partition("=")
        if not sep or not key.strip():
            raise RuntimeError(f"--param must be KEY=VALUE, got {param!r}")
        if key.strip().lower() in ("env", "database_admin_password"):
            raise RuntimeError(f"--param {key.strip()} is not allowed: use --env or --admin-password")
    cmd = [pgmi, "deploy", db_dir, "-d", database, "--param", f"env={env}"]
    for param in params:
        cmd += ["--param", param]
    return cmd + ["--force"]


def pgmi_environment(base: dict[str, str], connection_string: str, admin_password: bool) -> dict[str, str]:
    """The environment pgmi runs in: the connection string and, when asked,
    a fresh admin password, so neither appears on the command line."""
    env = {k: v for k, v in base.items() if k != ADMIN_PASSWORD_ENV}
    env["PGMI_CONNECTION_STRING"] = connection_string
    if admin_password:
        env[ADMIN_PASSWORD_ENV] = secrets.token_urlsafe(32)
    return env


def run_pgmi(args: argparse.Namespace) -> None:
    db_dir = Path(args.db_dir)
    if not (db_dir / "deploy.sql").is_file():
        raise RuntimeError(f"no deploy.sql in {db_dir}")

    w = WorkspaceClient()
    with tempfile.TemporaryDirectory() as tmp:
        pgmi = install_pgmi(Path(tmp))
        params = list(args.param)
        if args.workspace_oidc_issuer:
            params.append(workspace_oidc_issuer_param(w.config.host or ""))
        cmd = pgmi_command(str(pgmi), str(db_dir), args.database, args.env, params)
        conn = login(w, args.endpoint, args.maintenance_database).connection_string()
        env = pgmi_environment(dict(os.environ), conn, args.admin_password)
        print("Running:", " ".join(cmd[1:]), flush=True)
        if args.admin_password:
            print(f"database_admin_password: generated for this run, passed in {ADMIN_PASSWORD_ENV}")
        rc = subprocess.run(cmd, env=env, check=False).returncode
    if rc != 0:
        raise RuntimeError(f"pgmi deploy failed with exit code {rc}")
    print("pgmi deploy succeeded")


# --- the patch desk's groups ----------------------------------------------

def scim_filter_eq(attribute: str, value: str) -> str:
    return f'{attribute} eq "{value}"'


def group_user_ids(w: WorkspaceClient, display_name: str) -> list[str]:
    """IDs of the users directly in a group; nested groups and service
    principals are skipped with a log line."""
    found = w.api_client.do("GET", f"{ACCOUNT_SCIM}/Groups",
                            query={"filter": scim_filter_eq("displayName", display_name)})
    groups = found.get("Resources", [])
    if len(groups) != 1:
        raise RuntimeError(f"want exactly one group named {display_name!r}, found {len(groups)}")
    group = w.api_client.do("GET", f"{ACCOUNT_SCIM}/Groups/{groups[0]['id']}")
    ids = []
    for member in group.get("members", []):
        kind = member.get("$ref", "").split("/", 1)[0]
        if kind == "Users":
            ids.append(member["value"])
        else:
            print(f"{display_name}: skipping {kind or 'unknown'} member {member.get('display')!r}")
    return ids


def user_names(w: WorkspaceClient, ids: list[str]) -> dict[str, str]:
    """userName (the email) by user ID, in one filtered list call."""
    if not ids:
        return {}
    query = " or ".join(scim_filter_eq("id", i) for i in ids)
    found = w.api_client.do("GET", f"{ACCOUNT_SCIM}/Users",
                            query={"filter": query, "attributes": "userName", "count": len(ids)})
    names = {u["id"]: u["userName"] for u in found.get("Resources", []) if u.get("userName")}
    missing = set(ids) - names.keys()
    if missing:
        raise RuntimeError(f"no user name for {len(missing)} group member(s)")
    return names


def group_people(w: WorkspaceClient, uploaders_group: str, approvers_group: str) -> tuple[set[str], set[str]]:
    """The user names (emails) of the uploaders and the approvers."""
    uploader_ids = group_user_ids(w, uploaders_group)
    approver_ids = group_user_ids(w, approvers_group)
    names = user_names(w, sorted(set(uploader_ids) | set(approver_ids)))
    uploaders, approvers = {names[i] for i in uploader_ids}, {names[i] for i in approver_ids}
    print(f"Group members: {len(uploaders)} uploader(s), {len(approvers)} approver(s)")
    return uploaders, approvers


# --- provision-principals --------------------------------------------------

DEMO_ORG_SLUG = "demo"
DEMO_ORG_NAME = "Patch desk demo"
PATCH_DESK_ROLES = ("patch.uploader", "patch.approver")
OWNER_ROLE = "org.owner"


def template_roles(uploaders: set[str], approvers: set[str]) -> dict[str, str]:
    """The template role by login role name (the email): approvers win."""
    want = {email: "patch.uploader" for email in uploaders}
    want.update({email: "patch.approver" for email in approvers})
    return want


def demo_owner(approvers: set[str]) -> str | None:
    """Who owns the demo organization when it is created: the first approver
    by user name, or nobody yet."""
    return min(approvers) if approvers else None


@dataclass(frozen=True)
class LoginAccess:
    """What a login role holds in the database: whether the role exists, and
    the CONNECT and caller-role grants."""
    exists: bool = False
    connect: bool = False
    caller: bool = False


@dataclass(frozen=True)
class Member:
    """A login's template principal, its current membership in the demo
    organization with that membership's roles, and whether the login is mapped."""
    principal: str | None = None
    membership: str | None = None
    roles: frozenset[str] = frozenset()
    mapped: bool = False


def plan_login_access(want: set[str], have: dict[str, LoginAccess]) -> list[tuple[str, str]]:
    """(action, login) steps that give every wanted login a role, CONNECT and
    the caller role, and take CONNECT and the caller role from the others in
    `have`. A role is never dropped."""
    steps: list[tuple[str, str]] = []
    for login in sorted(want):
        access = have.get(login, LoginAccess())
        if not access.exists:
            steps.append(("create_role", login))
        if not access.connect:
            steps.append(("grant_connect", login))
        if not access.caller:
            steps.append(("grant_caller", login))
    for login in sorted(have.keys() - want):
        if have[login].connect:
            steps.append(("revoke_connect", login))
        if have[login].caller:
            steps.append(("revoke_caller", login))
    return steps


def plan_members(want: dict[str, str], have: dict[str, Member]) -> list[tuple[str, str, str]]:
    """(action, login, role) steps that make every wanted login a mapped
    member with its one patch desk role, and end the others' memberships.
    The owner's membership never ends (the template refuses), and roles other
    than the patch desk's are left alone."""
    steps: list[tuple[str, str, str]] = []
    for login, role in sorted(want.items()):
        member = have.get(login, Member())
        if member.principal is None:
            steps.append(("create_principal", login, ""))
        if member.membership is None:
            steps.append(("add_member", login, role))
        else:
            if role not in member.roles:
                steps.append(("grant_role", login, role))
            steps += [("revoke_role", login, other) for other in PATCH_DESK_ROLES
                      if other != role and other in member.roles]
        if not member.mapped:
            steps.append(("map", login, ""))
    for login in sorted(have.keys() - want.keys()):
        member = have[login]
        if member.membership is not None and OWNER_ROLE not in member.roles:
            steps.append(("end_membership", login, ""))
    return steps


def set_role(conn, role: str | None) -> None:
    import pg8000.native

    conn.run("RESET ROLE" if role is None else f"SET ROLE {pg8000.native.identifier(role)}")


def read_login_access(conn, logins: list[str], caller_role: str) -> dict[str, LoginAccess]:
    """CONNECT on this database granted to the role itself, and the caller
    role granted by this login (the grants this job makes)."""
    rows = conn.run(
        """SELECT l.login, r.oid IS NOT NULL,
                  EXISTS (SELECT FROM pg_database d, aclexplode(d.datacl) a
                          WHERE d.datname = current_database() AND a.grantee = r.oid
                            AND a.privilege_type = 'CONNECT'),
                  EXISTS (SELECT FROM pg_auth_members m
                          WHERE m.member = r.oid AND m.roleid = to_regrole(quote_ident(:caller))
                            AND m.grantor = (SELECT oid FROM pg_roles WHERE rolname = session_user))
           FROM unnest(CAST(:logins AS text[])) AS l(login)
           LEFT JOIN pg_roles r ON r.rolname = l.login""",
        logins=logins, caller=caller_role)
    return {login: LoginAccess(exists, connect, caller) for login, exists, connect, caller in rows}


def callers_granted_by_me(conn, caller_role: str) -> set[str]:
    return {row[0] for row in conn.run(
        """SELECT r.rolname FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.member
           WHERE m.roleid = to_regrole(quote_ident(:caller)) AND r.rolcanlogin
             AND m.grantor = (SELECT oid FROM pg_roles WHERE rolname = session_user)""",
        caller=caller_role)}


def read_members(conn, organization: str, logins: list[str]) -> dict[str, Member]:
    """As the kernel role. The principal is the one the login is mapped to,
    else the user principal with the login's email (a verified one first)."""
    rows = conn.run(
        """SELECT l.login, p.principal_object_id::text, m.object_id::text,
                  coalesce((SELECT array_agg(ra.role_id::text) FROM membership.role_assignment ra
                            WHERE ra.membership_object_id = m.object_id AND upper_inf(ra.valid_during)),
                           '{}'),
                  dl.database_role IS NOT NULL
           FROM unnest(CAST(:logins AS text[])) AS l(login)
           LEFT JOIN membership.database_login dl ON dl.database_role = l.login
           LEFT JOIN LATERAL (
               SELECT coalesce(dl.principal_object_id,
                               (SELECT up.principal_object_id FROM membership.user_principal up
                                WHERE up.email = membership.fn_normalize_email(l.login)
                                ORDER BY up.is_email_verified DESC, up.principal_object_id
                                LIMIT 1)) AS principal_object_id) p ON true
           LEFT JOIN membership.organization_membership m
                  ON m.organization_object_id = CAST(:org AS uuid)
                 AND m.principal_object_id = p.principal_object_id AND upper_inf(m.valid_during)""",
        logins=logins, org=organization)
    return {login: Member(principal, membership, frozenset(roles), mapped)
            for login, principal, membership, roles, mapped in rows}


def kernel_value(conn, sql: str, what: str, **params) -> object:
    """One kernel call that returns a row; NULL means the kernel refused."""
    value = conn.run(sql, **params)[0][0]
    if value is None:
        raise RuntimeError(f"the template refused: {what}")
    return value


def find_or_create_principal(conn, login: str) -> tuple[str, bool]:
    """(principal id, created). The email is the person's Databricks user
    name, so it counts as verified."""
    found = conn.run(
        """SELECT principal_object_id::text FROM membership.user_principal
           WHERE email = membership.fn_normalize_email(:email)
           ORDER BY is_email_verified DESC, principal_object_id LIMIT 1""", email=login)
    if found:
        return found[0][0], False
    principal = kernel_value(
        conn, "SELECT u.principal_object_id::text FROM membership.fn_create_user_principal(:email, NULL, true) u",
        f"create a user principal for {login}", email=login)
    print(f"created principal for {login}")
    return str(principal), True


def apply_login_access(conn, steps: list[tuple[str, str]], caller_role: str) -> None:
    """As the deploy login itself, which owns the caller role's grants."""
    import pg8000.native

    ident = pg8000.native.identifier
    missing = [login for action, login in steps if action == "create_role"]
    if missing:
        # Never here: databricks_auth would land in this database's schemas.
        raise RuntimeError(f"no login role for {len(missing)} person(s); create_login_roles "
                           "makes them in the maintenance database first")
    database = conn.run("SELECT current_database()")[0][0]
    for action, login in steps:
        if action == "grant_connect":
            conn.run(f"GRANT CONNECT ON DATABASE {ident(database)} TO {ident(login)}")
            print(f"granted CONNECT on {database} to {login}")
        elif action == "grant_caller":
            conn.run(f"GRANT {ident(caller_role)} TO {ident(login)}")
            print(f"granted {caller_role} to {login}")
        elif action == "revoke_connect":
            conn.run(f"REVOKE CONNECT ON DATABASE {ident(database)} FROM {ident(login)}")
            print(f"revoked CONNECT on {database} from {login}")
        elif action == "revoke_caller":
            conn.run(f"REVOKE {ident(caller_role)} FROM {ident(login)}")
            print(f"revoked {caller_role} from {login}")
        else:
            raise RuntimeError(f"unknown step {action}")


def create_login_roles(conn, logins: list[str]) -> int:
    """Makes the missing login roles, on a connection to the maintenance
    database (roles belong to the whole branch). databricks_auth is created
    there, and only when a role is missing. Returns the number made."""
    missing = [row[0] for row in conn.run(
        """SELECT l FROM unnest(CAST(:logins AS text[])) AS l
           WHERE NOT EXISTS (SELECT FROM pg_roles r WHERE r.rolname = l)
           ORDER BY l""", logins=logins)]
    if not missing:
        return 0
    conn.run("CREATE EXTENSION IF NOT EXISTS databricks_auth")
    for name in missing:
        conn.run("SELECT databricks_create_role(:name, 'USER')", name=name)
        print(f"created role for {name}")
    return len(missing)


def apply_members(conn, organization: str, steps: list[tuple[str, str, str]], have: dict[str, Member]) -> None:
    """As the kernel role, through the template's kernels only."""
    principal = {login: m.principal for login, m in have.items()}
    membership = {login: m.membership for login, m in have.items()}
    for action, login, role in steps:
        if action == "create_principal":
            principal[login], _ = find_or_create_principal(conn, login)
        elif action == "add_member":
            membership[login] = str(kernel_value(
                conn, "SELECT m.object_id::text FROM membership.fn_add_member(CAST(:org AS uuid), CAST(:p AS uuid), :role) m",
                f"add {login} to the demo organization", org=organization, p=principal[login], role=role))
            print(f"added {login} to the demo organization as {role}")
        elif action == "grant_role":
            kernel_value(conn, "SELECT g.granted FROM membership.fn_grant_role(CAST(:m AS uuid), :role) g",
                         f"grant {role} to {login}", m=membership[login], role=role)
            print(f"granted {role} to {login}")
        elif action == "revoke_role":
            kernel_value(conn, "SELECT r.object_id FROM membership.fn_revoke_role(CAST(:m AS uuid), :role) r",
                         f"revoke {role} from {login}", m=membership[login], role=role)
            print(f"revoked {role} from {login}")
        elif action == "end_membership":
            kernel_value(conn, "SELECT e.object_id FROM membership.fn_end_membership(CAST(:m AS uuid), 'removed') e",
                         f"end the membership of {login}", m=membership[login])
            print(f"ended the membership of {login}")
        elif action == "map":
            kernel_value(
                conn, """SELECT d.database_role FROM membership.fn_map_database_login(
                             CAST(:login AS name), CAST(:p AS uuid), CAST(:org AS uuid)) d""",
                f"map the login {login}", login=login, p=principal[login], org=organization)
            print(f"mapped the login {login}")
        else:
            raise RuntimeError(f"unknown step {action}")


EXPORT_SERVICE_ID = "service.patch_export"
EXPORT_SERVICE_DESCRIPTION = "Patch desk export job"


def register_export_service(conn) -> int:
    """As the kernel role: registers the deploy login as the template service
    principal the export job marks patches in the name of. Attribution only:
    a service principal is no database_login mapping, so the deploy login
    still names no one. Returns 1 when it registered, 0 when one already
    names the login."""
    if conn.run("SELECT EXISTS (SELECT FROM membership.service_principal WHERE database_role = session_user)")[0][0]:
        return 0
    kernel_value(conn, "SELECT s.id FROM membership.fn_register_service_principal(:id, :description, session_user) s",
                 f"register the deploy login as {EXPORT_SERVICE_ID}",
                 id=EXPORT_SERVICE_ID, description=EXPORT_SERVICE_DESCRIPTION)
    print(f"registered the deploy login as service principal {EXPORT_SERVICE_ID}")
    return 1


def provision_principals_in(conn, uploaders: set[str], approvers: set[str]) -> int:
    """Brings the database the connection is on in line with the groups, in
    one transaction. Returns the number of changes."""
    database, deploy_login = conn.run("SELECT current_database(), session_user::text")[0]
    caller_role, kernel_role = f"{database}_caller", f"{database}_kernel"
    want = template_roles(uploaders, approvers)
    if deploy_login in want:
        raise RuntimeError("the deploy login is in a patch desk group; it is never mapped")

    conn.run("BEGIN")
    try:
        set_role(conn, kernel_role)
        found = conn.run("SELECT object_id::text FROM membership.organization WHERE slug = :slug", slug=DEMO_ORG_SLUG)
        organization = found[0][0] if found else None
        owner = demo_owner(approvers)
        if organization is None and owner is None:
            print("No demo organization yet and no approver to own it: mapped no one")
            conn.run("ROLLBACK")
            return 0
        mapped = set() if organization is None else {row[0] for row in conn.run(
            "SELECT database_role::text FROM membership.database_login WHERE organization_object_id = CAST(:org AS uuid)",
            org=organization)}
        set_role(conn, None)

        logins = sorted(want.keys() | mapped | callers_granted_by_me(conn, caller_role))
        access_steps = plan_login_access(set(want), read_login_access(conn, logins, caller_role))
        apply_login_access(conn, access_steps, caller_role)
        changes = len(access_steps)

        set_role(conn, kernel_role)
        if organization is None:
            owner_principal, created = find_or_create_principal(conn, owner)
            changes += created
            organization = str(kernel_value(
                conn, "SELECT o.object_id::text FROM membership.fn_create_organization_with_owner(:name, :slug, CAST(:owner AS uuid)) o",
                "create the demo organization", name=DEMO_ORG_NAME, slug=DEMO_ORG_SLUG, owner=owner_principal))
            print(f"created the demo organization, owned by {owner}")
            changes += 1
        members = read_members(conn, organization, logins)
        member_steps = plan_members(want, members)
        apply_members(conn, organization, member_steps, members)
        changes += len(member_steps)

        changes += register_export_service(conn)

        if conn.run("SELECT EXISTS (SELECT FROM membership.database_login WHERE database_role = session_user)")[0][0]:
            raise RuntimeError("the deploy login is mapped to a principal; it must name no one")
        set_role(conn, None)
        conn.run("COMMIT")
    except Exception:
        conn.run("ROLLBACK")
        raise
    return changes


def provision_principals(args: argparse.Namespace) -> None:
    w = WorkspaceClient()
    uploaders, approvers = group_people(w, args.uploaders_group, args.approvers_group)
    conn = connect(login(w, args.endpoint, args.maintenance_database))
    try:
        changes = create_login_roles(conn, sorted(template_roles(uploaders, approvers)))
    finally:
        conn.close()
    conn = connect(login(w, args.endpoint, args.database))
    try:
        changes += provision_principals_in(conn, uploaders, approvers)
    finally:
        conn.close()
    print(f"provision_principals: {changes} changes")


# --- export ----------------------------------------------------------------

EXPORT_SCHEMA = "patch_desk"
EXPORT_TABLE = "product"


def export_struct():
    """The Delta table's columns, in the order of export_row."""
    from pyspark.sql.types import (
        BooleanType,
        DecimalType,
        StringType,
        StructField,
        StructType,
        TimestampType,
    )

    return StructType([
        StructField("product_code", StringType(), nullable=False),
        StructField("name", StringType()),
        StructField("category", StringType()),
        StructField("unit_price", DecimalType(12, 2)),
        StructField("active", BooleanType()),
        StructField("updated_at", TimestampType()),
        StructField("patch_id", StringType()),       # the latest approved patch that changed the row
        StructField("approved_by", StringType()),
        StructField("approved_at", TimestampType()),
    ])


def quote_name(name: str) -> str:
    """A Spark SQL identifier in backticks."""
    return "`" + name.replace("`", "``") + "`"


def parse_timestamp(value: str | None) -> datetime.datetime | None:
    return None if value is None else datetime.datetime.fromisoformat(value)


@dataclass(frozen=True)
class ExportBatch:
    """What api.job_patch_export_batch answers: the patches to mark after the
    merge, the products to merge, and how many products the database holds."""
    patch_ids: tuple[str, ...]
    products: tuple[dict, ...]
    product_count: int


def parse_export_batch(value: object) -> ExportBatch:
    """The batch document, checked: the job marks exactly these ids, so a
    document of another shape is an error, not an empty batch."""
    if isinstance(value, str):
        value = json.loads(value)
    if not isinstance(value, dict):
        raise TypeError(f"the export batch is not a JSON object: {type(value).__name__}")
    patch_ids, products, count = value.get("patch_ids"), value.get("products"), value.get("product_count")
    if not isinstance(patch_ids, list) or not all(isinstance(i, str) for i in patch_ids):
        raise RuntimeError("the export batch has no list of patch ids")
    if not isinstance(products, list) or not all(isinstance(p, dict) and p.get("product_code") for p in products):
        raise RuntimeError("the export batch has no list of products")
    if isinstance(count, bool) or not isinstance(count, int) or count < 0:
        raise RuntimeError("the export batch has no product count")
    return ExportBatch(tuple(patch_ids), tuple(products), count)


def read_export_batch(conn, delta_count: int) -> tuple[ExportBatch, bool]:
    """(batch, full). Patches change products, but products can also arrive
    another way (the demo seed, a new product). When the copy has a different
    number of rows, copy every product, not just the patched ones: this also
    covers an empty table and a first run that failed. Each call is one
    snapshot: the patch ids and the rows they touched."""
    batch = parse_export_batch(conn.run("SELECT api.job_patch_export_batch(false)")[0][0])
    if delta_count == batch.product_count:
        return batch, False
    return parse_export_batch(conn.run("SELECT api.job_patch_export_batch(true)")[0][0]), True


def mark_exported(conn, patch_ids: tuple[str, ...]) -> int:
    """Marks the patches exported; how many it marked (0 on a repeat)."""
    marked = conn.run("SELECT api.job_patch_mark_exported(CAST(:ids AS uuid[]))", ids=list(patch_ids))[0][0]
    if marked is None:
        raise RuntimeError(f"the database marked nothing: the job's login is no registered service principal "
                           f"(the db_deploy job's provision_principals task registers it as {EXPORT_SERVICE_ID})")
    return marked


def export_row(product: dict) -> tuple:
    """One api.job_patch_export_batch product as a row in export_struct order. The price
    comes as text, so it converts to Decimal without float rounding."""
    return (
        product["product_code"],
        product["name"],
        product["category"],
        decimal.Decimal(product["unit_price"]),
        product["active"],
        parse_timestamp(product["updated_at"]),
        product["patch_id"],
        product["approved_by"],
        parse_timestamp(product["approved_at"]),
    )


def export(args: argparse.Namespace) -> None:
    # The job's own Spark session; serverless allows only Spark Connect APIs
    # (DataFrames and SQL, no RDDs).
    from databricks.connect import DatabricksSession
    from pyspark.sql.functions import col as spark_col

    w = WorkspaceClient()
    catalog = args.catalog or w.metastores.current().default_catalog_name
    if not catalog:
        raise RuntimeError("no --catalog given and the workspace has no default catalog")
    spark = DatabricksSession.builder.getOrCreate()
    struct = export_struct()
    schema_name = f"{quote_name(catalog)}.{quote_name(EXPORT_SCHEMA)}"
    table = f"{schema_name}.{quote_name(EXPORT_TABLE)}"
    columns = ", ".join(f"{quote_name(f.name)} {f.dataType.simpleString()}{'' if f.nullable else ' NOT NULL'}"
                        for f in struct.fields)
    spark.sql(f"CREATE SCHEMA IF NOT EXISTS {schema_name} "
              "COMMENT 'Copies of patch desk data, written by the patch_export job'")
    spark.sql(f"CREATE TABLE IF NOT EXISTS {table} ({columns}) "
              "COMMENT 'Products from Lakebase; patch_id is the latest approved patch that changed the row'")
    if args.agent_app_id:
        # The planned AI agent reads this copy to look for suspicious
        # data. The deploy principal owns the schema.
        spark.sql(f"GRANT USE SCHEMA, SELECT ON SCHEMA {schema_name} TO {quote_name(args.agent_app_id)}")
        print("Granted the agent USE SCHEMA and SELECT on the export schema")
    delta_count = spark.table(table).count()

    print(f"Target: {catalog}.{EXPORT_SCHEMA}.{EXPORT_TABLE}")
    creds = login(w, args.endpoint, args.database)
    conn = connect(creds)
    try:
        batch, full = read_export_batch(conn, delta_count)
    finally:
        conn.close()
    patch_ids, products = batch.patch_ids, batch.products
    print(f"Batch: {len(patch_ids)} patch(es), {len(products)} product(s)"
          + (f" (full copy: {delta_count} rows in Delta, {batch.product_count} in Postgres)" if full else ""))

    if products:
        spark.createDataFrame([export_row(p) for p in products], struct) \
             .createOrReplaceTempView("patch_export_batch")
        spark.sql(f"""MERGE INTO {table} AS t
                      USING patch_export_batch AS s
                      ON t.product_code = s.product_code
                      WHEN MATCHED THEN UPDATE SET *
                      WHEN NOT MATCHED THEN INSERT *""")

    # Only after the merge returned: a failure above leaves the patches
    # unmarked, and the next run merges the same values again.
    marked = 0
    if patch_ids:
        conn = connect(creds)
        try:
            marked = mark_exported(conn, patch_ids)
        finally:
            conn.close()

    print(f"patch_export: {len(products)} products merged, {marked} patches marked")
    # Read the merged rows back from the Delta table, not from the batch.
    if products:
        codes = [p["product_code"] for p in products]
        merged = (spark.table(table).where(spark_col("product_code").isin(codes))
                  .select("product_code", "unit_price", "patch_id").orderBy("product_code").collect())
        for row in merged:
            print(f"  {row.product_code}  {row.unit_price}  {row.patch_id or '-'}")


def main() -> None:
    args = parse_args()
    if args.command == "pgmi":
        run_pgmi(args)
    elif args.command == "provision-principals":
        provision_principals(args)
    else:
        export(args)


if __name__ == "__main__":
    main()
