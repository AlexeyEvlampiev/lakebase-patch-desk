#!/usr/bin/env pwsh
# Tear the Lakebase patch desk demo down and check that nothing is left.
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Help
)

. (Join-Path $PSScriptRoot 'lib.ps1')

if ($Help) {
    Write-Log @'
Usage: scripts/teardown.ps1 [-DryRun] [-Help]

Removes what scripts/deploy.ps1 created:
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

Settings come from the environment, then from $env:DEMO_ENV_FILE or .env.
See .env.example for the list.

Options:
  -DryRun  print every action, change nothing, call no cloud tool
  -Help    show this text
'@
    exit 0
}

$script:IsDryRun = [bool]$DryRun

Import-Settings
Assert-Settings @('AZURE_SUBSCRIPTION_ID')
$BundleVars = @()
if (Test-Bundle) {
    Assert-Settings (@('DATABRICKS_HOST') + $DeploySpSettings)
    $BundleVars = @(Get-BundleVars)
}
Assert-SettingValues
if ($script:IsDryRun) { Write-Log 'Dry run: nothing will change.' }

Assert-Tools @('az', 'databricks')
Assert-AzLogin

$Sub = Get-Setting 'AZURE_SUBSCRIPTION_ID'
$Rg = Get-Setting 'DEMO_RESOURCE_GROUP'
$Project = "projects/$(Get-Setting 'DEMO_LAKEBASE_PROJECT_ID')"
$script:WorkspaceDeleted = $false

# Is the Lakebase project there, active or soft-deleted? 'yes', 'no' or 'unknown: <error>'.
function Get-LakebaseProjectState {
    $r = Invoke-Capture 'databricks' @('postgres', 'list-projects', '--show-deleted', '-o', 'json')
    if (-not $r.Ok) { return "unknown: $($r.Err)" }
    if ($r.Out.Contains("`"$Project`"")) { return 'yes' }
    return 'no'
}

# Run a step; a failure is reported and the teardown goes on.
function Invoke-Soft([string]$Exe, [string[]]$Arguments, [string]$What) {
    try { Invoke-Step $Exe $Arguments } catch { Write-Warn "$What failed: $($_.Exception.Message)" }
}

function Remove-DemoBundle {
    Write-Log '== Bundle'
    if (-not (Test-Bundle)) { Write-Log 'no bundle yet, skipping'; return }
    # A repeat teardown: the workspace deploy.ps1 made is already deleted, so
    # everything in it went with it.
    if (-not $script:IsDryRun) {
        $w = Invoke-Capture 'az' @('rest', '--method', 'get', '--url', (Get-WorkspaceUrl), '-o', 'none')
        if (-not $w.Ok -and (Test-NotFound $w.Err)) {
            Write-Log "Workspace $(Get-Setting 'DEMO_WORKSPACE_NAME') is already gone, and everything in it; skipping the Databricks steps."
            $script:WorkspaceDeleted = $true
            return
        }
    }
    Assert-DatabricksLogin
    # bundle destroy needs the same variables as deploy, the agent's ID too.
    if ($script:IsDryRun) { $script:BundleVars += '--var=agent_app_id=<agent-application-id>' }
    else {
        $agent = Find-AgentPrincipal
        if ($agent) { $script:BundleVars += "--var=agent_app_id=$($agent.AppId)" }
    }
    Push-Location $RepoRoot
    try {
        # The principal deployed the bundle and owns its state, so it destroys it.
        try {
            Invoke-AsDeployPrincipal 'databricks' (@('bundle', 'destroy', '-t', (Get-Setting 'DEMO_BUNDLE_TARGET'),
                '--auto-approve') + $BundleVars)
        }
        catch { Write-Warn "bundle destroy failed: $($_.Exception.Message)" }
    }
    finally { Pop-Location }
    Remove-ExportSchema
    Remove-AgentPrincipal

    Write-Log '== Lakebase project (purge)'
    if ($script:IsDryRun) {
        Invoke-Step 'databricks' @('postgres', 'delete-project', $Project, '--purge')
        return
    }
    $state = Get-LakebaseProjectState
    if ($state -eq 'yes') {
        $r = Invoke-Capture 'databricks' @('postgres', 'delete-project', $Project, '--purge')
        if (-not $r.Ok -and -not (Test-NotFound $r.Err)) { Write-Warn "purge failed: $($r.Err)" }
    }
    elseif ($state -eq 'no') { Write-Log 'Lakebase project already gone.' }
    else { Write-Warn "could not list Lakebase projects: $state" }
}

function Remove-DemoBudget {
    Write-Log "== Cost alert (Azure budget '$(Get-Setting 'DEMO_PROJECT_TAG')')"
    $args_ = @('rest', '--method', 'delete', '--url', (Get-BudgetUrl))
    if ($script:IsDryRun) { Invoke-Step 'az' $args_; return }
    Write-Log "+ az $($args_ -join ' ')"
    $r = Invoke-Capture 'az' $args_
    if (-not $r.Ok -and -not (Test-NotFound $r.Err)) { Write-Warn "budget delete failed: $($r.Err)" }
}

function Test-WorkspaceCreatedByScript {
    $r = Invoke-Capture 'az' @('rest', '--method', 'get', '--url', (Get-WorkspaceUrl), '--query', 'tags."created-by"', '-o', 'tsv')
    $r.Ok -and $r.Out -eq 'deploy-script'
}

function Remove-DemoWorkspace {
    Write-Log '== Resource group / workspace'
    $rgArgs = @('group', 'delete', '--name', $Rg, '--subscription', $Sub, '--yes')
    $wsArgs = @('rest', '--method', 'delete', '--url', (Get-WorkspaceUrl))
    if ($script:IsDryRun) {
        Write-Log '[dry-run] if the workspace was made by deploy.ps1, first its catalog, external location and credential:'
        Remove-WorkspaceCatalog
        Write-Log "[dry-run] if $Rg has tag created-by=deploy-script:"
        Invoke-Step 'az' $rgArgs
        Write-Log "[dry-run] else, if workspace $(Get-Setting 'DEMO_WORKSPACE_NAME') has tag created-by=deploy-script:"
        Invoke-Step 'az' $wsArgs
        return
    }
    if ((Test-RgCreatedByScript) -or (Test-WorkspaceCreatedByScript)) { Remove-WorkspaceCatalog }
    if (Test-RgCreatedByScript) {
        Invoke-Soft 'az' $rgArgs 'resource group delete'
        $script:WorkspaceDeleted = $true
    }
    elseif (Test-WorkspaceCreatedByScript) {
        Invoke-Soft 'az' $wsArgs 'workspace delete'
        $script:WorkspaceDeleted = $true
    }
    else {
        Write-Log 'No resource group or workspace made by deploy.ps1; leaving them alone.'
    }
    if ($script:WorkspaceDeleted) { Remove-ManagedRg }
}

# Azure usually deletes a workspace's managed resource group with it, but on
# 2026-11-09 it was still there 25 minutes later, with a storage account that
# bills. Delete it when it is deploy.ps1's (tagged) and its workspace is gone.
function Test-ManagedRgLeft {
    $mrg = "$Rg-managed"
    if ((az group exists --name $mrg --subscription $Sub) -ne 'true') { return $false }
    $tag = az group show --name $mrg --subscription $Sub --query 'tags."created-by"' -o tsv 2>$null
    return ($tag -eq 'deploy-script')
}

function Remove-ManagedRg {
    $mrg = "$Rg-managed"
    if (-not (Test-ManagedRgLeft)) { return }
    Write-Log "== Managed resource group $mrg"
    foreach ($i in 1..6) {
        $r = Invoke-Capture 'az' @('group', 'delete', '--name', $mrg, '--subscription', $Sub, '--yes')
        if ($r.Ok) { Write-Log "Deleted $mrg."; return }
        Write-Log 'Not deletable yet (Azure may still hold it): waiting...'
        Start-Sleep -Seconds 30
    }
    Write-Warn "could not delete ${mrg}: $($r.Err)"
}

function Test-NothingLeft {
    Write-Log ''
    Write-Log '== What is left'
    $app = Get-Setting 'DEMO_APP_NAME'
    $job = Get-Setting 'DEMO_DB_JOB_NAME'
    $budget = Get-Setting 'DEMO_PROJECT_TAG'
    if ($script:IsDryRun) {
        Write-Log "[dry-run] would check: app $app, job $job, Lakebase $Project,"
        Write-Log "[dry-run]   budget $budget, resource group / workspace made by deploy.ps1"
        return $true
    }
    $left = [System.Collections.Generic.List[string]]::new()
    if ((Test-Bundle) -and -not $script:WorkspaceDeleted) {
        $r = Invoke-Capture 'databricks' @('apps', 'get', $app, '-o', 'json')
        if ($r.Ok) { $left.Add("app $app") }
        elseif (-not (Test-NotFound $r.Err)) { $left.Add("app $app (check failed: $($r.Err))") }

        $r = Invoke-Capture 'databricks' @('jobs', 'list', '--name', $job, '-o', 'json')
        if (-not $r.Ok) { $left.Add("job $job (check failed: $($r.Err))") }
        elseif ($r.Out.Contains('"job_id"')) { $left.Add("job $job") }

        $state = Get-LakebaseProjectState
        if ($state -eq 'yes') { $left.Add("Lakebase $Project") }
        elseif ($state -ne 'no') { $left.Add("Lakebase $Project (check failed: $state)") }
    }
    $r = Invoke-Capture 'az' @('rest', '--method', 'get', '--url', (Get-BudgetUrl), '-o', 'none')
    if ($r.Ok) { $left.Add("budget $budget") }
    elseif (-not (Test-NotFound $r.Err)) { $left.Add("budget $budget (check failed: $($r.Err))") }
    if (Test-RgCreatedByScript) { $left.Add("resource group $Rg") }
    if (Test-ManagedRgLeft) { $left.Add("managed resource group $Rg-managed") }
    if (Test-WorkspaceCreatedByScript) { $left.Add("workspace $(Get-Setting 'DEMO_WORKSPACE_NAME')") }

    if ($left.Count -gt 0) {
        Write-Log 'Still there:'
        foreach ($l in $left) { Write-Log "  - $l" }
        return $false
    }
    Write-Log 'Nothing left. Kept on purpose, all free: the usage policy (made by hand), the deploy'
    Write-Log "principal's Entra app, the account groups and the agent's account record."
    return $true
}

Remove-DemoBundle
Remove-DemoBudget
Remove-DemoWorkspace
if (-not (Test-NothingLeft)) { exit 1 }
