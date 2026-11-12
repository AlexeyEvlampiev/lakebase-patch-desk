#!/usr/bin/env bash
# Deploy the Lakebase patch desk demo: cost alert, bundle, database, app.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/deploy.sh [--dry-run] [--create-workspace] [--help]

Brings the demo up in your Databricks workspace:
  1. checks settings, tools and logins (databricks, az);
  2. optionally creates a resource group and a Premium Azure Databricks
     workspace (--create-workspace);
  3. creates or updates the Azure budget 'lakebase-patch-desk' that watches
     spend tagged project=lakebase-patch-desk (optional: skipped without
     DEMO_ALERT_EMAIL or without the right to create budgets);
  4. adds the deploy service principal to the
     workspace, makes the patch desk groups and the agent principal, lets the principal create a
     schema in the export catalog, then, as that principal, bundle deploy,
     database deploy job and app start.

Settings come from the environment, then from $DEMO_ENV_FILE or .env.
See .env.example for the list.

Options:
  --dry-run           print every action, change nothing, call no cloud tool
  --create-workspace  create the resource group and workspace first
  -h, --help          show this text
EOF
}

CREATE_WORKSPACE=0
while (( $# )); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --create-workspace) CREATE_WORKSPACE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

load_settings
if (( CREATE_WORKSPACE )); then
  # The host comes from the new workspace; a placeholder or an old value
  # does not count.
  is_placeholder "${DATABRICKS_HOST:-}" && DATABRICKS_HOST=""
  require_settings AZURE_SUBSCRIPTION_ID
else
  require_settings DATABRICKS_HOST AZURE_SUBSCRIPTION_ID
fi
if has_bundle; then
  require_settings "${DEPLOY_SP_SETTINGS[@]}"
  set_bundle_vars
fi
validate_settings
(( DRY_RUN )) && log "Dry run: nothing will change."

require_tools az databricks curl python3
check_az_login

create_workspace() {
  local sub="$AZURE_SUBSCRIPTION_ID" rg="$DEMO_RESOURCE_GROUP" tag="project=$DEMO_PROJECT_TAG"
  log "== Resource group and workspace"
  if (( DRY_RUN )); then
    run az group create --name "$rg" --location "$DEMO_LOCATION" --subscription "$sub" \
      --tags "$tag" created-by=deploy-script
  elif [[ "$(az group exists --name "$rg" --subscription "$sub")" == "true" ]]; then
    log "Resource group $rg exists; leaving its tags alone."
  else
    run az group create --name "$rg" --location "$DEMO_LOCATION" --subscription "$sub" \
      --tags "$tag" created-by=deploy-script -o none
  fi

  if (( DRY_RUN )); then
    create_workspace_resource
  elif capture az rest --method get --url "$(workspace_url)" -o none; then
    log "Workspace $DEMO_WORKSPACE_NAME exists; not touching it."
  elif is_not_found "$ERR"; then
    create_workspace_resource
  else
    die "could not read the workspace: $ERR"
  fi
  wait_for_workspace
}

create_workspace_resource() {
  local sub="$AZURE_SUBSCRIPTION_ID" rg="$DEMO_RESOURCE_GROUP"
  local body
  body="$(printf '{"location":"%s","sku":{"name":"premium"},"tags":{"project":"%s","created-by":"deploy-script"},"properties":{"managedResourceGroupId":"/subscriptions/%s/resourceGroups/%s-managed"}}' \
    "$DEMO_LOCATION" "$DEMO_PROJECT_TAG" "$sub" "$rg")"
  run az rest --method put --url "$(workspace_url)" --body "$body" -o none
}

wait_for_workspace() {
  if (( DRY_RUN )); then
    log "[dry-run] wait until the workspace is provisioned, then use its URL as DATABRICKS_HOST"
    return 0
  fi
  local state="" i
  for (( i = 0; i < 90; i++ )); do
    state="$(az rest --method get --url "$(workspace_url)" --query properties.provisioningState -o tsv)"
    [[ "$state" == "Succeeded" ]] && break
    [[ "$state" == "Failed" ]] && die "workspace provisioning failed"
    log "Workspace state: $state; waiting..."
    sleep 20
  done
  [[ "$state" == "Succeeded" ]] || die "workspace not ready after 30 minutes"
  local host
  host="https://$(az rest --method get --url "$(workspace_url)" --query properties.workspaceUrl -o tsv)"
  log "Workspace ready: $host"
  if [[ -z "${DATABRICKS_HOST:-}" || "$DATABRICKS_HOST" != "$host" ]]; then
    DATABRICKS_HOST="$host"
    export DATABRICKS_HOST
    log "Put DATABRICKS_HOST=$host in your env file."
  fi
}

# The cost alert is optional: without DEMO_ALERT_EMAIL, or without the right
# to create a budget on the subscription, deploy goes on and says so.
upsert_budget() {
  log "== Cost alert (Azure budget '$DEMO_PROJECT_TAG')"
  if [[ -z "${DEMO_ALERT_EMAIL:-}" ]] || is_placeholder "$DEMO_ALERT_EMAIL"; then
    log "no DEMO_ALERT_EMAIL set, skipping the cost alert"
    return 0
  fi
  local start
  start="$(date -u +%Y-%m-01T00:00:00Z)"
  if (( ! DRY_RUN )); then
    # An existing budget keeps its start date.
    if capture az rest --method get --url "$(budget_url)" --query properties.timePeriod.startDate -o tsv; then
      [[ -n "$OUT" ]] && start="$OUT"
    elif ! is_not_found "$ERR"; then
      warn "could not read the budget, skipping the cost alert: $ERR"
      return 0
    fi
  fi
  local email="$DEMO_ALERT_EMAIL"
  local note
  note='"enabled":true,"operator":"GreaterThanOrEqualTo","thresholdType":"Actual","contactEmails":["'"$email"'"]'
  local body
  body="$(printf '{"properties":{"category":"Cost","amount":%s,"timeGrain":"Monthly","timePeriod":{"startDate":"%s"},"filter":{"tags":{"name":"project","operator":"In","values":["%s"]}},"notifications":{"actual80":{%s,"threshold":80},"actual100":{%s,"threshold":100}}}}' \
    "$DEMO_BUDGET_USD" "$start" "$DEMO_PROJECT_TAG" "$note" "$note")"
  if (( DRY_RUN )); then
    run az rest --method put --url "$(budget_url)" --body "$body" -o none
    return 0
  fi
  log "+ az rest --method put --url $(budget_url) (budget $DEMO_BUDGET_USD per month, alerts at 80 and 100 %)"
  capture az rest --method put --url "$(budget_url)" --body "$body" -o none \
    || warn "could not create the cost alert (no right to create budgets?), going on without it: $ERR"
}

deploy_bundle() {
  log "== Bundle"
  if ! has_bundle; then
    log "no bundle yet, skipping"
    return 0
  fi
  local t="$DEMO_BUNDLE_TARGET" key
  (cd "$REPO_ROOT" && as_deploy_principal databricks bundle deploy -t "$t" ${BUNDLE_VARS[@]+"${BUNDLE_VARS[@]}"})
  grant_agent_bundle_read
  for key in "$DEMO_DB_JOB_KEY" "$DEMO_APP_KEY"; do
    if bundle_declares "$key"; then
      (cd "$REPO_ROOT" && as_deploy_principal databricks bundle run "$key" -t "$t" ${BUNDLE_VARS[@]+"${BUNDLE_VARS[@]}"})
    else
      log "bundle does not declare $key yet, skipping its run"
    fi
  done
}

(( CREATE_WORKSPACE )) && create_workspace
upsert_budget
if has_bundle; then
  add_deploy_principal
  ensure_groups
  ensure_agent_principal
  grant_export_catalog
fi
deploy_bundle

log ""
log "== Now running"
if has_bundle; then
  log "  - Lakebase project $DEMO_LAKEBASE_PROJECT_ID, owned by the deploy principal"
  bundle_declares "$DEMO_DB_JOB_KEY" && log "  - Job $DEMO_DB_JOB_NAME"
  log "  - Agent service principal $(agent_name) (an identity; no cost)"
  bundle_declares patch_export && log "  - Job $DEMO_EXPORT_JOB_NAME (schedule paused) and its Delta table <catalog>.patch_desk.product"
  bundle_declares "$DEMO_APP_KEY" && log "  - App $DEMO_APP_NAME"
else
  log "  - No bundle yet: no app, job or Lakebase project."
fi
log "  - Azure budget $DEMO_PROJECT_TAG (no cost of its own)"
(( CREATE_WORKSPACE )) && log "  - Workspace $DEMO_WORKSPACE_NAME in $DEMO_RESOURCE_GROUP"
print_idle_cost
