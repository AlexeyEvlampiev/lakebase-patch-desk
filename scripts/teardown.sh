#!/usr/bin/env bash
# Tear the Lakebase patch desk demo down and check that nothing is left.
set -euo pipefail

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/teardown.sh [--dry-run] [--help]

Removes what scripts/deploy.sh created:
  1. bundle destroy (as the deploy service
     principal), deletes the export schema <catalog>.patch_desk with its
     Delta table, takes the agent service principal out of the workspace,
     then hard-delete (purge) the Lakebase project if it is
     still there, also when soft-deleted;
  2. deletes the Azure budget 'lakebase-patch-desk';
  3. deletes the resource group, or else the workspace, only when it carries
     the tag created-by=deploy-script.
It never deletes the serverless usage policy (made by hand, may be reused)
or the deploy principal's Microsoft Entra app (it lives outside the workspace).
Every step treats "already gone" as success. At the end it lists what is
left and exits non-zero if anything is.

Settings come from the environment, then from $DEMO_ENV_FILE or .env.
See .env.example for the list.

Options:
  --dry-run   print every action, change nothing, call no cloud tool
  -h, --help  show this text
EOF
}

while (( $# )); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

load_settings
require_settings AZURE_SUBSCRIPTION_ID
if has_bundle; then
  require_settings DATABRICKS_HOST "${DEPLOY_SP_SETTINGS[@]}"
  set_bundle_vars
fi
validate_settings
(( DRY_RUN )) && log "Dry run: nothing will change."

require_tools az databricks
check_az_login

SUB="$AZURE_SUBSCRIPTION_ID"
PROJECT="projects/$DEMO_LAKEBASE_PROJECT_ID"
WORKSPACE_DELETED=0

# Is the Lakebase project there, active or soft-deleted? 0 yes, 1 no, 2 unknown.
lakebase_project_state() {
  capture databricks postgres list-projects --show-deleted -o json || return 2
  grep -q "\"$PROJECT\"" <<<"$OUT"
}

destroy_bundle() {
  log "== Bundle"
  if ! has_bundle; then
    log "no bundle yet, skipping"
    return 0
  fi
  # A repeat teardown: the workspace deploy.sh made is already deleted, so
  # everything in it went with it.
  if (( ! DRY_RUN )) && ! capture az rest --method get --url "$(workspace_url)" -o none && is_not_found "$ERR"; then
    log "Workspace $DEMO_WORKSPACE_NAME is already gone, and everything in it; skipping the Databricks steps."
    WORKSPACE_DELETED=1
    return 0
  fi
  check_databricks_login
  # bundle destroy needs the same variables as deploy, the agent's ID too.
  if (( DRY_RUN )); then
    BUNDLE_VARS+=("--var=agent_app_id=<agent-application-id>")
  elif find_agent_principal; then
    BUNDLE_VARS+=("--var=agent_app_id=$AGENT_APP_ID")
  fi
  # The principal deployed the bundle and owns its state, so it destroys it.
  (cd "$REPO_ROOT" && as_deploy_principal databricks bundle destroy -t "$DEMO_BUNDLE_TARGET" \
    --auto-approve ${BUNDLE_VARS[@]+"${BUNDLE_VARS[@]}"}) || warn "bundle destroy failed"
  drop_export_schema
  remove_agent_principal

  log "== Lakebase project (purge)"
  if (( DRY_RUN )); then
    run databricks postgres delete-project "$PROJECT" --purge
    return 0
  fi
  local rc=0
  lakebase_project_state || rc=$?
  case "$rc" in
    0) if ! capture databricks postgres delete-project "$PROJECT" --purge && ! is_not_found "$ERR"; then
         warn "purge failed: $ERR"
       fi ;;
    1) log "Lakebase project already gone." ;;
    *) warn "could not list Lakebase projects: $ERR" ;;
  esac
}

delete_budget() {
  log "== Cost alert (Azure budget '$DEMO_PROJECT_TAG')"
  if (( DRY_RUN )); then
    run az rest --method delete --url "$(budget_url)"
    return 0
  fi
  printf '+ az rest --method delete --url %s\n' "$(budget_url)"
  if ! capture az rest --method delete --url "$(budget_url)" && ! is_not_found "$ERR"; then
    warn "budget delete failed: $ERR"
  fi
}

workspace_created_by_script() {
  capture az rest --method get --url "$(workspace_url)" --query 'tags."created-by"' -o tsv \
    && [[ "$OUT" == "deploy-script" ]]
}

delete_workspace() {
  log "== Resource group / workspace"
  local rg="$DEMO_RESOURCE_GROUP"
  if (( DRY_RUN )); then
    log "[dry-run] if the workspace was made by deploy.sh, first its catalog, external location and credential:"
    drop_workspace_catalog
    log "[dry-run] if $rg has tag created-by=deploy-script:"
    run az group delete --name "$rg" --subscription "$SUB" --yes
    log "[dry-run] else, if workspace $DEMO_WORKSPACE_NAME has tag created-by=deploy-script:"
    run az rest --method delete --url "$(workspace_url)"
    return 0
  fi
  if rg_created_by_script || workspace_created_by_script; then
    drop_workspace_catalog
  fi
  if rg_created_by_script; then
    run az group delete --name "$rg" --subscription "$SUB" --yes || warn "resource group delete failed"
    WORKSPACE_DELETED=1
  elif workspace_created_by_script; then
    run az rest --method delete --url "$(workspace_url)" || warn "workspace delete failed"
    WORKSPACE_DELETED=1
  else
    log "No resource group or workspace made by deploy.sh; leaving them alone."
  fi
  (( WORKSPACE_DELETED )) && delete_managed_rg
}

# Azure usually deletes a workspace's managed resource group with it, but on
# 2026-11-09 it was still there 25 minutes later, with a storage account that
# bills. Delete it when it is deploy.sh's (tagged) and its workspace is gone.
delete_managed_rg() {
  local mrg="$DEMO_RESOURCE_GROUP-managed"
  managed_rg_left || return 0
  log "== Managed resource group $mrg"
  for _ in 1 2 3 4 5 6; do
    if capture az group delete --name "$mrg" --subscription "$SUB" --yes; then
      log "Deleted $mrg."
      return 0
    fi
    log "Not deletable yet (Azure may still hold it): waiting..."
    sleep 30
  done
  warn "could not delete $mrg: $ERR"
}

# managed_rg_left: deploy.sh's managed resource group still exists.
managed_rg_left() {
  local mrg="$DEMO_RESOURCE_GROUP-managed" tag
  [[ "$(az group exists --name "$mrg" --subscription "$SUB")" == "true" ]] || return 1
  tag="$(az group show --name "$mrg" --subscription "$SUB" --query 'tags."created-by"' -o tsv 2>/dev/null)"
  [[ "$tag" == "deploy-script" ]]
}

check_nothing_left() {
  log ""
  log "== What is left"
  if (( DRY_RUN )); then
    log "[dry-run] would check: app $DEMO_APP_NAME, job $DEMO_DB_JOB_NAME, Lakebase $PROJECT,"
    log "[dry-run]   budget $DEMO_PROJECT_TAG, resource group / workspace made by deploy.sh"
    return 0
  fi
  local left=()
  if has_bundle && (( ! WORKSPACE_DELETED )); then
    if capture databricks apps get "$DEMO_APP_NAME" -o json; then
      left+=("app $DEMO_APP_NAME")
    elif ! is_not_found "$ERR"; then
      left+=("app $DEMO_APP_NAME (check failed: $ERR)")
    fi
    if capture databricks jobs list --name "$DEMO_DB_JOB_NAME" -o json; then
      grep -q '"job_id"' <<<"$OUT" && left+=("job $DEMO_DB_JOB_NAME")
    else
      left+=("job $DEMO_DB_JOB_NAME (check failed: $ERR)")
    fi
    local rc=0
    lakebase_project_state || rc=$?
    case "$rc" in
      0) left+=("Lakebase $PROJECT") ;;
      1) ;;
      *) left+=("Lakebase $PROJECT (check failed: $ERR)") ;;
    esac
  fi
  if capture az rest --method get --url "$(budget_url)" -o none; then
    left+=("budget $DEMO_PROJECT_TAG")
  elif ! is_not_found "$ERR"; then
    left+=("budget $DEMO_PROJECT_TAG (check failed: $ERR)")
  fi
  rg_created_by_script && left+=("resource group $DEMO_RESOURCE_GROUP")
  managed_rg_left && left+=("managed resource group $DEMO_RESOURCE_GROUP-managed")
  workspace_created_by_script && left+=("workspace $DEMO_WORKSPACE_NAME")

  if (( ${#left[@]} )); then
    log "Still there:"
    printf '  - %s\n' "${left[@]}"
    exit 1
  fi
  log "Nothing left. Kept on purpose, all free: the usage policy (made by hand), the deploy"
  log "principal's Entra app, the account groups and the agent's account record."
}

destroy_bundle
delete_budget
delete_workspace
check_nothing_left
