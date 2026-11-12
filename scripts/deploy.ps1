#!/usr/bin/env pwsh
# Deploy the Lakebase patch desk demo: cost alert, bundle, database, app.
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$CreateWorkspace,
    [switch]$Help
)

. (Join-Path $PSScriptRoot 'lib.ps1')

if ($Help) {
    Write-Log @'
Usage: scripts/deploy.ps1 [-DryRun] [-CreateWorkspace] [-Help]

Brings the demo up in your Databricks workspace:
  1. checks settings, tools and logins (databricks, az);
  2. optionally creates a resource group and a Premium Azure Databricks
     workspace (-CreateWorkspace);
  3. creates or updates the Azure budget 'lakebase-patch-desk' that watches
     spend tagged project=lakebase-patch-desk;
  4. adds the deploy service principal to the
     workspace, makes the patch desk groups and the agent principal, lets the principal create a
     schema in the export catalog, then, as that principal, bundle deploy,
     database deploy job and app start.

Settings come from the environment, then from $env:DEMO_ENV_FILE or .env.
See .env.example for the list.

Options:
  -DryRun           print every action, change nothing, call no cloud tool
  -CreateWorkspace  create the resource group and workspace first
  -Help             show this text
'@
    exit 0
}

$script:IsDryRun = [bool]$DryRun

Import-Settings
if ($CreateWorkspace) {
    # The host comes from the new workspace; a placeholder does not count.
    if ((Get-Setting 'DATABRICKS_HOST') -match '<.*>') { Set-Setting 'DATABRICKS_HOST' '' }
    Assert-Settings @('AZURE_SUBSCRIPTION_ID')
}
else {
    Assert-Settings @('DATABRICKS_HOST', 'AZURE_SUBSCRIPTION_ID')
}
$BundleVars = @()
if (Test-Bundle) {
    Assert-Settings $DeploySpSettings
    $BundleVars = @(Get-BundleVars)
}
Assert-SettingValues
if ($script:IsDryRun) { Write-Log 'Dry run: nothing will change.' }

Assert-Tools @('az', 'databricks')
Assert-AzLogin

$Sub = Get-Setting 'AZURE_SUBSCRIPTION_ID'
$Tag = Get-Setting 'DEMO_PROJECT_TAG'
$Rg = Get-Setting 'DEMO_RESOURCE_GROUP'
$Location = Get-Setting 'DEMO_LOCATION'

function New-DemoWorkspaceResource {
    $body = @{
        location   = $Location
        sku        = @{ name = 'premium' }
        tags       = @{ project = $Tag; 'created-by' = 'deploy-script' }
        properties = @{ managedResourceGroupId = "/subscriptions/$Sub/resourceGroups/$Rg-managed" }
    } | ConvertTo-Json -Compress -Depth 5
    Invoke-AzRestPut (Get-WorkspaceUrl) $body
}

function Wait-DemoWorkspace {
    if ($script:IsDryRun) {
        Write-Log '[dry-run] wait until the workspace is provisioned, then use its URL as DATABRICKS_HOST'
        return
    }
    $state = ''
    for ($i = 0; $i -lt 90; $i++) {
        $r = Invoke-Capture 'az' @('rest', '--method', 'get', '--url', (Get-WorkspaceUrl), '--query', 'properties.provisioningState', '-o', 'tsv')
        $state = $r.Out
        if ($state -eq 'Succeeded') { break }
        if ($state -eq 'Failed') { Stop-Script 'workspace provisioning failed' }
        Write-Log "Workspace state: $state; waiting..."
        Start-Sleep -Seconds 20
    }
    if ($state -ne 'Succeeded') { Stop-Script 'workspace not ready after 30 minutes' }
    $r = Invoke-Capture 'az' @('rest', '--method', 'get', '--url', (Get-WorkspaceUrl), '--query', 'properties.workspaceUrl', '-o', 'tsv')
    $hostUrl = "https://$($r.Out)"
    Write-Log "Workspace ready: $hostUrl"
    if ((Get-Setting 'DATABRICKS_HOST') -ne $hostUrl) {
        Set-Setting 'DATABRICKS_HOST' $hostUrl
        Write-Log "Put DATABRICKS_HOST=$hostUrl in your env file."
    }
}

function New-DemoWorkspace {
    Write-Log '== Resource group and workspace'
    $createRg = @('group', 'create', '--name', $Rg, '--location', $Location, '--subscription', $Sub,
        '--tags', "project=$Tag", 'created-by=deploy-script', '-o', 'none')
    if ($script:IsDryRun) {
        Invoke-Step 'az' $createRg
    }
    else {
        $exists = Invoke-Capture 'az' @('group', 'exists', '--name', $Rg, '--subscription', $Sub)
        if (-not $exists.Ok) { Stop-Script "could not check the resource group: $($exists.Err)" }
        if ($exists.Out -eq 'true') { Write-Log "Resource group $Rg exists; leaving its tags alone." }
        else { Invoke-Step 'az' $createRg }
    }

    if ($script:IsDryRun) {
        New-DemoWorkspaceResource
    }
    else {
        $ws = Invoke-Capture 'az' @('rest', '--method', 'get', '--url', (Get-WorkspaceUrl), '-o', 'none')
        if ($ws.Ok) { Write-Log "Workspace $(Get-Setting 'DEMO_WORKSPACE_NAME') exists; not touching it." }
        elseif (Test-NotFound $ws.Err) { New-DemoWorkspaceResource }
        else { Stop-Script "could not read the workspace: $($ws.Err)" }
    }
    Wait-DemoWorkspace
}

# The cost alert is optional: without DEMO_ALERT_EMAIL, or without the right
# to create a budget on the subscription, deploy goes on and says so.
function Set-DemoBudget {
    Write-Log "== Cost alert (Azure budget '$Tag')"
    $email = Get-Setting 'DEMO_ALERT_EMAIL'
    if (-not $email -or $email -match '<.*>') { Write-Log 'no DEMO_ALERT_EMAIL set, skipping the cost alert'; return }
    $start = (Get-Date).ToUniversalTime().ToString('yyyy-MM-01T00:00:00Z')
    if (-not $script:IsDryRun) {
        # An existing budget keeps its start date.
        $r = Invoke-Capture 'az' @('rest', '--method', 'get', '--url', (Get-BudgetUrl), '--query', 'properties.timePeriod.startDate', '-o', 'tsv')
        if ($r.Ok) { if ($r.Out) { $start = $r.Out } }
        elseif (-not (Test-NotFound $r.Err)) { Write-Warn "could not read the budget, skipping the cost alert: $($r.Err)"; return }
    }
    $note = @{
        enabled       = $true
        operator      = 'GreaterThanOrEqualTo'
        thresholdType = 'Actual'
        contactEmails = @($email)
    }
    $n80 = $note.Clone(); $n80.threshold = 80
    $n100 = $note.Clone(); $n100.threshold = 100
    $body = @{
        properties = @{
            category      = 'Cost'
            amount        = [decimal](Get-Setting 'DEMO_BUDGET_USD')
            timeGrain     = 'Monthly'
            timePeriod    = @{ startDate = $start }
            filter        = @{ tags = @{ name = 'project'; operator = 'In'; values = @($Tag) } }
            notifications = @{ actual80 = $n80; actual100 = $n100 }
        }
    } | ConvertTo-Json -Compress -Depth 6
    try { Invoke-AzRestPut (Get-BudgetUrl) $body }
    catch { Write-Warn "could not create the cost alert (no right to create budgets?), going on without it: $($_.Exception.Message)" }
}

function Publish-DemoBundle {
    Write-Log '== Bundle'
    if (-not (Test-Bundle)) { Write-Log 'no bundle yet, skipping'; return }
    $t = Get-Setting 'DEMO_BUNDLE_TARGET'
    Push-Location $RepoRoot
    try {
        Invoke-AsDeployPrincipal 'databricks' (@('bundle', 'deploy', '-t', $t) + $BundleVars)
        Grant-AgentBundleRead
        foreach ($key in (Get-Setting 'DEMO_DB_JOB_KEY'), (Get-Setting 'DEMO_APP_KEY')) {
            if (Test-BundleDeclares $key) {
                Invoke-AsDeployPrincipal 'databricks' (@('bundle', 'run', $key, '-t', $t) + $BundleVars)
            }
            else { Write-Log "bundle does not declare $key yet, skipping its run" }
        }
    }
    finally { Pop-Location }
}

try {
    if ($CreateWorkspace) { New-DemoWorkspace }
    Set-DemoBudget
    if (Test-Bundle) {
        Add-DeployPrincipal
        Add-PatchDeskGroups
        Add-AgentPrincipal
        Grant-ExportCatalog
    }
    Publish-DemoBundle
}
catch {
    Stop-Script $_.Exception.Message
}

Write-Log ''
Write-Log '== Now running'
if (Test-Bundle) {
    Write-Log "  - Lakebase project $(Get-Setting 'DEMO_LAKEBASE_PROJECT_ID'), owned by the deploy principal"
    if (Test-BundleDeclares (Get-Setting 'DEMO_DB_JOB_KEY')) { Write-Log "  - Job $(Get-Setting 'DEMO_DB_JOB_NAME')" }
    if (Test-BundleDeclares 'patch_export') {
        Write-Log "  - Job $(Get-Setting 'DEMO_EXPORT_JOB_NAME') (schedule paused) and its Delta table <catalog>.patch_desk.product"
    }
    if (Test-BundleDeclares (Get-Setting 'DEMO_APP_KEY')) { Write-Log "  - App $(Get-Setting 'DEMO_APP_NAME')" }
}
else {
    Write-Log '  - No bundle yet: no app, job or Lakebase project.'
}
Write-Log "  - Azure budget $Tag (no cost of its own)"
if ($CreateWorkspace) { Write-Log "  - Workspace $(Get-Setting 'DEMO_WORKSPACE_NAME') in $Rg" }
Write-IdleCost
