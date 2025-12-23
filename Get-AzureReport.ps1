<#
.SYNOPSIS
    Audits Azure Diagnostic Settings across all resources in one or ALL subscriptions.

.DESCRIPTION
    This script audits resources for Diagnostic Settings configuration. 
    It can target a specific subscription or automatically iterate through ALL accessible subscriptions.
    It captures details such as Log Analytics workspace, Storage Account, Event Hub, and enabled log categories.
    Results are exported to a single consolidated CSV file.

.PARAMETER SubscriptionId
    Optional. The ID of a specific subscription to audit. 
    If NOT provided, the script will audit ALL subscriptions accessible to the current user.

.PARAMETER ResourceGroupName
    Optional. audits only resources within the specified Resource Group (applies to all checked subscriptions).

.PARAMETER ResourceType
    Optional. Audits only resources of the specified type (e.g., 'Microsoft.Compute/virtualMachines').

.PARAMETER OutputPath
    Optional. The directory where the CSV report will be saved. Defaults to the current script directory.

.EXAMPLE
    .\Get-AzureReport.ps1
    Audits ALL subscriptions accessible to the user.

.EXAMPLE
    .\Get-AzureReport.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"
    Audits only the specified subscription.
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
        Get-AzContext -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Error "No Azure context found. Please run 'Connect-AzAccount' to login."
    }

    # Determine Target Subscriptions
    $targetSubscriptions = @()

    if (-not [string]::IsNullOrEmpty($SubscriptionId)) {
        # User specified a single subscription
        $sub = Get-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction Stop
        $targetSubscriptions += $sub
        Write-Host "Targeting specific subscription: $($sub.Name)" -ForegroundColor Green
    }
    else {
        # Audit ALL subscriptions
        Write-Host "No SubscriptionId provided. Retrieving ALL accessible subscriptions..." -ForegroundColor Cyan
        $targetSubscriptions = Get-AzSubscription
        Write-Host "Found $($targetSubscriptions.Count) subscriptions to audit." -ForegroundColor Green
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmm"
    $filenameSuffix = if ($targetSubscriptions.Count -eq 1) { $targetSubscriptions[0].Name -replace '[^a-zA-Z0-9]', '_' } else { "AllSubscriptions" }
    $csvFileName = "AzureDiagAudit_$($filenameSuffix)_$timestamp.csv"
    $fullCsvPath = Join-Path -Path $OutputPath -ChildPath $csvFileName
    
    $globalResults = [System.Collections.Generic.List[PSObject]]::new()
}

Process {
    $subCounter = 0
    
    foreach ($sub in $targetSubscriptions) {
        $subCounter++
        Write-Host "`n[$subCounter/$($targetSubscriptions.Count)] Processing Subscription: $($sub.Name) ($($sub.Id))" -ForegroundColor Magenta
        
        try {
            # Set Context
            Set-AzContext -SubscriptionId $sub.Id -Force | Out-Null
        }
        catch {
            Write-Warning "Failed to set context for subscription '$($sub.Name)'. Skipping... Error: $_"
            continue
        }

        # Retrieve Resources
        $params = @{}
        if ($ResourceGroupName) { $params['ResourceGroupName'] = $ResourceGroupName }
        if ($ResourceType) { $params['ResourceType'] = $ResourceType }

        try {
            Write-Host "  Retrieving resources..." -ForegroundColor Gray
            $resources = Get-AzResource @params
        }
        catch {
            Write-Warning "  Failed to retrieve resources for subscription '$($sub.Name)'. Error: $_"
            continue
        }

        $count = $resources.Count
        if ($count -eq 0) {
            Write-Host "  No resources found." -ForegroundColor DarkGray
            continue
        }
        Write-Host "  Found $count resources. Auditing..." -ForegroundColor Cyan

        # Audit Loop
        $resCounter = 0
        foreach ($res in $resources) {
            $resCounter++
            if ($resCounter % 10 -eq 0) {
                Write-Progress -Activity "Auditing Subscription: $($sub.Name)" -Status "Processing resource $resCounter of $count" -PercentComplete (($resCounter / $count) * 100)
            }

            
            
            try {
                $diagSettings = Get-AzDiagnosticSetting -ResourceId $res.ResourceId -ErrorAction SilentlyContinue
                
                if ($diagSettings) {
                    # One, row per diagnostic setting
                    foreach ($ds in $diagSettings) {


                        $laWorkspaceId = $null
                        $laWorkspaceName = $null
                        $storageId = $null
                        $eventHubId = $null
                        $enabledLogs = [System.Collections.Generic.List[string]]::new()

                        if ($ds.WorkspaceId) { 
                            $laWorkspaceId = $ds.WorkspaceId 
                            if ($laWorkspaceId -match "/workspaces/([^/]+)$") {
                                $laWorkspaceName = $matches[1]
                            }
                        }
                        if ($ds.StorageAccountId) { $storageId = $ds.StorageAccountId }
                        if ($ds.EventHubAuthorizationRuleId) { $eventHubId = $ds.EventHubAuthorizationRuleId }
                        
                        # Consolidate 'Logs' and 'Log' properties safely
                        $logCollection = @()
                        if ($ds.Logs) { $logCollection += $ds.Logs }
                        
                        # Check strictly for Log property to avoid errors if it missing
                        # Using Try-Catch for property access just in case, or relying on PS loose typing
                        try {
                            if ($ds.Log) { $logCollection += $ds.Log }
                        }
                        catch {}

                        if ($logCollection) {
                            foreach ($item in $logCollection) {
                                # Safe check for Enabled
                                if ($null -ne $item -and $item.Enabled -eq $true) {
                                    # Check Category
                                    if (-not [string]::IsNullOrEmpty($item.Category)) {
                                        $enabledLogs.Add($item.Category)
                                    }
                                    # Check CategoryGroup
                                    elseif (-not [string]::IsNullOrEmpty($item.CategoryGroup)) {
                                        $enabledLogs.Add("Group:$($item.CategoryGroup)")
                                    }
                                }
                            }
                        }

                        # Check Metrics
                        # Similar logic: check 'Metric' or 'Metrics' property
                        $metricCollection = @()
                        if ($ds.Metrics) { $metricCollection += $ds.Metrics }
                        try { if ($ds.Metric) { $metricCollection += $ds.Metric } } catch {}

                        if ($metricCollection) {
                            foreach ($m in $metricCollection) {
                                if ($null -ne $m -and $m.Enabled -eq $true) {
                                    $enabledLogs.Add("Metric:$($m.Category)")
                                }
                            }
                        }
                        
                        # Some resources might still use top-level 'CategoryGroups' property
                        if ($ds.CategoryGroups) {
                            foreach ($cg in $ds.CategoryGroups) {
                                if ($cg.Enabled) { $enabledLogs.Add("Group:$($cg.GroupName)") }
                            }
                        }

                        $obj = [PSCustomObject]@{
                            SubscriptionName     = $sub.Name
                            SubscriptionId       = $sub.Id
                            ResourceName         = $res.Name
                            ResourceType         = $res.ResourceType
                            ResourceGroup        = $res.ResourceGroupName
                            Location             = $res.Location
                            DiagnosticConfigured = "Yes"
                            SettingName          = $ds.Name
                            LogsEnabled          = if ($enabledLogs.Count -gt 0) { $enabledLogs -join "; " } else { "None" }
                            LAWorkspaceName      = $laWorkspaceName
                            LAWorkspaceId        = $laWorkspaceId
                            StorageAccount       = $storageId
                            EventHub             = $eventHubId
                        }
                        $globalResults.Add($obj)
                    }
                }
                else {
                    # No settings found
                    $obj = [PSCustomObject]@{
                        SubscriptionName     = $sub.Name
                        SubscriptionId       = $sub.Id
                        ResourceName         = $res.Name
                        ResourceType         = $res.ResourceType
                        ResourceGroup        = $res.ResourceGroupName
                        Location             = $res.Location
                        DiagnosticConfigured = "No"
                        SettingName          = $null
                        LogsEnabled          = $null
                        LAWorkspaceName      = $null
                        LAWorkspaceId        = $null
                        StorageAccount       = $null
                        EventHub             = $null
                    }
                    $globalResults.Add($obj)
                }
            }
            catch {
                # Quietly ignore individual resource failures to keep flow going
                Write-Warning "Failed to audit resource '$($res.Name)': $_"
            }
        }
        Write-Progress -Activity "Auditing Subscription: $($sub.Name)" -Completed
    }

    # Export
    if ($globalResults.Count -gt 0) {
        try {
            $globalResults | Export-Csv -Path $fullCsvPath -NoTypeInformation -Force
            Write-Host "`nSUCCESS: Audit completed. Results exported to: $fullCsvPath" -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to export CSV. Error: $_"
        }
    }
    else {
        Write-Warning "No resources were audited across any subscription."
    }

    # Summary Stats
    Write-Host "`nSummary Statistics (All Subscriptions)" -ForegroundColor Yellow
    Write-Host "--------------------------------------" -ForegroundColor Yellow
    Write-Host "Total Subscriptions Scanned  : $($targetSubscriptions.Count)"
    Write-Host "Total Resources Checked      : $($globalResults.Count)"
    
    $settingsYes = ($globalResults | Where-Object { $_.DiagnosticConfigured -eq "Yes" }).Count
    $settingsNo = ($globalResults.Count) - $settingsYes
    
    Write-Host "With Diagnostic Settings     : $settingsYes"
    Write-Host "Without Diagnostic Settings  : $settingsNo"
    
    $laCounts = $globalResults | Where-Object { $_.LAWorkspaceName } | Group-Object LAWorkspaceName
    if ($laCounts) {
        Write-Host "`nLog Analytics Destination Counts:" -ForegroundColor Yellow
        foreach ($la in $laCounts) {
            Write-Host "  $($la.Name): $($la.Count)"
        }
    }
}
End {
    Write-Host "`nScript Execution Finished." -ForegroundColor Cyan
}
