# Deploy the demo in detail

The repo deploys a small demo into your own Azure Databricks workspace, so you
can try the app and see that it does what it says. The demo stays up until you
tear it down.

You need the `databricks` CLI and the Azure CLI (`az`), logged in to your
subscription with `az login`. The scripts set `DATABRICKS_HOST`, so the
`databricks` CLI signs in through that same login
([docs](https://learn.microsoft.com/azure/databricks/dev-tools/auth/azure-cli)).

1. **Settings.** Copy `.env.example` to `.env` and fill in the `<...>`
   values. `.env` is git-ignored; never commit it.
2. **Deploy app in Microsoft Entra ID (once, by hand).** A service principal,
   not a person, owns the Lakebase project, so no user works as the owner.
   Register an app in Microsoft Entra ID (single tenant, no redirect URI)
   and give it a client secret
   ([how](https://learn.microsoft.com/azure/databricks/dev-tools/auth/azure-sp)).
   Put its application (client) ID, tenant ID and secret in the
   `DEMO_DEPLOY_SP_*` settings in `.env`. The app lives in your tenant, so
   it survives a teardown. Each deploy adds it to the workspace with the
   Workspace access entitlement (you need to be a workspace admin for that)
   and runs the bundle commands as this app.
   The secret expires; renew it in Entra ID when it does.
3. **Usage policy (optional, once per workspace, by hand).** A serverless
   usage policy puts the demo's tag on the serverless spend of the app, the
   jobs and Lakebase. Without one, the Lakebase project still tags its own
   usage through its custom tags
   ([docs](https://learn.microsoft.com/azure/databricks/admin/account-settings/usage-detail-tags)),
   and the scripts log `no usage policy set, skipping`.
   A workspace admin creates the policy in the workspace settings
   ([how](https://learn.microsoft.com/azure/databricks/admin/usage/budget-policies)):
   - name `lakebase-patch-desk`, tag `project` = `lakebase-patch-desk`;
   - give the deploy service principal (the Entra app from step 2, added
     to the workspace by the first deploy run) the **User** role on it;
   - put the policy ID in `DEMO_USAGE_POLICY_ID` in `.env`.

   The scripts never create or delete this policy.
4. **Deploy.** `scripts/deploy.sh` (or `scripts/deploy.ps1`). If
   `DEMO_ALERT_EMAIL` is set, it sets a monthly Azure budget with mail alerts
   on the tagged spend. Then it deploys the
   bundle, the database and the app. It also makes two groups,
   `patch-desk-uploaders` and `patch-desk-approvers`: add people to them in
   the workspace settings, and the next deploy gives each one a database
   login. The groups give their members workspace access: on the demo
   (2026-11-09), Lakebase refused a database login to members with only
   Consumer access. Deploy also creates the AI agent's own identity, the
   service principal `lakebase-patch-desk-agent`, with no secret to manage,
   for a planned agent inbox; no agent runs in this demo. Approved fixes are copied to the Delta table
   `<catalog>.patch_desk.product` by the job `lakebase-patch-desk-patch-export`
   (its 15-minute schedule starts paused). The catalog is the workspace's
   default one unless `DEMO_EXPORT_CATALOG` names another; deploy lets the
   deploy principal create a schema there, which needs a workspace admin
   for the workspace catalog.

   Members of either group may open the app, and it works as the person
   signed in.

   No workspace yet? Add `--create-workspace` (`-CreateWorkspace`). The
   script creates the resource group and workspace, tags them
   `created-by=deploy-script` so teardown may delete them, and prints the new
   `DATABRICKS_HOST`. Put it in `.env` before you run deploy or teardown
   again. To add a usage policy later, do step 3 and run deploy again.
5. **Tear down.** `scripts/teardown.sh` (or `scripts/teardown.ps1`). It
   removes what deploy made and lists anything left. It keeps the Entra app,
   the usage policy, the two account groups and the agent's account record.

Both scripts take `--dry-run` (`-DryRun`) to print the plan without touching
anything, and `--help` (`-Help`).

While idle, a stopped app costs nothing and Lakebase compute costs nothing
while suspended. Stop the app with
`databricks apps stop lakebase-patch-desk`.

After the app restarts, an open tab shows "Reconnecting…" for about a
minute and then opens the app again
([`app/session_watch.py`](../app/session_watch.py)).

## Your environment is different?

The demo was built in a private subscription where the person deploying is
a workspace admin. Common differences, and what to do:

- **Not a workspace admin:** deploy needs one, once. On the demo,
  workspace admin rights were enough.
- **No right to create budgets:** leave `DEMO_ALERT_EMAIL` empty; deploy
  skips the cost alert.
- **Another catalog:** set `DEMO_EXPORT_CATALOG`; its owner grants the deploy
  principal `CREATE SCHEMA` (deploy prints the statement if it may not).
- **Another region or cloud:** the region must offer Lakebase and
  Databricks Apps; the scripts are Azure-only.

If you use a coding agent, point it at [`AGENTS.md`](../AGENTS.md): it lists
what to check first and which setting adapts each case.
