<#
.SYNOPSIS
    Collects vCPU quota availability for eastus and eastus2 across all Azure subscriptions
    and uploads a timestamped CSV to Azure Blob Storage.

.REQUIREMENTS
    Automation Account Modules: Az.Accounts, Az.Compute, Az.Storage
    Managed Identity Roles:
      - Reader on all Subscriptions (or Management Group)
      - Storage Blob Data Contributor on the target Storage Account
#>

param(
    [string]$StorageAccountName   = "yourstorageaccount",  # <-- UPDATE
    [string]$StorageResourceGroup = "your-rg-name",        # <-- UPDATE
    [string]$ContainerName        = "quota-reports",        # <-- UPDATE
    [string]$SubscriptionFilter   = ""  # Comma-separated sub IDs to limit scope; leave empty for ALL
)

# ──────────────────────────────────────────
# 1. Authenticate using Managed Identity
# ──────────────────────────────────────────
try {
    Write-Output "Authenticating with Managed Identity..."
    Connect-AzAccount -Identity | Out-Null
    Write-Output "Authentication successful."
} catch {
    throw "Failed to authenticate with Managed Identity: $_"
}

# ──────────────────────────────────────────
# 2. Hardcoded target regions (East US + East US 2 only)
# ──────────────────────────────────────────
$targetRegions = @("eastus", "eastus2")
Write-Output "Target regions: $($targetRegions -join ', ')"

# ──────────────────────────────────────────
# 3. Get all enabled subscriptions
# ──────────────────────────────────────────
Write-Output "Fetching subscriptions..."
$allSubscriptions = Get-AzSubscription -WarningAction SilentlyContinue | 
    Where-Object { $_.State -eq "Enabled" }

if ($SubscriptionFilter -ne "") {
    $filterList = $SubscriptionFilter -split "," | ForEach-Object { $_.Trim() }
    $allSubscriptions = $allSubscriptions | Where-Object { $filterList -contains $_.Id }
}

Write-Output "Total subscriptions to process: $($allSubscriptions.Count)"

# ──────────────────────────────────────────
# 4. Iterate subscriptions → regions → vCPU quotas
# ──────────────────────────────────────────
$quotaReport = [System.Collections.Generic.List[PSCustomObject]]::new()
$subIndex    = 0
$totalSubs   = $allSubscriptions.Count

foreach ($subscription in $allSubscriptions) {
    $subIndex++
    Write-Output "[$subIndex/$totalSubs] Processing: $($subscription.Name) ($($subscription.Id))"

    try {
        Set-AzContext -SubscriptionId $subscription.Id -WarningAction SilentlyContinue | Out-Null
    } catch {
        Write-Warning "  Could not set context for '$($subscription.Name)': $_"
        continue
    }

    foreach ($region in $targetRegions) {
        try {
            $usages = Get-AzVMUsage -Location $region -ErrorAction SilentlyContinue
            if (-not $usages) {
                Write-Warning "  No usage data returned for region '$region' in '$($subscription.Name)'"
                continue
            }

            foreach ($usage in $usages) {
                $currentValue = $usage.CurrentValue
                $limit        = $usage.Limit
                $available    = $limit - $currentValue
                $usedPercent  = if ($limit -gt 0) { [math]::Round(($currentValue / $limit) * 100, 2) } else { 0 }

                $quotaReport.Add([PSCustomObject]@{
                    SubscriptionId   = $subscription.Id
                    SubscriptionName = $subscription.Name
                    Region           = $region
                    QuotaName        = $usage.Name.LocalizedValue
                    QuotaNameCode    = $usage.Name.Value
                    CurrentUsage     = $currentValue
                    Limit            = $limit
                    Available        = $available
                    UsedPercent      = $usedPercent
                    IsNearLimit      = if ($usedPercent -ge 80) { "YES" } else { "NO" }
                    CollectedAt      = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                })
            }

        } catch {
            Write-Warning "  Skipped region '$region' in '$($subscription.Name)': $_"
        }
    }
}

Write-Output "Total quota records collected: $($quotaReport.Count)"

# ──────────────────────────────────────────
# 5. Export to CSV (temp path)
# ──────────────────────────────────────────
$timestamp   = Get-Date -Format "yyyyMMdd-HHmmss"
$csvFileName = "vCPU-Quota-EastUS-Report-$timestamp.csv"
$tempPath    = "$env:TEMP\$csvFileName"

$quotaReport | Export-Csv -Path $tempPath -NoTypeInformation -Encoding UTF8
Write-Output "CSV written to temp: $tempPath  |  Rows: $($quotaReport.Count)"

# ──────────────────────────────────────────
# 6. Upload CSV to Azure Blob Storage
# ──────────────────────────────────────────
Write-Output "Uploading to: $StorageAccountName / $ContainerName / $csvFileName"

try {
    # Managed Identity — no storage key or SAS needed
    $storageContext = New-AzStorageContext `
        -StorageAccountName $StorageAccountName `
        -UseConnectedAccount

    # Create container if it doesn't exist
    $containerExists = Get-AzStorageContainer -Name $ContainerName -Context $storageContext -ErrorAction SilentlyContinue
    if (-not $containerExists) {
        New-AzStorageContainer -Name $ContainerName -Context $storageContext -Permission Off | Out-Null
        Write-Output "Container '$ContainerName' created."
    }

    # Upload the CSV blob
    Set-AzStorageBlobContent `
        -File      $tempPath `
        -Container $ContainerName `
        -Blob      $csvFileName `
        -Context   $storageContext `
        -Force | Out-Null

    Write-Output "Upload successful: $csvFileName"

} catch {
    throw "Blob upload failed: $_"
} finally {
    if (Test-Path $tempPath) { Remove-Item $tempPath -Force }
    Write-Output "Temp file cleaned up."
}

Write-Output "Runbook completed. Blob: $StorageAccountName/$ContainerName/$csvFileName"
