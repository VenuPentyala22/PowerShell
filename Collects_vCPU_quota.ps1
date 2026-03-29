<#
.SYNOPSIS
    Collects vCPU quota availability across all Azure subscriptions
    and uploads a timestamped CSV to Azure Blob Storage.

.REQUIREMENTS
    Automation Account Modules: Az.Accounts, Az.Compute, Az.Storage
    Managed Identity Roles:
      - Reader on all Subscriptions (or Management Group)
      - Storage Blob Data Contributor on the target Storage Account
#>

param(
    [string]$StorageAccountName  = "yourstorageaccount",   # <-- UPDATE
    [string]$StorageResourceGroup = "your-rg-name",        # <-- UPDATE
    [string]$ContainerName       = "quota-reports",         # <-- UPDATE
    [string]$SubscriptionFilter  = ""  # Comma-separated sub IDs to limit scope; leave empty for ALL
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
# 2. Get target subscriptions
# ──────────────────────────────────────────
Write-Output "Fetching subscriptions..."
$allSubscriptions = Get-AzSubscription -WarningAction SilentlyContinue | Where-Object { $_.State -eq "Enabled" }

if ($SubscriptionFilter -ne "") {
    $filterList = $SubscriptionFilter -split "," | ForEach-Object { $_.Trim() }
    $allSubscriptions = $allSubscriptions | Where-Object { $filterList -contains $_.Id }
}

Write-Output "Total subscriptions to process: $($allSubscriptions.Count)"

# ──────────────────────────────────────────
# 3. Get available Azure regions for vCPU usage API
# ──────────────────────────────────────────
# Use first subscription to enumerate available regions
Set-AzContext -SubscriptionId $allSubscriptions[0].Id -WarningAction SilentlyContinue | Out-Null
$computeProvider = Get-AzResourceProvider -ProviderNamespace Microsoft.Compute | 
    Where-Object { $_.ResourceTypes.ResourceTypeName -eq "locations/usages" }
$availableLocations = $computeProvider.Locations
Write-Output "Scanning $($availableLocations.Count) regions per subscription."

# ──────────────────────────────────────────
# 4. Iterate subscriptions and collect vCPU quota data
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
        Write-Warning "Could not set context for $($subscription.Name): $_"
        continue
    }

    foreach ($location in $availableLocations) {
        try {
            $usages = Get-AzVMUsage -Location $location -ErrorAction SilentlyContinue
            if (-not $usages) { continue }

            foreach ($usage in $usages) {
                $currentValue = $usage.CurrentValue
                $limit        = $usage.Limit
                $available    = $limit - $currentValue
                $usedPercent  = if ($limit -gt 0) { [math]::Round(($currentValue / $limit) * 100, 2) } else { 0 }

                $quotaReport.Add([PSCustomObject]@{
                    SubscriptionId   = $subscription.Id
                    SubscriptionName = $subscription.Name
                    Region           = $location
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
            Write-Warning "  Skipped region '$location' in '$($subscription.Name)': $_"
        }
    }
}

Write-Output "Total quota records collected: $($quotaReport.Count)"

# ──────────────────────────────────────────
# 5. Export to CSV (in-memory temp path)
# ──────────────────────────────────────────
$timestamp  = Get-Date -Format "yyyyMMdd-HHmmss"
$csvFileName = "vCPU-Quota-Report-$timestamp.csv"
$tempPath    = "$env:TEMP\$csvFileName"

$quotaReport | Export-Csv -Path $tempPath -NoTypeInformation -Encoding UTF8
Write-Output "CSV exported to temp path: $tempPath"

# ──────────────────────────────────────────
# 6. Upload CSV to Azure Blob Storage
# ──────────────────────────────────────────
Write-Output "Uploading CSV to Storage Account: $StorageAccountName / Container: $ContainerName"

try {
    # Use Managed Identity — no storage key required
    $storageContext = New-AzStorageContext `
        -StorageAccountName $StorageAccountName `
        -UseConnectedAccount

    # Ensure container exists
    $container = Get-AzStorageContainer -Name $ContainerName -Context $storageContext -ErrorAction SilentlyContinue
    if (-not $container) {
        New-AzStorageContainer -Name $ContainerName -Context $storageContext -Permission Off | Out-Null
        Write-Output "Created container: $ContainerName"
    }

    # Upload blob (overwrite if exists)
    Set-AzStorageBlobContent `
        -File      $tempPath `
        -Container $ContainerName `
        -Blob      $csvFileName `
        -Context   $storageContext `
        -Force | Out-Null

    Write-Output "Successfully uploaded: $csvFileName to $StorageAccountName/$ContainerName"

} catch {
    throw "Failed to upload CSV to Blob Storage: $_"
} finally {
    # Clean up temp file
    if (Test-Path $tempPath) { Remove-Item $tempPath -Force }
}

Write-Output "Runbook completed successfully. File: $csvFileName"
