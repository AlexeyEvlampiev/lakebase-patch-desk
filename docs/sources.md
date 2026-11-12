# Sources

The public evidence behind the platform claims in this repo (grounding rule
in `CLAUDE.md`). Each entry gives the URL, the date it was read and what it
backs. `/fact-check <file>` looks here.

A source read more than 30 days ago is stale: re-read it before the claims
it backs are published again.

## Databricks and Lakebase

| Source | Read | Backs |
|---|---|---|
| [Lakebase Postgres overview](https://learn.microsoft.com/azure/databricks/oltp/projects/) | 2026-11-08 | Lakebase is "a fully managed Postgres database integrated into the Databricks platform" (README, `CLAUDE.md`) |
| [Manage projects](https://docs.databricks.com/aws/en/oltp/projects/manage-projects) | 2026-11-08 | Lakebase Autoscaling offers Postgres 16, 17 and 18; 17 is the default, 18 is chosen at creation (`CLAUDE.md`, design rules) |
| [Connection pooling](https://docs.databricks.com/aws/en/oltp/projects/connection-pooling) | 2026-11-08 | the pooler runs PgBouncer in transaction mode and needs native password roles, "not available for OAuth roles" (`CLAUDE.md`, design rules) |
| [Authentication](https://docs.databricks.com/aws/en/oltp/projects/authentication) | 2026-11-08 | OAuth tokens expire after one hour; expiry is enforced only at login; open connections stay up; the project owner's OAuth role is created automatically |
| [Postgres roles](https://docs.databricks.com/aws/en/oltp/projects/postgres-roles) | 2026-11-08 | `databricks_create_role(<identity>, 'USER' \| 'SERVICE_PRINCIPAL' \| 'GROUP')`; user roles are named by email; members log in as a group role; new roles get `LOGIN` only |
| [Roles and permissions](https://docs.databricks.com/aws/en/oltp/projects/manage-roles-permissions) | 2026-11-08 | `databricks_superuser` has `BYPASSRLS`; the project owner is a member |
| [Manage database permissions (Azure)](https://learn.microsoft.com/azure/databricks/oltp/projects/manage-roles-permissions) | 2026-11-09 | `databricks_superuser` is `NOLOGIN` with `BYPASSRLS` and all privileges (with grant) on all tables; the project owner is a member |
| [Scale to zero](https://docs.databricks.com/aws/en/oltp/projects/scale-to-zero) | 2026-11-08 | suspend timeout default 24 hours, minimum 60 seconds; compute cost drops to zero when suspended; suspension resets connections (`CLAUDE.md`, design rules) |
| [Change Data Feed quickstart](https://learn.microsoft.com/azure/databricks/oltp/projects/quickstart-lakebase-cdf) | 2026-11-08 | CDF is Public Preview, started from the branch UI, needs `REPLICA IDENTITY FULL` |
| [Synced tables quickstart](https://docs.databricks.com/aws/en/oltp/projects/quickstart-synced-tables) | 2026-11-08 | synced tables copy Unity Catalog tables into Postgres |
| [Lakebase with bundles, typical project](https://learn.microsoft.com/azure/databricks/oltp/projects/dabs-typical-project) | 2026-11-08 | bundle support for Lakebase is Beta; `postgres_projects` and related resources; app resource `postgres` (bundle-first rule in `CLAUDE.md`) |
| [Manage Lakebase with bundles](https://learn.microsoft.com/azure/databricks/oltp/projects/manage-with-bundles) | 2026-11-08 | CLI 0.287.0 or above for `postgres_projects`; `enable_pg_native_login` defaults to `false`; `bundle destroy` soft-deletes, `delete-project --purge` hard-deletes (`resources/lakebase.yml`, `scripts/teardown.*`) |
| [Manage computes](https://docs.databricks.com/aws/en/oltp/projects/manage-computes) | 2026-11-08 | autoscale computes range 0.5 CU to 64 CU (`resources/lakebase.yml`) |
| [Entra service principal auth](https://learn.microsoft.com/azure/databricks/dev-tools/auth/azure-sp) | 2026-11-08 | workspace operations as a Microsoft Entra service principal take the host plus `ARM_TENANT_ID`, `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`; assign the principal to the workspace (`docs/deploy.md`, step 2; `scripts/lib.*`) |
| [Unified auth environment variables](https://learn.microsoft.com/azure/databricks/dev-tools/auth/env-vars) | 2026-11-08 | `DATABRICKS_AUTH_TYPE=azure-client-secret` selects Entra client-secret auth when several credentials are present (`scripts/lib.*`) |
| [Groups](https://learn.microsoft.com/azure/databricks/admin/users-groups/groups) | 2026-11-09 | workspace admins create groups and manage those they create; the Manage permission may be given to service principals; workspace-local groups are legacy (`scripts/lib.*`) |
| [Manage groups: API](https://learn.microsoft.com/azure/databricks/admin/users-groups/manage-groups) | 2026-11-09 | workspace admins use `/api/2.0/account/scim/v2/Groups` and the permission-assignment API; group managers are granted through the rule set `accounts/{account-id}/groups/{group-id}/ruleSets/default` at `/api/2.0/preview/accounts/access-control/rule-sets`, a PUT that replaces the whole rule set (`scripts/lib.*`) |
| [Create Postgres roles](https://learn.microsoft.com/azure/databricks/oltp/projects/postgres-roles) | 2026-11-11 | `CREATE EXTENSION IF NOT EXISTS databricks_auth` per database; `databricks_create_role(<email>, 'USER')` needs `CREATE`, `CREATE ROLE` and an OAuth session and makes a role with `LOGIN` only; a user's role is named by their email; members of a group role log in as it (`jobs/patch_desk_job.py` `provision-principals`, `db/README.md` "How a person gets access") |
| [Manage service principals](https://learn.microsoft.com/azure/databricks/admin/users-groups/manage-service-principals) | 2026-11-08 | workspace admins add Entra ID managed principals by application ID; workspace admins use `/api/2.0/account/scim/v2/` and `/api/2.0/preview/permissionassignments/principals/{principal_id}` (`scripts/lib.*`, README) |
| [Workspace assignment API](https://docs.databricks.com/api/azure/account/workspaceassignment/update) | 2026-11-08 | assignment body `permissions`: `USER` or `ADMIN`; the call creates or updates (`scripts/lib.*`) |
| [Manage entitlements](https://learn.microsoft.com/azure/databricks/security/auth/entitlements) | 2026-11-09 | since 2026-09-14 principals added to a workspace no longer inherit entitlements from `users`; `workspace-access` is granted with a SCIM `PatchOp` on `/api/2.0/preview/scim/v2/ServicePrincipals/{id}` (`scripts/lib.*`). Seen on the demo 2026-11-09: with only the `USER` assignment, `bundle deploy` got 403 |
| [Authenticate with the Azure CLI](https://learn.microsoft.com/azure/databricks/dev-tools/auth/azure-cli) | 2026-11-09 | with `DATABRICKS_HOST` set, the Databricks CLI signs in through `az login`; no `databricks auth login` needed (README, "Deploy the demo") |
| [Features with limited regional availability](https://learn.microsoft.com/azure/databricks/resources/feature-region-support) | 2026-11-09 | `westeurope` has Lakebase Autoscaling and Databricks Apps (`.env.example`, `DEMO_LOCATION`) |
| [Apps authorization](https://docs.databricks.com/aws/en/dev-tools/databricks-apps/auth) | 2026-11-08 | user authorization forwards the token in `x-forwarded-access-token`; `postgres` is a supported scope; each app has its own service principal (`CLAUDE.md`, design rules) |
| [Apps key concepts](https://learn.microsoft.com/azure/databricks/dev-tools/databricks-apps/key-concepts) | 2026-11-08 | a stopped app "doesn't incur any costs"; a running app is billed for its compute (README, `CLAUDE.md`) |
| [CLI `apps` commands](https://docs.databricks.com/aws/en/dev-tools/cli/reference/apps-commands) | 2026-11-08 | `databricks apps stop [NAME]` stops the app's active deployment (README, `CLAUDE.md`) |
| [Databricks Apps](https://docs.databricks.com/aws/en/dev-tools/databricks-apps/) | 2026-11-08 | Streamlit is a supported framework |
| [Serverless dependencies](https://docs.databricks.com/aws/en/compute/serverless/dependencies) | 2026-11-08 | serverless runs on `aarch64` or `x86_64` and the architecture can change between runs (`CLAUDE.md`, design rules) |
| [Use tags to attribute and track usage](https://learn.microsoft.com/azure/databricks/admin/account-settings/usage-detail-tags) | 2026-11-08 | custom tags go to the account usage logs and are used for budgets; a Lakebase Autoscaling project takes custom tags through the Postgres API (README, "Usage policy"; `.env.example`) |
| [Serverless usage policies](https://learn.microsoft.com/azure/databricks/admin/usage/budget-policies) | 2026-11-08 | Public Preview; a workspace admin creates a policy; its tags go on serverless usage (jobs, apps, Lakebase projects) of users with the User role (`docs/deploy.md`, step 3) |
| [Serverless environment version 5](https://learn.microsoft.com/azure/databricks/release-notes/serverless/environment-version/five) | 2026-11-09 | environment version 5: Python 3.12; version 4 ships `databricks-sdk` 0.49.0, so the `db_deploy` job adds `databricks-sdk>=0.81.0` (`resources/db_deploy.yml`) |
| [Admin privileges in Unity Catalog](https://learn.microsoft.com/azure/databricks/data-governance/unity-catalog/manage-privileges/admin-privileges) | 2026-11-09 | a new workspace's workspace catalog is named after it and owned by its workspace admins; all workspace users get `USE CATALOG` on it and table rights only in its `default` schema (`scripts/lib.*` `grant_export_catalog`) |
| [Manage privileges in Unity Catalog](https://learn.microsoft.com/azure/databricks/data-governance/unity-catalog/manage-privileges/) | 2026-11-09 | owners may grant privileges on their objects and have all privileges on them (the deploy principal owns the `patch_desk` schema it creates) |
| [Databricks Connect in notebooks and jobs](https://learn.microsoft.com/azure/databricks/dev-tools/databricks-connect/notebooks) | 2026-11-09 | in a job, `DatabricksSession.builder.getOrCreate()` with no extra settings returns the job's default Spark session (`jobs/patch_desk_job.py` `export`) |
| [SparkSession.sparkContext](https://learn.microsoft.com/azure/databricks/pyspark/reference/classes/sparksession/sparkcontext) | 2026-11-09 | `spark.sparkContext` is not available on serverless; use the SparkSession APIs (`export` uses DataFrames and SQL only) |
| [Configure authorization in a Databricks app](https://learn.microsoft.com/azure/databricks/dev-tools/databricks-apps/auth) | 2026-11-11 | user authorization forwards the token in `x-forwarded-access-token` (Streamlit: `st.context.headers`); `postgres` is a supported scope; defaults `iam.access-control:read`, `iam.current-user:read`; `CAN USE` on the app for the people approved to run it; never log tokens (`app/db.py`, `resources/app.yml`, README "How it works") |
| [Connect to an API Databricks app using token authentication](https://learn.microsoft.com/azure/databricks/dev-tools/databricks-apps/connect-local) | 2026-11-11 | token authentication reaches only apps that expose `/api/` routes; an Entra ID token cannot call an app directly, it is exchanged first (so the app is checked in a browser sign-in) |
| [HTTP headers in Databricks apps](https://learn.microsoft.com/azure/databricks/dev-tools/databricks-apps/http-headers) | 2026-11-09 | the proxy sets `X-Forwarded-Email` and other `X-Forwarded-*` headers (`app/db.py` fallback) |
| [Databricks Apps environment](https://learn.microsoft.com/azure/databricks/dev-tools/databricks-apps/system-env) | 2026-11-09 | Python 3.11; `DATABRICKS_HOST`, `DATABRICKS_CLIENT_ID`/`SECRET` set in every app; the runtime sets Streamlit's port and address (`app/app.yaml`, `app/requirements.txt`) |
| [Configure app execution with app.yaml](https://learn.microsoft.com/azure/databricks/dev-tools/databricks-apps/app-runtime) | 2026-11-09 | `command` and `env` in `app.yaml`; the Streamlit example `command: ['streamlit', 'run', 'app.py']` |
| [Access control lists: Lakebase project ACLs](https://learn.microsoft.com/azure/databricks/security/auth/access-control/#lakebase-project-acls) | 2026-11-09 | all workspace users inherit `CAN CREATE` (view and list project endpoints); `CAN USE` adds e.g. the connection URI and deleting branch databases; workspace admins inherit `CAN MANAGE` (`app/db.py` reads the host with the user's client) |
| [Default workspace permissions](https://learn.microsoft.com/azure/databricks/security/auth/default-permissions) | 2026-11-09 | the `admins` group has CAN MANAGE on all jobs, so a workspace admin can run the export job (README, "Try the patch desk") |
| [Manage Lakebase with bundles](https://learn.microsoft.com/azure/databricks/oltp/projects/manage-with-bundles) | 2026-11-09 | `postgres_projects` take `permissions` with `CAN_USE` or `CAN_MANAGE` (not used yet) |
| [Manage branches](https://learn.microsoft.com/azure/databricks/oltp/projects/manage-branches) | 2026-11-10 | a branch shares storage with its parent through copy-on-write; `databricks postgres create-branch <project> <id> --json '{"spec":{"source_branch":...,"ttl":"<n>s"}}'` sets an expiration, after which the branch is deleted automatically (at most 30 days ahead); deleting a branch removes its databases, roles and compute; a branch with children cannot be deleted |
| [Bundle permissions](https://learn.microsoft.com/azure/databricks/dev-tools/bundles/permissions) | 2026-11-10 | top-level `permissions` apply to all resources in the bundle |
| [Bundle configuration reference: run_as](https://learn.microsoft.com/azure/databricks/dev-tools/bundles/reference#run_as) | 2026-11-09 | `run_as.service_principal_name` takes an application ID and needs the `servicePrincipal/user` role |
| [Roles for managing service principals](https://learn.microsoft.com/azure/databricks/security/auth/access-control/service-principal-acl) | 2026-11-09 | the Service principal: User role is granted through the principal's rule set `accounts/<account-id>/servicePrincipals/<application-id>/ruleSets/default`, a PUT that replaces it whole |
| [Serverless DBU consumption by SKU](https://learn.microsoft.com/azure/databricks/resources/pricing) | 2026-11-11 | Lakebase Autoscaling compute is billed on the Database Serverless Compute SKU; Database Storage is billed on its own Databricks Storage SKU, separately from compute (`scripts/lib.*` deploy summary, `CLAUDE.md`, cloud work) |

## PostgreSQL

| Source | Read | Backs |
|---|---|---|
| [Row security policies](https://www.postgresql.org/docs/current/ddl-rowsecurity.html) | 2026-11-08 | superusers, `BYPASSRLS` roles and table owners (without `FORCE`) skip row-level security (`CLAUDE.md`, design rules) |
| [System information functions](https://www.postgresql.org/docs/current/functions-info.html) | 2026-11-08 | `session_user` is the role that connected; `current_user` changes inside `SECURITY DEFINER` functions; `pg_input_is_valid(text, type)` tests input without raising (`fn_patch_line_problems`) |
| [SET SESSION AUTHORIZATION](https://www.postgresql.org/docs/current/sql-set-session-authorization.html) | 2026-11-08 | sets both `session_user` and `current_user`; only a superuser may name another role; `LOCAL` lasts to the end of the transaction (`db/api/__test__/database_logins/`) |
| [Role attributes](https://www.postgresql.org/docs/current/role-attributes.html) | 2026-11-10 | a non-superuser that creates a role with `CREATEROLE` is granted it back `WITH ADMIN TRUE, SET FALSE, INHERIT FALSE`; any role with `ADMIN OPTION` on a role may grant membership in it |
| [Numeric types (PostgreSQL 18)](https://www.postgresql.org/docs/18/datatype-numeric.html) | 2026-11-09 | `numeric` accepts `NaN`, and PostgreSQL treats `NaN` as equal to itself and greater than all non-`NaN` values, so `> 0` lets it through (`db/core/catalogue-structure.sql`, `core.fn_patch_line_problems`) |
| [CREATE VIEW](https://www.postgresql.org/docs/current/sql-createview.html) | 2026-11-08 | with `security_invoker = true` the invoking user's policies and permissions apply to the view's base tables (every view in `db/`; `db/lib/__test__/test_view_standards.sql`) |
| [REVOKE](https://www.postgresql.org/docs/current/sql-revoke.html) | 2026-11-11 | a non-owner's `REVOKE` revokes only the privileges it holds grant options for and warns when it holds none for a privilege it names (the `no privileges could be revoked` warnings) |
| [Advisory lock functions](https://www.postgresql.org/docs/current/functions-admin.html#FUNCTIONS-ADVISORY-LOCKS) | 2026-11-11 | `pg_advisory_unlock` returns false and the server reports a warning when the lock was not held (`db/lib/__test__/test_jobs.sql`) |
| [Database roles](https://www.postgresql.org/docs/current/database-roles.html) | 2026-11-11 | "Database roles are global across a database cluster installation (and not per individual database)", so `provision-principals` makes login roles in the maintenance database (`jobs/patch_desk_job.py`) |
| [CREATE POLICY (PostgreSQL 18)](https://www.postgresql.org/docs/current/sql-createpolicy.html) | 2026-11-11 | a policy's `TO` defaults to `PUBLIC`, which applies it to all roles; a row is accessible only when one permissive policy and all restrictive policies pass (`db/core/patch-export-structure.sql`, `db/README.md` "The export job") |
| [Event trigger functions in PL/pgSQL](https://www.postgresql.org/docs/current/plpgsql-trigger.html#PLPGSQL-EVENT-TRIGGER) | 2026-11-11 | a function called as an event trigger is declared with no arguments and returns `event_trigger` (`db/deploy.sql`) |

## Other tools

| Source | Read | Backs |
|---|---|---|
| [pgmi v0.14.1 release](https://github.com/vvka-141/pgmi/releases/tag/v0.14.1) | 2026-11-09 | release assets `pgmi_0.14.1_linux_{amd64,arm64}.tar.gz` and `checksums.txt`; the archive holds `pgmi` at its top level (`jobs/patch_desk_job.py` pins 0.14.1) |
| [pgmi v0.14.1 docs: `pgmi init`](https://github.com/vvka-141/pgmi/blob/v0.14.1/docs/CLI.md#pgmi-init) | 2026-11-10 | templates `minimal`, `basic`, `advanced` via `-t` |
| [pgmi v0.14.1 docs: CLI parameters](https://github.com/vvka-141/pgmi/blob/v0.14.1/docs/CLI.md) | 2026-11-11 | an environment variable `PGMI_PARAM_<NAME>` is the deploy parameter `<name>` (`PGMI_PARAM_DB_PASSWORD=x` becomes `pgmi.db_password`); precedence `--param` > `--params-file` > `PGMI_PARAM_*` > `pgmi.yaml`; an empty value exits 10 (`jobs/patch_desk_job.py` `--admin-password`) |
| [pgmi v0.14.1 docs: basic template](https://github.com/vvka-141/pgmi/blob/v0.14.1/docs/basic/README.md) | 2026-11-10 | two layers, functions called by name, no API layer or gateway; tests run before `COMMIT` and a failure commits nothing |
| [pgmi v0.14.1 docs: testing](https://github.com/vvka-141/pgmi/blob/v0.14.1/docs/TESTING.md) | 2026-11-10 | tests run in the deploy's transaction inside savepoints; a failure rolls back |
| [pgmi v0.14.1 docs: advanced template](https://github.com/vvka-141/pgmi/blob/v0.14.1/docs/advanced/README.md#multi-tenant-identity-and-rls) | 2026-11-10 | the database resolves login and organization session handles into one person per request; gateways call an `api` role |
| [pgmi v0.14.1: advanced template README](https://github.com/vvka-141/pgmi/blob/v0.14.1/internal/scaffold/templates/advanced/README.md) | 2026-11-10 | the README `pgmi init -t advanced` generates: a gateway calls `api.rest_invoke`, `api.rpc_invoke` and `api.mcp_handle_request` after their policy functions; `provider_role_pattern` takes a `LIKE` pattern of a managed provider's own roles |
| [pgmi v0.14.1 docs: upgrading](https://github.com/vvka-141/pgmi/blob/v0.14.1/docs/advanced/UPGRADING.md) | 2026-11-10 | the v0.14 advanced template refuses to deploy onto a database built by v0.13 or earlier; the way forward is a new database and moving the data across |
| [pg8000 on PyPI](https://pypi.org/project/pg8000/) | 2026-11-10 | "a pure-Python PostgreSQL driver"; 1.31.6 is the latest release (`CLAUDE.md`, design rules; `app/requirements.txt`) |
| [Azure budgets](https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-acm-create-budgets) | 2026-11-08 | budgets filter costs, send mail at thresholds and do not stop resources (`docs/deploy.md`) |
| [Entra app credentials](https://learn.microsoft.com/entra/identity-platform/how-to-add-credentials) | 2026-11-08 | an app registration gets a client secret under Certificates & secrets; secrets expire after at most 24 months (README, `.env.example`) |
| [Streamlit `st.context`](https://docs.streamlit.io/develop/api-reference/caching-and-state/st.context) | 2026-11-08 | `st.context.headers` holds the headers of the initial request |
| [Claude Code skills](https://code.claude.com/docs/en/skills) | 2026-11-08 | `.claude/commands/<name>.md` still creates `/<name>`; project skills live in `.claude/skills/<name>/SKILL.md`; `disallowed-tools` removes tools while a command runs; `allowed-tools` only pre-approves |
| [Streamlit meta-skill, tag 1.67.0](https://github.com/streamlit/streamlit/tree/1.67.0/lib/streamlit/.agents/meta-skill/developing-with-streamlit) | 2026-11-08 | the vendored `developing-with-streamlit` skill: publisher, Apache-2.0, files (`.claude/skills/developing-with-streamlit/ATTRIBUTION.md`) |
| [`streamlit/agent-skills` README](https://github.com/streamlit/agent-skills) | 2026-11-08 | that repo is deprecated; the meta-skill now ships in `streamlit/streamlit` |

## Not backed by a vendor doc

These claims rest on what this project saw, not on a vendor page. Keep them
out of published text unless they are worded as an observation.
- Observed: `psycopg[binary]` aborted at import on serverless ARM, so the
  deploy job uses `pg8000`. No vendor page.
- Observed: in a serverless Python task, `sys.exit(0)` marks the task failed
  (`SystemExit: 0`). Community threads disagree; no vendor page found on
  2026-11-08.
- Observed on the demo (2026-11-10): the host of a deleted workspace
  answered with a redirect to `login.html?error=workspace_does_not_exist_error`.
- Observed on the demo (2026-11-11): in `databricks_postgres` and in a new
  database `lakebase_apps`, schema `public` holds
  `grant_usage_on_new_schema()`, `grant_select_on_new_objects()` and
  `grant_all_on_new_sequences()`, which return `event_trigger`, back the
  event triggers `on_create_schema`, `on_create_table_or_view` and
  `on_create_sequence`, are executable by PUBLIC and are not owned by the
  deploy principal. Locally, calling such a function from SQL fails with
  `trigger functions can only be called as triggers`.
- Observed on the demo (2026-11-11): the workspace's
  `<workspace-host>/oidc/.well-known/oauth-authorization-server` names the
  issuer `<workspace-host>/oidc`, the value the `db_deploy` job passes as
  `oidc_issuers` (`jobs/patch_desk_job.py`, `--workspace-oidc-issuer`).
- Observed on the demo (2026-11-11): in the `db_deploy` job's parameters,
  `${workspace.host}` was substituted as empty; the job reads its host from
  the SDK instead.
- Observed on the demo (2026-11-09): a Lakebase database's `public` schema
  holds platform helper functions (`grant_all_on_new_sequences()` and others)
  that PUBLIC may execute; `db/deploy.sql` leaves them out when it revokes
  `EXECUTE` from `PUBLIC`.
- Observed on the demo (2026-11-09): in the serverless `db_deploy` task,
  `WorkspaceClient()` with no arguments acts as the job's identity (the
  deploy principal), and its Postgres role is named by its application ID.
  Runs have landed on both `x86_64` and `aarch64`; the matching pgmi asset
  downloaded and ran on each.
- Observed on the demo (2026-11-09): with default rights the deploy service
  principal may not read an account group's members (`PERMISSION_DENIED`);
  with the group's Manage permission (`roles/group.manager`) it may, after a
  short delay, and a filtered user list (`filter=id eq "..."`) gives the
  members' user names. Single-user reads stay admin-only.
- Observed on the demo (2026-11-09): a serverless Python task runs its file
  through `exec()`; `__file__` is not defined there.
- Observed on the demo (2026-11-09): the deploy principal, which created the
  group roles, is itself a member of `patch_uploader` and `patch_approver`
  (not granted by this project's code).
- Observed on the demo (2026-11-09): the deploy principal's Postgres role
  has `BYPASSRLS`, so the export functions see every patch.
- Observed on the demo (2026-11-09): `databricks metastores current` returns
  `default_catalog_name`, the workspace catalog in a new workspace; that
  catalog grants workspace users only `USE_CATALOG`. In serverless
  environment version 5, `databricks.connect` imports without being listed
  as a dependency.
- Observed on the demo (2026-11-09): an app's `user_api_scopes` may not
  include `iam.current-user:read` (deploy fails with `not a valid scope`,
  400), but an app that requests only `postgres` gets it anyway in its
  effective scopes. With the forwarded token, a workspace admin's
  `generate_database_credential` works and the app logs in as that user.
- Observed on the demo (2026-11-09): with the Databricks SDK 0.163.0,
  creating a `WorkspaceClient` probes the host's metadata, retrying while
  the host is unreachable; tests stub that probe.
- Observed on the demo (2026-11-09), with a temporary non-admin service
  principal: with only `workspace-consume`, the Postgres API refuses
  `get_endpoint` and `generate_database_credential` ("This API is disabled
  for users without the workspace-access entitlement"); with
  `workspace-access` and the inherited project `CAN CREATE` both work. A
  login whose Postgres role does not exist fails with `password
  authentication failed for user '<name>'`.
- Observed on the demo (2026-11-09), with a real non-admin user through the
  app: with only `workspace-consume` the forwarded token is refused by the
  Postgres API the same way; with `workspace-access` the user gets a
  database login and works through the app.
- Observed on the demo (2026-11-09): a job with `run_as` set to another
  service principal fails with "Cannot read the python file" until that
  principal can read the bundle's files folder; `CAN_READ` on the folder
  fixes it.
- Observed on the demo (2026-11-09, Chromium driven by Playwright, signed in
  as a test user): after `databricks apps stop` and `start`, an open
  Streamlit tab's background calls (`/_stcore/health`, `/_stcore/host-config`)
  get a 302 to the Databricks sign-in page, which a background call cannot
  follow; Streamlit retries, and each 302 sets a `__Host-databricksapps_cs…`
  cookie (about 340 bytes, 15 minutes). After about 60 to 86 of them, page
  loads fail with `net::ERR_HTTP2_PROTOCOL_ERROR` ("This site can't be
  reached") until the cookies expire or are cleared. A full page load does
  follow the redirect and signs in again.
- Observed on the demo (2026-11-09, again on 2026-11-10): the deploy
  principal is not a PostgreSQL superuser on Lakebase; the identity tests that need `SET
  SESSION AUTHORIZATION` print `skipped: needs superuser` there and run in
  full on a local Postgres (`db/local-check.sh`).
- Observed on the demo (2026-11-09, suspend timeout 300 s): an idle open
  connection does not keep the Lakebase compute awake; the endpoint went
  `IDLE` in the fifth minute and the open session was closed
  (`terminating connection due to administrator command`).
- Observed on the demo (2026-11-10): a branch made with `create-branch`
  and a TTL had an endpoint `primary` at once and already held the parent's
  OAuth roles (a person's and the agent's), so `databricks_create_role` was
  not needed there. On it, the deploy principal was not a superuser and had
  `CREATEROLE`, `CREATEDB` and `BYPASSRLS`; the server reported PostgreSQL
  18.6.
- Observed on the demo (2026-11-10): `jobs.submit` with `run_as` the
  agent's service principal ran a one-time serverless task as the agent,
  which minted its own database credential.
- Observed (Streamlit 1.67.0): `st.html(..., unsafe_allow_javascript=True)`
  drops the whole script when its text contains HTML-like tags, even inside
  a string literal.
- Observed (2026-11-09, fresh Lakebase database and locally): changing a
  function's owner to a role needs the deploying role to be able to `SET
  ROLE` to it ("must be able to SET ROLE"); a non-superuser owner got that
  only from `GRANT ... WITH SET TRUE`, so the grant must run before the
  change of owner. A superuser deploy
  hides this; `db/local-check.sh` does not.
- Observed (2026-11-09): after a teardown and a new workspace of the same
  name, the metastore kept the old workspace catalog under the plain name
  (bound to the deleted workspace), named the new one
  `<name>_<workspace id>`, and still reported the plain name as the new
  workspace's default catalog, which it could not reach.
