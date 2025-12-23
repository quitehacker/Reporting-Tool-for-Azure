# Azure Diagnostic Settings Audit Tool

This repository contains a PowerShell script `Get-AzureReport.ps1` designed to audit Diagnostic Settings across all resources in an Azure Subscription.

## Features

- **Resource Discovery**: Scans all resources in the current or specified subscription.
- **Audit Checks**: Determines if Diagnostic settings are enabled for each resource.
- **Detailed Output**: Captures Log Analytics Workspace, Storage Account, Event Hub details, and enabled Log Categories.
- **CSV Export**: Automatically exports all findings to a timestamped CSV file for easy reporting.
- **Summary Statistics**: Displays a quick summary of enabled/disabled resources and workspace usage in the console.

## Prerequisites

- **PowerShell 5.1** or newer (PowerShell 7+ recommended).
- **Azure PowerShell Module** (`Az`).
  - Install via: `Install-Module -Name Az -AllowClobber -Scope CurrentUser`
- **Azure Login**: You must be authenticated to Azure.
  - Run: `Connect-AzAccount`

## Required Permissions

To run this script effectively, the logged-in user requires **Read** access to the target resources. 

- **Reader**: Sufficient to listing resources and viewing diagnostic settings.
- **Monitoring Reader**: Also allows viewing of diagnostic settings and metrics.

If you are auditing a specific Resource Group, you only need permissions on that Resource Group. For a full Subscription audit, you need permissions at the Subscription scope.

## Usage

### 1. Audit ALL Subscriptions (Default)
This is the default behavior. The script will iterate through every subscription you have access to.
```powershell
.\Get-AzureReport.ps1
```

### 2. Audit Specific Subscription
Limit the audit to a single specific subscription.
```powershell
.\Get-AzureReport.ps1 -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

### 3. Audit Specific Resource Group
Limit the audit to a specific resource group (will check for this RG in all subscriptions, or the specific one if provided).
```powershell
.\Get-AzureReport.ps1 -ResourceGroupName "rg-production-01"
```

### 4. Filter by Resource Type
Audit only specific resources, such as Virtual Machines.
```powershell
.\Get-AzureReport.ps1 -ResourceType "Microsoft.Compute/virtualMachines"
```

### 5. Custom Output Path
Save the CSV report to a specific folder.
```powershell
.\Get-AzureReport.ps1 -OutputPath "C:\Reports\Azure"
```

## Output CSV Columns

| Column | Description |
|--------|-------------|
| ResourceName | Name of the Azure Resource |
| ResourceType | Type of the resource (e.g., Microsoft.Web/sites) |
| ResourceGroup | Resource Group name |
| Location | Azure Region |
| DiagnosticConfigured | "Yes" if settings exist, "No" otherwise |
| SettingName | Name of the specific diagnostic setting (useful if multiple exist) |
| LogsEnabled | List of enabled logs and metrics (e.g., `Administrative; Group:allLogs; Metric:AllMetrics`) |
| LAWorkspaceName | Name of the destination Log Analytics Workspace (derived from ID) |
| LAWorkspaceId | Resource ID of the Log Analytics Workspace |
| StorageAccount | Resource ID of the destination Storage Account |
| EventHub | Resource ID of the destination Event Hub |

## Troubleshooting

- **"No Azure context found"**: Ensure you have run `Connect-AzAccount`.
- **"Failed to retrieve resources"**: Check your permissions on the subscription (Reader role is required at minimum).
- **Script runs slowly**: The script processes resources sequentially. For large subscriptions (1000+ resources), this may take some time.
