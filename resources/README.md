# resources: what the bundle declares

[`../databricks.yml`](../databricks.yml) includes these files. One
`databricks bundle deploy` creates or updates all of them; the deploy
service principal runs it, so it owns what the bundle creates.

| File | Declares |
|---|---|
| `lakebase.yml` | the Lakebase project: PostgreSQL 18, smallest compute, scales to zero after 5 minutes idle |
| `db_deploy.yml` | job `lakebase-patch-desk-db-deploy`: deploys the database, then gives the patch desk groups their database logins |
| `patch_export.yml` | job `lakebase-patch-desk-patch-export`: copies approved fixes to Delta; its 15-minute schedule starts paused |
| `app.yml` | the Databricks App `lakebase-patch-desk`, with the `postgres` user scope and no database resource of its own |

All jobs run on serverless compute. `scripts/deploy.sh` runs the bundle
commands; you rarely call them by hand.
