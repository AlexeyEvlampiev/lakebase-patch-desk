# Lakebase patch desk

A working Databricks App that keeps its business data in Lakebase (managed
PostgreSQL inside Databricks). Business users upload Excel files with data
fixes, PostgreSQL validates them, a second person approves them, and a job
copies the approved values to Delta. Core line: **"Spark analyzes,
PostgreSQL runs the business, and both live in Databricks."**

This file holds the rules for a coding agent working in this repo. A person
deploying the demo should start with `README.md`; an agent helping them,
with `AGENTS.md`.

## This repo is public

Write every file and commit message as if anyone can read it:

- No secrets, tokens, passwords, connection strings with credentials.
- No personal IDs: emails, account IDs, tenant, subscription or workspace
  IDs, workspace URLs. Use placeholders such as `<workspace-host>`.
- No research notes, article drafts, reviews or personal config.
  `scripts/check-repo.sh` fails when such folders or files are tracked; CI
  runs it on every push.
- `.env` holds your settings and secrets. It is git-ignored; never print
  or commit it.

## Grounding rule

Never state a platform fact from memory. Platform means Databricks,
Lakebase, Databricks Apps, Declarative Automation Bundles, Unity Catalog,
PostgreSQL and any other vendor tool the repo uses. They change fast.

- Check each fact in current official docs, through a docs tool such as
  context7 or a live fetch of the vendor's site.
- Record the URL and the date read: next to the claim, or as an entry in
  [`docs/sources.md`](docs/sources.md).
- A claim that cannot be checked is marked `UNVERIFIED:` and is not
  published.

`/fact-check <file>` lists the platform claims in one file and their
evidence. It only reports.

## Design rules

These hold the demo together. Change one only with a clear reason, and
update the README and `docs/sources.md` with it.

- **Bundle-first.** One bundle declares the Lakebase project, the database
  deploy job, the export job and the Databricks App.
- **A deploy service principal owns the Lakebase project**, never a person.
  Table owners and `BYPASSRLS` roles skip row-level security
  ([docs](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)),
  so no person works as the owner.
- **The app connects as the signed-in person.** Databricks Apps forwards
  the user's token; the app asks for the `postgres` user scope
  ([docs](https://learn.microsoft.com/azure/databricks/dev-tools/databricks-apps/auth)).
  Row-level security in PostgreSQL does the filtering. No shared service
  account does user work.
- **Logic lives in PostgreSQL.** The Streamlit app is thin and calls named
  operations through `api.rest_invoke`. People hold no privileges on the
  tables.
- **Tests run in the deploy.** The database tests run inside the deploy's
  transaction; a failing test commits nothing.
- **Serverless jobs, direct connection.** The jobs use `pg8000` (pure
  Python) and connect directly, not through the Lakebase pooler, which does
  not serve the OAuth roles the app and jobs use
  ([docs](https://learn.microsoft.com/azure/databricks/oltp/projects/connection-pooling)).

## Cloud work

- **Deploy on demand.** Run `scripts/deploy.*` only when the user asks.
- **Never tear down on your own.** Teardown runs only when the user runs
  `scripts/teardown.*` or asks for it.
- **Report what runs.** After a session that deployed the demo, say what is
  still running and offer to stop the app
  (`databricks apps stop lakebase-patch-desk`) or tear down.
- **Names:** resource group `rg-lakebase-patch-desk`, tag
  `project=lakebase-patch-desk`. Smallest sizes, serverless only.

## Test

```bash
uv run --with pytest --with-requirements app/requirements.txt pytest app/tests jobs/tests
db/local-check.sh   # needs docker and pgmi: deploys db/ into a local PostgreSQL 18 and runs every test
```

## Layout

| Path | Holds |
|---|---|
| `README.md` | the front page: what it is, what it demonstrates, deploy, try it |
| `AGENTS.md` | for an agent helping someone deploy: what to check in their environment |
| `databricks.yml`, `resources/` | the bundle |
| `db/` | the database: a pgmi project on its advanced template; business rules in `core/`, operations in `api/`, tests in `__test__/` folders |
| `app/` | the Streamlit app and its tests |
| `jobs/` | the job script: database deploy, database logins for the groups, export to Delta |
| `scripts/` | deploy, teardown, repo guard |
| `docs/` | deploy details, sources, samples, images |
| `.claude/` | the `/fact-check` command and the vendored Streamlit skill |

Each main folder has a short README.

## Skills

- pgmi skills for the database are in `db/.agents/skills/` (they come with
  the pgmi advanced template; leave them where they are). Start with
  `pgmi-workflow`, `pgmi-sql` and `postgres-security`.
- `developing-with-streamlit` (in `.claude/skills/`) for `app/`.

## Style

Plain English. Short sentences, ordinary words.
