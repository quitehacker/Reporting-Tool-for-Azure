<#
.SYNOPSIS
    Audits Azure Diagnostic Settings across all resources in a subscription.

.DESCRIPTION
    This script retrieves all resources in a specified Azure subscription (or the current context)
    and checks if Diagnostic Settings are configured for each resource.
    It captures details such as Log Analytics workspace, Storage Account, Event Hub, and enabled log categories.
    Results are exported to a CSV file and a summary is displayed in the console.

.PARAMETER SubscriptionId
    Optional. The ID of the subscription to audit. If not provided, the current context's subscription is used.

.PARAMETER ResourceGroupName
    Optional. audits only resources within the specified Resource Group.

.PARAMETER ResourceType
    Optional. Audits only resources of the specified type (e.g., 'Microsoft.Compute/virtualMachines').

.PARAMETER OutputPath
    Optional. The directory where the CSV report will be saved. Defaults to the current script directory.

.EXAMPLE
    .\Get-AzureDiagnosticAudit.ps1
    Audits all resources in the current subscription.

.EXAMPLE
    .\Get-AzureDiagnosticAudit.ps1 -ResourceGroupName "my-rg"
    Audits only resources in the resource group 'my-rg'.

.EXAMPLE
    .\Get-AzureDiagnosticAudit.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000" -Verbose
    Audits a specific subscription with verbose output.
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId,

    [string]$ResourceGroupName,

    [string]$ResourceType,

    [string]$OutputPath = $PSScriptRoot
)

Begin {
    $ErrorActionPreference = "Stop"
    Write-Host "Initializing Azure Diagnostic Audit..." -ForegroundColor Cyan

    # Login Check
    try {
        $context = Get-AzContext -ErrorAction Stop
    }
    catch {
        Write-Error "No Azure context found. Please run 'Connect-AzAccount' to login."
    }

    # Set Subscription
    if (-not [string]::IsNullOrEmpty($SubscriptionId)) {
        try {
            Write-Verbose "Setting context to subscription: $SubscriptionId"
            Set-AzContext -SubscriptionId $SubscriptionId -Force | Out-Null
            $context = Get-AzContext
        }
        catch {
            Write-Error "Failed to set subscription with ID '$SubscriptionId'. Error: $_"
        }
    }

    $SubName = $context.Subscription.Name
    $SubId = $context.Subscription.Id
    Write-Host "Target Subscription: $SubName ($SubId)" -ForegroundColor Green

    # Define resources that ignore diagnostic settings generally or cause noise (Optional refinement)
    # For now, we audit everything returned by Get-AzResource.
    
    $timestamp = Get-Date -Format "yyyyMMdd-HHmm"
    $csvFileName = "AzureDiagAudit_$($SubName -replace '[^a-zA-Z0-9]','_')_$timestamp.csv"
    $fullCsvPath = Join-Path -Path $OutputPath -ChildPath $csvFileName
}

Process {
    Write-Host "Retrieving resources..." -ForegroundColor Cyan
    
    $params = @{}
    if ($ResourceGroupName) { $params['ResourceGroupName'] = $ResourceGroupName }
    if ($ResourceType) { $params['ResourceType'] = $ResourceType }

    try {
        $resources = Get-AzResource @params
    }
    catch {
        Write-Error "Failed to retrieve resources. Error: $_"
    }

    $totalResources = $resources.Count
    if ($totalResources -eq 0) {
        Write-Warning "No resources found matching the criteria."
        return
    }
    Write-Host "Found $totalResources resources. Starting audit..." -ForegroundColor Cyan

    $results = [System.Collections.Generic.List[PSObject]]::new()
    
    $counter = 0
    foreach ($res in $resources) {
        $counter++
        $percentComplete = [int](($counter / $totalResources) * 100)
        Write-Progress -Activity "Auditing Resources" -Status "Processing $($res.Name)" -PercentComplete $percentComplete -CurrentOperation "$counter / $totalResources"

        $diagStatus = "No"
        $laWorkspaceId = $null
        $laWorkspaceName = $null
        $storageId = $null
        $eventHubId = $null
        $enabledLogs = [System.Collections.Generic.List[string]]::new()
        $hasSettableDiagnostics = $true

        try {
            # Some resource types might not support diagnostic settings, but Get-AzDiagnosticSetting usually returns empty or clean error?
            # We treat errors as "Not Supported" or "Error".
            # Note: Get-AzDiagnosticSetting requires the resource ID.
            
            $diagSettings = Get-AzDiagnosticSetting -ResourceId $res.ResourceId -ErrorAction SilentlyContinue
            
            if ($diagSettings) {
                $diagStatus = "Yes"
                
                # There can be multiple diagnostic settings. We will concatenate info or take the first valid one?
                # Requirement implies checking if configured. We'll summarize.
                
                foreach ($ds in $diagSettings) {
                    if ($ds.WorkspaceId) { 
                        $laWorkspaceId = $ds.WorkspaceId 
                        # Attempt to extract name from ID if possible
                        if ($laWorkspaceId -match "/workspaces/([^/]+)$") {
                            $laWorkspaceName = $matches[1]
                        }
                    }
                    if ($ds.StorageAccountId) { $storageId = $ds.StorageAccountId }
                    if ($ds.EventHubAuthorizationRuleId) { $eventHubId = $ds.EventHubAuthorizationRuleId }
                    
                    # Logs
                    if ($ds.Logs) {
                        foreach ($log in $ds.Logs) {
                            if ($log.Enabled) {
                                $enabledLogs.Add($log.Category)
                            }
                        }
                    }
                }
            }
        }
        catch {
            $hasSettableDiagnostics = $false
            Write-Verbose "Could not get diagnostics for $($res.Name) ($($res.ResourceType)). Error: $_"
        }
        
        $obj = [PSCustomObject]@{
            ResourceName         = $res.Name
            ResourceType         = $res.ResourceType
            ResourceGroup        = $res.ResourceGroupName
            Location             = $res.Location
            DiagnosticConfigured = $diagStatus
            LogsEnabled          = if ($enabledLogs.Count -gt 0) { $enabledLogs -join "; " } else { "None" }
            LAWorkspaceName      = $laWorkspaceName
            LAWorkspaceId        = $laWorkspaceId
            StorageAccount       = $storageId
            EventHub             = $eventHubId
            Subscription         = $SubName
        }
        
        $results.Add($obj)
    }
    Write-Progress -Activity "Auditing Resources" -Completed

    # Export
    try {
        $results | Export-Csv -Path $fullCsvPath -NoTypeInformation -Force
        Write-Host "Results exported to: $fullCsvPath" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to export CSV. Error: $_"
    }

    # Summary Stats
    $settingsYes = ($results | Where-Object { $_.DiagnosticConfigured -eq "Yes" }).Count
    $settingsNo = $totalResources - $settingsYes
    
    $laCounts = $results | Where-Object { $_.LAWorkspaceName } | Group-Object LAWorkspaceName

    Write-Host "`nSummary Statistics" -ForegroundColor Yellow
    Write-Host "------------------" -ForegroundColor Yellow
    Write-Host "Total Resources Checked      : $totalResources"
    Write-Host "With Diagnostic Settings     : $settingsYes"
    Write-Host "Without Diagnostic Settings  : $settingsNo"
    
    if ($laCounts) {
        Write-Host "`nLog Analytics Destination Counts:" -ForegroundColor Yellow
        foreach ($la in $laCounts) {
            Write-Host "  $($la.Name): $($la.Count)"
        }
    }
}
End {
    Write-Host "`nAudit Complete." -ForegroundColor Cyan
}
