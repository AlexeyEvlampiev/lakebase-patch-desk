# shellcheck shell=bash
# Shared helpers for deploy.sh and teardown.sh. Sourced, not run.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN=0

# Azure REST API versions (checked in the Azure template reference).
BUDGET_API="2026-06-01"
WORKSPACE_API="2026-01-01"

log()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# run CMD ARGS...: print the command; run it unless this is a dry run.
run() {
  if (( DRY_RUN )); then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi
  printf '+ %s\n' "$*"
  "$@"
}

# load_settings: environment first, then the env file for unset keys.
# The file is parsed as KEY=value lines; it is never sourced.
load_settings() {
  local file="${DEMO_ENV_FILE:-}"
  if [[ -z "$file" && -f "$REPO_ROOT/.env" ]]; then
    file="$REPO_ROOT/.env"
  fi
  if [[ -n "$file" ]]; then
    [[ -f "$file" ]] || die "env file not found: $file"
    log "Settings file: $file"
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
      [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] \
        || die "bad line in $file: $line"
      key="${BASH_REMATCH[2]}"
      value="${BASH_REMATCH[3]}"
      value="${value%"${value##*[![:space:]]}"}"
      if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
        value="${BASH_REMATCH[1]}"
      fi
      if [[ -z "${!key+x}" ]]; then
        printf -v "$key" '%s' "$value"
        export "${key?}"
      fi
    done < "$file"
  else
    log "Settings file: none (environment only)"
  fi

  : "${DEMO_BUDGET_USD:=20}"
  : "${DEMO_PROJECT_TAG:=lakebase-patch-desk}"
  : "${DEMO_BUNDLE_TARGET:=demo}"
  : "${DEMO_APP_KEY:=patch_desk}"
  : "${DEMO_APP_NAME:=lakebase-patch-desk}"
  : "${DEMO_DB_JOB_KEY:=db_deploy}"
  : "${DEMO_DB_JOB_NAME:=lakebase-patch-desk-db-deploy}"
  : "${DEMO_EXPORT_JOB_NAME:=lakebase-patch-desk-patch-export}"
  : "${DEMO_EXPORT_CATALOG:=}"
  : "${DEMO_LAKEBASE_PROJECT_ID:=lakebase-patch-desk}"
  : "${DEMO_RESOURCE_GROUP:=rg-lakebase-patch-desk}"
  : "${DEMO_WORKSPACE_NAME:=dbw-lakebase-patch-desk}"
  : "${DEMO_LOCATION:=westeurope}"
  export DATABRICKS_HOST
}

# require_settings NAME...: fail naming every missing setting at once.
require_settings() {
  local missing=() name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || missing+=("$name")
  done
  if (( ${#missing[@]} )); then
    die "missing required settings: ${missing[*]} (set them in the environment or the env file, see .env.example)"
  fi
}

is_placeholder() { [[ "$1" == *"<"*">"* ]]; }

# check_value NAME REGEX: placeholders pass in a dry run, fail otherwise.
check_value() {
  local name="$1" re="$2" value="${!1:-}"
  [[ -z "$value" ]] && return 0
  if is_placeholder "$value"; then
    (( DRY_RUN )) && { warn "$name is still a placeholder: $value"; return 0; }
    die "$name is still a placeholder: $value"
  fi
  [[ "$value" =~ $re ]] || die "$name has an unexpected value: $value"
}

# check_secret NAME: like check_value, but never prints the value.
check_secret() {
  local name="$1" value="${!1:-}"
  [[ -z "$value" ]] && return 0
  if is_placeholder "$value"; then
    (( DRY_RUN )) && { warn "$name is still a placeholder"; return 0; }
    die "$name is still a placeholder"
  fi
}

# The settings the bundle commands need: the deploy principal's Entra app.
# Read by the sourcing scripts.
# shellcheck disable=SC2034
DEPLOY_SP_SETTINGS=(DEMO_DEPLOY_SP_CLIENT_ID DEMO_DEPLOY_SP_TENANT_ID DEMO_DEPLOY_SP_CLIENT_SECRET)

# The serverless usage policy is optional. An empty value or the
# .env.example placeholder means none: the bundle commands then get no
# --var=usage_policy_id and the bundle's empty default applies.
# BUNDLE_VARS is read by the sourcing scripts.
# shellcheck disable=SC2034
BUNDLE_VARS=()
# shellcheck disable=SC2034
set_bundle_vars() {
  if [[ -z "${DEMO_USAGE_POLICY_ID:-}" ]] || is_placeholder "$DEMO_USAGE_POLICY_ID"; then
    DEMO_USAGE_POLICY_ID=""
    log "no usage policy set, skipping"
  else
    BUNDLE_VARS=("--var=usage_policy_id=$DEMO_USAGE_POLICY_ID")
  fi
  if [[ -n "$DEMO_EXPORT_CATALOG" ]] && ! is_placeholder "$DEMO_EXPORT_CATALOG"; then
    BUNDLE_VARS+=("--var=export_catalog=$DEMO_EXPORT_CATALOG")
  fi
}

validate_settings() {
  local name_re='^[A-Za-z0-9._-]+$'
  check_value DATABRICKS_HOST '^https://[A-Za-z0-9.-]+/?$'
  check_value AZURE_SUBSCRIPTION_ID '^[0-9a-fA-F-]{36}$'
  check_value DEMO_ALERT_EMAIL '^[^@[:space:]"\\]+@[^@[:space:]"\\]+$'
  check_value DEMO_USAGE_POLICY_ID "$name_re"
  check_value DEMO_EXPORT_CATALOG '^[A-Za-z0-9_-]+$'
  check_value DEMO_BUDGET_USD '^[0-9]+(\.[0-9]+)?$'
  check_value DEMO_DEPLOY_SP_CLIENT_ID '^[0-9a-fA-F-]{36}$'
  check_value DEMO_DEPLOY_SP_TENANT_ID '^[0-9a-fA-F-]{36}$'
  check_secret DEMO_DEPLOY_SP_CLIENT_SECRET
  local n
  for n in DEMO_PROJECT_TAG DEMO_BUNDLE_TARGET DEMO_APP_KEY DEMO_APP_NAME \
           DEMO_DB_JOB_KEY DEMO_DB_JOB_NAME DEMO_EXPORT_JOB_NAME DEMO_LAKEBASE_PROJECT_ID \
           DEMO_RESOURCE_GROUP DEMO_WORKSPACE_NAME DEMO_LOCATION; do
    check_value "$n" "$name_re"
  done
}

# require_tools TOOL...: missing tools fail a real run, warn in a dry run.
require_tools() {
  local missing=() t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  (( ${#missing[@]} )) || return 0
  (( DRY_RUN )) && { warn "not on PATH: ${missing[*]}"; return 0; }
  die "not on PATH: ${missing[*]}"
}

check_az_login() {
  (( DRY_RUN )) && { log "[dry-run] skip: az login check"; return 0; }
  az account show --subscription "$AZURE_SUBSCRIPTION_ID" -o none 2>/dev/null \
    || die "not logged in to Azure for subscription $AZURE_SUBSCRIPTION_ID (run: az login)"
}

check_databricks_login() {
  (( DRY_RUN )) && { log "[dry-run] skip: databricks login check"; return 0; }
  databricks current-user me -o json >/dev/null 2>&1 \
    || die "not logged in to Databricks at $DATABRICKS_HOST (run: databricks auth login --host $DATABRICKS_HOST)"
}

has_bundle() { [[ -f "$REPO_ROOT/databricks.yml" ]]; }

# bundle_declares KEY: true when the bundle files declare a resource KEY.
# Reads the files only, so it also works in a dry run.
bundle_declares() {
  local files=("$REPO_ROOT/databricks.yml")
  [[ -d "$REPO_ROOT/resources" ]] && files+=("$REPO_ROOT"/resources/*.yml)
  grep -qE "^[[:space:]]+$1:[[:space:]]*$" "${files[@]}" 2>/dev/null
}

# as_deploy_principal CMD ARGS...: run one command as the deploy service
# principal (Microsoft Entra client secret auth). Only this command sees the
# principal's credentials; the secret is never printed.
as_deploy_principal() {
  local who="(as deploy principal $DEMO_DEPLOY_SP_CLIENT_ID)"
  if (( DRY_RUN )); then
    printf '[dry-run] %s %s\n' "$who" "$*"
    return 0
  fi
  printf '+ %s %s\n' "$who" "$*"
  env -u DATABRICKS_TOKEN -u DATABRICKS_CONFIG_PROFILE \
    -u DATABRICKS_CLIENT_ID -u DATABRICKS_CLIENT_SECRET \
    DATABRICKS_AUTH_TYPE=azure-client-secret \
    ARM_CLIENT_ID="$DEMO_DEPLOY_SP_CLIENT_ID" \
    ARM_TENANT_ID="$DEMO_DEPLOY_SP_TENANT_ID" \
    ARM_CLIENT_SECRET="$DEMO_DEPLOY_SP_CLIENT_SECRET" \
    "$@"
}

# The deploy principal in the workspace: added by application ID (it lives in
# Microsoft Entra ID, so it outlives the workspace) and given workspace access.
# Runs as the person deploying, who must be a workspace admin. Idempotent.
SP_SCIM_PATH="/api/2.0/account/scim/v2/ServicePrincipals"
WS_SP_SCIM_PATH="/api/2.0/preview/scim/v2/ServicePrincipals"
WORKSPACE_ACCESS_PATCH='{"schemas":["urn:ietf:params:scim:api:messages:2.0:PatchOp"],"Operations":[{"op":"add","path":"entitlements","value":[{"value":"workspace-access"}]}]}'
add_deploy_principal() {
  log "== Deploy service principal in the workspace"
  local app="$DEMO_DEPLOY_SP_CLIENT_ID" name="$DEMO_PROJECT_TAG-deploy"
  if (( DRY_RUN )); then
    log "[dry-run] look up $app with: databricks api get '$SP_SCIM_PATH?filter=applicationId eq \"$app\"'"
    log "[dry-run] if missing: databricks api post $SP_SCIM_PATH (applicationId $app, displayName $name)"
    log "[dry-run] then: databricks api put /api/2.0/preview/permissionassignments/principals/<id> (permissions USER)"
    log "[dry-run] then: databricks api patch $WS_SP_SCIM_PATH/<id> (add entitlement workspace-access)"
    return 0
  fi
  check_databricks_login
  local filter id
  filter="$(printf 'applicationId%%20eq%%20%%22%s%%22' "$app")"
  capture databricks api get "$SP_SCIM_PATH?filter=$filter" -o json \
    || die "could not look up the deploy principal: $ERR"
  id="$(scim_first_id <<<"$OUT")"
  if [[ -z "$id" ]]; then
    local body
    body="$(printf '{"schemas":["urn:ietf:params:scim:schemas:core:2.0:ServicePrincipal"],"applicationId":"%s","displayName":"%s","active":true}' \
      "$app" "$name")"
    log "+ databricks api post $SP_SCIM_PATH (applicationId $app)"
    capture databricks api post "$SP_SCIM_PATH" --json "$body" -o json \
      || die "could not add the deploy principal (are you a workspace admin?): $ERR"
    id="$(scim_first_id <<<"$OUT")"
    [[ -n "$id" ]] || die "no ID in the reply when adding the deploy principal"
  else
    log "Deploy principal $app is in the account (id $id)."
  fi
  run databricks api put "/api/2.0/preview/permissionassignments/principals/$id" \
    --json '{"permissions":["USER"]}'
  # Principals added to a workspace no longer inherit entitlements from the
  # users group; bundle deploy needs Workspace access, so grant it here.
  run databricks api patch "$WS_SP_SCIM_PATH/$id" --json "$WORKSPACE_ACCESS_PATCH"
}

# The patch desk's two Databricks groups. provision_principals gives their members
# Postgres roles. Account groups (workspace-local groups are legacy), made
# through the workspace's account-SCIM proxy, assigned to the workspace, with
# workspace access (Consumer access is not enough: the Lakebase API refuses
# a database login to identities without workspace-access, seen 2026-11-09),
# and managed by the deploy
# principal so the job may read their members. Runs as the person deploying,
# a workspace admin. Idempotent.
PATCH_DESK_GROUPS=(patch-desk-uploaders patch-desk-approvers)
GROUP_SCIM_PATH="/api/2.0/account/scim/v2/Groups"
GROUP_ENTITLEMENT_PATCH='{"schemas":["urn:ietf:params:scim:api:messages:2.0:PatchOp"],"Operations":[{"op":"add","path":"entitlements","value":[{"value":"workspace-access"}]}]}'
ensure_groups() {
  log "== Patch desk groups"
  local name id
  if (( DRY_RUN )); then
    for name in "${PATCH_DESK_GROUPS[@]}"; do
      log "[dry-run] look up or create account group $name: $GROUP_SCIM_PATH"
      log "[dry-run]   assign it to the workspace (USER), add entitlement workspace-access"
      log "[dry-run]   make the deploy principal its manager (roles/group.manager)"
    done
    return 0
  fi
  check_databricks_login
  local account
  account="$(workspace_account_id)" || die "could not read the account ID from $DATABRICKS_HOST"
  for name in "${PATCH_DESK_GROUPS[@]}"; do
    capture databricks api get "$GROUP_SCIM_PATH?filter=$(printf 'displayName%%20eq%%20%%22%s%%22' "$name")" -o json \
      || die "could not look up group $name: $ERR"
    id="$(scim_first_id <<<"$OUT")"
    if [[ -z "$id" ]]; then
      log "+ databricks api post $GROUP_SCIM_PATH (displayName $name)"
      capture databricks api post "$GROUP_SCIM_PATH" -o json \
        --json "$(printf '{"schemas":["urn:ietf:params:scim:schemas:core:2.0:Group"],"displayName":"%s"}' "$name")" \
        || die "could not create group $name (are you a workspace admin?): $ERR"
      id="$(scim_first_id <<<"$OUT")"
      [[ -n "$id" ]] || die "no ID in the reply when creating group $name"
    else
      log "Group $name exists (id $id)."
    fi
    run databricks api put "/api/2.0/preview/permissionassignments/principals/$id" \
      --json '{"permissions":["USER"]}'
    run databricks api patch "/api/2.0/preview/scim/v2/Groups/$id" --json "$GROUP_ENTITLEMENT_PATCH"
    grant_group_manager "$account" "$id" "$name"
  done
}

# export_catalog_name: the catalog the patch_export job writes to:
# DEMO_EXPORT_CATALOG, or else the workspace's default catalog (the job makes
# the same choice when its --catalog is empty).
#
# The default can point at a catalog this workspace cannot reach: after a
# teardown and a new workspace of the same name, the metastore keeps the old
# workspace catalog under the plain name (bound to the deleted workspace),
# names the new one <name>_<workspace id>, and still reports the plain name
# as the default (seen 2026-11-09). So a default that cannot be read falls
# back to this workspace's own catalog.
export_catalog_name() {
  if [[ -n "$DEMO_EXPORT_CATALOG" ]]; then
    printf '%s\n' "$DEMO_EXPORT_CATALOG"
    return 0
  fi
  local default
  default="$(databricks metastores current -o json \
    | python3 -c 'import json, sys; print(json.load(sys.stdin).get("default_catalog_name", ""))')" || return 1
  if [[ -n "$default" ]] && databricks catalogs get "$default" -o json >/dev/null 2>&1; then
    printf '%s\n' "$default"
    return 0
  fi
  workspace_catalog_name
}

# workspace_catalog_name: the catalog Azure made for this workspace (named
# after it, isolated to it), among the catalogs the workspace can reach.
workspace_catalog_name() {
  local base="${DEMO_WORKSPACE_NAME//-/_}"
  databricks catalogs list -o json | python3 -I -c '
import json, re, sys
base = sys.argv[1]
names = [c["name"] for c in json.load(sys.stdin)
         if c.get("isolation_mode") == "ISOLATED" and re.fullmatch(re.escape(base) + r"(_[0-9]+)?", c["name"])]
print(names[0] if len(names) == 1 else "")
' "$base"
}

# drop_workspace_catalog: before deploy-made workspace is deleted, remove the
# catalog, external location and storage credential Azure made for it, so a
# later workspace of the same name gets the plain names back. Only objects
# named after this workspace and isolated to it; nothing else on the
# metastore. Runs as the person tearing down (a workspace admin, the owner).
drop_workspace_catalog() {
  if (( DRY_RUN )); then
    run databricks catalogs delete "<workspace catalog>" --force
    run databricks external-locations delete "<workspace catalog>" --force
    run databricks storage-credentials delete "<workspace catalog>" --force
    return 0
  fi
  local name
  name="$(workspace_catalog_name)" || { warn "could not list catalogs"; return 0; }
  [[ -n "$name" ]] || { log "No workspace catalog named after $DEMO_WORKSPACE_NAME found."; return 0; }
  local kind
  for kind in catalogs external-locations storage-credentials; do
    printf '+ databricks %s delete %s --force\n' "$kind" "$name"
    if ! capture databricks "$kind" delete "$name" --force && ! is_not_found "$ERR"; then
      warn "could not delete $kind $name: $ERR"
    fi
  done
}

# grant_export_catalog: let the deploy principal create the patch_desk
# schema in the export catalog. Workspace users get only USE CATALOG on the
# workspace catalog; its owners, the workspace admins, may grant more. The
# principal then owns the schema it creates and needs nothing else.
grant_export_catalog() {
  log "== Export catalog"
  local sp="$DEMO_DEPLOY_SP_CLIENT_ID" catalog
  local changes='{"changes":[{"principal":"'"$sp"'","add":["USE_CATALOG","CREATE_SCHEMA"]}]}'
  if (( DRY_RUN )); then
    log "[dry-run] catalog: ${DEMO_EXPORT_CATALOG:-(the default catalog of the workspace)}"
    run databricks grants update catalog "<catalog>" --json "$changes"
    return 0
  fi
  check_databricks_login
  catalog="$(export_catalog_name)" || die "could not read the workspace's default catalog"
  [[ -n "$catalog" ]] || die "no reachable default catalog in this workspace: set DEMO_EXPORT_CATALOG"
  log "Export catalog: $catalog"
  # The jobs get the same catalog, not their own guess at the default.
  [[ -n "$DEMO_EXPORT_CATALOG" ]] || BUNDLE_VARS+=("--var=export_catalog=$catalog")
  log "+ databricks grants update catalog $catalog (deploy principal: USE_CATALOG, CREATE_SCHEMA)"
  if ! capture databricks grants update catalog "$catalog" --json "$changes" -o json; then
    die "could not grant on catalog $catalog: $ERR
The catalog's owner can run, in a notebook or the SQL editor:
  GRANT USE CATALOG, CREATE SCHEMA ON CATALOG \`$catalog\` TO \`$sp\`;"
  fi
}

# drop_export_schema: remove <catalog>.patch_desk and its Delta table, as the
# deploy principal that created and owns them.
drop_export_schema() {
  log "== Export schema"
  if (( DRY_RUN )); then
    as_deploy_principal databricks schemas delete "<catalog>.patch_desk" --force
    return 0
  fi
  local catalog
  catalog="$(export_catalog_name)" || { warn "could not read the workspace's default catalog"; return 0; }
  [[ -n "$catalog" ]] || { log "no export catalog, skipping"; return 0; }
  printf '+ (as deploy principal) databricks schemas delete %s.patch_desk --force\n' "$catalog"
  if ! capture as_deploy_principal databricks schemas delete "$catalog.patch_desk" --force \
      && ! is_not_found "$ERR"; then
    warn "could not delete $catalog.patch_desk: $ERR"
  fi
}

# workspace_account_id: the Databricks account ID, from the workspace's
# public metadata.
workspace_account_id() {
  curl -fsS "${DATABRICKS_HOST%/}/.well-known/databricks-config" \
    | grep -oE '"account_id"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n 1 | sed -E 's/.*"([^"]+)"$/\1/'
}

# grant_group_manager ACCOUNT GROUP_ID NAME: add the deploy principal to the
# group's manager role, keeping everyone already there. Read, then write with
# the read's etag (the rule set is replaced whole).
grant_group_manager() {
  grant_rule_set_role "accounts/$1/groups/$2/ruleSets/default" roles/group.manager "the deploy principal manages $3"
}

# grant_rule_set_role RULE_SET ROLE LABEL: add the deploy principal to ROLE
# in an account rule set, keeping everyone already there. Read, then write
# with the read's etag (the rule set is replaced whole).
grant_rule_set_role() {
  local rs="$1" role="$2" label="$3" body
  local sp="servicePrincipals/$DEMO_DEPLOY_SP_CLIENT_ID"
  capture databricks api get "/api/2.0/preview/accounts/access-control/rule-sets?name=$(urlencode "$rs")&etag=" -o json \
    || die "could not read the rule set for: $label: $ERR"
  if python3 -I -c '
import json, sys
role, sp, current = sys.argv[1], sys.argv[2], json.loads(sys.stdin.read())
sys.exit(0 if any(r["role"] == role and sp in r.get("principals", []) for r in current.get("grant_rules", [])) else 1)
' "$role" "$sp" <<<"$OUT"; then
    log "Already done: $label."
    return 0
  fi
  body="$(python3 -I -c '
import json, sys
name, role, sp, current = sys.argv[1], sys.argv[2], sys.argv[3], json.loads(sys.stdin.read())
rules = current.get("grant_rules", [])
for rule in rules:
    if rule["role"] == role:
        rule["principals"].append(sp)
        break
else:
    rules.append({"role": role, "principals": [sp]})
print(json.dumps({"name": name, "rule_set": {"name": name, "etag": current["etag"], "grant_rules": rules}}))
' "$rs" "$role" "$sp" <<<"$OUT")" || die "could not build the rule set for: $label"
  log "+ databricks api put /api/2.0/preview/accounts/access-control/rule-sets ($label)"
  capture databricks api put /api/2.0/preview/accounts/access-control/rule-sets --json "$body" -o json \
    || die "could not grant: $label: $ERR"
}

# The AI agent's identity (the agent inbox is planned): a Databricks-managed
# service principal, so no Entra app and no secret. It gets workspace access
# (the Lakebase API needs it), and the deploy principal gets the Service
# Principal User role on it, so bundle jobs may run as the agent. Sets
# AGENT_APP_ID. Runs as the person deploying, a workspace admin. Idempotent.
AGENT_APP_ID=""
agent_name() { printf '%s-agent' "$DEMO_PROJECT_TAG"; }

# find_agent_principal: set AGENT_ID (account SCIM id) and AGENT_APP_ID if the
# agent exists; return 1 if it does not.
find_agent_principal() {
  local filter
  filter="$(printf 'displayName%%20eq%%20%%22%s%%22' "$(agent_name)")"
  capture databricks api get "$SP_SCIM_PATH?filter=$filter" -o json \
    || die "could not look up the agent principal: $ERR"
  AGENT_ID="$(scim_first_id <<<"$OUT")"
  AGENT_APP_ID="$(grep -oE '"applicationId"[[:space:]]*:[[:space:]]*"[^"]+"' <<<"$OUT" | head -n 1 | sed -E 's/.*"([^"]+)"$/\1/')"
  [[ -n "$AGENT_ID" && -n "$AGENT_APP_ID" ]]
}

ensure_agent_principal() {
  log "== Agent service principal"
  local name
  name="$(agent_name)"
  if (( DRY_RUN )); then
    log "[dry-run] look up or create service principal $name: $SP_SCIM_PATH (display name only: Databricks-managed)"
    log "[dry-run]   assign it to the workspace (USER), add entitlement workspace-access"
    log "[dry-run]   give the deploy principal roles/servicePrincipal.user on it"
    AGENT_APP_ID="<agent-application-id>"
    BUNDLE_VARS+=("--var=agent_app_id=$AGENT_APP_ID")
    return 0
  fi
  check_databricks_login
  if find_agent_principal; then
    log "Agent $name exists (application ID $AGENT_APP_ID)."
  else
    local body
    body="$(printf '{"schemas":["urn:ietf:params:scim:schemas:core:2.0:ServicePrincipal"],"displayName":"%s","active":true}' "$name")"
    log "+ databricks api post $SP_SCIM_PATH (displayName $name)"
    capture databricks api post "$SP_SCIM_PATH" --json "$body" -o json \
      || die "could not create the agent principal (are you a workspace admin?): $ERR"
    find_agent_principal || die "the agent principal was created but cannot be found"
    log "Created agent $name (application ID $AGENT_APP_ID)."
  fi
  run databricks api put "/api/2.0/preview/permissionassignments/principals/$AGENT_ID" \
    --json '{"permissions":["USER"]}'
  run databricks api patch "$WS_SP_SCIM_PATH/$AGENT_ID" --json "$WORKSPACE_ACCESS_PATCH"
  local account
  account="$(workspace_account_id)" || die "could not read the account ID from $DATABRICKS_HOST"
  grant_rule_set_role "accounts/$account/servicePrincipals/$AGENT_APP_ID/ruleSets/default" \
    roles/servicePrincipal.user "the deploy principal may run jobs as $name"
  BUNDLE_VARS+=("--var=agent_app_id=$AGENT_APP_ID")
}

# grant_agent_bundle_read: jobs that run as the agent read their code from
# the bundle's files folder, which is private to the deploy principal. Give
# the agent CAN_READ on that folder only (bundle-wide permissions would also
# reach the app and the Lakebase project). Runs as the deploy principal, who
# owns the folder.
grant_agent_bundle_read() {
  local dir="/Workspace/Users/$DEMO_DEPLOY_SP_CLIENT_ID/.bundle/$DEMO_PROJECT_TAG/$DEMO_BUNDLE_TARGET/files"
  local acl='{"access_control_list":[{"service_principal_name":"'"$AGENT_APP_ID"'","permission_level":"CAN_READ"}]}'
  if (( DRY_RUN )); then
    as_deploy_principal databricks permissions update directories "<object-id of $dir>" --json "$acl"
    return 0
  fi
  local oid
  capture as_deploy_principal databricks workspace get-status "$dir" -o json \
    || die "could not read the bundle folder $dir: $ERR"
  oid="$(sed -n '/^{/,$p' <<<"$OUT" | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["object_id"])')" \
    || die "no object ID for the bundle folder $dir"
  log "+ (as deploy principal) databricks permissions update directories $oid (agent: CAN_READ on the bundle files)"
  capture as_deploy_principal databricks permissions update directories "$oid" --json "$acl" -o json \
    || die "could not let the agent read the bundle files: $ERR"
}

# remove_agent_principal: take the agent out of the workspace (teardown). Its
# account-level record stays: deleting it needs an account admin (a
# workspace admin gets "missing permissions", seen 2026-11-09). Without a
# workspace it has no access to anything; the next deploy reuses it.
remove_agent_principal() {
  log "== Agent service principal"
  if (( DRY_RUN )); then
    run databricks api delete "$WS_SP_SCIM_PATH/<agent-id>"
    return 0
  fi
  if [[ -z "${AGENT_ID:-}" ]] && ! find_agent_principal; then
    log "Agent principal not found."
    return 0
  fi
  printf '+ databricks api delete %s/%s\n' "$WS_SP_SCIM_PATH" "$AGENT_ID"
  if ! capture databricks api delete "$WS_SP_SCIM_PATH/$AGENT_ID" && ! is_not_found "$ERR"; then
    warn "could not remove the agent principal from the workspace: $ERR"
  fi
  log "The agent's account-level record stays (only an account admin can delete it; no access, no cost)."
}

urlencode() { python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

# scim_first_id: the "id" of a SCIM service principal, or of the first one
# in a list. (Group and entitlement entries carry "value", not "id".)
scim_first_id() {
  grep -oE '"id"[[:space:]]*:[[:space:]]*"[0-9]+"' | head -n 1 | grep -oE '[0-9]+' || true
}

budget_url() {
  printf 'https://management.azure.com/subscriptions/%s/providers/Microsoft.Consumption/budgets/%s?api-version=%s' \
    "$AZURE_SUBSCRIPTION_ID" "$DEMO_PROJECT_TAG" "$BUDGET_API"
}

workspace_url() {
  printf 'https://management.azure.com/subscriptions/%s/resourceGroups/%s/providers/Microsoft.Databricks/workspaces/%s?api-version=%s' \
    "$AZURE_SUBSCRIPTION_ID" "$DEMO_RESOURCE_GROUP" "$DEMO_WORKSPACE_NAME" "$WORKSPACE_API"
}

# is_not_found TEXT: true when a CLI error says the thing does not exist.
is_not_found() {
  grep -qiE 'not ?found|does not exist|RESOURCE_DOES_NOT_EXIST|\(404\)' <<<"$1"
}

# capture CMD ARGS...: run, keep stdout in OUT and stderr in ERR.
# OUT and ERR are read by the sourcing scripts.
# shellcheck disable=SC2034
OUT="" ERR=""
# shellcheck disable=SC2034
capture() {
  local errf rc=0
  errf="$(mktemp)"
  OUT="$("$@" 2>"$errf")" || rc=$?
  ERR="$(<"$errf")"
  rm -f "$errf"
  return "$rc"
}

# A resource group counts as ours only when deploy created it.
rg_created_by_script() {
  local tag
  tag="$(az group show --name "$DEMO_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION_ID" \
    --query 'tags."created-by"' -o tsv 2>/dev/null)" || return 1
  [[ "$tag" == "deploy-script" ]]
}

print_idle_cost() {
  cat <<EOF

While idle:
  - Databricks App ($DEMO_APP_NAME): bills while running; a stopped app costs
    nothing. Stop it with: databricks apps stop $DEMO_APP_NAME
  - Lakebase compute: costs nothing while suspended (scale to zero).
  - Lakebase storage is billed separately from compute.
Remove everything with: scripts/teardown.sh
EOF
  if [[ -n "${DEMO_ALERT_EMAIL:-}" ]] && ! is_placeholder "$DEMO_ALERT_EMAIL"; then
    log "Cost alert: Azure budget '$DEMO_PROJECT_TAG', $DEMO_BUDGET_USD per month, on spend tagged project=$DEMO_PROJECT_TAG."
  fi
}
