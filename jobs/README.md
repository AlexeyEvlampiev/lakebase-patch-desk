# jobs: the bundle's job code

One script, `patch_desk_job.py`, with one command per job task. It is a
single file because a serverless Python task cannot import a sibling
module.

| Command | Job (in [`../resources/`](../resources/README.md)) | What it does |
|---|---|---|
| `pgmi` | `db_deploy` | downloads the pinned pgmi release for the machine's architecture, checks its SHA-256, and deploys [`../db/`](../db/README.md) into Lakebase; the database tests run in the deploy's transaction |
| `provision-principals` | `db_deploy` | gives each member of `patch-desk-uploaders` and `patch-desk-approvers` a database login, a principal in the database and its role |
| `export` | `patch_export` | merges the products changed by approved patches into the Delta table `<catalog>.patch_desk.product`, then marks those patches exported |

Every task connects directly to Lakebase (not through the pooler) with a
short-lived OAuth token, using `pg8000`, a pure-Python driver.

`tests/` holds the unit tests; the `*_db.py` tests skip unless
`PATCH_DESK_DB_URL` points at a database (`db/local-check.sh` runs them).

```bash
uv run --with pytest --with-requirements app/requirements.txt pytest jobs/tests
```
