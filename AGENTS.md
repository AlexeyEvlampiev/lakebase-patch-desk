# Notes for coding agents helping someone deploy this demo

You are helping a person run `scripts/deploy.sh` (or `deploy.ps1`) in their
own Azure Databricks workspace. Their environment may differ from the one
the demo was built in (a private subscription where the person deploying is a
workspace admin). Check these points first, explain the result in plain
words, and adapt settings in `.env`, not the code. Never print or commit the
contents of `.env`.

Platform facts here are backed in [`docs/sources.md`](docs/sources.md);
re-check them there, they change.

## 1. Who is the person in the workspace?

- `databricks current-user me` shows them. Deploy needs a **workspace
  admin**: it adds the deploy service principal and the agent principal to
  the workspace, makes two account groups through the workspace, grants
  entitlements, and grants on the export catalog. On the demo, workspace
  admin rights were enough; no account admin rights were used.
- Not an admin: they need one to run deploy once, or to do those steps for
  them. The steps are listed in `scripts/deploy.sh --help` and in the
  functions of `scripts/lib.sh`.

## 2. Region

The workspace region must offer Lakebase Autoscaling and Databricks Apps
(see the region rows in `docs/sources.md`). The
demo is tested in `westeurope` (`DEMO_LOCATION` for `--create-workspace`).

## 3. Cost alert

The Azure budget is optional. Leave `DEMO_ALERT_EMAIL` empty to skip it;
without the right to create budgets on the subscription, deploy warns and
goes on.

## 4. Usage policy

Optional (`DEMO_USAGE_POLICY_ID`). Without it the Lakebase project still
carries the demo's tag.

## 5. People who use the app

App users are added to `patch-desk-uploaders` or `patch-desk-approvers`;
the next deploy gives each a database login. The groups give
**workspace access**: on the demo, Lakebase refused a database login to
users with only Consumer access. If the organisation allows only Consumer
access, the app cannot log those users in.

## 6. Export catalog

The export job writes to the workspace's default catalog unless
`DEMO_EXPORT_CATALOG` names another. Deploy grants the deploy principal
`USE CATALOG` and `CREATE SCHEMA` there, which needs the catalog's owner (for
the workspace catalog: a workspace admin). If that grant is refused, deploy
stops and prints the one `GRANT` the owner must run.

## 7. The agent

The agent inbox is planned. Deploy still creates the agent's service
principal (an identity, no cost); no job runs as it.

## 8. Other clouds

The scripts are Azure-only (Azure budget, `--create-workspace`, an Entra ID
deploy principal). The bundle, the database code and the app are not tied
to Azure, but nothing here was tested on AWS or GCP.

## 9. After an app restart

An open browser tab shows "Reconnecting…" for about a minute and then
reloads the app by itself (`app/session_watch.py`). Clearing browser data is
not needed.

## Costs

`scripts/teardown.sh` removes everything deploy made and lists anything
left. While up: a stopped app costs nothing; Lakebase compute costs nothing
while suspended.
