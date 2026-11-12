# scripts: deploy and tear down the demo

| Script | What it does |
|---|---|
| `deploy.sh`, `deploy.ps1` | checks settings and logins; optionally creates the resource group and workspace (`--create-workspace`); sets the optional cost alert; adds the deploy service principal, the patch desk groups and the agent's identity to the workspace; then, as the deploy service principal, runs `bundle deploy`, the database deploy job and the app |
| `teardown.sh`, `teardown.ps1` | removes what deploy made, including the Lakebase project and, when the script created them, the resource group and workspace; lists anything left |
| `lib.sh`, `lib.ps1` | the shared functions both scripts use |

Settings come from `.env` (copy [`../.env.example`](../.env.example)). Every
script takes `--dry-run` (`-DryRun`) to print the plan without touching
anything, and `--help` (`-Help`).

The Bash and PowerShell versions do the same steps. See
[`../docs/deploy.md`](../docs/deploy.md) for the full walk-through.
