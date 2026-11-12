# Shared helpers for deploy.ps1 and teardown.ps1. Dot-sourced, not run.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$script:IsDryRun = $false

# Azure REST API versions (checked in the Azure template reference).
$BudgetApi = '2026-06-01'
$WorkspaceApi = '2026-01-01'

$Defaults = [ordered]@{
    DEMO_BUDGET_USD          = '20'
    DEMO_PROJECT_TAG         = 'lakebase-patch-desk'
    DEMO_BUNDLE_TARGET       = 'demo'
    DEMO_APP_KEY             = 'patch_desk'
    DEMO_APP_NAME            = 'lakebase-patch-desk'
    DEMO_DB_JOB_KEY          = 'db_deploy'
    DEMO_DB_JOB_NAME         = 'lakebase-patch-desk-db-deploy'
    DEMO_EXPORT_JOB_NAME     = 'lakebase-patch-desk-patch-export'
    DEMO_LAKEBASE_PROJECT_ID = 'lakebase-patch-desk'
    DEMO_RESOURCE_GROUP      = 'rg-lakebase-patch-desk'
    DEMO_WORKSPACE_NAME      = 'dbw-lakebase-patch-desk'
    DEMO_LOCATION            = 'westeurope'
}

function Write-Log([string]$Message) { Write-Host $Message }
function Write-Warn([string]$Message) { [Console]::Error.WriteLine("warning: $Message") }
function Stop-Script([string]$Message) {
    [Console]::Error.WriteLine("error: $Message")
    exit 1
}

function Get-Setting([string]$Name) {
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ($null -eq $v) { return '' }
    return $v
}

function Set-Setting([string]$Name, [string]$Value) {
    [Environment]::SetEnvironmentVariable($Name, $Value)
}

# Print a command; run it unless this is a dry run. Throws on a non-zero exit.
function Invoke-Step([string]$Exe, [string[]]$Arguments) {
    if ($script:IsDryRun) {
        Write-Log "[dry-run] $Exe $($Arguments -join ' ')"
        return
    }
    Write-Log "+ $Exe $($Arguments -join ' ')"
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe failed (exit $LASTEXITCODE)" }
}

# Run a command, return @{ Ok; Out; Err } without throwing.
function Invoke-Capture([string]$Exe, [string[]]$Arguments) {
    $errFile = [IO.Path]::GetTempFileName()
    try {
        $out = & $Exe @Arguments 2>$errFile
        $ok = ($LASTEXITCODE -eq 0)
        $err = Get-Content -Raw -LiteralPath $errFile
        return @{ Ok = $ok; Out = (($out | Out-String).Trim()); Err = "$err".Trim() }
    }
    finally {
        Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue
    }
}

# Environment first, then the env file for unset keys.
# The file is parsed as KEY=value lines; it is never executed.
function Import-Settings {
    $file = Get-Setting 'DEMO_ENV_FILE'
    if (-not $file -and (Test-Path -LiteralPath (Join-Path $RepoRoot '.env'))) {
        $file = Join-Path $RepoRoot '.env'
    }
    if ($file) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Stop-Script "env file not found: $file" }
        Write-Log "Settings file: $file"
        foreach ($line in Get-Content -LiteralPath $file) {
            if ($line -match '^\s*(#|$)') { continue }
            if ($line -notmatch '^\s*(export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
                Stop-Script "bad line in ${file}: $line"
            }
            $key = $Matches[2]
            $value = $Matches[3].TrimEnd()
            if ($value -match '^"(.*)"$' -or $value -match "^'(.*)'$") { $value = $Matches[1] }
            if ($null -eq [Environment]::GetEnvironmentVariable($key)) { Set-Setting $key $value }
        }
    }
    else {
        Write-Log 'Settings file: none (environment only)'
    }
    foreach ($k in $Defaults.Keys) {
        if (-not (Get-Setting $k)) { Set-Setting $k $Defaults[$k] }
    }
}

# Fail naming every missing setting at once.
function Assert-Settings([string[]]$Names) {
    $missing = @($Names | Where-Object { -not (Get-Setting $_) })
    if ($missing.Count -gt 0) {
        Stop-Script "missing required settings: $($missing -join ' ') (set them in the environment or the env file, see .env.example)"
    }
}

# Placeholders pass in a dry run, fail otherwise.
function Assert-Value([string]$Name, [string]$Pattern) {
    $value = Get-Setting $Name
    if (-not $value) { return }
    if ($value -match '<.*>') {
        if ($script:IsDryRun) { Write-Warn "$Name is still a placeholder: $value"; return }
        Stop-Script "$Name is still a placeholder: $value"
    }
    if ($value -cnotmatch $Pattern) { Stop-Script "$Name has an unexpected value: $value" }
}

# Like Assert-Value, but never prints the value.
function Assert-Secret([string]$Name) {
    $value = Get-Setting $Name
    if (-not $value) { return }
    if ($value -match '<.*>') {
        if ($script:IsDryRun) { Write-Warn "$Name is still a placeholder"; return }
        Stop-Script "$Name is still a placeholder"
    }
}

# The settings the bundle commands need: the deploy principal's Entra app.
$DeploySpSettings = @('DEMO_DEPLOY_SP_CLIENT_ID', 'DEMO_DEPLOY_SP_TENANT_ID', 'DEMO_DEPLOY_SP_CLIENT_SECRET')

# The serverless usage policy is optional. An empty value or the
# .env.example placeholder means none: the bundle commands then get no
# --var=usage_policy_id and the bundle's empty default applies.
function Get-BundleVars {
    $vars = @()
    $id = Get-Setting 'DEMO_USAGE_POLICY_ID'
    if (-not $id -or $id -match '<.*>') {
        Set-Setting 'DEMO_USAGE_POLICY_ID' ''
        Write-Log 'no usage policy set, skipping'
    }
    else {
        $vars += "--var=usage_policy_id=$id"
    }
    $catalog = Get-Setting 'DEMO_EXPORT_CATALOG'
    if ($catalog -and $catalog -notmatch '<.*>') { $vars += "--var=export_catalog=$catalog" }
    return $vars
}

function Assert-SettingValues {
    $nameRe = '^[A-Za-z0-9._-]+$'
    Assert-Value 'DATABRICKS_HOST' '^https://[A-Za-z0-9.-]+/?$'
    Assert-Value 'AZURE_SUBSCRIPTION_ID' '^[0-9a-fA-F-]{36}$'
    Assert-Value 'DEMO_ALERT_EMAIL' '^[^@\s"\\]+@[^@\s"\\]+$'
    Assert-Value 'DEMO_USAGE_POLICY_ID' $nameRe
    Assert-Value 'DEMO_EXPORT_CATALOG' '^[A-Za-z0-9_-]+$'
    Assert-Value 'DEMO_BUDGET_USD' '^[0-9]+(\.[0-9]+)?$'
    Assert-Value 'DEMO_DEPLOY_SP_CLIENT_ID' '^[0-9a-fA-F-]{36}$'
    Assert-Value 'DEMO_DEPLOY_SP_TENANT_ID' '^[0-9a-fA-F-]{36}$'
    Assert-Secret 'DEMO_DEPLOY_SP_CLIENT_SECRET'
    foreach ($n in 'DEMO_PROJECT_TAG', 'DEMO_BUNDLE_TARGET', 'DEMO_APP_KEY', 'DEMO_APP_NAME',
        'DEMO_DB_JOB_KEY', 'DEMO_DB_JOB_NAME', 'DEMO_EXPORT_JOB_NAME', 'DEMO_LAKEBASE_PROJECT_ID',
        'DEMO_RESOURCE_GROUP', 'DEMO_WORKSPACE_NAME', 'DEMO_LOCATION') {
        Assert-Value $n $nameRe
    }
}

# Missing tools fail a real run, warn in a dry run.
function Assert-Tools([string[]]$Tools) {
    $missing = @($Tools | Where-Object { -not (Get-Command $_ -CommandType Application -ErrorAction SilentlyContinue) })
    if ($missing.Count -eq 0) { return }
    if ($script:IsDryRun) { Write-Warn "not on PATH: $($missing -join ' ')"; return }
    Stop-Script "not on PATH: $($missing -join ' ')"
}

function Assert-AzLogin {
    if ($script:IsDryRun) { Write-Log '[dry-run] skip: az login check'; return }
    $sub = Get-Setting 'AZURE_SUBSCRIPTION_ID'
    $r = Invoke-Capture 'az' @('account', 'show', '--subscription', $sub, '-o', 'none')
    if (-not $r.Ok) { Stop-Script "not logged in to Azure for subscription $sub (run: az login)" }
}

function Assert-DatabricksLogin {
    if ($script:IsDryRun) { Write-Log '[dry-run] skip: databricks login check'; return }
    $r = Invoke-Capture 'databricks' @('current-user', 'me', '-o', 'json')
    if (-not $r.Ok) {
        $h = Get-Setting 'DATABRICKS_HOST'
        Stop-Script "not logged in to Databricks at $h (run: databricks auth login --host $h)"
    }
}

function Test-Bundle { Test-Path -LiteralPath (Join-Path $RepoRoot 'databricks.yml') }

# True when the bundle files declare a resource with this key.
# Reads the files only, so it also works in a dry run.
function Test-BundleDeclares([string]$Key) {
    $files = @(Join-Path $RepoRoot 'databricks.yml')
    $res = Join-Path $RepoRoot 'resources'
    if (Test-Path -LiteralPath $res) { $files += @(Get-ChildItem -LiteralPath $res -Filter '*.yml' | ForEach-Object FullName) }
    $pattern = '^\s+' + [regex]::Escape($Key) + ':\s*$'
    [bool](Select-String -LiteralPath $files -Pattern $pattern -Quiet -ErrorAction SilentlyContinue)
}

# Run one command as the deploy service principal (Microsoft Entra client
# secret auth). Only this command sees the principal's credentials: they are
# set for the call and the old values put back after. The secret is never printed.
function Invoke-AsDeployPrincipal([string]$Exe, [string[]]$Arguments) {
    $who = "(as deploy principal $(Get-Setting 'DEMO_DEPLOY_SP_CLIENT_ID'))"
    if ($script:IsDryRun) {
        Write-Log "[dry-run] $who $Exe $($Arguments -join ' ')"
        return
    }
    Write-Log "+ $who $Exe $($Arguments -join ' ')"
    $scoped = [ordered]@{
        DATABRICKS_AUTH_TYPE      = 'azure-client-secret'
        ARM_CLIENT_ID             = Get-Setting 'DEMO_DEPLOY_SP_CLIENT_ID'
        ARM_TENANT_ID             = Get-Setting 'DEMO_DEPLOY_SP_TENANT_ID'
        ARM_CLIENT_SECRET         = Get-Setting 'DEMO_DEPLOY_SP_CLIENT_SECRET'
        DATABRICKS_TOKEN          = $null
        DATABRICKS_CONFIG_PROFILE = $null
        DATABRICKS_CLIENT_ID      = $null
        DATABRICKS_CLIENT_SECRET  = $null
    }
    $saved = @{}
    foreach ($k in $scoped.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, $scoped[$k])
    }
    try {
        & $Exe @Arguments
        if ($LASTEXITCODE -ne 0) { throw "$Exe failed (exit $LASTEXITCODE)" }
    }
    finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
}

# The "id" of a SCIM service principal, or of the first one in a list.
function Get-ScimFirstId([string]$Json) {
    $d = $Json | ConvertFrom-Json
    $first = $d
    if ($d.PSObject.Properties['Resources']) { $first = @($d.Resources) | Select-Object -First 1 }
    if ($first -and $first.PSObject.Properties['id']) { return [string]$first.id }
    return ''
}

# The deploy principal in the workspace: added by application ID (it lives in
# Microsoft Entra ID, so it outlives the workspace) and given workspace access.
# Runs as the person deploying, who must be a workspace admin. Idempotent.
$SpScimPath = '/api/2.0/account/scim/v2/ServicePrincipals'
$WsSpScimPath = '/api/2.0/preview/scim/v2/ServicePrincipals'
$WorkspaceAccessPatch = '{"schemas":["urn:ietf:params:scim:api:messages:2.0:PatchOp"],"Operations":[{"op":"add","path":"entitlements","value":[{"value":"workspace-access"}]}]}'
function Add-DeployPrincipal {
    Write-Log '== Deploy service principal in the workspace'
    $app = Get-Setting 'DEMO_DEPLOY_SP_CLIENT_ID'
    $name = "$(Get-Setting 'DEMO_PROJECT_TAG')-deploy"
    if ($script:IsDryRun) {
        Write-Log "[dry-run] look up $app with: databricks api get '${SpScimPath}?filter=applicationId eq `"$app`"'"
        Write-Log "[dry-run] if missing: databricks api post $SpScimPath (applicationId $app, displayName $name)"
        Write-Log '[dry-run] then: databricks api put /api/2.0/preview/permissionassignments/principals/<id> (permissions USER)'
        Write-Log "[dry-run] then: databricks api patch $WsSpScimPath/<id> (add entitlement workspace-access)"
        return
    }
    Assert-DatabricksLogin
    $filter = 'applicationId%20eq%20%22' + $app + '%22'
    $r = Invoke-Capture 'databricks' @('api', 'get', "${SpScimPath}?filter=$filter", '-o', 'json')
    if (-not $r.Ok) { Stop-Script "could not look up the deploy principal: $($r.Err)" }
    $id = Get-ScimFirstId $r.Out
    if (-not $id) {
        $body = @{
            schemas       = @('urn:ietf:params:scim:schemas:core:2.0:ServicePrincipal')
            applicationId = $app
            displayName   = $name
            active        = $true
        } | ConvertTo-Json -Compress
        Write-Log "+ databricks api post $SpScimPath (applicationId $app)"
        $r = Invoke-Capture 'databricks' @('api', 'post', $SpScimPath, '--json', $body, '-o', 'json')
        if (-not $r.Ok) { Stop-Script "could not add the deploy principal (are you a workspace admin?): $($r.Err)" }
        $id = Get-ScimFirstId $r.Out
        if (-not $id) { Stop-Script 'no ID in the reply when adding the deploy principal' }
    }
    else {
        Write-Log "Deploy principal $app is in the account (id $id)."
    }
    Invoke-Step 'databricks' @('api', 'put', "/api/2.0/preview/permissionassignments/principals/$id",
        '--json', '{"permissions":["USER"]}')
    # Principals added to a workspace no longer inherit entitlements from the
    # users group; bundle deploy needs Workspace access, so grant it here.
    Invoke-Step 'databricks' @('api', 'patch', "$WsSpScimPath/$id", '--json', $WorkspaceAccessPatch)
}

# The patch desk's two Databricks groups. provision_principals gives their members
# Postgres roles. Account groups (workspace-local groups are legacy), made
# through the workspace's account-SCIM proxy, assigned to the workspace, with
# workspace access (Consumer access is not enough: the Lakebase API refuses
# a database login to identities without workspace-access, seen 2026-11-09),
# and managed by the deploy
# principal so the job may read their members. Runs as the person deploying,
# a workspace admin. Idempotent.
$PatchDeskGroups = @('patch-desk-uploaders', 'patch-desk-approvers')
$GroupScimPath = '/api/2.0/account/scim/v2/Groups'
$GroupEntitlementPatch = '{"schemas":["urn:ietf:params:scim:api:messages:2.0:PatchOp"],"Operations":[{"op":"add","path":"entitlements","value":[{"value":"workspace-access"}]}]}'
function Add-PatchDeskGroups {
    Write-Log '== Patch desk groups'
    if ($script:IsDryRun) {
        foreach ($name in $PatchDeskGroups) {
            Write-Log "[dry-run] look up or create account group ${name}: $GroupScimPath"
            Write-Log '[dry-run]   assign it to the workspace (USER), add entitlement workspace-access'
            Write-Log '[dry-run]   make the deploy principal its manager (roles/group.manager)'
        }
        return
    }
    Assert-DatabricksLogin
    $host_ = (Get-Setting 'DATABRICKS_HOST').TrimEnd('/')
    $account = (Invoke-RestMethod -Uri "$host_/.well-known/databricks-config").account_id
    if (-not $account) { Stop-Script "could not read the account ID from $host_" }
    foreach ($name in $PatchDeskGroups) {
        $filter = 'displayName%20eq%20%22' + $name + '%22'
        $r = Invoke-Capture 'databricks' @('api', 'get', "${GroupScimPath}?filter=$filter", '-o', 'json')
        if (-not $r.Ok) { Stop-Script "could not look up group ${name}: $($r.Err)" }
        $id = Get-ScimFirstId $r.Out
        if (-not $id) {
            $body = @{ schemas = @('urn:ietf:params:scim:schemas:core:2.0:Group'); displayName = $name } | ConvertTo-Json -Compress
            Write-Log "+ databricks api post $GroupScimPath (displayName $name)"
            $r = Invoke-Capture 'databricks' @('api', 'post', $GroupScimPath, '--json', $body, '-o', 'json')
            if (-not $r.Ok) { Stop-Script "could not create group $name (are you a workspace admin?): $($r.Err)" }
            $id = Get-ScimFirstId $r.Out
            if (-not $id) { Stop-Script "no ID in the reply when creating group $name" }
        }
        else {
            Write-Log "Group $name exists (id $id)."
        }
        Invoke-Step 'databricks' @('api', 'put', "/api/2.0/preview/permissionassignments/principals/$id",
            '--json', '{"permissions":["USER"]}')
        Invoke-Step 'databricks' @('api', 'patch', "/api/2.0/preview/scim/v2/Groups/$id", '--json', $GroupEntitlementPatch)
        Grant-GroupManager $account $id $name
    }
}

# Add the deploy principal to the group's manager role, keeping everyone
# already there. Read, then write with the read's etag (the rule set is
# replaced whole).
function Grant-GroupManager([string]$Account, [string]$Id, [string]$Name) {
    Grant-RuleSetRole "accounts/$Account/groups/$Id/ruleSets/default" 'roles/group.manager' "the deploy principal manages $Name"
}

# Add the deploy principal to a role in an account rule set, keeping everyone
# already there. Read, then write with the read's etag (the rule set is
# replaced whole).
function Grant-RuleSetRole([string]$RuleSet, [string]$Role, [string]$Label) {
    $sp = "servicePrincipals/$(Get-Setting 'DEMO_DEPLOY_SP_CLIENT_ID')"
    $r = Invoke-Capture 'databricks' @('api', 'get',
        "/api/2.0/preview/accounts/access-control/rule-sets?name=$([uri]::EscapeDataString($RuleSet))&etag=", '-o', 'json')
    if (-not $r.Ok) { Stop-Script "could not read the rule set for: ${Label}: $($r.Err)" }
    $current = $r.Out | ConvertFrom-Json
    $rules = @($current.grant_rules | Where-Object { $_ })
    $rule = $rules | Where-Object { $_.role -eq $Role } | Select-Object -First 1
    if ($rule -and (@($rule.principals) -contains $sp)) {
        Write-Log "Already done: $Label."
        return
    }
    if ($rule) { $rule.principals = @($rule.principals) + $sp }
    else { $rules += [pscustomobject]@{ role = $Role; principals = @($sp) } }
    $body = @{ name = $RuleSet; rule_set = @{ name = $RuleSet; etag = $current.etag; grant_rules = $rules } } | ConvertTo-Json -Compress -Depth 6
    Write-Log "+ databricks api put /api/2.0/preview/accounts/access-control/rule-sets ($Label)"
    $r = Invoke-Capture 'databricks' @('api', 'put', '/api/2.0/preview/accounts/access-control/rule-sets', '--json', $body, '-o', 'json')
    if (-not $r.Ok) { Stop-Script "could not grant: ${Label}: $($r.Err)" }
}

# The AI agent's identity (the agent inbox is planned): a Databricks-managed
# service principal, so no Entra app and no secret. It gets workspace access
# (the Lakebase API needs it), and the deploy principal gets the Service
# Principal User role on it, so bundle jobs may run as the agent.
function Get-AgentName { "$(Get-Setting 'DEMO_PROJECT_TAG')-agent" }

# The agent as @{ Id; AppId }, or $null when it does not exist.
function Find-AgentPrincipal {
    $filter = 'displayName%20eq%20%22' + (Get-AgentName) + '%22'
    $r = Invoke-Capture 'databricks' @('api', 'get', "${SpScimPath}?filter=$filter", '-o', 'json')
    if (-not $r.Ok) { Stop-Script "could not look up the agent principal: $($r.Err)" }
    $first = @(($r.Out | ConvertFrom-Json).Resources) | Select-Object -First 1
    if ($first -and $first.id -and $first.applicationId) { return @{ Id = [string]$first.id; AppId = [string]$first.applicationId } }
    return $null
}

function Add-AgentPrincipal {
    Write-Log '== Agent service principal'
    $name = Get-AgentName
    if ($script:IsDryRun) {
        Write-Log "[dry-run] look up or create service principal ${name}: $SpScimPath (display name only: Databricks-managed)"
        Write-Log '[dry-run]   assign it to the workspace (USER), add entitlement workspace-access'
        Write-Log '[dry-run]   give the deploy principal roles/servicePrincipal.user on it'
        $script:BundleVars += '--var=agent_app_id=<agent-application-id>'
        return
    }
    Assert-DatabricksLogin
    $agent = Find-AgentPrincipal
    if ($agent) {
        Write-Log "Agent $name exists (application ID $($agent.AppId))."
    }
    else {
        $body = @{ schemas = @('urn:ietf:params:scim:schemas:core:2.0:ServicePrincipal'); displayName = $name; active = $true } | ConvertTo-Json -Compress
        Write-Log "+ databricks api post $SpScimPath (displayName $name)"
        $r = Invoke-Capture 'databricks' @('api', 'post', $SpScimPath, '--json', $body, '-o', 'json')
        if (-not $r.Ok) { Stop-Script "could not create the agent principal (are you a workspace admin?): $($r.Err)" }
        $agent = Find-AgentPrincipal
        if (-not $agent) { Stop-Script 'the agent principal was created but cannot be found' }
        Write-Log "Created agent $name (application ID $($agent.AppId))."
    }
    Invoke-Step 'databricks' @('api', 'put', "/api/2.0/preview/permissionassignments/principals/$($agent.Id)",
        '--json', '{"permissions":["USER"]}')
    Invoke-Step 'databricks' @('api', 'patch', "$WsSpScimPath/$($agent.Id)", '--json', $WorkspaceAccessPatch)
    $host_ = (Get-Setting 'DATABRICKS_HOST').TrimEnd('/')
    $account = (Invoke-RestMethod -Uri "$host_/.well-known/databricks-config").account_id
    if (-not $account) { Stop-Script "could not read the account ID from $host_" }
    Grant-RuleSetRole "accounts/$account/servicePrincipals/$($agent.AppId)/ruleSets/default" 'roles/servicePrincipal.user' "the deploy principal may run jobs as $name"
    $script:BundleVars += "--var=agent_app_id=$($agent.AppId)"
}

# Jobs that run as the agent read their code from the bundle's files folder,
# which is private to the deploy principal. Give the agent CAN_READ on that
# folder only (bundle-wide permissions would also reach the app and the
# Lakebase project). Runs as the deploy principal, who owns the folder.
function Grant-AgentBundleRead {
    $dir = "/Workspace/Users/$(Get-Setting 'DEMO_DEPLOY_SP_CLIENT_ID')/.bundle/$(Get-Setting 'DEMO_PROJECT_TAG')/$(Get-Setting 'DEMO_BUNDLE_TARGET')/files"
    $agentAppId = (@($script:BundleVars | Where-Object { $_ -like '--var=agent_app_id=*' }) | Select-Object -Last 1) -replace '^--var=agent_app_id=', ''
    $acl = @{ access_control_list = @(@{ service_principal_name = $agentAppId; permission_level = 'CAN_READ' }) } | ConvertTo-Json -Compress -Depth 4
    if ($script:IsDryRun) {
        Write-Log "[dry-run] (as deploy principal) databricks permissions update directories <object-id of $dir> --json $acl"
        return
    }
    $out = Invoke-AsDeployPrincipal 'databricks' @('workspace', 'get-status', $dir, '-o', 'json')
    $oid = (($out | Out-String) -replace '(?s)^[^{]*', '' | ConvertFrom-Json).object_id
    if (-not $oid) { Stop-Script "no object ID for the bundle folder $dir" }
    Invoke-AsDeployPrincipal 'databricks' @('permissions', 'update', 'directories', [string]$oid, '--json', $acl, '-o', 'json') | Out-Null
}

# Take the agent out of the workspace (teardown). Its account-level record
# stays: deleting it needs an account admin (a workspace admin gets "missing
# permissions", seen 2026-11-09). Without a workspace it has no access; the
# next deploy reuses it.
function Remove-AgentPrincipal {
    Write-Log '== Agent service principal'
    if ($script:IsDryRun) {
        Write-Log "[dry-run] databricks api delete $WsSpScimPath/<agent-id>"
        return
    }
    $agent = Find-AgentPrincipal
    if (-not $agent) { Write-Log 'Agent principal not found.'; return }
    Write-Log "+ databricks api delete $WsSpScimPath/$($agent.Id)"
    $r = Invoke-Capture 'databricks' @('api', 'delete', "$WsSpScimPath/$($agent.Id)")
    if (-not $r.Ok -and -not (Test-NotFound $r.Err)) { Write-Warn "could not remove the agent principal from the workspace: $($r.Err)" }
    Write-Log "The agent's account-level record stays (only an account admin can delete it; no access, no cost)."
}

# The catalog the patch_export job writes to: DEMO_EXPORT_CATALOG, or else
# the workspace's default catalog (the job makes the same choice when its
# --catalog is empty).
#
# The default can point at a catalog this workspace cannot reach: after a
# teardown and a new workspace of the same name, the metastore keeps the old
# workspace catalog under the plain name, names the new one
# <name>_<workspace id>, and still reports the plain name as the default
# (seen 2026-11-09). So a default that cannot be read falls back to this
# workspace's own catalog.
function Get-ExportCatalog {
    $catalog = Get-Setting 'DEMO_EXPORT_CATALOG'
    if ($catalog) { return $catalog }
    $r = Invoke-Capture 'databricks' @('metastores', 'current', '-o', 'json')
    if (-not $r.Ok) { Stop-Script "could not read the workspace's default catalog: $($r.Err)" }
    $default = ($r.Out | ConvertFrom-Json).default_catalog_name
    if ($default -and (Invoke-Capture 'databricks' @('catalogs', 'get', $default, '-o', 'json')).Ok) { return $default }
    return Get-WorkspaceCatalogName
}

# The catalog Azure made for this workspace (named after it, isolated to it),
# among the catalogs the workspace can reach; '' when there is not exactly one.
function Get-WorkspaceCatalogName {
    $base = (Get-Setting 'DEMO_WORKSPACE_NAME') -replace '-', '_'
    $r = Invoke-Capture 'databricks' @('catalogs', 'list', '-o', 'json')
    if (-not $r.Ok) { return '' }
    $names = @(($r.Out | ConvertFrom-Json) | Where-Object {
            $_.isolation_mode -eq 'ISOLATED' -and $_.name -match ('^' + [regex]::Escape($base) + '(_[0-9]+)?$') } |
        ForEach-Object { $_.name })
    if ($names.Count -eq 1) { return $names[0] }
    return ''
}

# Before a deploy-made workspace is deleted, remove the catalog, external
# location and storage credential Azure made for it, so a later workspace of
# the same name gets the plain names back. Only objects named after this
# workspace and isolated to it.
function Remove-WorkspaceCatalog {
    if ($script:IsDryRun) {
        foreach ($kind in 'catalogs', 'external-locations', 'storage-credentials') {
            Write-Log "[dry-run] databricks $kind delete <workspace catalog> --force"
        }
        return
    }
    $name = Get-WorkspaceCatalogName
    if (-not $name) { Write-Log "No workspace catalog named after $(Get-Setting 'DEMO_WORKSPACE_NAME') found."; return }
    foreach ($kind in 'catalogs', 'external-locations', 'storage-credentials') {
        Write-Log "+ databricks $kind delete $name --force"
        $r = Invoke-Capture 'databricks' @($kind, 'delete', $name, '--force')
        if (-not $r.Ok -and -not (Test-NotFound $r.Err)) { Write-Warn "could not delete $kind ${name}: $($r.Err)" }
    }
}

# Let the deploy principal create the patch_desk schema in the export
# catalog. Workspace users get only USE CATALOG on the workspace catalog; its
# owners, the workspace admins, may grant more. The principal then owns the
# schema it creates and needs nothing else.
function Grant-ExportCatalog {
    Write-Log '== Export catalog'
    $sp = Get-Setting 'DEMO_DEPLOY_SP_CLIENT_ID'
    $changes = @{ changes = @(@{ principal = $sp; add = @('USE_CATALOG', 'CREATE_SCHEMA') }) } | ConvertTo-Json -Compress -Depth 4
    if ($script:IsDryRun) {
        Write-Log "[dry-run] databricks grants update catalog <catalog> --json $changes"
        return
    }
    Assert-DatabricksLogin
    $catalog = Get-ExportCatalog
    if (-not $catalog) { Stop-Script 'no reachable default catalog in this workspace: set DEMO_EXPORT_CATALOG' }
    Write-Log "Export catalog: $catalog"
    # The jobs get the same catalog, not their own guess at the default.
    if (-not (Get-Setting 'DEMO_EXPORT_CATALOG')) { $script:BundleVars += "--var=export_catalog=$catalog" }
    Write-Log "+ databricks grants update catalog $catalog (deploy principal: USE_CATALOG, CREATE_SCHEMA)"
    $r = Invoke-Capture 'databricks' @('grants', 'update', 'catalog', $catalog, '--json', $changes, '-o', 'json')
    if (-not $r.Ok) {
        Stop-Script ("could not grant on catalog ${catalog}: $($r.Err)`n" +
            "The catalog's owner can run, in a notebook or the SQL editor:`n" +
            "  GRANT USE CATALOG, CREATE SCHEMA ON CATALOG ``$catalog`` TO ``$sp``;")
    }
}

# Remove <catalog>.patch_desk and its Delta table, as the deploy principal
# that created and owns them.
function Remove-ExportSchema {
    Write-Log '== Export schema'
    if ($script:IsDryRun) {
        Invoke-AsDeployPrincipal 'databricks' @('schemas', 'delete', '<catalog>.patch_desk', '--force')
        return
    }
    $catalog = Get-ExportCatalog
    if (-not $catalog) { Write-Log 'no export catalog, skipping'; return }
    try { Invoke-AsDeployPrincipal 'databricks' @('schemas', 'delete', "$catalog.patch_desk", '--force') }
    catch { Write-Warn "could not delete $catalog.patch_desk (already gone?): $($_.Exception.Message)" }
}

function Get-BudgetUrl {
    'https://management.azure.com/subscriptions/{0}/providers/Microsoft.Consumption/budgets/{1}?api-version={2}' -f `
    (Get-Setting 'AZURE_SUBSCRIPTION_ID'), (Get-Setting 'DEMO_PROJECT_TAG'), $BudgetApi
}

function Get-WorkspaceUrl {
    'https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Databricks/workspaces/{2}?api-version={3}' -f `
    (Get-Setting 'AZURE_SUBSCRIPTION_ID'), (Get-Setting 'DEMO_RESOURCE_GROUP'), (Get-Setting 'DEMO_WORKSPACE_NAME'), $WorkspaceApi
}

# True when a CLI error says the thing does not exist.
function Test-NotFound([string]$Text) {
    $Text -match '(?i)not ?found|does not exist|RESOURCE_DOES_NOT_EXIST|\(404\)'
}

# az rest with a JSON body. The body goes through a temp file, so quoting
# works the same on every shell and OS.
function Invoke-AzRestPut([string]$Url, [string]$Body) {
    if ($script:IsDryRun) {
        Write-Log "[dry-run] az rest --method put --url $Url --body $Body"
        return
    }
    $tmp = [IO.Path]::GetTempFileName()
    try {
        Set-Content -LiteralPath $tmp -Value $Body -NoNewline -Encoding utf8NoBOM
        Invoke-Step 'az' @('rest', '--method', 'put', '--url', $Url, '--body', "@$tmp", '-o', 'none')
    }
    finally {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}

# A resource group counts as ours only when deploy created it.
function Test-RgCreatedByScript {
    $r = Invoke-Capture 'az' @('group', 'show', '--name', (Get-Setting 'DEMO_RESOURCE_GROUP'),
        '--subscription', (Get-Setting 'AZURE_SUBSCRIPTION_ID'), '--query', 'tags."created-by"', '-o', 'tsv')
    $r.Ok -and $r.Out -eq 'deploy-script'
}

function Write-IdleCost {
    $app = Get-Setting 'DEMO_APP_NAME'
    $tag = Get-Setting 'DEMO_PROJECT_TAG'
    $amount = Get-Setting 'DEMO_BUDGET_USD'
    Write-Log @"

While idle:
  - Databricks App ($app): bills while running; a stopped app costs
    nothing. Stop it with: databricks apps stop $app
  - Lakebase compute: costs nothing while suspended (scale to zero).
  - Lakebase storage is billed separately from compute.
Remove everything with: scripts/teardown.ps1
"@
    $email = Get-Setting 'DEMO_ALERT_EMAIL'
    if ($email -and $email -notmatch '<.*>') {
        Write-Log "Cost alert: Azure budget '$tag', $amount per month, on spend tagged project=$tag."
    }
}
