# db: the demo's database on the advanced template

## Start here

The patch desk lives in six places. Read these; the rest is support code.

| File | What it does |
|---|---|
| `data/authorization.json` | who may do what: permissions `patch.submit` and `patch.decide`, roles `patch.uploader` and `patch.approver` |
| `core/patch-structure.sql` | the tables: a patch, its lines, its audit events. Row-level security per organization; a check that nobody decides their own patch |
| `core/patch.sql` | the business rules: submit, approve, reject, and why a line or a file is refused |
| `api/patch-desk.sql` | what the app and agents call: each operation as a REST route, an RPC method and an MCP tool, over the rules above |
| `membership/05d-database-logins.sql` | a person's own database login is mapped to that person; `membership/03-session.sql` makes every request act as the mapped person |
| `core/patch-export.sql`, `api/patch-export.sql` | what the export job may read and mark: approved patches and the products they changed, nothing else |

**The tests are the app's rules, written as code.** They run inside every
deploy, in the same transaction: if one fails, nothing is committed. Each
test file's first line says what it proves. List them all with
`grep -rh '^-- Proves:' db --include='*.sql'`. The patch desk's own tests:

| Rule | Test |
|---|---|
| a person cannot approve their own patch; approval applies only the clean lines, rejection nothing | `core/__test__/test_patch_kernels.sql` |
| an uploader sees only their own patches, an approver the organization's, nobody another organization's | `core/__test__/test_patch_rls.sql` |
| the REST routes, RPC methods and MCP tools keep the same rules | `api/__test__/test_patch_handlers.sql` |
| each role gets exactly the routes it should | `api/__test__/test_access_matrix.sql` |
| a database login acts as its own person, whatever the request claims | `api/__test__/database_logins/` |
| only the export job reads approved patches across organizations | `core/__test__/test_patch_export.sql` |
| the demo catalogue is seeded, and an approved fix survives the next deploy | `core/__test__/test_catalogue.sql` |

The other tests (`lib/__test__/`, `membership/__test__/`, the rest of
`api/__test__/`) guard the support code: identity, access, the API
contract, row-level security on every table.

Everything else (`lib/`, the rest of `membership/` and `api/`) is support
code from the template. Readers rarely need to touch it.

## About this project

A [pgmi](https://github.com/vvka-141/pgmi) project made with
`pgmi init db -t advanced` (pgmi 0.14.1), adapted for the patch desk, and
restructured to the layout of the advanced template on pgmi main (commit
`8e39366f`): `deploy.sql` reads top to bottom, and its setup lives in
`deploy/`, one file per concern. It deploys with pgmi 0.14.1. The `db_deploy` job deploys it into
the database `lakebase_apps`.

What this project adds to the generated code: each
person connects as their own database login, and a mapped login acts as its
principal and nobody else. The same holds for an AI agent's login once the
agent inbox is built (planned).

| File | Holds |
|---|---|
| `membership/02g-database-logins.sql` | table `membership.database_login`: login role, principal, default organization |
| `membership/06b-database-login-rls.sql` | its forced row-level security; only the kernel writes |
| `membership/05d-database-logins.sql` | `membership.fn_map_database_login(role, principal, organization)`, called by provisioning as the kernel role |
| `membership/03-session.sql` | the request context comes from a mapped `session_user` before anything else |
| `deploy/bootstrap.sql`, `deploy/schemas.sql`, `deploy/settings.sql`, `deploy/parameters.xml`, `lib/api/13-entry-point-grants.sql` | group role `<database>_caller`: `USAGE` on schema `api` and `EXECUTE` on the REST, RPC and MCP entry points only |
| `api/__test__/database_logins/` | tests: a mapped login acts as itself; separate logins (superuser deploys only) |

**How a person gets access.** The `db_deploy` job's task
`provision_principals` (`jobs/patch_desk_job.py provision-principals`) runs
after every deploy, as the deploy service principal. For each member of
`patch-desk-uploaders` and `patch-desk-approvers` it gives:

1. their login role, named by their email (`databricks_create_role` when it
   is missing), `CONNECT` on the database (`deploy/bootstrap.sql` revokes it from
   `PUBLIC`) and the role `<database>_caller`;
2. a template user principal with that email, membership in the demo
   organization (slug `demo`) and the role `patch.approver` or
   `patch.uploader` (approver wins);
3. the login mapped to that principal (`membership.fn_map_database_login`).

The template's kernels write steps 2 and 3, as the kernel role. The first
run creates the demo organization, owned by the first approver by user name;
while `patch-desk-approvers` is empty, it does nothing. A person who left
both groups loses `CONNECT`, the caller role and the membership. The owner
keeps the membership (the template never ends an owner's) but loses `CONNECT`
and the caller role. Login roles are never dropped. The deploy service
principal is never mapped: the kernels accept it only while it names no one.
A run with nothing to do prints `provision_principals: 0 changes`.
`local-check.sh` runs the provisioning between its first two deploys and
again after the second (`jobs/tests/test_provision_principals_db.py`).

The patch desk's data model is in `core/`:

| File | Holds |
|---|---|
| `core/catalogue-structure.sql` | tables `core.category` and `core.product`: one catalogue shared by every organization, exempt from organization row-level security |
| `core/catalogue.sql` | `core.fn_add_product` (adds a missing product, leaves an existing one alone), `core.fn_product_field_text`, view `core.vw_product` |
| `core/catalogue-seed.sql`, `data/catalogs/core.category.json` | the categories, and the demo products when missing; every environment, so an approved fix survives the next deploy |
| `core/patch-structure.sql` | tables `core.patch`, `core.patch_line`, `core.patch_event`: organization rows; a submitter sees their own patches, a `patch.decide` holder all of the organization's; lines and events follow their patch and never change |
| `core/patch.sql` | kernels `core.fn_submit_patch`, `core.fn_approve_patch`, `core.fn_reject_patch`; problem functions `core.fn_patch_problems`, `core.fn_patch_line_problems`, `core.fn_patch_problem`; views `core.vw_patch`, `core.vw_patch_line`, `core.vw_patch_event` |
| `data/authorization.json` | permissions `patch.submit`, `patch.decide`; roles `patch.uploader` (submit) and `patch.approver` (submit and decide) |
| `core/__test__/` | tests: the seed and a redeploy keeping an approved price, each kernel rule, who sees which patch |

The patch desk's API is in `api/patch-desk.sql`,
over the reads in `core/patch-read.sql`. Each operation is a REST route
(`api.rest_invoke`), an RPC method (`api.rpc_invoke`) and an MCP tool
(`api.mcp_handle_request`), and all three call the same kernel or read
function:

| Operation | REST | RPC method | MCP tool | Who may call |
|---|---|---|---|---|
| categories | `GET /patch-categories` | `patch.categories` | `list_patch_categories` | any member |
| submit a file | `POST /patches` (201) | `patch.submit` | `submit_patch` | `patch.submit` |
| check a draft | `POST /patches/check` | `patch.check_lines` | `check_patch_lines` | `patch.submit` |
| my patches | `GET /patches/mine` | `patch.list_mine` | `list_my_patches` | `patch.submit` |
| pending patches | `GET /patches/pending` | `patch.list_pending` | `list_pending_patches` | `patch.decide` |
| one patch and its lines | `GET /patches/{patchId}/lines` | `patch.lines` | `read_patch_lines` | any member |
| history | `GET /patch-events` | `patch.history` | `read_patch_history` | any member |
| approve | `POST /patches/{patchId}/approve` | `patch.approve` | `approve_patch` | `patch.decide` |
| reject | `POST /patches/{patchId}/reject` | `patch.reject` | `reject_patch` | `patch.decide` |
| who am I | `GET /patch-desk/me` | `patch.whoami` | `patch_desk_whoami` | any signed-in caller |

- Row-level security decides which patches each answer holds: a submitter
  sees their own, a `patch.decide` holder all of the organization's.
- Lists are pages: `limit` (default 200, at most 500) and `offset`, answered
  as `{items, total, limit, offset, hasMore}`. Approve and reject take an
  optional `note`; send `{}` without one.
- Field names are the ones the app reads: a patch is `patch_id`,
  `file_name`, `state`, `submitted_by`, `submitted_at`, `line_count`,
  `problem_count`, `decided_by`, `decided_at`, `decision_note`,
  `exported_at`, `approve_problem`, `own`, `by_agent`; an event is
  `patch_id`, `at`, `file_name`, `event`, `actor`, `note`, `actor_is_agent`;
  a line is `line_no`, `product_code`, `field`, `new_value`, `reason`,
  `old_value`, `current_value`, `problem`. People are named by email (a
  service by its display name); `by_agent` and `actor_is_agent` are true for
  a service principal.
- Who am I answers `principal_id`, `name`, `actor_kind`, `organization_id`,
  `can_submit` and `can_decide`.
- MCP answers add `asOf`, `hints` and `nextActions`.

Refusal codes:

| Code | REST | RPC | MCP | When |
|---|---|---|---|---|
| `core.patch.not_found` | 404 | -32011, `patchId` `not_found` | isError | no such patch among those the caller may see |
| `core.patch.not_approver` | 403 | -32010 | isError | the caller does not hold `patch.decide` |
| `core.patch.own_patch` | 403 | -32010 | isError | the caller submitted the patch (four eyes) |
| `core.patch.not_pending` | 409 | -32010 | isError | the patch was decided already, or is invalid |
| `core.patch.stale` | 409 | -32010 | isError | a product changed after the upload |
| `core.patch.file_invalid` | 422 + `invalid-params` | -32011 + `invalid-params` | isError + `invalidParams` | `file_name` or `lines` is `required` or `invalid` (`core.fn_patch_problems`) |
| `core.patch.arguments_invalid` | | | isError + `invalidParams` | a `patchId` that is not a uuid |

Line problems are not refusals: a submitted file with a line problem is
stored as `invalid`, and each line carries its code in `problem`:
`core.patch_line.product_not_found`, `field_unknown`, `duplicate`,
`reason_required`, `value_invalid`, `value_unchanged`
(`core.fn_patch_line_problems`). The dispatcher's own refusals (401, 403
`pgmi.forbidden`, 400 for a body that breaks the declared schema) come before
any of these.

An MCP connection acts with its `agent.*` role, which must fit inside its
person's permissions. Of the roles in `data/authorization.json` only
`agent.delegate` carries `patch.*`, and it fits only an owner or
administrator.

| File | Holds |
|---|---|
| `core/patch-read.sql` | the JSON each read answers, one `LANGUAGE sql STABLE` function per read, from the patch views |
| `api/patch-desk.sql` | the routes, methods and tools |
| `api/__test__/test_patch_handlers.sql` | tests over REST, RPC and MCP: submit, check, lists, approve and reject, each refusal, another organization |
| `api/__test__/database_logins/test_patch_logins.sql` | tests with a person's own login (superuser deploys only): submit, list and decide as themselves; forged identity ignored; unmapped login refused |

**The export job.** The `patch_export` job (`jobs/patch_desk_job.py export`)
copies approved fixes to the lakehouse. It calls two job routines and
nothing else in the database:

| Routine | Does |
|---|---|
| `api.job_patch_export_batch(p_full)` | `{patch_ids, product_count, products}`: the approved, not yet exported patches of every organization and the products they changed (every product when `p_full`), each with its latest approved patch, approver and time |
| `api.job_patch_mark_exported(p_patch_ids)` | sets `exported_at` and writes one `exported` event per patch, in the name of the login's registered service principal; the count marked, 0 on a repeat, NULL (nothing marked) for a login that is no registered service principal |

They run outside any request and read no `auth.*` setting or header. The
kernels behind them (`core/patch-export.sql`) are owned by the kernel role,
which `core/patch-export-structure.sql` lets past the patch tables'
row-level security; that file also narrows the two restrictive policies on
`core.patch` (own patches or `patch.decide`) to the owner, which runs every
request: created without `TO`, a policy applies to every role
([CREATE POLICY](https://www.postgresql.org/docs/current/sql-createpolicy.html)),
so they bound the kernel too.

The job runs as the deploy service principal and reaches the routines as a
member of the owner, as [The jobs login](#the-jobs-login-optional) allows the admin login to.
It is not the template's jobs login (`database_jobs_role`): the deploy login
executes every routine through the owner, and
`lib/__test__/test_exact_grants.sql` refuses a jobs login that can. Nor is it
mapped: `provision_principals` registers it once as service principal
`service.patch_export` (`membership.fn_register_service_principal`), which
only names it in the audit trail and leaves it naming no one in a request.
Tests: `core/__test__/test_patch_export.sql`, and
`jobs/tests/test_export_db.py` after the app's data layer test in
`local-check.sh`.

One change to generated files keeps the deploy output free of warnings:
`deploy/finalize.sql` leaves out a provider's event-trigger functions in
schema `public` when it revokes `EXECUTE` from `PUBLIC`
(`pg_temp.provider_event_trigger` in `deploy/providers.sql`).

Check a change locally with `db/local-check.sh` (needs docker and pgmi). It
deploys twice as a non-superuser owner with `CREATEROLE`, `CREATEDB` and
`BYPASSRLS`, the second time on top of the first, then once as a superuser
into a fresh database, where the tests that switch login run. It ends with
`local check passed`.

On the demo, the `pgmi_deploy_template` task of the `db_deploy` job deploys
this project into the database `lakebase_apps` with `env=test`
(`resources/db_deploy.yml`).

The rest of this file is the template's own README, as pgmi generated it.

---

# Advanced Template

An optional architecture where PostgreSQL is your application server — HTTP routing, business logic, and data in one transactional system. Treat it as a starting point to own and adapt, not a worldview pgmi requires.

> **New to this approach?** Read [ARCHITECTURE.md](ARCHITECTURE.md) first to understand the "Application as Dataset" philosophy, layered schema design, and when this template is right for your project.

## When to Use This Template

Choose it when the database should hold the business logic and serve REST, RPC and MCP from one handler registry. [Choosing a template](https://vvka-141.github.io/pgmi/docs/templates/) compares it with the basic template.

**Requires PostgreSQL 18 or newer.** `deploy.sql` refuses an older server before it creates any objects; the empty database pgmi created for the deploy stays.

**No superuser required.** A login with `CREATEROLE` and `CREATEDB` deploys it: `deploy.sql` grants itself the roles it creates. [Production Guide](https://github.com/vvka-141/pgmi/blob/main/docs/PRODUCTION.md#managed-cloud-postgresql) shows the statement that creates that login. `TestAdvancedTemplate_DeploysWithoutSuperuser` deploys it twice that way. Entity lifecycle standards (`created_at`/`deleted_at`) are enforced by a deploy-end sweep over `pg_temp` functions — no DDL event trigger, no superuser privilege. For a managed host, see [On a managed host](#on-a-managed-host).

## Deployment Architecture

The handlers run behind a web server or API gateway; PostgreSQL is never exposed to the internet. The gateway calls `api.rest_invoke` for REST and `api.mcp_handle_request` for MCP, each after the matching policy function (`api.rest_route_policy`, `api.mcp_request_policy`). JSON-RPC goes through `api.rpc_route_policy` and `api.rpc_invoke`; a gateway routes it at `POST /rpc`, and `api/patch-desk.sql` has the patch desk's methods. `api.mcp_handle_request` dispatches a tool call to `api.mcp_call_tool` inside the database. `gateways/PROTOCOL.md` lists every function a gateway calls.

### Why This Architecture?

| Concern | Handled By | Rationale |
|---------|------------|-----------|
| TLS/HTTPS | Gateway | Web servers excel at TLS, connection pooling |
| Rate limiting | Gateway | Stateless, before hitting database |
| Header validation | Gateway | Reject malformed requests early |
| OIDC sign-in | Gateway | Validates the ID token, then `api.open_login_session`; PostgreSQL owns the session |
| CORS | Gateway | Simple header manipulation |
| Error sanitization | Gateway | Don't leak SQLERRM to clients |
| Business logic | PostgreSQL | Transactional, close to data |
| Authorization (RLS) | PostgreSQL | Row-level filtering at query time |
| Data validation | PostgreSQL | Constraints and `*_problem` functions |
| Complex operations | PostgreSQL | Single roundtrip, ACID guarantees |

### Gateway integration

A gateway turns each HTTP request into one call,
`SELECT * FROM api.rest_invoke(method, path, headers, body)`, and copies the
answer back. Around that call a gateway also

- checks `Origin` and the `X-CSRF-Token` header on every write;
- resolves the route's transaction policy (`api.rest_route_policy`) and opens
  the transaction it needs, so `readOnly` routes and isolation floors work;
- retries a serialization failure or deadlock (40001, 40P01);
- reads the login session from its own `__Host-session` cookie and never
  forwards the client's `Cookie`, `x-login-session`, `x-connection` or
  `x-csrf-token` headers as they came;
- strips the `/api` mount before the path reaches the database;
- answers a database error with a sanitized 500 and logs the detail.

`gateways/PROTOCOL.md` states every rule a gateway in any language follows.

## Project Structure

```
myproject/
├── lib/                      # Pre-built framework — extend around it; see "Trimming the template"
│   ├── api/                  # HTTP framework (types, routing, gateways, MCP)
│   ├── internal/             # Environment label, deploy history views
│   ├── core/                 # Managed object infrastructure
│   ├── common/               # Cross-cutting primitives (casting, encoding, text)
│   ├── __test__/             # Framework tests
│   └── README.md             # Framework API reference
├── membership/               # Principals, organizations, memberships, roles, invitations, audit
├── core/                     # YOUR tables and kernels (create it; see .agents/skills/pgmi-endpoint)
├── api/                      # YOUR API HANDLERS
│   ├── examples.sql          # Starting point - modify/replace this
│   ├── sessions.sql          # Organization sessions for a signed-in tab
│   ├── connections.sql       # Approve, list and revoke MCP client connections
│   ├── admin.sql             # Operator endpoints (platform.operate)
│   └── proposals.sql         # Agent proposals a person confirms or rejects
├── __test__/                 # YOUR TESTS
├── data/authorization.json   # Permission vocabulary and roles, synced every deploy
├── data/catalogs/            # Reference data synced by pg_temp.sync_catalog (create when needed)
├── gateways/PROTOCOL.md      # The wire rules for a gateway; never deployed
├── deploy.sql                # The deployment, top to bottom: phases, transaction, file loop
├── deploy/                   # Setup deploy.sql runs by name (settings.sql: the lists you edit; parameters.xml: the declared parameters)
├── pgmi.yaml                 # Project configuration (connection, params, timeout)
├── ARCHITECTURE.md           # Design rationale
└── README.md
```

### What Goes Where

| Directory | Purpose | Modify? |
|-----------|---------|---------|
| `lib/` | Framework code (HTTP routing, types, utilities) | Rarely - extend in root dirs instead |
| `core/` | Your entity tables (run once) and kernels, the functions that write them | Yes - create it for your domain |
| `api/` | Your HTTP handlers (REST, RPC, MCP) | Yes - your application code |
| `__test__/` | Tests of the whole project; an API test goes in `api/__test__/`, over its Alice fixture | Yes - add tests here |
| `deploy.sql` | Deployment phases, transaction control, the file loop | Yes - customize deployment |
| `deploy/` | Setup `deploy.sql` runs by name: settings, providers, parameters, file rules, roles, schemas, ledger, finalize | `settings.sql` yes; others rarely, in the file whose name fits |

### deploy.sql and deploy/

`deploy.sql` reads as the deployment, top to bottom, in five banners:
PREFLIGHT, BOOTSTRAP, DEPLOY, VERIFY and TAIL. Its setup code lives in
`deploy/`, a fixed set of files `deploy.sql` runs by name through
`pg_temp.run_file`. They are not in the plan and carry no `<pgmi-meta>` block.

- `deploy/settings.sql` holds the lists a project edits: required extensions,
  database settings, schema grants, tenant columns and the optional guards.
- Add code to the `deploy/` file whose name fits. A new `deploy/` file is a
  design change, not a place for one more statement.
- `deploy/` files run inside the deploy's transaction: they never `COMMIT` and
  never build an index `CONCURRENTLY`. Those go in the TAIL of `deploy.sql`.

## Trimming the template

This template is a working reference system, not a framework you must keep whole. The `lib/` files are coupled and tested — extend *around* them in root directories rather than editing internals — but you are meant to own the result and cut what you don't need.

This project has removed the template's reference gateways, the
development-only handlers (`api/dev/`, `membership/dev/`), change tracking,
the entity registry, per-organization numbering, the member and invitation
routes, the access explorer's routes, the ownership-transfer route and the
`echo` example, each with its own tests.

**Keep, and change instead:**
- `api/examples.sql` — the framework's tests use its handlers (`hello_world`, `health_check`, `get_current_user`, `list_organizations`, `get_organization`, `echo_note`) as fixtures. Change their bodies freely and add your handlers beside them; removing them means removing the tests that name them.

**Load-bearing — removing these is a rework, not a delete:**
- **Membership** (`membership/`) — the identity readers (`api.current_principal_id()`, `api.current_organization_id()`) are defined there and called from `lib/`, so deleting it fails the deploy with exit 13 at the first `lib/` file. A single-login site keeps one organization and drops the invitation and sign-up handlers instead.
- **Entity standards** (`lib/core/entity-standards.sql`) — adds `created_at`/`deleted_at` to entity tables, and the handler registry reads `api.handler.deleted_at`.
- **Access explorer** (`membership/10-access-explorer.sql`) — the access-matrix test checks every handler against `membership.fn_simulate_access`.
- **Background jobs' run log** (`lib/internal/job-run-log.sql`) — the maintenance jobs write `internal.job_run_log`.
- **Role hierarchy and schema grants** — `database_owner/admin/api/kernel` own every object and back every `GRANT` and RLS policy. If your org manages roles externally, override the role *names* via parameters (see Parameters below); don't delete the hierarchy.
- **MCP support** — woven through the shared API files (types, handler registry, helpers, gateways), not isolated to the `*-mcp-*` files. If you don't use MCP, simply don't register MCP handlers — the protocol code stays dormant and harmless. Physically removing it means editing the framework's core files.

## Quick Start

### 1. Deploy

Every deploy says which environment it targets with `env`: `dev`, `test` or
`prod`. There is no default.

On a local, disposable database, `env=dev` is enough: missing role passwords
default to `postgres`, with a warning.

```bash
pgmi deploy . --database myapp_dev --param env=dev
```

Anywhere else, use `env=test` or `env=prod` and pass the admin
password in a params file, **never as command-line `--param`**. Values on the
command line leak to the process list (`ps`), shell history, and CI logs. Use
strong, generated values; the names below are placeholders.

```bash
# PGMI_PARAM_<NAME> becomes parameter <name>; nothing reaches argv or disk.
export PGMI_PARAM_DATABASE_ADMIN_PASSWORD='CHANGE_ME'
pgmi deploy . --database myapp --param env=prod
```

In CI, map the secret straight to the variable
(`PGMI_PARAM_DATABASE_ADMIN_PASSWORD: ${{ secrets.DB_ADMIN_PASSWORD }}`). A
missing secret arrives empty and pgmi refuses it (exit 10). Stdin
(`--params-file -`) and a private params file also work; see the
[pgmi Security Guide](https://github.com/vvka-141/pgmi/blob/main/docs/SECURITY.md#pipeline-patterns).

### On a managed host

Every host needs the same three things: PostgreSQL 18, a login with
`CREATEDB` and `CREATEROLE` (the server's administrator login has both), and
the extensions `uuid-ossp`, `pgcrypto`, `pg_trgm`, `hstore` and `btree_gist`.
A first deploy checks the login and Azure's extension list before it changes
anything, and names what is missing.

| Host | Before the first deploy |
|---|---|
| Azure Database for PostgreSQL | Add the five extensions to the server parameter `azure.extensions`, keeping what it lists: `az postgres flexible-server parameter set --resource-group <group> --server-name <server> --name azure.extensions --value UUID-OSSP,PGCRYPTO,PG_TRGM,HSTORE,BTREE_GIST`. Sign in with `--azure` |
| Amazon RDS and Aurora | Sign in with `--aws`; pass the RDS certificate bundle with `--sslrootcert` |
| Google Cloud SQL | Sign in with `--google --google-instance <project:region:instance>`. An IAM user needs `ALTER ROLE "<user>" CREATEDB CREATEROLE`, run as `postgres` |
| Databricks Lakebase | Connect to the maintenance database `databricks_postgres` ([Lakebase guide](https://vvka-141.github.io/pgmi/docs/lakebase/)). The deploy recognises Lakebase and sets `provider_role_pattern` and `provider_schemas` itself; with `env=dev` the admin password is a generated one, because Lakebase refuses `postgres` |

Connect to the server directly, not through a transaction pooler (PgBouncer
on port 6432, RDS Proxy): a deploy is one session.

### 2. Test the Examples

Tests run automatically as part of deployment via the `pgmi_test()` macro in deploy.sql. If all tests pass, the deployment commits. If any test fails, the deployment rolls back.

### 3. Add Your Own Handler

Edit `api/examples.sql` or create a new file in `api/`:

```sql
/*
<pgmi-meta
    id="YOUR-UUID-HERE"
    idempotent="true">
  <description>My custom handler</description>
  <sortKeys>
    <key>005/100/my_endpoint</key>
  </sortKeys>
</pgmi-meta>
*/

SELECT api.create_or_replace_rest_handler(
    jsonb_build_object(
        'id', 'YOUR-HANDLER-UUID',
        'path', '/my-endpoint',
        'httpMethod', '^GET$',
        'name', 'my_endpoint',
        'description', 'My custom endpoint',
        'access', 'public',
        'outputSchema', jsonb_build_object(
            'type', 'object',
            'properties', jsonb_build_object('message', jsonb_build_object('type', 'string')),
            'required', jsonb_build_array('message')
        )
    ),
    $body$
BEGIN
    RETURN api.json_response(200, jsonb_build_object(
        'message', 'Hello from my endpoint!'
    ));
END;
    $body$
);
```

### 4. Add Tests

An API test goes in `api/__test__/test_<entity>.sql`, beside the shipped ones.
A test file takes no `<pgmi-meta>` block. It runs on every deploy, inside a
savepoint that is rolled back, over `api/__test__/_setup.sql`, which signs Alice
up as the owner of Acme Corp:

```sql
DO $$
DECLARE
    v_h    extensions.hstore := pg_temp.test_session_headers(current_setting('test.alice_subject'),
                                                             current_setting('test.acme_org_id')::uuid);
    v_resp api.http_response;
BEGIN
    v_resp := api.rest_invoke('GET', '/my-endpoint', v_h, NULL::bytea);
    IF (v_resp).status_code IS DISTINCT FROM 200 THEN
        RAISE EXCEPTION 'GET /my-endpoint: want 200, got %', (v_resp).status_code;
    END IF;
END $$;
```

`.agents/skills/pgmi-testing/SKILL.md` covers placement, fixtures and
assertions that cannot pass by accident; the worked example's test block in
`.agents/skills/pgmi-endpoint/references/example.md` covers a whole entity, and
`.agents/skills/pgmi-api/references/identity-and-access.md` the identity helpers.

## Metadata-Driven Deployment

The advanced template uses pgmi's optional metadata system for path-independent tracking, idempotency control, and explicit ordering. For a complete guide, see [docs/METADATA.md](https://github.com/vvka-141/pgmi/blob/main/docs/METADATA.md).

Every script requires a `<pgmi-meta>` block:

```sql
/*
<pgmi-meta
    id="550e8400-e29b-41d4-a716-446655440000"
    idempotent="true">
  <description>What this script does</description>
  <sortKeys>
    <key>005/001</key>
  </sortKeys>
</pgmi-meta>
*/
```

### Attributes

| Attribute | Required | Description |
|-----------|----------|-------------|
| `id` | Yes | UUID for path-independent tracking |
| `idempotent` | Yes | `true` = re-run every deploy, `false` = once only |

### Child elements

| Element | Required | Description |
|---------|----------|-------------|
| `sortKeys` | Yes | Execution order (lexicographic). `deploy.sql` refuses a SQL file without one ("SQL file(s) without a place in the plan"); application files use `005/100/...` or later (see [Sort Key Conventions](#sort-key-conventions)) |
| `description` | No | Human-readable purpose |

### Sort Key Conventions

| Range | Purpose |
|-------|---------|
| `001/...` | `lib/common`: casting, encoding, text |
| `002/...` | `lib/internal`: environment label, job run log |
| `003/...` | `lib/core`: managed-object infrastructure, catalogs; `lib/internal/views.sql` |
| `004/...` | `lib/api`: handler registry, routes, gateways, MCP, OpenAPI |
| `005/000/...` | `membership/` |
| `005/001` to `005/008` | the shipped handlers in `api/` |
| `005/100/...` | your files: one prefix per entity, structure before kernel before handlers (`005/100/project/1`, `/2`, `/3`) |

## Three Protocols

The framework supports REST, RPC, and MCP protocols:

### REST Handlers

An excerpt of `get_project` from
[`.agents/skills/pgmi-endpoint/references/example.md`](.agents/skills/pgmi-endpoint/references/example.md),
which deploys in full with its table, kernel and test:

```sql
SELECT api.create_or_replace_rest_handler(
    jsonb_build_object(
        'id', 'c503ec2d-1f5d-4b57-9b56-acd3b9cab6c2',
        'name', 'get_project',
        'description', 'Read one project',
        'path', '/projects/{id:uuid}',
        'httpMethod', '^GET$',
        'access', 'organization',
        'outputSchema', jsonb_build_object('$ref', '#/components/schemas/Project')),
    $body$
DECLARE
    v_row core.vw_project;
BEGIN
    SELECT * INTO v_row FROM core.vw_project
    WHERE object_id = ((request).path_params->>'id')::uuid;
    IF NOT FOUND THEN
        RETURN api.problem_response(404, 'Not Found', 'Project not found', code => 'core.project.not_found');
    END IF;
    RETURN api.json_response(200, core.fn_project_json(v_row));
END;
    $body$);

-- Invoke: api.rest_invoke('GET', '/projects/' || v_id, headers)
```

A route is a `path` template. A parameter takes a whole segment: `{name}` is
text, `{name:uuid}` and `{name:int}` are checked by the dispatcher (`api.rest_invoke`), which answers
400 `pgmi.invalid_path_parameter` to a malformed value after the access decision. The
handler reads the values, percent-decoded, from `(request).path_params`. A
literal segment outranks a parameter, so `/users/me` and `/users/{userId:int}`
coexist in any order; registration refuses a segment mixing text and a parameter
(`/files/{name}.json`) and a second route of one shape with a common method.
There is no regex route and no route versioning: version in the path
(`/v2/users`). OPTIONS and 405 list every method of a path, whoever asks.

### RPC Handlers

```sql
SELECT api.create_or_replace_rpc_handler(
    jsonb_build_object(
        'id', 'handler-uuid',
        'methodName', 'users.create',
        'description', 'Create a new user',
        'access', 'authenticated'
    ),
    $body$
BEGIN
    -- JSON-RPC 2.0 handler
    RETURN api.jsonrpc_success(
        jsonb_build_object('userId', 123),
        api.content_json((request).content)->'id'
    );
END;
    $body$
);

-- Invoke: api.rpc_invoke(api.rpc_resolve('users.create'), headers, content)
```

### MCP Handlers

A tool answers one task, not a table or a query: `review_project_tasks` in
[`.agents/skills/pgmi-mcp/references/tool-example.md`](.agents/skills/pgmi-mcp/references/tool-example.md)
deploys in full with its schemas, refusals, paging and test. Its shape:

```sql
SELECT api.create_or_replace_mcp_handler(
    jsonb_build_object(
        'id', 'b4e1c7a2-6f3d-4b8e-9a51-2c7d0e8f4a96',
        'type', 'tool', 'effect', 'read',
        'name', 'review_project_tasks',
        'description', 'The tasks of one project, overdue first, then by due date. ...',
        'permissions', jsonb_build_array('task.read'),
        'inputSchema', ...,    -- project (uuid), states, detail, limit, offset
        'outputSchema', ...),  -- tasks, total, hasMore, asOf, hints, nextActions
    $body$ ... $body$);

-- Invoke: api.mcp_call_tool('review_project_tasks', arguments, context, request_id)
```

**MCP identity.** An MCP caller is the agent of a connection a person
approved. The client gets one of two ways:

- **OAuth.** With `MCP_RESOURCE` set, the gateway is an OAuth resource
  server: the client signs in at the identity provider for a token whose
  audience is `/mcp`, and the gateway passes the database only the token's
  issuer, subject and client id. The first call of a new (person, client)
  answers `-31001` `membership.connection.pending` with a pairing code; the
  person, signed in on the web, approves it with `POST /connections/approve`
  (`{pairingCode, organizationId, roleId, validDays}`).
- **A handle.** Signed in on the web, the person calls `POST /connections`
  (`{clientName, organizationId, roleId, validDays}`) and gets the
  connection's handle once; the client sends it as
  `Authorization: Bearer cn_...` or `X-Connection`. A handle that names no
  live connection is HTTP 401.

The database resolves either to the person, in the organization chosen at
approval: a client cannot name another organization, and nothing on MCP
provisions anyone. Wire rules: `gateways/PROTOCOL.md`.
Approval also creates the connection's own **agent principal**. A call through
the connection acts *for* the person (the effective principal,
`api.current_principal_id()`, which row-level security sees) and is made *by*
the agent (the actual principal, `api.current_actual_principal_id()`), with
`api.current_actor_kind()` = `agent`; a person's own call is `human`. The audit
log, the access-denial log and the exchange log record both
principals and the actor kind. A platform operator lists what one agent did
with `GET /admin/exchanges?actualPrincipalId=<agent id>`, newest first.

**Agent roles.** `roleId` is one of the `agent.*` roles in
`data/authorization.json` (`agent.reader`, `agent.contributor`,
`agent.delegate`). The agent holds that role's permissions intersected with
its person's in the organization, recomputed on every request, so a person who
loses a permission takes it from their agents at once. Approval refuses a role
granting anything the person lacks there (422 `membership.connection.role_too_broad`), an
organization they are not a current member of (422 `membership.connection.not_member`),
and any request but a person's own signed-in one: an agent never approves or
extends an agent. Agent roles are never assigned to members or offered in
invitations.

**Agent lifecycle.** The person lists their connections (`GET /connections`),
reads one (`GET /connections/{id}`, the `Location` that `POST /connections`
answers) and pauses, resumes or revokes one (`POST /connections/{id}/pause`,
`.../resume`, `DELETE /connections/{id}`). A holder of `members.manage` does
the same for every connection into the request's organization under `/agents`
(`GET /agents`, `POST /agents/{id}/pause`, `.../resume`,
`DELETE /agents/{id}`); a pause a manager made is lifted only by a manager:
while it stands, its person can neither revoke that connection nor approve a
new one in that organization.
The owner switches every agent of the organization off and on
(`POST /agents/disable`, `POST /agents/enable`). A connection acts only while
it is not paused, revoked or expired, its membership is current and its
organization's agents are on; ending a membership revokes the person's
connections into it. Each change is in the audit log with the agent as its
subject, and a logged agent call replays only while its connection is live. A
connection carries no second factor, so it never holds a platform permission.

**Proposals: an agent proposes, a person confirms.** A tool with
`"effect": "proposal"` names, in `"proposes"`, a registered tool with
`"effect": "write"` (registration refuses a missing, unknown or non-write
target, and `"reversible"`: nothing changes until someone confirms; it also
refuses a target above read committed, because confirming runs at read
committed, so such a tool is called directly). Its body
calls only `membership.fn_propose(<target>, (request).arguments)` and answers
`{"proposalId": ...}` at once; the call never waits for a person. It is called
under the permission it declares, like any tool, so a role's grant list stays
the only ceiling: `agent.reader` may hold `task.propose` without `task.write`.
A person signed in on the web, acting as themselves and holding
`proposals.decide`, lists the organization's pending proposals
(`GET /proposals`) and confirms (`POST /proposals/{id}/confirm`) or rejects
(`POST /proposals/{id}/reject`) each. Confirming runs the target tool through
the MCP dispatcher as that person, so the target's own permission applies to
them, and answers the proposal with the tool's `answer`; a target that refuses
answers 409 `membership.proposal.tool_refused` and leaves it pending. The 409
rolls back everything the confirm wrote, the target's `api.access_denial` and
`api.mcp_exchange` rows included; the refusal is recorded in the confirm
request's `api.rest_exchange` row, whose response carries the target's error,
refusal code included, under `answer`. An agent
never decides (403 `membership.proposal.human_required`), and a decided
proposal is decided for good (409 `membership.proposal.decided`).

Any handler may declare a minimum isolation floor (`minTransactionIsolation`); a REST or RPC route may declare a read-only policy (`readOnly`), which leaves it unlogged. The HTTP gateway (`gateways/PROTOCOL.md`) resolves the policy before `BEGIN`; the database enforces it fail-closed. See [Transaction policy](https://vvka-141.github.io/pgmi/docs/advanced/transaction-policy/).

## Parameters

| Parameter | Default | Required | Description |
|-----------|---------|----------|-------------|
| `env` | - | **Yes** | `dev`, `test` or `prod`. See [Environments](#environments) |
| `database_admin_password` | `postgres` when `env=dev` on a new or dev-labelled database (on Lakebase, which refuses a weak password, a generated value) | **Yes**, otherwise | Admin role password |
| `relabel_environment` | empty | No | Change the database's label; must equal `env` |
| `upgrade` | `false` | No | `true` refuses unless the database already carries the label `env` names |
| `platform_operators` | `[]` | No | JSON array of platform operators (`email`, optional `displayName`, `issuer` + `subject`); synced every deploy, a person left out loses the status; an email-only entry names the address's verified holder, or a new verified person (an unverified holder is never promoted); an entry with `issuer` and `subject` names that login's person and verifies the address on it, refused (22023) when another person holds the address verified |
| `oidc_issuers` | `[]` | No | JSON array of OIDC issuer URLs people may sign in with (`api.open_login_session`); synced every deploy, an issuer still holding logins cannot be dropped |
| `platform_mfa_required` | `true` | No | Platform permissions need a login session whose `amr` includes `mfa`; `false` turns the check off |
| `exchange_retention_days` | `30` | No | Days the exchange log keeps a row: the retention of the `purge_exchanges` job and the default of `POST /admin/maintenance/purge-exchanges` |
| `api_base_path` | `/api` | No | The path the gateway serves REST under; the OpenAPI `servers` url, so generated clients and `/docs` call the right paths |
| `www_authenticate` | `Session` | No | The `WWW-Authenticate` challenge on a 401 (RFC 9110 §15.5.2), e.g. `Bearer realm="app"` |
| `provider_role_pattern` | `databricks\_%` on Lakebase, else empty | No | A managed provider's own roles, as a `LIKE` pattern (Lakebase: `databricks\_%`); every deploy revokes their `CREATE` on the template's schemas and `extensions` and their whole-table privileges (`TRUNCATE`, `REFERENCES`, `TRIGGER`, `MAINTAIN`) on its tables; the guards ignore their `USAGE` on schemas, their row-level DML on membership tables and event-trigger functions another role keeps in `public`. Refused when it matches a template role. Row-level security still binds them ([Production Guide](https://github.com/vvka-141/pgmi/blob/main/docs/PRODUCTION.md#grants-a-provider-makes-on-its-own)) |
| `provider_schemas` | `["__db_system"]` on Lakebase, else `[]` | No | A managed provider's own schemas, as a JSON array (Lakebase: `["__db_system"]`); the schema guard leaves them out. Refused when it names a template schema |
| `database_owner_role` | `<dbname>_owner` | No | Owner role (NOLOGIN). An existing owner, kernel or api role on which another login holds ADMIN, or an owner, admin or kernel role with a member the deploy did not grant, is refused (22023), never adopted |
| `database_admin_role` | `<dbname>_admin` | No | Admin role (LOGIN, full access). The deploy creates it; an existing role that is not a member of this database's owner role is refused (22023), never adopted |
| `database_api_role` | `<dbname>_api` | No | API group role (NOLOGIN, permission bundle) |
| `database_kernel_role` | `<dbname>_kernel` | No | Kernel role (NOLOGIN): owns the membership kernels; never granted to a login |
| `database_jobs_role` | `<dbname>_jobs` | No | Background jobs login; never created by the deploy. When it exists and is a registered service principal, granted `CONNECT`, `USAGE` on `api` and `EXECUTE` on every `api.job_*` routine. See [The jobs login](#the-jobs-login-optional) |

Pass the required password parameters as `PGMI_PARAM_*` environment variables,
stdin or a params file, never as command-line `--param` — see [Deploy](#1-deploy).

Defaults sit beside the values, in one `CASE` in `deploy/parameters.sql`. A parameter
without a default is required, and a blank value counts as not given.

The parameters are declared in `deploy/parameters.xml`; a parameter it does not
declare is refused. Each value is readable in SQL as
`current_setting('pgmi.<key>')`, or through `pg_temp.deployment_setting('<key>')`
during the deploy.

Every deploy sets the admin role's password to `database_admin_password`, so
the parameter is the password's source of truth: rotating it is a redeploy with
the new value, for example from a key vault through
`PGMI_PARAM_DATABASE_ADMIN_PASSWORD`.

## Environments

The first deploy records `env` in `internal.environment`. Every later deploy
must name the same label, or it is refused before any role is touched: a stray
`env=dev` against a production database cannot reset its passwords to the dev
default.

- **Relabel on purpose** (say, a restored copy of production becoming a test
  database): pass the new label as both `env` and `relabel_environment`. The
  deploy warns. It is refused when the database is new or already carries that
  label, so a leftover `relabel_environment` in a params file fails the next
  deploy instead of staying switched on. Relabelling to `dev` does not default
  the passwords: pass them.
- **`upgrade=true`** is for pipelines that only ever upgrade: the deploy is
  refused unless the database already carries the label `env` names, so a typo
  in the database name never builds a fresh one. It cannot be combined with
  `relabel_environment`.

**Dev-only files.** A file under a `dev/` folder, at any depth
(`api/dev/fixtures.sql`), deploys only with `env=dev`. The plan loop, the
file-contract check and the run-once drift check all ask
`pg_temp.deploys_file(path)`, so a run-once `dev/` file that ran while the
database was dev is not drift on a `test` deploy. Tests run in every
environment, so a `__test__/` under `dev/` is refused; branch on
`current_setting('pgmi.env')` in an ordinary test instead.

## Sign-in, sessions and connections

The database signs no one in. The transport in front of it (your web server or
gateway) does, and must:

1. Run the OIDC sign-in (authorization code with PKCE) against an issuer listed
   in `oidc_issuers`, and check the ID token.
2. Call `api.open_login_session(iss, sub, email, name, email_verified, amr)` as
   its login in the api role, passing `email_verified` and `amr` as the provider
   sent them. It returns an opaque handle, or a problem code
   (`membership.login.issuer_unknown`, `membership.login.subject_invalid`,
   `membership.login.email_missing`, `membership.login.email_unverified`,
   `membership.login.principal_disabled`, `membership.login.refused`). This
   is the only place a person is provisioned; it creates no organization.
3. Keep only that handle, in an `HttpOnly`, `Secure`, `SameSite=Strict` cookie, and
   write it as `x-login-session` on every request.
4. Never forward a session or connection header it did not issue: a
   client-sent `x-login-session`, in any letter case, is dropped. The tab's
   `x-organization-session` (from `POST /organization-sessions`) is forwarded;
   it is valid only inside its own login session. When two header names differ
   only in case, REST and RPC answer 400.
5. On logout, call `api.close_login_session(handle)` and clear the cookie.

MCP clients send an OAuth access token or `X-Connection`, a handle a person
approved with `POST /connections` (see MCP identity above).

The full contract: [Login transport contract](https://vvka-141.github.io/pgmi/docs/advanced/login-transport/).

## Organizations and members

Organizations are invitation-only. A platform operator creates one with
`POST /admin/organizations` (`{name, slug, ownerEmail}`): it starts `pending`
with an owner invitation, and becomes `active` when that person signs in with
the verified address. Signing in never creates an organization.

**Only a verified address belongs to someone.** At most one person holds an
address verified; any number may hold it unverified. A new login links to the
verified holder only when its own email is verified too, and is refused
otherwise (`membership.login.email_unverified`). For an address no one has
verified, a new login always gets a person of its own, so an unverified sign-up
never locks the address's real owner out. Such an address never blocks an invitation.

**Members.** Members, roles and invitations are written by the membership
kernels (`membership.fn_add_member`, `fn_grant_role`, `fn_invite`, ...); the
demo's provisioning calls them. There are no REST routes for them. Ownership
moves only by `membership.fn_transfer_ownership`.

**Who may call what.** A handler declares `permissions` from
`data/authorization.json` and the dispatcher refuses everyone else with 403 before
its body runs. `api/__test__/test_access_matrix.sql` calls every
permission-guarded REST handler as each role and as a platform operator, against
a table written out by hand. Change that table in the same commit as a role's
grants or a handler's `permissions`; a new permission-guarded handler fails the
matrix until it has a row.

**Access explorer.** `membership/10-access-explorer.sql` answers "who may call
what, and why" from four starting points: `membership.vw_handler_access` (by
handler), `vw_role_access` (by role), `vw_permission` (by permission) and
`vw_access_path` (by person, one row per path through a role or platform
status). `membership.fn_simulate_access(person, organization, method, url)`
predicts the dispatcher's answer with the dispatcher's own routing
(`internal.rest_route_lookup`) and decision (`internal.access_denial_reason`),
assuming a session with a second factor. The views are security_invoker, so
psql as the owner sees what the request context lets it see. The access matrix checks that the
simulation agrees with the dispatcher for every handler and role.

## Role Hierarchy

```
database_owner_role (NOLOGIN)
  └── owns all database objects; every handler runs as it
  └── holds kernel WITH INHERIT FALSE, SET TRUE

database_kernel_role (NOLOGIN)
  └── owns the SECURITY DEFINER kernels that work across organizations
  └── passes forced row-level security by its own policies

database_api_role (NOLOGIN)
  └── the gateway's bundle: its entry points, nothing else

database_admin_role (LOGIN)
  └── inherits: owner + api

database_jobs_role (LOGIN, optional, never created by the deploy, granted only once registered)
  └── api.job_* routines, nothing else
```

Row-level security reads the request context (`auth.*`), which counts only
from a login in the api role: the gateways state it from the session handles,
and a session outside the api role that sets it is ignored. Grant the api role
only to logins you trust to state who calls.

**Each role executes exactly its list.** The api role executes the gateway
entry points (`api.rest_invoke`, `api.rpc_invoke`, `api.rpc_resolve`,
`api.mcp_handle_request`, the route-policy lookups, `api.catalog_version`,
`api.open_login_session` and `api.close_login_session`), granted once at the end of the
deploy (`deploy/finalize.sql`). The admin login has no grant of its own; it is a member of the
owner. The optional jobs login executes every `api.job_*` routine and nothing
else. No routine is executable by `PUBLIC`. `lib/__test__/test_exact_grants.sql`
fails the deploy on any other grant.

**Forced row-level security.** Every table the owner has in an application
schema is `ENABLE` + `FORCE ROW LEVEL SECURITY` with at least one policy, so
the owner, which runs every handler, is held to the policies too. A table that
holds no organization's rows is declared exempt with the reason, in the
run-once file that creates it:

```sql
SELECT pg_temp.exempt_from_rls('core.country', 'reference data synced by the deploy');
```

`lib/__test__/test_forced_rls.sql` names any table that is neither. It also
names FORCE without ENABLE, a table without an organization column whose foreign
key points at one with it (its rows belong to an organization too, so an
exemption does not cover it), a table with an organization column, row-level
security off and a `SELECT` grant beyond the owner, admin and kernel, and an
exemption whose table is gone or now forced. The organization columns are
`pg_temp.tenant_column()` in `deploy/settings.sql`.

**Kernels.** Membership rows are read by requests through the owner's
policies (themselves, their organization, the organizations they belong to)
and written only by kernels: `SECURITY DEFINER` functions handed to the kernel
role right after their `CREATE`, which pass every row by the kernel's own
policy (`pg_temp.kernel_passes`):

```sql
SELECT pg_temp.kernel_owns('membership.fn_grant_role(uuid, text)');        -- the owner may call it
SELECT pg_temp.kernel_owns('membership.fn_record_audit_event(text, uuid, uuid, jsonb)', false);  -- kernels only
```

Since the kernel sees every organization, each kernel checks its own reach: a
kernel given an organization, membership or invitation refuses one outside the
request's organization, and one acting for a person refuses anyone but the
request's own principal (`membership.fn_is_organization_in_reach`,
`membership.fn_is_principal_in_reach`; a platform operator reaches both, and so
does a context naming no one: the deploy and sign-in; a person signed in
without an organization session reaches no organization). A handler that calls a
kernel must not be `access: public`. `membership/__test__/test_kernel_reach.sql`
calls every kernel the owner may call, from a request in one organization and
from one with no organization, with another organization's ids and names any
that answers or changes a row. The
deploy takes every kernel back to the owner before the first file, so a re-run
file's `CREATE OR REPLACE` works, and the file hands it over again.

## Schema Design

`deploy.sql` creates six schemas. `search_path` is set database-wide to
`core, api, membership, internal, extensions, common, pg_temp`.

| Schema | Purpose | USAGE granted to |
|--------|---------|------------------|
| `common` | Cross-cutting primitives (casting, encoding, text) | admin, api, kernel |
| `api` | HTTP types, routing, handlers | api, kernel |
| `core` | Business domain (your tables) | api, kernel |
| `membership` | User identity, organizations, invitations, access control | admin, api, kernel |
| `internal` | Deployment tracking, infrastructure | kernel |
| `extensions` | `uuid-ossp`, `pgcrypto`, `pg_trgm`, `hstore`, `btree_gist`, kept out of `search_path` conflicts | PUBLIC |

`pg_temp.approved_schema_grant()` in `deploy/settings.sql` holds this table as a list,
and `lib/__test__/test_approved_schemas.sql` fails the deploy on a schema or
schema grant it does not name. A project that creates a schema adds its rows.

The database-wide settings come from one list, `pg_temp.database_setting()` in
`deploy/settings.sql`; add a row there rather than an `ALTER DATABASE` elsewhere. An
extension already installed in another schema (some images pre-install them in
`public`) is moved into `extensions`; one that cannot be moved stops the deploy
with the commands to recreate it.

## Privileges: closed by default

- **Routines.** PostgreSQL lets `PUBLIC` execute every new function. Before any
  file runs, `deploy.sql` revokes that default for the owner role, which every
  file runs as. A function you create is callable only by the roles you grant
  it to. At the end of the deploy, a sweep revokes `EXECUTE` from `PUBLIC` on
  every routine in every application schema it finds in the catalog, yours
  included, so a `GRANT ... TO PUBLIC` does not survive. The api role gets its
  entry points (see Role Hierarchy); the kernel role every plain routine of
  `membership` and `common` and the request-context readers. Everything else
  needs its own `GRANT EXECUTE`. `lib/__test__/test_exact_grants.sql` holds
  both lists: a routine one of these roles can execute that is not on its
  list fails the deploy and is named.
- **The database.** `CONNECT` and `TEMPORARY` are revoked from `PUBLIC` and
  granted to the admin and api roles. A login role you add needs the api role
  or its own grant.
- **Nothing lost silently.** Before the first file runs, `deploy.sql` records
  every grant (schema, table, sequence, column, routine), row policy and user
  trigger in the application schemas. After the last file it compares. A
  deploy that took one away from an object that still exists fails and names
  each loss: typically a `DROP ... CASCADE` that took a view's grants with it.
  To remove one on purpose, the file that removes it declares it in the same
  deploy:

  ```sql
  INSERT INTO pg_temp.access_removal (object, entry)
  VALUES ('core.task', 'grant SELECT to ' || pg_temp.deployment_setting('database_api_role')),
         ('core.task', 'policy task_read');
  ```

  The object and entry are spelled as the error spells them.
- **The deploy login is fully trusted.** It owns the database and may state
  any request context, like a gateway. To retire a CI deploy login, drop or
  disable the role (`ALTER ROLE ... NOLOGIN`); revoking a grant does not retire
  it.

## Extending the Framework

To add custom utilities or types, create files in root directories (not `lib/`):

```
myproject/
├── lib/                      # Framework (don't modify)
├── api/
│   ├── examples.sql          # Framework examples
│   └── my_handlers.sql       # YOUR handlers
├── common/                   # YOUR cross-cutting helpers (create if needed)
│   └── my_helpers.sql
└── core/                     # YOUR domain (create if needed)
    └── my_tables.sql
```

Every SQL file needs a `<pgmi-meta>` block giving its place in the plan, with a
sort key of `005/100/...` or later so it runs after the framework:

```sql
/*
<pgmi-meta id="<a new uuid>" idempotent="false">
  <sortKeys><key>005/100/my_table/1</key></sortKeys>
</pgmi-meta>
*/
CREATE TABLE core.my_table (...);
```

A file without one would sort by its path, ahead of the framework, so
`deploy.sql` stops before running anything and names it.

### Run-once structure, re-run code

Each file holds one kind of object, and its `idempotent` flag says which:

| Kind | Objects | Flag | Runs |
|------|---------|------|------|
| Structure | tables, indexes, types, domains, sequences, policies, operators, constraint triggers, `ALTER TABLE` | `idempotent="false"` | once, then skipped |
| Code | functions, procedures, views (through `core.ensure_view`), handler registrations, seed data | `idempotent="true"` | on every deploy |

Write structure as plain DDL: no `IF NOT EXISTS`. A changed table gets a new
run-once file (`ALTER TABLE ...`), sorted after the one that created it. Code
is replaced on every deploy, so edit it in place. `GRANT` and `COMMENT` fit
either kind; the framework keeps a table's grants beside the table.

`deploy.sql` refuses a deploy before it runs anything when a re-run file
creates structure or a run-once file defines code, and names the file. A table
in a re-run file would skip any later edit to its definition, and its index DDL
would lock the application's writers on every deploy; a function in a run-once
file could never be changed again. When code must exist before structure (a
domain `CHECK` calling a validator), give the code file the lower sort key, as
`lib/api/01-types-validators.sql` does for `lib/api/01-types.sql`.

A run-once file is fixed once it has run. When one that already ran on the
target database was edited, moved, re-sorted, flipped to `idempotent="true"`
or removed, `deploy.sql` refuses the deploy before running anything and names
each file and what changed: a skipped edit would reach fresh databases only.
Comment, whitespace and keyword-case edits pass, because the comparison uses
pgmi's normalized checksum. Restore the file and put the change in a new
run-once file sorted after it; to rewrite run-once files on a dev database,
recreate it with `pgmi deploy . -d <db> --overwrite --force --param env=dev`.

`core.ensure_view` replaces a view only when its statement, its stored
definition or its options (`security_invoker`, `security_barrier`,
`check_option`) changed, so an unchanged view is not locked and a view altered
by hand is restored on the next deploy.

### Concurrent indexes

`CREATE INDEX CONCURRENTLY` cannot run inside a transaction or a function, so
it cannot live in a project file. Write it in the tail of `deploy.sql`, after
the `COMMIT` that ends the deploy transaction, as
`CREATE INDEX CONCURRENTLY IF NOT EXISTS ...;` at top level. Each tail
statement commits on its own, as in psql. A build that fails leaves an invalid
index; the tail's last check fails the deploy and names every invalid index
in the application schemas. Fix the cause, `DROP INDEX CONCURRENTLY` it, and
deploy again to rebuild it.

### Catalogs: reference data as files

A lookup table (task statuses, document kinds) can keep its rows in
`data/catalogs/<schema>.<table>.json`, one JSON object per row, keyed by
column name:

```json
[{"code": "open", "label": "Open"}, {"code": "done", "label": "Done"}]
```

Create the table in a run-once file, then sync it from a re-run file sorted
after it:

```sql
SELECT pg_temp.sync_catalog('core.task_status');
```

Every deploy makes the table hold exactly the file's rows, matched by primary
key: new rows are inserted, changed rows updated, rows the file no longer
lists deleted (one `MERGE`). Columns no row names keep their values. The sync
refuses, before changing anything, a column the table does not have, a row
without its primary key, two rows with the same key, and dropping a row that
another table still references, whatever that foreign key's `ON DELETE` says.
A file under `data/catalogs/` that no file syncs fails the deploy.

### Deploy history

`internal.vw_deployment` has one row per committed deploy: when, the login
role, the environment, and how many scripts ran, ran for the first time or
changed. `internal.vw_deployed_script` has one row per script that ever ran:
its path, whether it is run-once, first and last run, run count, how many
contents it ran with and its checksum. Both read the tracking tables
`deploy.sql` keeps in `internal`, and only the owner and admin roles can read
them.

### Deploy-time statements under FORCE RLS

`FORCE ROW LEVEL SECURITY` binds the owner too, so a backfill in a project
file sees no tenant's rows. Run it through
`core.execute_with_force_rls_lifted(ARRAY['core.task']::regclass[], $sql$UPDATE core.task SET ...$sql$)`:
FORCE is lifted on the listed tables for that one statement and put back,
inside the deploy transaction, so no other session ever sees it lifted. It is
granted to no application role.

## Background jobs

A job is a stored procedure a scheduler CALLs, which works through a backlog in
batches and commits after each one. The template ships one,
`purge_exchanges`, which deletes the exchange log past
`exchange_retention_days`:

```sql
CALL api.job_purge_exchanges();          -- batches of 5000, until none are left
CALL api.job_purge_exchanges(1000, 50);  -- batches of 1000, at most 50 of them
```

**The contract.** A job is `api.job_<name>(p_batch_size int DEFAULT 5000,
p_max_batches int DEFAULT NULL)`, a PL/pgSQL procedure that hands its batch
function to the driver:

```sql
-- One batch: at most p_batch_size rows, the count processed, 0 when done.
CREATE OR REPLACE FUNCTION api.job_close_stale_tasks_batch(p_batch_size int)
RETURNS int LANGUAGE sql SECURITY DEFINER SET search_path = core, common, pg_temp AS $$
    SELECT core.fn_close_stale_tasks(p_batch_size);
$$;

CREATE OR REPLACE PROCEDURE api.job_close_stale_tasks(p_batch_size int DEFAULT 5000, p_max_batches int DEFAULT NULL)
LANGUAGE plpgsql AS $$
BEGIN
    CALL api.job_run('close_stale_tasks', 'api.job_close_stale_tasks_batch(int)', p_batch_size, p_max_batches);
END $$;
```

`api.job_run` refuses a missing or non-positive batch size, a non-positive
`p_max_batches` and a batch function that is not `(int) RETURNS int` (22023)
before it takes any lock. It then takes the job's session-level advisory lock
and returns quietly when another session holds it, logs the run, and calls the
batch function until it returns 0 or `p_max_batches` batches ran, committing
after each. The procedures carry no `SECURITY DEFINER` and no `SET` clause:
PostgreSQL forbids COMMIT in either, so they name everything with its schema.
A batch function that needs the owner's rights is `SECURITY DEFINER` with a
pinned `search_path`, as above. Forced row-level security holds the owner to
the policies, and a job runs outside any request, so the owner sees no
organization's rows: a batch over them calls a kernel
(`core.fn_close_stale_tasks` here, handed to the kernel role with
`pg_temp.kernel_owns` and let through with `pg_temp.kernel_passes`; see
[Role Hierarchy](#role-hierarchy)) that selects `FOR UPDATE SKIP LOCKED`, at
most `p_batch_size` rows.

**The run log.** `internal.job_run_log` has one row per run: the job, the login
that ran it, its backend, start and finish, rows and batches, and an outcome
that is NULL while the run is live, `succeeded`, or `abandoned`. Only
`api.job_run_started` and `api.job_run_finished` write it, and they log only a
run the calling session holds the lock for.

**Worker rules.** Anything that can open a session and send one statement can
run a job: cron with `psql`, `pg_cron`, a container scheduler.

- CALL the job at top level, never inside `BEGIN ... COMMIT` or a function: in a
  transaction block its first COMMIT fails with 2D000.
- Use the simple query protocol (`psql -c`, or your driver's simple mode).
- One session per run. A run that fails keeps its session's advisory lock
  (session-level locks survive a rollback), and every other session skips the
  job until that session ends; the next run then marks the failed one
  `abandoned`. Close the session after a failed run, or call
  `SELECT pg_advisory_unlock_all()` before reusing it.

```bash
# crontab: purge the exchange log nightly at 03:15
15 3 * * * psql "$DATABASE_URL" -c 'CALL api.job_purge_exchanges()'
```

```sql
-- pg_cron, scheduled from the database pg_cron runs in
SELECT cron.schedule_in_database('purge-exchanges', '15 3 * * *',
    'CALL api.job_purge_exchanges()', 'mydb');
```

Each `pg_cron` run opens its own session, so the rule above holds.

### The jobs login (optional)

A scheduler can connect as the admin login, but a login that can run jobs
and nothing else limits what a leaked scheduler credential exposes. The deploy
never creates it: not every project runs a scheduler. Create it once per
environment, as the deploy login or a superuser, then register it as a
service principal so the run log and the audit trail name it. Any other
`CREATEROLE` login keeps `ADMIN` on a role it creates, and the deploy refuses
such a role:

```sql
CREATE ROLE mydb_jobs LOGIN PASSWORD '...' CONNECTION LIMIT 2;
SELECT membership.fn_register_service_principal('service.jobs', 'Background jobs', 'mydb_jobs');
```

Run the second statement as the admin login. Then deploy. Every deploy that
finds the role named by `database_jobs_role` (default `<database>_jobs`)
registered as a service principal grants it `CONNECT`, `USAGE` on schema `api`
and `EXECUTE` on every `api.job_*` routine, so a job added later is runnable
after the next deploy. A role of that name nobody registered may have been
created by anyone: the deploy grants it nothing, revokes what an earlier deploy
granted, and prints a notice with the statement that registers it.
It gets nothing else: no gateway entry point, no table, no other schema, and
it is no member of the api role, so it cannot state a request context.
`lib/__test__/test_exact_grants.sql` holds it to that list.

```sql
-- pg_cron, running the job as the jobs login
SELECT cron.schedule_in_database('purge-exchanges', '15 3 * * *',
    'CALL api.job_purge_exchanges()', 'mydb', 'mydb_jobs');
```

A job's batch function must not read `auth.*` settings or session headers:
`lib/__test__/test_handler_context_reads.sql` checks every `api.job_*`
routine as it checks handlers.

## Working with an AI assistant

This template has real conventions an assistant will not guess — the four-phase
handler body, kernel-before-handler sort keys, `<pgmi-meta>` blocks, mandatory
`outputSchema`, RLS through `api.current_organization_id()`. Give it the rules
before it writes any SQL.

`AGENTS.md` routes an assistant to this README and to the skills in
`.agents/skills/`: endpoints, the table, kernel and view layers, handler
bodies, the API's design and MCP tools, as well as deploying, testing, SQL
and PostgreSQL recipes. `CLAUDE.md` imports it for Claude Code. They belong to this project: commit them, and change them
when your conventions change. To read the endpoint recipe yourself:
`.agents/skills/pgmi-endpoint/SKILL.md`.

## Deploy guards

Tests in `lib/__test__/` read the catalog and fail the deploy, naming each
offender, when the database breaks a structural rule. They hold your objects
to the same rules as the template's. Each one plants a broken object first, so
it cannot pass by looking at nothing.

| Guard | Fails on |
|---|---|
| `test_view_standards.sql` | a view in an application schema without `security_invoker`; a reader proves an invoker view keeps row-level security |
| `test_forced_rls.sql` | see Forced row-level security above |
| `test_rls_initplan.sql` | a row policy calling an identity reader (`api.current_organization_id()`, `api.has_permission(...)`, ...) without wrapping it as `(SELECT ...)`, which runs it once per row instead of once per query |
| `test_policy_drift.sql` | a row policy that differs from what the deploy's files left (`ALTER POLICY` by hand), one no deploy file created, or one that is gone. The deploy records each policy a file creates, changes or drops in `internal.policy_fingerprint`; change a policy in a new run-once file |
| `test_fk_index_coverage.sql` | a foreign key no index leads with (a key holding an organization column is judged by its other column, led by it or by `(organization, it)`). A key left unindexed on purpose is declared in the run-once file that creates it: `SELECT pg_temp.exempt_from_fk_index('core.task', '{created_by_user_id}', '<reason>');` (recorded in `internal.fk_index_exemption`); an exemption naming no unindexed key fails as stale |
| `test_approved_schemas.sql` | an application schema, or a grant on one, that `pg_temp.approved_schema_grant()` in `deploy/settings.sql` does not list, or a listed one the database lacks. A new schema adds its rows there |
| `test_handler_context_reads.sql` | a handler, `api.job_*` or `core` routine reading an `auth.*` setting or a session header by name instead of the typed readers |
| `test_exact_grants.sql` | see Role Hierarchy |
| `test_common_reach.sql` | a routine pinning a `search_path` without `common` |
| `test_tenant_foreign_keys.sql` | a foreign key between two organizations' tables that does not pair the organization columns: a key on the id alone accepts another organization's row |

### Optional guards

Eight more checks ship off: each encodes one house's rules, so a project
switches on the ones it holds. A switch is a row in `pg_temp.guard_enabled()`
in `deploy/settings.sql`; set it to `true`:

```sql
    SELECT o.enabled INTO v_enabled FROM (VALUES
        ('strict_fk_index',      true),
        ...
```

| Option (`lib/__test__/test_option_<name>.sql`) | Fails on |
|---|---|
| `strict_fk_index` | a foreign key with `ON DELETE`/`ON UPDATE` `CASCADE`, `SET NULL` or `SET DEFAULT` and no index on exactly its columns (a partial index is accepted only on `<key> IS NOT NULL`). That lookup bypasses row-level security, so an index led by the organization cannot serve it |
| `rls_index_method` | a GIN, GiST or other non-btree lookup index on a forced table: its operators are not leakproof, so under row-level security the query cannot use it. An index backing a constraint passes |
| `plpgsql_check` | any error [plpgsql_check](https://github.com/okbob/plpgsql_check) finds in a PL/pgSQL routine. The extension is created inside the test and rolled back; it needs the extension installed on the server and a superuser deploy login, and is skipped with a warning otherwise |
| `sql_lint` | `x = NULL` / `x <> NULL`, `NOT IN (SELECT ...)`, `WHEN OTHERS THEN NULL` and `::money` in a routine or view body |
| `naming` | a view not named `vw_*`, a constraint not ending `_pkey`, `_key`, `_fkey`, `_check` or `_excl`, an index not named `ix_*` (`uq_*` when unique). The rules are `pg_temp.naming_rule()` in that file |
| `handler_reads_views` | a registered handler naming a `core` table: handlers read `core` views and write through kernels |
| `view_column_comments` | a `core` view, or a column of one, without a comment |
| `trigger_allowlist` | a trigger on a `core` table not listed in `pg_temp.guard_exemption()` |

Off, each file still proves on a planted object that its check works, so a
switched-on option cannot pass by looking at nothing. On, an object it should
let pass is listed with the reason in `pg_temp.guard_exemption()` in
`deploy/settings.sql`, spelled as the error names it; for `trigger_allowlist` that list
is the allowlist:

```sql
    VALUES ('trigger_allowlist', 'core.task trg_task_number', 'numbers each task of an organization in order'),
           ('naming', 'core.legacy_report (want ^vw_)', 'read by an external tool under this name')
```

An entry that names nothing the option would flag fails as stale.

## Testing

Tests run as part of deployment via the `pgmi_test()` macro in deploy.sql. Each
test runs in a savepoint that rolls back its transactional changes while your
migrations commit. Sequence advances and external effects are not rolled back.

To filter tests, pass a pattern to the macro in deploy.sql:

```sql
-- Run only API tests
CALL pgmi_test('.*/api/.*');
```

## Troubleshooting

### "Missing required parameter(s)"
Every deploy needs `env`. Every deploy needs `database_admin_password` too,
unless `env=dev` targets a new or dev-labelled database. Pass them in a params
file (see [Deploy](#1-deploy)), not on the command line:
```bash
pgmi deploy . -d mydb --params-file prod.params
```

### "Database ... was built by pgmi v0.13 or earlier"

The database predates this template's structure and membership model, and
nothing upgrades it in place. Deploy to a new database and move the data
across: [Upgrading an advanced-template project](https://github.com/vvka-141/pgmi/blob/main/docs/advanced/UPGRADING.md), "From v0.13 to v0.14".

### "env=... does not match database ...'s environment label"
The database was deployed as another environment. Deploy with the label the
error names, or relabel on purpose (see [Environments](#environments)).

### "canceling statement due to lock timeout" (55P03)
`deploy.sql` sets `lock_timeout = '5s'`: a deploy that needs a table lock held
by a long-running application transaction fails instead of queueing every
query behind it. Retry when the load drops. An unchanged redeploy takes no
lock that blocks the application's readers or writers: tables, indexes and
policies live in run-once files and are not touched again, and views go
through `core.ensure_view`, which replaces a view only when it changed.
`CREATE OR REPLACE VIEW` locks the view exclusively even when the definition
is identical, so wrap your own views the same way.

### "This deploy took away grants, policies or triggers ..."
A file removed a grant, policy or trigger the database had before the deploy.
Restore it in the file that removed it, or declare the removal (see
[Privileges](#privileges-closed-by-default)).

### "Invalid indexes in the database: ..."
A concurrent index build failed or was cancelled (see
[Concurrent indexes](#concurrent-indexes)). The rest of the deploy committed.
Fix the cause, `DROP INDEX CONCURRENTLY` each index named, and deploy again.

### Script execution order issues
Check your `<sortKeys>` - lower values execute first.

### Extending framework code
Create files in root directories (api/, common/, core/) not in lib/.
Use sortKeys `005/100/...` or higher to execute after the framework.

Taking a newer template into this project: [Upgrading an advanced-template project](https://github.com/vvka-141/pgmi/blob/main/docs/advanced/UPGRADING.md).
