<#
.SYNOPSIS
    Collects vCPU quota availability for eastus and eastus2 across all Azure subscriptions
    and uploads a timestamped CSV to Azure Blob Storage.

.REQUIREMENTS
    Automation Account Modules : Az.Accounts, Az.Compute, Az.Storage
    Managed Identity Roles     :
      - Reader on all Subscriptions (or Management Group)
      - Storage Blob Data Contributor on the target Storage Account

.NOTES
    Designed for Azure Automation Account (PowerShell 7.2 runtime).
    Uses Managed Identity — no credentials or secrets required.
#>

param(
    [string]$StorageAccountName    = "yourstorageaccount",   # <-- UPDATE
    [string]$StorageResourceGroup  = "your-rg-name",         # <-- UPDATE
    [string]$ContainerName         = "quota-reports",         # <-- UPDATE
    [string]$SubscriptionFilter    = "",    # Comma-separated sub IDs; empty = ALL
    [int]   $NearLimitThresholdPct = 80,    # Flag quotas at or above this % as near-limit
    [int]   $MaxRetries            = 3      # Retry attempts for transient API failures
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ──────────────────────────────────────────────────────────────
# Helper: timestamped logging
# ──────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output "[$ts][$Level] $Message"
}

# ──────────────────────────────────────────────────────────────
# Helper: retry wrapper for transient failures
# ──────────────────────────────────────────────────────────────
function Invoke-WithRetry {
    param(
        [scriptblock]$ScriptBlock,
        [string]      $OperationName = "Operation",
        [int]         $MaxAttempts   = $MaxRetries
    )

    $attempt = 0
    while ($attempt -lt $MaxAttempts) {
        $attempt++
        try {
            return & $ScriptBlock
        } catch {
            if ($attempt -ge $MaxAttempts) {
                Write-Log "$OperationName failed after $MaxAttempts attempts: $_" "ERROR"
                throw
            }
            $wait = [math]::Pow(2, $attempt)   # exponential back-off: 2s, 4s, 8s
            Write-Log "$OperationName attempt $attempt failed — retrying in ${wait}s..." "WARN"
            Start-Sleep -Seconds $wait
        }
    }
}

# ──────────────────────────────────────────────────────────────
# 1. Authenticate via Managed Identity
# ──────────────────────────────────────────────────────────────
Write-Log "Authenticating with Managed Identity..."
Invoke-WithRetry -OperationName "Connect-AzAccount" -ScriptBlock {
    Connect-AzAccount -Identity | Out-Null
}
Write-Log "Authentication successful."

# ──────────────────────────────────────────────────────────────
# 2. Target regions
# ──────────────────────────────────────────────────────────────
$targetRegions = @("eastus", "eastus2")
Write-Log "Target regions: $($targetRegions -join ', ')"

# ──────────────────────────────────────────────────────────────
# 3. Resolve subscriptions
# ──────────────────────────────────────────────────────────────
Write-Log "Fetching enabled subscriptions..."

$allSubscriptions = Invoke-WithRetry -OperationName "Get-AzSubscription" -ScriptBlock {
    Get-AzSubscription -WarningAction SilentlyContinue |
        Where-Object { $_.State -eq "Enabled" }
}

if ($SubscriptionFilter -ne "") {
    $filterList      = $SubscriptionFilter -split "," | ForEach-Object { $_.Trim() }
    $allSubscriptions = $allSubscriptions | Where-Object { $filterList -contains $_.Id }
    Write-Log "Subscription filter applied — matched: $($allSubscriptions.Count)"
}

if (-not $allSubscriptions -or $allSubscriptions.Count -eq 0) {
    throw "No enabled subscriptions found. Verify Managed Identity Reader permissions."
}

Write-Log "Subscriptions to process: $($allSubscriptions.Count)"

# ──────────────────────────────────────────────────────────────
# 4. Collect vCPU quotas (subscription → region)
# ──────────────────────────────────────────────────────────────
$quotaReport  = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()
$collectedAt  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$totalSubs    = $allSubscriptions.Count
$subIndex     = 0

foreach ($subscription in $allSubscriptions) {
    $subIndex++
    $subLabel = "$($subscription.Name) [$($subscription.Id)]"
    Write-Log "[$subIndex/$totalSubs] Processing subscription: $subLabel"

    # Set context once per subscription — not inside the region loop
    try {
        Set-AzContext -SubscriptionId $subscription.Id -WarningAction SilentlyContinue | Out-Null
    } catch {
        Write-Log "Could not set context for $subLabel — skipping. Error: $_" "WARN"
        continue
    }

    foreach ($region in $targetRegions) {
        Write-Log "  Querying quotas: $region"

        $usages = $null
        try {
            $usages = Invoke-WithRetry -OperationName "Get-AzVMUsage ($region)" -ScriptBlock {
                Get-AzVMUsage -Location $region -ErrorAction Stop
            }
        } catch {
            Write-Log "  Skipped region '$region' in '$($subscription.Name)': $_" "WARN"
            continue
        }

        if (-not $usages -or $usages.Count -eq 0) {
            Write-Log "  No usage data for '$region' in '$($subscription.Name)'" "WARN"
            continue
        }

        foreach ($usage in $usages) {
            $currentValue = $usage.CurrentValue
            $limit        = $usage.Limit
            $available    = $limit - $currentValue
            $usedPercent  = if ($limit -gt 0) {
                [math]::Round(($currentValue / $limit) * 100, 2)
            } else { 0 }

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
                IsNearLimit      = if ($usedPercent -ge $NearLimitThresholdPct) { "YES" } else { "NO" }
                CollectedAt      = $collectedAt
            })
        }

        Write-Log "  Region '$region' — $($usages.Count) quota entries collected."
    }
}

Write-Log "Total quota records collected: $($quotaReport.Count)"

if ($quotaReport.Count -eq 0) {
    throw "No quota records were collected. Check permissions and region availability."
}

# ──────────────────────────────────────────────────────────────
# 5. Export to CSV
# ──────────────────────────────────────────────────────────────
$timestamp   = Get-Date -Format "yyyyMMdd-HHmmss"
$csvFileName = "vCPU-Quota-EastUS-$timestamp.csv"
$tempPath    = Join-Path $env:TEMP $csvFileName

try {
    $quotaReport |
        Sort-Object SubscriptionName, Region, QuotaName |
        Export-Csv -Path $tempPath -NoTypeInformation -Encoding UTF8

    Write-Log "CSV written to temp path: $tempPath  |  Rows: $($quotaReport.Count)"
} catch {
    throw "Failed to write CSV: $_"
}

# ──────────────────────────────────────────────────────────────
# 6. Upload to Azure Blob Storage
# ──────────────────────────────────────────────────────────────
Write-Log "Uploading blob: $StorageAccountName/$ContainerName/$csvFileName"

try {
    $storageContext = Invoke-WithRetry -OperationName "New-AzStorageContext" -ScriptBlock {
        New-AzStorageContext `
            -StorageAccountName $StorageAccountName `
            -UseConnectedAccount   # Managed Identity — no key/SAS needed
    }

    # Create container if absent
    $containerExists = Get-AzStorageContainer `
        -Name    $ContainerName `
        -Context $storageContext `
        -ErrorAction SilentlyContinue

    if (-not $containerExists) {
        New-AzStorageContainer `
            -Name       $ContainerName `
            -Context    $storageContext `
            -Permission Off | Out-Null
        Write-Log "Container '$ContainerName' created (private)."
    }

    Invoke-WithRetry -OperationName "Set-AzStorageBlobContent" -ScriptBlock {
        Set-AzStorageBlobContent `
            -File      $tempPath `
            -Container $ContainerName `
            -Blob      $csvFileName `
            -Context   $storageContext `
            -Force | Out-Null
    }

    Write-Log "Upload successful: $csvFileName"

} catch {
    throw "Blob upload failed: $_"
} finally {
    if (Test-Path $tempPath) {
        Remove-Item $tempPath -Force
        Write-Log "Temp file cleaned up."
    }
}

Write-Log "Runbook completed. Report: $StorageAccountName/$ContainerName/$csvFileName"
