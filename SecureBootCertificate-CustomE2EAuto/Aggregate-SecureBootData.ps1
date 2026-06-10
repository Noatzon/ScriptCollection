<#
.SYNOPSIS
    Aggregates Secure Boot status JSON data from multiple devices into summary reports.

.DESCRIPTION
    Reads collected Secure Boot status JSON files and generates:
    - HTML Dashboard with charts and filtering
    - Summary by ConfidenceLevel
    - Unique device bucket analysis for testing strategy
    
    Supports:
    - Per-machine files: HOSTNAME_latest.json (recommended)
    - Single JSON file
    
    Automatically deduplicates by HostName, keeping latest CollectionTime.
    
    By default, only includes devices with "Action Req" or "High" confidence
    to focus on actionable buckets. Use -IncludeAllConfidenceLevels to override.

.PARAMETER InputPath
    Path to JSON file(s):
    - Folder: Reads all *_latest.json files (or *.json if no _latest files)
    - File: Reads single JSON file

.PARAMETER OutputPath
    Path for generated reports (default: .\SecureBootReports)

.EXAMPLE
    # Aggregate from folder of per-machine files (recommended)
    .\Aggregate-SecureBootData.ps1 -InputPath "\\contoso\SecureBootLogs$"
    # Reads: \\contoso\SecureBootLogs$\*_latest.json

.EXAMPLE
    # Custom output location
    .\Aggregate-SecureBootData.ps1 -InputPath "\\contoso\SecureBootLogs$" -OutputPath "C:\Reports\SecureBoot"

.EXAMPLE
    # Include only Action Req and High confidence (default behavior)
    .\Aggregate-SecureBootData.ps1 -InputPath "\\contoso\SecureBootLogs$"
    # Excludes: Observation, Paused, Not Supported

.EXAMPLE
    # Include all confidence levels (override filter)
    .\Aggregate-SecureBootData.ps1 -InputPath "\\contoso\SecureBootLogs$" -IncludeAllConfidenceLevels

.EXAMPLE
    # Custom confidence level filter
    .\Aggregate-SecureBootData.ps1 -InputPath "\\contoso\SecureBootLogs$" -IncludeConfidenceLevels @("Action Req", "High", "Observation")

.EXAMPLE
    # ENTERPRISE SCALE: Incremental mode - only process changed files (fast subsequent runs)
    .\Aggregate-SecureBootData.ps1 -InputPath "\\contoso\SecureBootLogs$" -IncrementalMode
    # First run: Full load ~2 hours for 500K devices
    # Subsequent runs: Seconds if no changes, minutes for deltas

.EXAMPLE
    # Skip HTML if nothing changed (fastest for monitoring)
    .\Aggregate-SecureBootData.ps1 -InputPath "\\contoso\SecureBootLogs$" -IncrementalMode -SkipReportIfUnchanged
    # If no files changed since last run: ~5 seconds

.EXAMPLE
    # Summary only mode - skip large device tables (1-2 minutes vs 20+ minutes)
    .\Aggregate-SecureBootData.ps1 -InputPath "\\contoso\SecureBootLogs$" -SummaryOnly
    # Generates CSVs but skips HTML dashboard with full device tables

.NOTES
    Pair with Detect-SecureBootCertUpdateStatus.ps1 for enterprise deployment.
    See GPO-DEPLOYMENT-GUIDE.md for full deployment guide.
    
    Default behavior excludes Observation, Paused, and Not Supported devices
    to focus reporting on actionable device buckets only.
#>

param(
    [Parameter(Mandatory = $false)] # Where to find _latest.json
    [string]$InputPath,
    
    [Parameter(Mandatory = $false)] # Where to save the results og aggregation
    [string]$OutputPath,
    
    [Parameter(Mandatory = $false)] # Path to save logs
    [string]$LogPath, 
    
    [Parameter(Mandatory = $false)]
    [string]$ScanHistoryPath,
    
    [Parameter(Mandatory = $false)] # Path to RolloutState.json to identify InProgress devices
    [string]$RolloutStatePath,
    
    [Parameter(Mandatory = $false)] # Path to SecureBootRolloutSummary.json from Orchestrator (contains projection data)
    [string]$RolloutSummaryPath,  
    
    [Parameter(Mandatory = $false)]
    [string[]]$IncludeConfidenceLevels = @("Action Required", "High Confidence"),  # Only include these confidence levels (default: actionable buckets only)
    
    [Parameter(Mandatory = $false)] # Override filter to include all confidence levels
    [switch]$IncludeAllConfidenceLevels,  
    
    [Parameter(Mandatory = $false)]
    [switch]$SkipHistoryTracking,
    
    [Parameter(Mandatory = $false)]
    [switch]$IncrementalMode,  # Enable delta processing - only load changed files since last run
    
    [Parameter(Mandatory = $false)]
    [string]$CachePath,  # Path to cache directory (default: OutputPath\.cache)
    
    [Parameter(Mandatory = $false)]
    [int]$ParallelThreads = 8,  # Number of parallel threads for file loading (PS7+)
    
    [Parameter(Mandatory = $false)]
    [switch]$ForceFullRefresh,  # Force full reload even in incremental mode
    
    [Parameter(Mandatory = $false)]
    [switch]$SkipReportIfUnchanged,  # Skip HTML/CSV generation if no files changed (just output stats)
    
    [Parameter(Mandatory = $false)]
    [switch]$SummaryOnly,  # Generate summary stats only (no large device tables) - much faster
    
    [Parameter(Mandatory = $false)]
    [switch]$StreamingMode  # Memory-efficient mode: process chunks, write CSVs incrementally, keep only summaries in memory
)

# Get the full path to the script
 $ScriptPath = $ScriptInvocation.MyCommand.Path

# Self-repair: Strip invisible Unicode characters injected by web CMS when copy-pasting from HTML articles.
# The support.microsoft.com CMS injects Zero Width Spaces (U+200B), Non-Breaking Spaces (U+00A0), and other
# invisible characters around </script></body></html> tags inside here-strings, causing PowerShell parse errors.
if ($ScriptPath) {
    $rawScript = [System.IO.File]::ReadAllText($MyInvocation.MyCommand.Path)
    if ($rawScript -match '[\u200B-\u200F\uFEFF]' -or $rawScript -match '\xA0') {
        Write-Log "WARNING: Invisible Unicode characters detected (likely from web copy-paste) - auto-cleaning script..." -ForegroundColor Yellow
        $cleaned = $rawScript -replace '[\u200B-\u200F\uFEFF]', ''
        $cleaned = $cleaned -replace '\xA0', ' '
        [System.IO.File]::WriteAllText($MyInvocation.MyCommand.Path, $cleaned, [System.Text.UTF8Encoding]::new($false))
        Write-Log "Script cleaned successfully. Re-launching..." -ForegroundColor Green
        & $MyInvocation.MyCommand.Path @PSBoundParameters
        exit $LASTEXITCODE
    }
} 

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "OK"      { "Green" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "BLOCKED" { "DarkRed" }
        "WAVE"    { "Cyan" }
        default   { "White" }
    }
    
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
    
    # Also log to file
    $logFile = Join-Path $LogPath "Aggregation_$(Get-Date -Format 'yyyyMMdd').log"
    "[$timestamp] [$Level] $Message" | Out-File $logFile -Append -Encoding UTF8
}

# Auto-elevate to PowerShell 7 if available (6x faster for large datasets)
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwshPath = Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
    if ($pwshPath) {
        Write-Log "PowerShell $($PSVersionTable.PSVersion) detected - re-launching with PowerShell 7 for faster processing..." -ForegroundColor Yellow
        # Rebuild argument list from bound parameters
        $relaunchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MyInvocation.MyCommand.Path)
        foreach ($key in $PSBoundParameters.Keys) {
            $val = $PSBoundParameters[$key]
            if ($val -is [switch]) {
                if ($val.IsPresent) { $relaunchArgs += "-$key" }
            } elseif ($val -is [array]) {
                $relaunchArgs += "-$key"
                $relaunchArgs += ($val -join ',')
            } else {
                $relaunchArgs += "-$key"
                $relaunchArgs += """$val"""
            }
        }
        & $pwshPath @relaunchArgs
        exit $LASTEXITCODE
    }
}

$ErrorActionPreference = "Continue"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$scanTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

#region Setup
Write-Log ("=" * 60) -ForegroundColor Cyan
Write-Log "Secure Boot Data Aggregation" -ForegroundColor Cyan
Write-Log ("=" * 60) -ForegroundColor Cyan

# Create output directory
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# Load data - supports CSV (legacy) and JSON (native) formats
Write-Log "`nLoading data from: $InputPath" -ForegroundColor Yellow

# Helper function to normalize device object (handle field name differences)
function Normalize-DeviceRecord {
    param($device)
    
    # Handle Hostname vs HostName (JSON uses Hostname, CSV uses HostName)
    if ($device.PSObject.Properties['Hostname'] -and -not $device.PSObject.Properties['HostName']) {
        $device | Add-Member -NotePropertyName 'HostName' -NotePropertyValue $device.Hostname -Force
    }
    
    # Handle Confidence vs ConfidenceLevel (JSON uses Confidence, CSV uses ConfidenceLevel)
    # ConfidenceLevel is the official field name - map Confidence to it
    if ($device.PSObject.Properties['Confidence'] -and -not $device.PSObject.Properties['ConfidenceLevel']) {
        $device | Add-Member -NotePropertyName 'ConfidenceLevel' -NotePropertyValue $device.Confidence -Force
    }
    
    # Track update status via Event1808Count OR UEFICA2023Status="Updated"
    # This allows tracking how many devices in each confidence bucket have been updated
    $event1808 = 0
    if ($device.PSObject.Properties['Event1808Count']) {
        $event1808 = [int]$device.Event1808Count
    }
    $uefiCaUpdated = $false
    if ($device.PSObject.Properties['UEFICA2023Status'] -and $device.UEFICA2023Status -eq "Updated") {
        $uefiCaUpdated = $true
    }

    # Map UEFI errorcode to semantic category
    $uefiErrorCategory = "None"
    if ($device.PSObject.Properties['UEFICA2023Error']) {
        $err = $device.UEFICA2023Error
        if (-not [string]::IsNullOrEmpty($err) -and $err -ne "0") {
            try {
                switch ([long]$err) {
                    2147942750 { $uefiErrorCategory = "NeedsReboot" }
                    2147500037 { $uefiErrorCategory = "FirmwareError" }
                    2147946825 { $uefiErrorCategory = "PrerequisiteFailure" }
                    2147942402 { $uefiErrorCategory = "Pending" }
                    default    { $uefiErrorCategory = "Unknown" }
                }
            } catch {
                $uefiErrorCategory = "Unknown"
            }
        }
    }

    $device | Add-Member -NotePropertyName 'UEFIErrorCategory' -NotePropertyValue $uefiErrorCategory -Force
    
    if ($event1808 -gt 0 -or $uefiCaUpdated) {
        # Mark as updated for dashboard/rollout logic - but DON'T override ConfidenceLevel
        $device | Add-Member -NotePropertyName 'IsUpdated' -NotePropertyValue $true -Force
    } else {
        $device | Add-Member -NotePropertyName 'IsUpdated' -NotePropertyValue $false -Force
        
        # ConfidenceLevel classification:
        # - "High Confidence", "Under Observation...", "Temporarily Paused...", "Not Supported..." = use as-is
        # - Everything else (null, empty, "UpdateType:...", "Unknown", "N/A") = falls to Action Required in counters
        # No normalization needed — the streaming counter's else branch handles it
    }
    
    # Handle OEMManufacturerName vs WMI_Manufacturer (JSON uses OEM*, legacy uses WMI_*)
    if ($device.PSObject.Properties['OEMManufacturerName'] -and -not $device.PSObject.Properties['WMI_Manufacturer']) {
        $device | Add-Member -NotePropertyName 'WMI_Manufacturer' -NotePropertyValue $device.OEMManufacturerName -Force
    }
    
    # Handle OEMModelNumber vs WMI_Model
    if ($device.PSObject.Properties['OEMModelNumber'] -and -not $device.PSObject.Properties['WMI_Model']) {
        $device | Add-Member -NotePropertyName 'WMI_Model' -NotePropertyValue $device.OEMModelNumber -Force
    }
    
    # Handle FirmwareVersion vs BIOSDescription
    if ($device.PSObject.Properties['FirmwareVersion'] -and -not $device.PSObject.Properties['BIOSDescription']) {
        $device | Add-Member -NotePropertyName 'BIOSDescription' -NotePropertyValue $device.FirmwareVersion -Force
    }

    # --- Wave execution fields ---
    if (-not $device.PSObject.Properties['InWave']) {
        $device | Add-Member -NotePropertyName 'InWave' -NotePropertyValue $false -Force
    }
    else {
        $device.InWave = [bool]$device.InWave
    }

    if (-not $device.PSObject.Properties['WaveManifestSeen'] -or -not $device.WaveManifestSeen) {
        $device | Add-Member -NotePropertyName 'WaveManifestSeen' -NotePropertyValue $null -Force
    }

    # --- Ensure WinCS fields are usable downstream ---

    if (-not $device.PSObject.Properties['WinCSKeyApplied']) {
        $device | Add-Member -NotePropertyName 'WinCSKeyApplied' -NotePropertyValue $false -Force
    }
    else {
        $device.WinCSKeyApplied = [bool]$device.WinCSKeyApplied
    }

    if (-not $device.PSObject.Properties['WinCSKeyStatus']) {
        $device | Add-Member -NotePropertyName 'WinCSKeyStatus' -NotePropertyValue "Unknown" -Force
    }

    return $device
}

#region Incremental Processing / Cache Management
# Setup cache paths
if (-not $CachePath) {
    $CachePath = Join-Path $OutputPath ".cache"
}
# Unrelated to the one being used by Wave creation/monitoring!
$manifestPath = Join-Path $CachePath "FileManifest.json"
$deviceCachePath = Join-Path $CachePath "DeviceCache.json"

# Cache management functions
function Get-FileManifest {
    param([string]$Path)
    if (Test-Path $Path) {
        try {
            $json = Get-Content $Path -Raw | ConvertFrom-Json
            # Convert PSObject to hashtable (PS5.1 compatible - PS7 has -AsHashtable)
            $ht = @{}
            $json.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
            return $ht
        } catch {
            return @{}
        }
    }
    return @{}
}

function Save-FileManifest {
    param([hashtable]$Manifest, [string]$Path)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $Manifest | ConvertTo-Json -Depth 3 -Compress | Set-Content $Path -Force
}

# Ultra-fast parallel file loading using batched processing
function Load-FilesParallel {
    param(
        [System.IO.FileInfo[]]$Files,
        [int]$Threads = 8
    )

    $totalFiles = $Files.Count
    
    # Use batches of ~1000 files each for better memory control
    $batchSize = [math]::Min(1000, [math]::Ceiling($totalFiles / [math]::Max(1, $Threads)))
    $batches = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $totalFiles; $i += $batchSize) {
        $end = [math]::Min($i + $batchSize, $totalFiles)
        $batch = $Files[$i..($end-1)]
        $batches.Add($batch)
    }
    
    Write-Log " ($($batches.Count) batches of ~$batchSize files each)" -NoNewline -ForegroundColor DarkGray
    
    $flatResults = [System.Collections.Generic.List[object]]::new()
    
    # Check if PowerShell 7+ parallel is available
    $canParallel = $PSVersionTable.PSVersion.Major -ge 7
    
    if ($canParallel -and $Threads -gt 1) {
        # PS7+: Process batches in parallel
        $results = $batches | ForEach-Object -ThrottleLimit $Threads -Parallel {
            $batchFiles = $_
            $batchResults = [System.Collections.Generic.List[object]]::new()
            foreach ($file in $batchFiles) {
                try {
                    $content = [System.IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
                    $batchResults.Add($content)
                } catch { }
            }
            $batchResults.ToArray()
        }
        foreach ($batch in $results) {
            if ($batch) { foreach ($item in $batch) { $flatResults.Add($item) } }
        }
    } else {
        # PS5.1 fallback: Sequential processing (still fast for <10K files)
        foreach ($file in $Files) {
            try {
                $content = [System.IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
                $flatResults.Add($content)
            } catch { }
        }
    }
    
    return $flatResults.ToArray()
}
#endregion

$allDevices = @()
if (Test-Path $InputPath -PathType Leaf) {
    # Single JSON file
    if ($InputPath -like "*.json") {
        $jsonContent = Get-Content -Path $InputPath -Raw | ConvertFrom-Json
        $allDevices = @($jsonContent) | ForEach-Object { Normalize-DeviceRecord $_ }
        Write-Log "Loaded $($allDevices.Count) records from file"
    } else {
        Write-Error "Only JSON format is supported. File must have .json extension."
        exit 1
    }
} elseif (Test-Path $InputPath -PathType Container) {
    # Folder - JSON only
    $jsonFiles = @(Get-ChildItem -Path $InputPath -Filter "*.json" -Recurse -ErrorAction SilentlyContinue | 
                   Where-Object { $_.Name -notmatch "ScanHistory|RolloutState|RolloutPlan" })
    
    # Prefer *_latest.json files if they exist (per-machine mode)
    $latestJson = $jsonFiles | Where-Object { $_.Name -like "*_latest.json" }
    if ($latestJson.Count -gt 0) { $jsonFiles = $latestJson }
    
    $totalFiles = $jsonFiles.Count
    
    if ($totalFiles -eq 0) {
        Write-Error "No JSON files found in: $InputPath"
        exit 1
    }
    
    Write-Log "Found $totalFiles JSON files" -ForegroundColor Gray
    
    # Helper function to match confidence levels (handles both short and full forms)
    # Defined early so both StreamingMode and delta paths can use it. You can remove this section and the relevant tweaks made further down if you don't want UEFICA codes to also influence state/categorisation
    function Test-ConfidenceLevel {
        param([string]$Value, [string]$Match)
        if ([string]::IsNullOrEmpty($Value)) { return $false }
        switch ($Match) {
            "HighConfidence"     { return $Value -eq "High Confidence" }
            "UnderObservation"   { return $Value -like "Under Observation*" }
            "ActionRequired"     { return ($Value -like "*Action Required*" -or $Value -eq "Action Required") }
            "TemporarilyPaused"  { return $Value -like "Temporarily Paused*" }
            "NotSupported"       { return ($Value -like "Not Supported*" -or $Value -eq "Not Supported") }
            default              { return $false }
        }
    }
    
    #region STREAMING MODE - Memory-efficient processing for large datasets
    # Always use StreamingMode for memory-efficient processing and new-style dashboard
    if (-not $StreamingMode) {
        Write-Log "Auto-enabling StreamingMode (new-style dashboard)" -ForegroundColor Yellow
        $StreamingMode = $true
        if (-not $IncrementalMode) { $IncrementalMode = $true }
    }
    
    # When -StreamingMode is enabled, process files in chunks keeping only counters in memory.
    # Device-level data is written to JSON files per-chunk for on-demand loading in the dashboard.
    # Memory usage: ~1.5 GB regardless of dataset size (vs 10-20 GB without streaming).
    if ($StreamingMode) {
        Write-Log "STREAMING MODE enabled - memory-efficient processing" -ForegroundColor Green
        $streamSw = [System.Diagnostics.Stopwatch]::StartNew()
        
        # INCREMENTAL CHECK: If no files changed since last run, skip processing entirely
        if ($IncrementalMode -and -not $ForceFullRefresh) {
            $stManifestDir = Join-Path $OutputPath ".cache"
            $stManifestPath = Join-Path $stManifestDir "StreamingManifest.json"
            if (Test-Path $stManifestPath) {
                Write-Log "Checking for changes since last streaming run..." -ForegroundColor Cyan
                $stOldManifest = Get-FileManifest -Path $stManifestPath
                if ($stOldManifest.Count -gt 0) {
                    $stChanged = $false
                    # Quick check: same file count?
                    if ($stOldManifest.Count -eq $totalFiles) {
                        # Check the 100 NEWEST files (sorted by LastWriteTime descending)
                        # If any file changed, it will have the most recent timestamp and appear first
                        $sampleSize = [math]::Min(100, $totalFiles)
                        $sampleFiles = $jsonFiles | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First $sampleSize
                        foreach ($sf in $sampleFiles) {
                            $sfKey = $sf.FullName.ToLowerInvariant()
                            if (-not $stOldManifest.ContainsKey($sfKey)) {
                                $stChanged = $true
                                break
                            }
                            # Compare timestamps - cached may be DateTime or string after JSON roundtrip
                            $cachedLWT = $stOldManifest[$sfKey].LastWriteTimeUtc
                            $fileDT = $sf.LastWriteTimeUtc
                            try {
                                # If cached is already DateTime (ConvertFrom-Json auto-converts), use directly
                                if ($cachedLWT -is [DateTime]) {
                                    $cachedDT = $cachedLWT.ToUniversalTime()
                                } else {
                                    $cachedDT = [DateTimeOffset]::Parse("$cachedLWT").UtcDateTime
                                }
                                if ([math]::Abs(($cachedDT - $fileDT).TotalSeconds) -gt 1) {
                                    $stChanged = $true
                                    break
                                }
                            } catch {
                                $stChanged = $true
                                break
                            }
                        }
                    } else {
                        $stChanged = $true
                    }
                    
                    if (-not $stChanged) {
                        # Check if output files exist
                        $stSummaryExists = Get-ChildItem (Join-Path $OutputPath "SecureBoot_Summary_*.csv") -EA SilentlyContinue | Select-Object -First 1
                        $stDashExists = Get-ChildItem (Join-Path $OutputPath "SecureBoot_Dashboard_*.html") -EA SilentlyContinue | Select-Object -First 1
                        if ($stSummaryExists -and $stDashExists) {
                            Write-Log "   No changes detected ($totalFiles files unchanged) - skipping processing" -ForegroundColor Green
                            Write-Log "   Last dashboard: $($stDashExists.FullName)" -ForegroundColor White
                            $cachedStats = Get-Content $stSummaryExists.FullName | ConvertFrom-Csv
                            Write-Log "   Devices: $($cachedStats.TotalDevices) | Updated: $($cachedStats.Updated) | Errors: $($cachedStats.WithErrors)" -ForegroundColor Gray
                            Write-Log "   Completed in $([math]::Round($streamSw.Elapsed.TotalSeconds, 1))s (no processing needed)" -ForegroundColor Green
                            return $cachedStats
                        }
                    } else {
                        # ==================================================
                        # DELTA PATCH: Find exactly which files changed
                        # ==================================================

                        Write-Log "   Changes detected - identifying changed files..." -ForegroundColor Yellow
                        $changedFiles = [System.Collections.ArrayList]::new()
                        $newFiles = [System.Collections.ArrayList]::new()
                        foreach ($jf in $jsonFiles) {
                            $jfKey = $jf.FullName.ToLowerInvariant()
                            if (-not $stOldManifest.ContainsKey($jfKey)) {
                                [void]$newFiles.Add($jf)
                            } else {
                                $cachedLWT = $stOldManifest[$jfKey].LastWriteTimeUtc
                                $fileDT = $jf.LastWriteTimeUtc
                                try {
                                    $cachedDT = if ($cachedLWT -is [DateTime]) { $cachedLWT.ToUniversalTime() } else { [DateTimeOffset]::Parse("$cachedLWT").UtcDateTime }
                                    if ([math]::Abs(($cachedDT - $fileDT).TotalSeconds) -gt 1) { [void]$changedFiles.Add($jf) }
                                } catch { [void]$changedFiles.Add($jf) }
                            }
                        }
                        $totalChanged = $changedFiles.Count + $newFiles.Count
                        $changePct = [math]::Round(($totalChanged / $totalFiles) * 100, 1)
                        Write-Log "   Changed: $($changedFiles.Count) | New: $($newFiles.Count) | Total: $totalChanged ($changePct%)" -ForegroundColor Yellow
                        
                        if ($totalChanged -gt 0 -and $changePct -lt 10) {
                            # DELTA PATCH MODE: <10% changed, patch existing data
                            Write-Log "   Delta patch mode ($changePct% < 10%) - patching $totalChanged files..." -ForegroundColor Green
                            $dataDir = Join-Path $OutputPath "data"
                            
                            # Load changed/new device records
                            $deltaDevices = @{}
                            $allDeltaFiles = @($changedFiles) + @($newFiles)
                            foreach ($df in $allDeltaFiles) {
                                try {
                                    $devData = Get-Content $df.FullName -Raw | ConvertFrom-Json
                                    $dev = Normalize-DeviceRecord $devData
                                    if ($dev.HostName) { $deltaDevices[$dev.HostName] = $dev }
                                } catch { }
                            }
                            Write-Log "   Loaded $($deltaDevices.Count) changed device records" -ForegroundColor Gray
                            
                            # For each category JSON: remove old entries for changed hostnames, add new entries
                            $categoryFiles = @("errors", "known_issues", "missing_kek", "not_updated",
                                "task_disabled", "temp_failures", "perm_failures", "updated_devices",
                                "action_required", "secureboot_off", "rollout_inprogress")
                            $changedHostnames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                            foreach ($hn in $deltaDevices.Keys) { [void]$changedHostnames.Add($hn) }
                            
                            foreach ($cat in $categoryFiles) {
                                $catPath = Join-Path $dataDir "$cat.json"
                                if (Test-Path $catPath) {
                                    try {
                                        $catData = Get-Content $catPath -Raw | ConvertFrom-Json
                                        # Remove old entries for changed hostnames
                                        $catData = @($catData | Where-Object { -not $changedHostnames.Contains($_.HostName) })
                                        # Re-classify each changed device into categories
                                        # (will be added below after classification)
                                        $catData | ConvertTo-Json -Depth 5 | Set-Content $catPath -Encoding UTF8
                                    } catch { }
                                }
                            }
                            
                            # Classify each changed device and append to the right category files
                            foreach ($dev in $deltaDevices.Values) {
                                $uefiCat = $dev.$uefiErrorCategory
                                $slim = [ordered]@{
                                    HostName = $dev.HostName
                                    WMI_Manufacturer = if ($dev.PSObject.Properties['WMI_Manufacturer']) { $dev.WMI_Manufacturer } else { "" }
                                    WMI_Model = if ($dev.PSObject.Properties['WMI_Model']) { $dev.WMI_Model } else { "" }
                                    BucketId = if ($dev.PSObject.Properties['BucketId']) { $dev.BucketId } else { "" }
                                    ConfidenceLevel = if ($dev.PSObject.Properties['ConfidenceLevel']) { $dev.ConfidenceLevel } else { "" }
                                    IsUpdated = $dev.IsUpdated
                                    UEFICA2023Error = if ($dev.PSObject.Properties['UEFICA2023Error']) { $dev.UEFICA2023Error } else { $null }
                                    SecureBootTaskStatus = if ($dev.PSObject.Properties['SecureBootTaskStatus']) { $dev.SecureBootTaskStatus } else { "" }
                                    KnownIssueId = if ($dev.PSObject.Properties['KnownIssueId']) { $dev.KnownIssueId } else { $null }
                                    SkipReasonKnownIssue = if ($dev.PSObject.Properties['SkipReasonKnownIssue']) { $dev.SkipReasonKnownIssue } else { $null }
                                }
                                
                                $isUpd = $dev.IsUpdated -eq $true
                                $conf = if ($dev.PSObject.Properties['ConfidenceLevel']) { $dev.ConfidenceLevel } else { "" }
                                $hasErr = (-not [string]::IsNullOrEmpty($dev.UEFICA2023Error) -and $dev.UEFICA2023Error -ne "0" -and $dev.UEFICA2023Error -ne "") -or ($uefiCat -eq "FirmwareError")
                                $tskDis = ($dev.SecureBootTaskEnabled -eq $false -or $dev.SecureBootTaskStatus -eq 'Disabled' -or $dev.SecureBootTaskStatus -eq 'NotFound')
                                $tskNF = ($dev.SecureBootTaskStatus -eq 'NotFound')
                                $sbOn = ($dev.PSObject.Properties['SecureBootEnabled']) -and ($dev.SecureBootEnabled -eq $true -or "$($dev.SecureBootEnabled)" -eq "True")
                                $e1801 = if ($dev.PSObject.Properties['Event1801Count']) { [int]$dev.Event1801Count } else { 0 }
                                $e1808 = if ($dev.PSObject.Properties['Event1808Count']) { [int]$dev.Event1808Count } else { 0 }
                                $e1803 = if ($dev.PSObject.Properties['Event1803Count']) { [int]$dev.Event1803Count } else { 0 }
                                $mKEK = ($e1803 -gt 0 -or $dev.MissingKEK -eq $true)
                                $hKI = ((-not [string]::IsNullOrEmpty($dev.SkipReasonKnownIssue)) -or (-not [string]::IsNullOrEmpty($dev.KnownIssueId)))
                                $rStat = if ($dev.PSObject.Properties['RolloutStatus']) { $dev.RolloutStatus } else { "" }
                                
                                # Append to matching category files
                                $targets = @()
                                if (($isUpd -and $e1808 -eq 0) -or $uefiReboot) { $targets += "needs_reboot" }
                                if ($hasErr) { $targets += "errors" }
                                if ($hKI) { $targets += "known_issues" }
                                if ($mKEK) { $targets += "missing_kek" }
                                if (-not $isUpd -and $sbOn) { $targets += "not_updated" }
                                if ($tskDis) { $targets += "task_disabled" }
                                if (-not $isUpd -and ($tskDis -or (Test-ConfidenceLevel $conf 'TemporarilyPaused'))) { $targets += "temp_failures" }
                                if (-not $isUpd -and ((Test-ConfidenceLevel $conf 'NotSupported') -or ($tskNF -and $hasErr))) { $targets += "perm_failures" }
                                if (-not $isUpd -and (Test-ConfidenceLevel $conf 'ActionRequired')) { $targets += "action_required" }
                                if (-not $sbOn) { $targets += "secureboot_off" }
                                #Check V?
                                if (($e1801 -gt 0-or $uefiCat -eq "Pending") -and $e1808 -eq 0 -and -not $hasErr -and $rStat -eq "InProgress") { $targets += "rollout_inprogress" }
                                
                                foreach ($tgt in $targets) {
                                    $tgtPath = Join-Path $dataDir "$tgt.json"
                                    if (Test-Path $tgtPath) {
                                        $existing = Get-Content $tgtPath -Raw | ConvertFrom-Json
                                        $existing = @($existing) + @([PSCustomObject]$slim)
                                        $existing | ConvertTo-Json -Depth 5 | Set-Content $tgtPath -Encoding UTF8
                                    }
                                }
                            }
                            
                            # Regenerate CSVs from patched JSONs
                            Write-Log "   Regenerating CSVs from patched data..." -ForegroundColor Gray
                            $newTimestamp = Get-Date -Format "yyyyMMdd-HHmmss"
                            foreach ($cat in $categoryFiles) {
                                $catJsonPath = Join-Path $dataDir "$cat.json"
                                $catCsvPath = Join-Path $OutputPath "SecureBoot_${cat}_$newTimestamp.csv"
                                if (Test-Path $catJsonPath) {
                                    try {
                                        $catJsonData = Get-Content $catJsonPath -Raw | ConvertFrom-Json
                                        if ($catJsonData.Count -gt 0) {
                                            $catJsonData | Export-Csv -Path $catCsvPath -NoTypeInformation -Encoding UTF8
                                        }
                                    } catch { }
                                }
                            }
                            
                            # Recount stats from the patched JSON files
                            Write-Log "   Recalculating summary from patched data..." -ForegroundColor Gray
                            $patchedStats = [ordered]@{ ReportGeneratedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") }
                            $pTotal = 0; $pUpdated = 0; $pErrors = 0; $pKI = 0; $pKEK = 0
                            $pTaskDis = 0; $pTempFail = 0; $pPermFail = 0; $pActionReq = 0; $pSBOff = 0; $pRIP = 0
                            foreach ($cat in $categoryFiles) {
                                $catPath = Join-Path $dataDir "$cat.json"
                                $cnt = 0
                                if (Test-Path $catPath) { try { $cnt = (Get-Content $catPath -Raw | ConvertFrom-Json).Count } catch { } }
                                switch ($cat) {
                                    "updated_devices" { $pUpdated = $cnt }
                                    "errors" { $pErrors = $cnt }
                                    "known_issues" { $pKI = $cnt }
                                    "missing_kek" { $pKEK = $cnt }
                                    "not_updated" { } # computed
                                    "task_disabled" { $pTaskDis = $cnt }
                                    "temp_failures" { $pTempFail = $cnt }
                                    "perm_failures" { $pPermFail = $cnt }
                                    "action_required" { $pActionReq = $cnt }
                                    "secureboot_off" { $pSBOff = $cnt }
                                    "rollout_inprogress" { $pRIP = $cnt }
                                }
                            }
                            $pNotUpdated = (Get-Content (Join-Path $dataDir "not_updated.json") -Raw | ConvertFrom-Json).Count
                            $pTotal = $pUpdated + $pNotUpdated + $pSBOff
                            
                            Write-Log "   Delta patch complete: $totalChanged devices updated" -ForegroundColor Green
                            Write-Log "   Total: $pTotal | Updated: $pUpdated | NotUpdated: $pNotUpdated | Errors: $pErrors" -ForegroundColor White
                            
                            # Update manifest
                            $stManifestDir = Join-Path $OutputPath ".cache"
                            $stNewManifest = @{}
                            foreach ($jf in $jsonFiles) {
                                $stNewManifest[$jf.FullName.ToLowerInvariant()] = @{
                                    LastWriteTimeUtc = $jf.LastWriteTimeUtc.ToString("o"); Size = $jf.Length
                                }
                            }
                            Save-FileManifest -Manifest $stNewManifest -Path $stManifestPath
                            
                            Write-Log "   Completed in $([math]::Round($streamSw.Elapsed.TotalSeconds, 1))s (delta patch - $totalChanged devices)" -ForegroundColor Green
                            
                            # Fall through to full streaming reprocess to regenerate HTML dashboard
                            # The data files are already patched, so this ensures dashboard stays current
                            Write-Log "   Regenerating dashboard from patched data..." -ForegroundColor Yellow
                        } else {
                            Write-Log "   $changePct% files changed (>= 10%) - full streaming reprocess required" -ForegroundColor Yellow
                        }
                    }
                }
            }
        }
        
        # Create data subdirectory for on-demand device JSON files
        $dataDir = Join-Path $OutputPath "data"
        if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
        
        # Deduplication via HashSet (O(1) per lookup, ~50MB for 600K hostnames)
        $seenHostnames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        
        # Lightweight summary counters (replaces $allDevices + $uniqueDevices in memory)
        $c = @{
            Total = 0; SBEnabled = 0; SBOff = 0
            Updated = 0; HighConf = 0; UnderObs = 0; ActionReq = 0; TempPaused = 0; NotSupported = 0; NoConfData = 0
            TaskDisabled = 0; TaskNotFound = 0; TaskDisabledNotUpdated = 0
            WithErrors = 0; InProgress = 0; NotYetInitiated = 0; RolloutInProgress = 0
            WithKnownIssues = 0; WithMissingKEK = 0; TempFailures = 0; PermFailures = 0; NeedsReboot = 0
            UpdatePending = 0
        }
        
        # Bucket tracking for AtRisk/SafeList (lightweight sets)
        $stFailedBuckets = [System.Collections.Generic.HashSet[string]]::new()
        $stSuccessBuckets = [System.Collections.Generic.HashSet[string]]::new()
        $stAllBuckets = @{}
        $stMfrCounts = @{}
        $stErrorCodeCounts = @{}; $stErrorCodeSamples = @{}
        $stKnownIssueCounts = @{}
        
        # Batch-mode device data files: accumulate per-chunk, flush at chunk boundaries
        $stDeviceFiles = @("errors", "known_issues", "missing_kek", "not_updated", 
            "task_disabled", "temp_failures", "perm_failures", "updated_devices", "action_required",
            "secureboot_off", "rollout_inprogress", "under_observation", "needs_reboot", "update_pending")
        $stDeviceFilePaths = @{}; $stDeviceFileCounts = @{}
        foreach ($dfName in $stDeviceFiles) {
            $dfPath = Join-Path $dataDir "$dfName.json"
            [System.IO.File]::WriteAllText($dfPath, "[`n", [System.Text.Encoding]::UTF8)
            $stDeviceFilePaths[$dfName] = $dfPath; $stDeviceFileCounts[$dfName] = 0
        }
        
        # Slim device record for JSON output (only essential fields, ~200 bytes vs ~2KB full)
        function Get-SlimDevice {
            param($Dev)
            return [ordered]@{
                HostName                = $Dev.HostName
                WMI_Manufacturer        = if ($Dev.PSObject.Properties['WMI_Manufacturer']) { $Dev.WMI_Manufacturer } else { "" }
                WMI_Model               = if ($Dev.PSObject.Properties['WMI_Model']) { $Dev.WMI_Model } else { "" }
                BucketId                = if ($Dev.PSObject.Properties['BucketId']) { $Dev.BucketId } else { "" }
                ConfidenceLevel         = if ($Dev.PSObject.Properties['ConfidenceLevel']) { $Dev.ConfidenceLevel } else { "" }
                IsUpdated               = $Dev.IsUpdated
                UEFICA2023Error         = if ($Dev.PSObject.Properties['UEFICA2023Error']) { $Dev.UEFICA2023Error } else { $null }
                UEFIErrorCategory       = if ($Dev.PSObject.Properties['UEFIErrorCategory']) { $Dev.UEFIErrorCategory } else { "" }
                SecureBootTaskStatus    = if ($Dev.PSObject.Properties['SecureBootTaskStatus']) { $Dev.SecureBootTaskStatus } else { "" }
                KnownIssueId            = if ($Dev.PSObject.Properties['KnownIssueId']) { $Dev.KnownIssueId } else { $null }
                SkipReasonKnownIssue    = if ($Dev.PSObject.Properties['SkipReasonKnownIssue']) { $Dev.SkipReasonKnownIssue } else { $null }
                UEFICA2023Status        = if ($Dev.PSObject.Properties['UEFICA2023Status']) { $Dev.UEFICA2023Status } else { $null }
                AvailableUpdatesPolicy  = if ($Dev.PSObject.Properties['AvailableUpdatesPolicy']) { $Dev.AvailableUpdatesPolicy } else { $null }
                WinCSKeyApplied         = if ($Dev.PSObject.Properties['WinCSKeyApplied']) { $Dev.WinCSKeyApplied } else { $null }
                WinCSKeyStatus          = if ($Dev.PSObject.Properties['WinCSKeyStatus']) { $Dev.WinCSKeyStatus } else { "Unknown" }
                InWave                  = if ($Dev.PSObject.Properties['InWave']) { $Dev.InWave } else { $false }
                WaveManifestSeen        = if ($Dev.PSObject.Properties['WaveManifestSeen']) { $Dev.WaveManifestSeen } else { $null }
            }
        }
        
        # Flush batch to JSON file (append mode)
        function Flush-DeviceBatch {
            param([string]$StreamName, [System.Collections.Generic.List[object]]$Batch)
            if ($Batch.Count -eq 0) { return }
            $fPath = $stDeviceFilePaths[$StreamName]
            $fSb = [System.Text.StringBuilder]::new()
            foreach ($fDev in $Batch) {
                if ($stDeviceFileCounts[$StreamName] -gt 0) { [void]$fSb.Append(",`n") }
                [void]$fSb.Append(($fDev | ConvertTo-Json -Compress))
                $stDeviceFileCounts[$StreamName]++
            }
            [System.IO.File]::AppendAllText($fPath, $fSb.ToString(), [System.Text.Encoding]::UTF8)
        }

    # ===========================================================================================
    # MAIN STREAMING LOOP
    # ===========================================================================================
        $stChunkSize = if ($totalFiles -le 10000) { $totalFiles } else { 10000 }
        $stTotalChunks = [math]::Ceiling($totalFiles / $stChunkSize)
        $stPeakMemMB = 0
        if ($stTotalChunks -gt 1) {
            Write-Log "Processing $totalFiles files in $stTotalChunks chunks of $stChunkSize (streaming, $ParallelThreads threads):" -ForegroundColor Cyan
        } else {
            Write-Log "Processing $totalFiles files (streaming, $ParallelThreads threads):" -ForegroundColor Cyan
        }
        
        for ($ci = 0; $ci -lt $stTotalChunks; $ci++) {
            $cStart = $ci * $stChunkSize
            $cEnd = [math]::Min($cStart + $stChunkSize, $totalFiles) - 1
            $cFiles = $jsonFiles[$cStart..$cEnd]
            
            if ($stTotalChunks -gt 1) {
                Write-Log "   Chunk $($ci + 1)/$stTotalChunks ($($cFiles.Count) files): " -NoNewline -ForegroundColor Gray
            } else {
                Write-Log "   Loading $($cFiles.Count) files: " -NoNewline -ForegroundColor Gray
            }
            $cSw = [System.Diagnostics.Stopwatch]::StartNew()
            
            $rawDevices = Load-FilesParallel -Files $cFiles -Threads $ParallelThreads
            # ========================
            # Per-chunk batch lists
            # =======================
            $cBatches = @{}
            foreach ($df in $stDeviceFiles) { $cBatches[$df] = [System.Collections.Generic.List[object]]::new() }
            
            $cNew = 0; $cDupe = 0
            foreach ($raw in $rawDevices) {
                if (-not $raw) { continue }
                $device = Normalize-DeviceRecord $raw
                $hostname = $device.HostName
                
                #DEBUG
                if ($device.HostName -eq "SEMETICS-APP02") {
                    Write-Host "DEBUG: Error=$($device.UEFICA2023Error) Category=$($device.UEFIErrorCategory)"
                }

                $uefiCat = $device.UEFIErrorCategory #New property to use alongside event IDs for status
                if (-not $hostname) { continue }
                
                if ($seenHostnames.Contains($hostname)) { $cDupe++; continue }
                [void]$seenHostnames.Add($hostname)
                $cNew++; $c.Total++
                
                $sbOn = ($device.SecureBootEnabled -ne $false -and "$($device.SecureBootEnabled)" -ne "False")
                if ($sbOn) { $c.SBEnabled++ } else { $c.SBOff++; $cBatches["secureboot_off"].Add((Get-SlimDevice $device)) }
                
                $isUpd = $device.IsUpdated -eq $true
                $conf = if ($device.PSObject.Properties['ConfidenceLevel'] -and $device.ConfidenceLevel) { "$($device.ConfidenceLevel)" } else { "" }
                #$hasErr = (-not [string]::IsNullOrEmpty($device.UEFICA2023Error) -and "$($device.UEFICA2023Error)" -ne "0" -and "$($device.UEFICA2023Error)" -ne "")
                $hasErr = ($device.PSObject.Properties['UEFICA2023Error'] -and -not [string]::IsNullOrEmpty($device.UEFICA2023Error) -and $device.UEFICA2023Error -ne "0") -or ($uefiCat -eq "FirmwareError")

                $tskDis = ($device.SecureBootTaskEnabled -eq $false -or "$($device.SecureBootTaskStatus)" -eq 'Disabled' -or "$($device.SecureBootTaskStatus)" -eq 'NotFound')
                $tskNF = ("$($device.SecureBootTaskStatus)" -eq 'NotFound')
                $bid = if ($device.PSObject.Properties['BucketId'] -and $device.BucketId) { "$($device.BucketId)" } else { "" }
                $e1808 = if ($device.PSObject.Properties['Event1808Count']) { [int]$device.Event1808Count } else { 0 }
                $e1801 = if ($device.PSObject.Properties['Event1801Count']) { [int]$device.Event1801Count } else { 0 }
                $e1803 = if ($device.PSObject.Properties['Event1803Count']) { [int]$device.Event1803Count } else { 0 }
                $mKEK = ($e1803 -gt 0 -or $device.MissingKEK -eq $true -or "$($device.MissingKEK)" -eq "True")
                $hKI = ((-not [string]::IsNullOrEmpty($device.SkipReasonKnownIssue)) -or (-not [string]::IsNullOrEmpty($device.KnownIssueId)))
                $rStat = if ($device.PSObject.Properties['RolloutStatus']) { $device.RolloutStatus } else { "" }
                $mfr = if ($device.PSObject.Properties['WMI_Manufacturer'] -and -not [string]::IsNullOrEmpty($device.WMI_Manufacturer)) { $device.WMI_Manufacturer } else { "Unknown" }
                $bid = if (-not [string]::IsNullOrEmpty($bid)) { $bid } else { "" }
                
                # Pre-compute Update Pending flag (policy/WinCS applied, status not yet Updated, SB ON, task not disabled)
                $uefiStatus = if ($device.PSObject.Properties['UEFICA2023Status']) { "$($device.UEFICA2023Status)" } else { "" }
                $uefiPending = ($uefiCat -eq "Pending") #NEW!
                $uefiReboot = ($uefiCat -eq "NeedsReboot") #New!
                $hasPolicy = ($device.PSObject.Properties['AvailableUpdatesPolicy'] -and $null -ne $device.AvailableUpdatesPolicy -and "$($device.AvailableUpdatesPolicy)" -ne '')
                $hasWinCS = ($device.PSObject.Properties['WinCSKeyApplied'] -and $device.WinCSKeyApplied -eq $true)
                $statusPending = ([string]::IsNullOrEmpty($uefiStatus) -or $uefiStatus -eq 'NotStarted' -or $uefiStatus -eq 'InProgress')
                $isUpdatePending = (($hasPolicy -or $hasWinCS) -and $statusPending -and -not $isUpd -and $sbOn -and -not $tskDis)
                

                # Classification phase/device evaluation phase
                if ($isUpd) {
                    $c.Updated++; [void]$stSuccessBuckets.Add($bid); $cBatches["updated_devices"].Add((Get-SlimDevice $device))
                    # Track Updated devices that need reboot (UEFICA2023Status=Updated but Event1808=0)
                    #if ($e1808 -eq 0) { $c.NeedsReboot++; $cBatches["needs_reboot"].Add((Get-SlimDevice $device)) }
                }
                elseif (-not $sbOn) { 
                    # SecureBoot OFF — out of scope, don't classify by confidence
                }
                else {
                    if ($isUpdatePending) { } # Counted separately in Update Pending — mutually exclusive for pie chart
                    elseif (Test-ConfidenceLevel $conf "HighConfidence") { $c.HighConf++ }
                    elseif (Test-ConfidenceLevel $conf "UnderObservation") { $c.UnderObs++ }
                    elseif (Test-ConfidenceLevel $conf "TemporarilyPaused") { $c.TempPaused++ }
                    elseif (Test-ConfidenceLevel $conf "NotSupported") { $c.NotSupported++ }
                    else { $c.ActionReq++ }
                    if ([string]::IsNullOrEmpty($conf)) { $c.NoConfData++ }
                }
                #Moved out from the if ($isUpd) block since the device can still require a reboot without/before reporting as successful
                if (($isUpd -and $e1808 -eq 0) -or $uefiReboot) {
                        $c.NeedsReboot++
                        $cBatches["needs_reboot"].Add((Get-SlimDevice $device))
                    }

                if ($tskDis) { $c.TaskDisabled++; $cBatches["task_disabled"].Add((Get-SlimDevice $device)) }
                if ($tskNF) { $c.TaskNotFound++ }
                if (-not $isUpd -and $tskDis) { $c.TaskDisabledNotUpdated++ }
                
                if ($hasErr) {
                    $c.WithErrors++; [void]$stFailedBuckets.Add($bid); $cBatches["errors"].Add((Get-SlimDevice $device))
                    $ec = $device.UEFICA2023Error
                    if (-not $stErrorCodeCounts.ContainsKey($ec)) { $stErrorCodeCounts[$ec] = 0; $stErrorCodeSamples[$ec] = @() }
                    $stErrorCodeCounts[$ec]++
                    if ($stErrorCodeSamples[$ec].Count -lt 5) { $stErrorCodeSamples[$ec] += $hostname }
                }
                if ($hKI) {
                    $c.WithKnownIssues++; $cBatches["known_issues"].Add((Get-SlimDevice $device))
                    $ki = if (-not [string]::IsNullOrEmpty($device.SkipReasonKnownIssue)) { $device.SkipReasonKnownIssue } else { $device.KnownIssueId }
                    if (-not $stKnownIssueCounts.ContainsKey($ki)) { $stKnownIssueCounts[$ki] = 0 }; $stKnownIssueCounts[$ki]++
                }
                if ($mKEK) { $c.WithMissingKEK++; $cBatches["missing_kek"].Add((Get-SlimDevice $device)) }
                if (-not $isUpd -and ($tskDis -or (Test-ConfidenceLevel $conf 'TemporarilyPaused'))) { $c.TempFailures++; $cBatches["temp_failures"].Add((Get-SlimDevice $device)) }
                if (-not $isUpd -and ((Test-ConfidenceLevel $conf 'NotSupported') -or ($tskNF -and $hasErr))) { $c.PermFailures++; $cBatches["perm_failures"].Add((Get-SlimDevice $device)) }

                if ($e1801 -gt 0 -and $e1808 -eq 0 -and -not $hasErr -and $rStat -eq "InProgress") { $c.RolloutInProgress++; $cBatches["rollout_inprogress"].Add((Get-SlimDevice $device)) }
                if (($e1801 -gt 0 -or $uefiPending) -and $e1808 -eq 0 -and -not $hasErr -and $rStat -ne "InProgress") { $c.NotYetInitiated++ }

                if ($rStat -eq "InProgress" -and $e1808 -eq 0) { $c.InProgress++ }
                # Update Pending: policy or WinCS applied, status pending, SB ON, task not disabled
                if ($isUpdatePending) {
                    $c.UpdatePending++; $cBatches["update_pending"].Add((Get-SlimDevice $device))
                }
                if (-not $isUpd -and $sbOn) { $cBatches["not_updated"].Add((Get-SlimDevice $device)) }
                # Under Observation devices (separate from Action Required)
                if (-not $isUpd -and (Test-ConfidenceLevel $conf 'UnderObservation')) { $cBatches["under_observation"].Add((Get-SlimDevice $device)) }
                # Action Required: not-updated, SB ON, not matching other confidence categories, not Update Pending
                if (-not $isUpd -and $sbOn -and -not $isUpdatePending -and -not (Test-ConfidenceLevel $conf 'HighConfidence') -and -not (Test-ConfidenceLevel $conf 'UnderObservation') -and -not (Test-ConfidenceLevel $conf 'TemporarilyPaused') -and -not (Test-ConfidenceLevel $conf 'NotSupported')) {
                    $cBatches["action_required"].Add((Get-SlimDevice $device))
                }
                
                if (-not $stMfrCounts.ContainsKey($mfr)) { $stMfrCounts[$mfr] = @{ Total=0; Updated=0; UpdatePending=0; HighConf=0; UnderObs=0; ActionReq=0; TempPaused=0; NotSupported=0; SBOff=0; WithErrors=0 } }
                $stMfrCounts[$mfr].Total++
                if ($isUpd) { $stMfrCounts[$mfr].Updated++ }
                elseif (-not $sbOn) { $stMfrCounts[$mfr].SBOff++ }
                elseif ($isUpdatePending) { $stMfrCounts[$mfr].UpdatePending++ }
                elseif (Test-ConfidenceLevel $conf "HighConfidence") { $stMfrCounts[$mfr].HighConf++ }
                elseif (Test-ConfidenceLevel $conf "UnderObservation") { $stMfrCounts[$mfr].UnderObs++ }
                elseif (Test-ConfidenceLevel $conf "TemporarilyPaused") { $stMfrCounts[$mfr].TempPaused++ }
                elseif (Test-ConfidenceLevel $conf "NotSupported") { $stMfrCounts[$mfr].NotSupported++ }
                else { $stMfrCounts[$mfr].ActionReq++ }
                if ($hasErr) { $stMfrCounts[$mfr].WithErrors++ }
                
                # Track all devices by bucket (including empty BucketId)
                $bucketKey = if ($bid -and $bid -ne "") { $bid } else { "(empty)" }
                if (-not $stAllBuckets.ContainsKey($bucketKey)) {
                    $stAllBuckets[$bucketKey] = @{ Count=0; Updated=0; Manufacturer=$mfr; Model=""; BIOS="" }
                    if ($device.PSObject.Properties['WMI_Model']) { $stAllBuckets[$bucketKey].Model = $device.WMI_Model }
                    if ($device.PSObject.Properties['BIOSDescription']) { $stAllBuckets[$bucketKey].BIOS = $device.BIOSDescription }
                }
                $stAllBuckets[$bucketKey].Count++
                if ($isUpd) { $stAllBuckets[$bucketKey].Updated++ }
            }
            
            # Flush batches to disk
            foreach ($df in $stDeviceFiles) { Flush-DeviceBatch -StreamName $df -Batch $cBatches[$df] }
            $rawDevices = $null; $cBatches = $null; [System.GC]::Collect()
            
            $cSw.Stop()
            $cTime = [Math]::Round($cSw.Elapsed.TotalSeconds, 1)
            $cRem = $stTotalChunks - $ci - 1
            $cEta = if ($cRem -gt 0) { " | ETA: ~$([Math]::Round($cRem * $cSw.Elapsed.TotalSeconds / 60, 1)) min" } else { "" }
            $cMem = [math]::Round([System.GC]::GetTotalMemory($false) / 1MB, 0)
            if ($cMem -gt $stPeakMemMB) { $stPeakMemMB = $cMem }
            Write-Log " +$cNew new, $cDupe dupes, ${cTime}s | Mem: ${cMem}MB$cEta" -ForegroundColor Green
        }
        
        # Finalize JSON arrays
        foreach ($dfName in $stDeviceFiles) {
            [System.IO.File]::AppendAllText($stDeviceFilePaths[$dfName], "`n]", [System.Text.Encoding]::UTF8)
            Write-Log "   $dfName.json: $($stDeviceFileCounts[$dfName]) devices" -ForegroundColor DarkGray
        }
        
        # Compute derived stats
        $stAtRisk = 0; $stSafeList = 0
        foreach ($bid in $stAllBuckets.Keys) {
            $b = $stAllBuckets[$bid]; $nu = $b.Count - $b.Updated
            if ($stFailedBuckets.Contains($bid)) { $stAtRisk += $nu }
            elseif ($stSuccessBuckets.Contains($bid)) { $stSafeList += $nu }
        }
        $stAtRisk = [math]::Max(0, $stAtRisk - $c.WithErrors)
        # NotUptodate = count from not_updated batch (devices with SB ON and not updated)
        $stNotUptodate = $stDeviceFileCounts["not_updated"]
        
        $stats = [ordered]@{
            ReportGeneratedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            TotalDevices = $c.Total; SecureBootEnabled = $c.SBEnabled; SecureBootOFF = $c.SBOff
            Updated = $c.Updated; HighConfidence = $c.HighConf; UnderObservation = $c.UnderObs
            ActionRequired = $c.ActionReq; TemporarilyPaused = $c.TempPaused; NotSupported = $c.NotSupported
            NoConfidenceData = $c.NoConfData; TaskDisabled = $c.TaskDisabled; TaskNotFound = $c.TaskNotFound
            TaskDisabledNotUpdated = $c.TaskDisabledNotUpdated
            CertificatesUpdated = $c.Updated; NotUptodate = $stNotUptodate; FullyUpdated = $c.Updated
            UpdatesPending = $stNotUptodate; UpdatesComplete = $c.Updated
            WithErrors = $c.WithErrors; InProgress = $c.InProgress; NotYetInitiated = $c.NotYetInitiated
            RolloutInProgress = $c.RolloutInProgress; WithKnownIssues = $c.WithKnownIssues
            WithMissingKEK = $c.WithMissingKEK; TemporaryFailures = $c.TempFailures; PermanentFailures = $c.PermFailures
            NeedsReboot = $c.NeedsReboot; UpdatePending = $c.UpdatePending
            AtRiskDevices = $stAtRisk; SafeListDevices = $stSafeList
            PercentWithErrors = if ($c.Total -gt 0) { [math]::Round(($c.WithErrors/$c.Total)*100,2) } else { 0 }
            PercentAtRisk = if ($c.Total -gt 0) { [math]::Round(($stAtRisk/$c.Total)*100,2) } else { 0 }
            PercentSafeList = if ($c.Total -gt 0) { [math]::Round(($stSafeList/$c.Total)*100,2) } else { 0 }
            PercentHighConfidence = if ($c.Total -gt 0) { [math]::Round(($c.HighConf/$c.Total)*100,1) } else { 0 }
            PercentCertUpdated = if ($c.Total -gt 0) { [math]::Round(($c.Updated/$c.Total)*100,1) } else { 0 }
            PercentActionRequired = if ($c.Total -gt 0) { [math]::Round(($c.ActionReq/$c.Total)*100,1) } else { 0 }
            PercentNotUptodate = if ($c.Total -gt 0) { [math]::Round($stNotUptodate/$c.Total*100,1) } else { 0 }
            PercentFullyUpdated = if ($c.Total -gt 0) { [math]::Round(($c.Updated/$c.Total)*100,1) } else { 0 }
            UniqueBuckets = $stAllBuckets.Count; PeakMemoryMB = $stPeakMemMB; ProcessingMode = "Streaming"
        }
        
        # Write CSVs
        [PSCustomObject]$stats | Export-Csv -Path (Join-Path $OutputPath "SecureBoot_Summary_$timestamp.csv") -NoTypeInformation -Encoding UTF8
        $stMfrCounts.GetEnumerator() | Sort-Object { $_.Value.Total } -Descending | ForEach-Object {
            [PSCustomObject]@{ Manufacturer=$_.Key; Count=$_.Value.Total; Updated=$_.Value.Updated; HighConfidence=$_.Value.HighConf; ActionRequired=$_.Value.ActionReq }
        } | Export-Csv -Path (Join-Path $OutputPath "SecureBoot_ByManufacturer_$timestamp.csv") -NoTypeInformation -Encoding UTF8
        $stErrorCodeCounts.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
            [PSCustomObject]@{ ErrorCode=$_.Key; Count=$_.Value; SampleDevices=($stErrorCodeSamples[$_.Key] -join ", ") }
        } | Export-Csv -Path (Join-Path $OutputPath "SecureBoot_ErrorCodes_$timestamp.csv") -NoTypeInformation -Encoding UTF8
        $stAllBuckets.GetEnumerator() | Sort-Object { $_.Value.Count } -Descending | ForEach-Object {
            [PSCustomObject]@{ BucketId=$_.Key; Count=$_.Value.Count; Updated=$_.Value.Updated; NotUpdated=$_.Value.Count-$_.Value.Updated; Manufacturer=$_.Value.Manufacturer }
        } | Export-Csv -Path (Join-Path $OutputPath "SecureBoot_UniqueBuckets_$timestamp.csv") -NoTypeInformation -Encoding UTF8
        
        # Generate orchestrator-compatible CSVs (expected filenames for Start-SecureBootRolloutOrchestrator.ps1)
        $notUpdatedJsonPath = Join-Path $dataDir "not_updated.json"
        if (Test-Path $notUpdatedJsonPath) {
            try {
                $nuData = Get-Content $notUpdatedJsonPath -Raw | ConvertFrom-Json
                if ($nuData.Count -gt 0) {
                    # NotUptodate CSV - orchestrator searches for *NotUptodate*.csv
                    $nuData | Export-Csv -Path (Join-Path $OutputPath "SecureBoot_NotUptodate_$timestamp.csv") -NoTypeInformation -Encoding UTF8
                    Write-Log "   Orchestrator CSV: SecureBoot_NotUptodate_$timestamp.csv ($($nuData.Count) devices)" -ForegroundColor Gray
                }
            } catch { }
        }
        
        # Write JSON data for dashboard
        $stats | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $dataDir "summary.json") -Encoding UTF8
        
        # HISTORICAL TRACKING: Save data point for trend chart
        # Use a stable cache location so trend data persists across timestamped aggregation folders.
        # If OutputPath looks like "...\Aggregation_yyyyMMdd_HHmmss", cache goes in the parent folder.
        # Otherwise, cache goes inside OutputPath itself.
        $parentDir = Split-Path $OutputPath -Parent
        $leafName = Split-Path $OutputPath -Leaf
        if ($leafName -match '^Aggregation_\d{8}' -or $leafName -eq 'Aggregation_Current') {
            # Orchestrator-created timestamped folder — use parent for stable cache
            $historyPath = Join-Path $parentDir ".cache\trend_history.json"
        } else {
            $historyPath = Join-Path $OutputPath ".cache\trend_history.json"
        }
        $historyDir = Split-Path $historyPath -Parent
        if (-not (Test-Path $historyDir)) { New-Item -ItemType Directory -Path $historyDir -Force | Out-Null }
        $historyData = @()
        if (Test-Path $historyPath) {
            try { $historyData = @(Get-Content $historyPath -Raw | ConvertFrom-Json) } catch { $historyData = @() }
        }
        # Also check inside OutputPath\.cache\ (legacy location from older versions)
        # Merge any data points not already in the primary history
        if ($leafName -eq 'Aggregation_Current' -or $leafName -match '^Aggregation_\d{8}') {
            $innerHistoryPath = Join-Path $OutputPath ".cache\trend_history.json"
            if ((Test-Path $innerHistoryPath) -and $innerHistoryPath -ne $historyPath) {
                try {
                    $innerData = @(Get-Content $innerHistoryPath -Raw | ConvertFrom-Json)
                    $existingDates = @($historyData | ForEach-Object { $_.Date })
                    foreach ($entry in $innerData) {
                        if ($entry.Date -and $entry.Date -notin $existingDates) {
                            $historyData += $entry
                        }
                    }
                    if ($innerData.Count -gt 0) {
                        Write-Log "   Merged $($innerData.Count) data points from inner cache" -ForegroundColor DarkGray
                    }
                } catch { }
            }
        }

        # BOOTSTRAP: If trend history is empty/sparse, reconstruct from historical data
        if ($historyData.Count -lt 2 -and ($leafName -match '^Aggregation_\d{8}' -or $leafName -eq 'Aggregation_Current')) {
            Write-Log "   Bootstrapping trend history from historical data..." -ForegroundColor Yellow
            $dailyData = @{}
            
            # Source 1: Summary CSVs inside current folder (Aggregation_Current keeps all Summary CSVs)
            $localSummaries = Get-ChildItem $OutputPath -Filter "SecureBoot_Summary_*.csv" -EA SilentlyContinue | Sort-Object Name
            foreach ($summCsv in $localSummaries) {
                try {
                    $summ = Import-Csv $summCsv.FullName | Select-Object -First 1
                    if ($summ.TotalDevices -and [int]$summ.TotalDevices -gt 0 -and $summ.ReportGeneratedAt) {
                        $dateStr = ([datetime]$summ.ReportGeneratedAt).ToString("yyyy-MM-dd")
                        $updated = if ($summ.Updated) { [int]$summ.Updated } else { 0 }
                        $notUpd = if ($summ.NotUptodate) { [int]$summ.NotUptodate } else { [int]$summ.TotalDevices - $updated }
                        $dailyData[$dateStr] = [PSCustomObject]@{
                            Date = $dateStr; Total = [int]$summ.TotalDevices; Updated = $updated; NotUpdated = $notUpd
                            NeedsReboot = 0; Errors = 0; ActionRequired = if ($summ.ActionRequired) { [int]$summ.ActionRequired } else { 0 }
                        }
                    }
                } catch { }
            }
            
            # Source 2: Old timestamped Aggregation_* folders (legacy, if they still exist)
            $aggFolders = Get-ChildItem $parentDir -Directory -Filter "Aggregation_*" -EA SilentlyContinue |
                Where-Object { $_.Name -match '^Aggregation_\d{8}' } |
                Sort-Object Name
            foreach ($folder in $aggFolders) {
                $summCsv = Get-ChildItem $folder.FullName -Filter "SecureBoot_Summary_*.csv" -EA SilentlyContinue | Select-Object -First 1
                if ($summCsv) {
                    try {
                        $summ = Import-Csv $summCsv.FullName | Select-Object -First 1
                        if ($summ.TotalDevices -and [int]$summ.TotalDevices -gt 0) {
                            $dateStr = $folder.Name -replace '^Aggregation_(\d{4})(\d{2})(\d{2})_.*', '$1-$2-$3'
                            $updated = if ($summ.Updated) { [int]$summ.Updated } else { 0 }
                            $notUpd = if ($summ.NotUptodate) { [int]$summ.NotUptodate } else { [int]$summ.TotalDevices - $updated }
                            $dailyData[$dateStr] = [PSCustomObject]@{
                                Date = $dateStr; Total = [int]$summ.TotalDevices; Updated = $updated; NotUpdated = $notUpd
                                NeedsReboot = 0; Errors = 0; ActionRequired = if ($summ.ActionRequired) { [int]$summ.ActionRequired } else { 0 }
                            }
                        }
                    } catch { }
                }
            }
            
            # Source 3: RolloutState.json WaveHistory (has per-wave timestamps from day 1)
            # This provides baseline data points even when no old aggregation folders exist
            $rolloutStatePaths = @(
                (Join-Path $parentDir "RolloutState\RolloutState.json"),
                (Join-Path $OutputPath "RolloutState\RolloutState.json")
            )
            foreach ($rsPath in $rolloutStatePaths) {
                if (Test-Path $rsPath) {
                    try {
                        $rsData = Get-Content $rsPath -Raw | ConvertFrom-Json
                        if ($rsData.WaveHistory) {
                            # Use wave start dates as trend data points
                            # Calculate cumulative devices targeted at each wave
                            $cumulativeTargeted = 0
                            foreach ($wave in $rsData.WaveHistory) {
                                if ($wave.StartedAt -and $wave.DeviceCount) {
                                    $waveDate = ([datetime]$wave.StartedAt).ToString("yyyy-MM-dd")
                                    $cumulativeTargeted += [int]$wave.DeviceCount
                                    if (-not $dailyData.ContainsKey($waveDate)) {
                                        # Approximate: at wave start time, only devices from prior waves were updated
                                        $dailyData[$waveDate] = [PSCustomObject]@{
                                            Date = $waveDate; Total = $c.Total; Updated = [math]::Max(0, $cumulativeTargeted - [int]$wave.DeviceCount)
                                            NotUpdated = $c.Total - [math]::Max(0, $cumulativeTargeted - [int]$wave.DeviceCount)
                                            NeedsReboot = 0; Errors = 0; ActionRequired = 0
                                        }
                                    }
                                }
                            }
                        }
                    } catch { }
                    break  # Use first found
                }
            }

            if ($dailyData.Count -gt 0) {
                $historyData = @($dailyData.GetEnumerator() | Sort-Object Key | ForEach-Object { $_.Value })
                Write-Log "   Bootstrapped $($historyData.Count) data points from historical summaries" -ForegroundColor Green
            }
        }

        # Add current data point (deduplicate by day - keep latest per day)
        $todayKey = (Get-Date).ToString("yyyy-MM-dd")
        $existingToday = $historyData | Where-Object { "$($_.Date)" -like "$todayKey*" }
        if ($existingToday) {
            # Replace today's entry
            $historyData = @($historyData | Where-Object { "$($_.Date)" -notlike "$todayKey*" })
        }
        $historyData += [PSCustomObject]@{
            Date = $todayKey
            Total = $c.Total
            Updated = $c.Updated
            NotUpdated = $stNotUptodate
            NeedsReboot = $c.NeedsReboot
            Errors = $c.WithErrors
            ActionRequired = $c.ActionReq
        }
        # Remove bad data points (0 total) and keep last 90
        $historyData = @($historyData | Where-Object { [int]$_.Total -gt 0 })
        # No cap — trend data is ~100 bytes/entry, a full year = ~36 KB
        $historyData | ConvertTo-Json -Depth 3 | Set-Content $historyPath -Encoding UTF8
        Write-Log "   Trend history: $($historyData.Count) data points" -ForegroundColor DarkGray
        
        # Build trend chart data for HTML
        $trendLabels = ($historyData | ForEach-Object { "'$($_.Date)'" }) -join ","
        $trendUpdated = ($historyData | ForEach-Object { $_.Updated }) -join ","
        $trendNotUpdated = ($historyData | ForEach-Object { $_.NotUpdated }) -join ","
        $trendTotal = ($historyData | ForEach-Object { $_.Total }) -join ","
        # Projection: extend trend line using exponential doubling (2,4,8,16...)
        # Derives wave size and observation period from actual trend history data.
        # - Wave size = largest single-period increase seen in history (the most recent wave deployed)
        # - Observation days = average calendar days between trend data points (how often we run)
        # Then doubles the wave size each period, matching the orchestrator's 2x growth strategy.
        $projLabels = ""; $projUpdated = ""; $projNotUpdated = ""; $hasProjection = $false
        if ($historyData.Count -ge 2) {
            $lastUpdated = $c.Updated
            $remaining = $stNotUptodate  # Only SB-ON not-updated devices (excludes SecureBoot OFF)
            $projDates = @(); $projValues = @(); $projNotUpdValues = @()
            $projDate = Get-Date

            # Derive wave size and observation period from trend history
            $increments = @()
            $dayGaps = @()
            for ($hi = 1; $hi -lt $historyData.Count; $hi++) {
                $inc = $historyData[$hi].Updated - $historyData[$hi-1].Updated
                if ($inc -gt 0) { $increments += $inc }
                try {
                    $d1 = [datetime]::Parse($historyData[$hi-1].Date)
                    $d2 = [datetime]::Parse($historyData[$hi].Date)
                    $gap = ($d2 - $d1).TotalDays
                    if ($gap -gt 0) { $dayGaps += $gap }
                } catch {}
            }
            # Wave size = most recent positive increment (current wave), fallback to average, minimum 2
            $waveSize = if ($increments.Count -gt 0) {
                [math]::Max(2, $increments[-1])
            } else { 2 }
            # Observation period = average gap between data points (calendar days per wave), minimum 1
            $waveDays = if ($dayGaps.Count -gt 0) {
                [math]::Max(1, [math]::Round(($dayGaps | Measure-Object -Average).Average, 0))
            } else { 1 }

            Write-Log "   Projection: waveSize=$waveSize (from last increment), waveDays=$waveDays (avg gap from history)" -ForegroundColor DarkGray

            $dayCounter = 0
            # Project until all devices updated or 365 days max
            for ($pi = 1; $pi -le 365; $pi++) {
                $projDate = $projDate.AddDays(1)
                $dayCounter++
                # At each observation period boundary, deploy a wave then double
                if ($dayCounter -ge $waveDays) {
                    $devicesThisWave = [math]::Min($waveSize, $remaining)
                    $lastUpdated += $devicesThisWave
                    $remaining -= $devicesThisWave
                    if ($lastUpdated -gt ($c.Updated + $stNotUptodate)) { $lastUpdated = $c.Updated + $stNotUptodate; $remaining = 0 }
                    # Double wave size for next period (orchestrator 2x strategy)
                    $waveSize = $waveSize * 2
                    $dayCounter = 0
                }
                $projDates += "'$($projDate.ToString("yyyy-MM-dd"))'"
                $projValues += $lastUpdated
                $projNotUpdValues += [math]::Max(0, $remaining)
                if ($remaining -le 0) { break }
            }
            $projLabels = $projDates -join ","
            $projUpdated = $projValues -join ","
            $projNotUpdated = $projNotUpdValues -join ","
            $hasProjection = $projDates.Count -gt 0
        } elseif ($historyData.Count -eq 1) {
            Write-Log "   Projection: need at least 2 trend data points to derive wave timing" -ForegroundColor DarkGray
        }
        # Build combined chart data strings for the here-string
        $allChartLabels = if ($hasProjection) { "$trendLabels,$projLabels" } else { $trendLabels }
        $projDataJS = if ($hasProjection) { $projUpdated } else { "" }
        $projNotUpdJS = if ($hasProjection) { $projNotUpdated } else { "" }
        $histCount = ($historyData | Measure-Object).Count
        $stMfrCounts.GetEnumerator() | Sort-Object { $_.Value.Total } -Descending | ForEach-Object {
            @{ name=$_.Key; total=$_.Value.Total; updated=$_.Value.Updated; highConf=$_.Value.HighConf; actionReq=$_.Value.ActionReq }
        } | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $dataDir "manufacturers.json") -Encoding UTF8
        
        # Convert JSON data files to CSV for human-readable Excel downloads
        Write-Log "Converting device data to CSV for Excel download..." -ForegroundColor Gray
        foreach ($dfName in $stDeviceFiles) {
            $jsonFile = Join-Path $dataDir "$dfName.json"
            $csvFile = Join-Path $OutputPath "SecureBoot_${dfName}_$timestamp.csv"
            if (Test-Path $jsonFile) {
                try {
                    $jsonData = Get-Content $jsonFile -Raw | ConvertFrom-Json
                    if ($jsonData.Count -gt 0) {
                        # Include extra columns for update_pending CSV
                        $selectProps = if ($dfName -eq "update_pending") {
                            @('HostName', 'WMI_Manufacturer', 'WMI_Model', 'BucketId', 'ConfidenceLevel', 'IsUpdated', 'UEFICA2023Status', 'UEFICA2023Error', 'AvailableUpdatesPolicy', 'WinCSKeyApplied', 'WinCSKeyStatus', 'SecureBootTaskStatus')
                        } else {
                            @('HostName', 'WMI_Manufacturer', 'WMI_Model', 'BucketId', 'ConfidenceLevel', 'IsUpdated', 'UEFICA2023Error', 'SecureBootTaskStatus', 'KnownIssueId', 'SkipReasonKnownIssue')
                        }
                        $jsonData | Select-Object $selectProps |
                            Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
                        Write-Log "   $dfName -> $($jsonData.Count) rows -> CSV" -ForegroundColor DarkGray
                    }
                } catch { Write-Log "   $dfName - skipped" -ForegroundColor DarkYellow }
            }
        }
        
        # Generate self-contained HTML dashboard
        $htmlPath = Join-Path $OutputPath "SecureBoot_Dashboard_$timestamp.html"
        Write-Log "Generating self-contained HTML dashboard..." -ForegroundColor Yellow
        
        # VELOCITY PROJECTION: Calculate from scan history or previous summary
        $stDeadline = [datetime]"2026-06-24"  # KEK cert expiry
        $stDaysToDeadline = [math]::Max(0, ($stDeadline - (Get-Date)).Days)
        $stDevicesPerDay = 0
        $stProjectedDate = $null
        $stVelocitySource = "N/A"
        $stWorkingDays = 0
        $stCalendarDays = 0
        
        # Try trend history first (lightweight, already maintained by aggregator — replaces bloated ScanHistory.json)
        if ($historyData.Count -ge 2) {
            $validHistory = @($historyData | Where-Object { [int]$_.Total -gt 0 -and [int]$_.Updated -ge 0 })
            if ($validHistory.Count -ge 2) {
                $prev = $validHistory[-2]; $curr = $validHistory[-1]
                $prevDate = [datetime]::Parse($prev.Date.Substring(0, [Math]::Min(10, $prev.Date.Length)))
                $currDate = [datetime]::Parse($curr.Date.Substring(0, [Math]::Min(10, $curr.Date.Length)))
                $daysDiff = ($currDate - $prevDate).TotalDays
                if ($daysDiff -gt 0) {
                    $updDiff = [int]$curr.Updated - [int]$prev.Updated
                    if ($updDiff -gt 0) {
                        $stDevicesPerDay = [math]::Round($updDiff / $daysDiff, 0)
                        $stVelocitySource = "TrendHistory"
                    }
                }
            }
        }
        
        # Try orchestrator rollout summary (has pre-computed velocity)
        if ($stVelocitySource -eq "N/A" -and $RolloutSummaryPath -and (Test-Path $RolloutSummaryPath)) {
            try {
                $rolloutSummary = Get-Content $RolloutSummaryPath -Raw | ConvertFrom-Json
                if ($rolloutSummary.DevicesPerDay -and [double]$rolloutSummary.DevicesPerDay -gt 0) {
                    $stDevicesPerDay = [math]::Round([double]$rolloutSummary.DevicesPerDay, 1)
                    $stVelocitySource = "Orchestrator"
                    if ($rolloutSummary.ProjectedCompletionDate) {
                        $stProjectedDate = $rolloutSummary.ProjectedCompletionDate
                    }
                    if ($rolloutSummary.WorkingDaysRemaining) { $stWorkingDays = [int]$rolloutSummary.WorkingDaysRemaining }
                    if ($rolloutSummary.CalendarDaysRemaining) { $stCalendarDays = [int]$rolloutSummary.CalendarDaysRemaining }
                }
            } catch { }
        }
        
        # Fallback: try previous summary CSV (search current folder AND parent/sibling aggregation folders)
        if ($stVelocitySource -eq "N/A") {
            $searchPaths = @(
                (Join-Path $OutputPath "SecureBoot_Summary_*.csv")
            )
            # Also search sibling aggregation folders (orchestrator creates new folder each run)
            $parentPath = Split-Path $OutputPath -Parent
            if ($parentPath) {
                $searchPaths += (Join-Path $parentPath "Aggregation_*\SecureBoot_Summary_*.csv")
                $searchPaths += (Join-Path $parentPath "SecureBoot_Summary_*.csv")
            }
            $prevSummary = $searchPaths | ForEach-Object { Get-ChildItem $_ -EA SilentlyContinue } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($prevSummary) {
                try {
                    $prevStats = Get-Content $prevSummary.FullName | ConvertFrom-Csv
                    $prevDate = [datetime]$prevStats.ReportGeneratedAt
                    $daysSinceLast = ((Get-Date) - $prevDate).TotalDays
                    if ($daysSinceLast -gt 0.01) {
                        $prevUpdated = [int]$prevStats.Updated
                        $updDelta = $c.Updated - $prevUpdated
                        if ($updDelta -gt 0) {
                            $stDevicesPerDay = [math]::Round($updDelta / $daysSinceLast, 0)
                            $stVelocitySource = "PreviousReport"
                        }
                    }
                } catch { }
            }
        }
        
        # Fallback: calculate velocity from full trend history span (first vs latest data point)
        if ($stVelocitySource -eq "N/A" -and $historyData.Count -ge 2) {
            $validHistory = @($historyData | Where-Object { [int]$_.Total -gt 0 -and [int]$_.Updated -ge 0 })
            if ($validHistory.Count -ge 2) {
                $first = $validHistory[0]
                $last = $validHistory[-1]
                $firstDate = [datetime]::Parse($first.Date.Substring(0, [Math]::Min(10, $first.Date.Length)))
                $lastDate = [datetime]::Parse($last.Date.Substring(0, [Math]::Min(10, $last.Date.Length)))
                $daysDiff = ($lastDate - $firstDate).TotalDays
                if ($daysDiff -gt 0) {
                    $updDiff = [int]$last.Updated - [int]$first.Updated
                    if ($updDiff -gt 0) {
                        $stDevicesPerDay = [math]::Round($updDiff / $daysDiff, 1)
                        $stVelocitySource = "TrendHistory"
                    }
                }
            }
        }
        
        # Calculate projection using exponential doubling (consistent with trend chart)
        # Reuse the projection data already computed for the chart if available
        if ($hasProjection -and $projDates.Count -gt 0) {
            # Use the last projected date (when all devices are updated)
            $lastProjDateStr = $projDates[-1] -replace "'", ""
            $stProjectedDate = ([datetime]::Parse($lastProjDateStr)).ToString("MMM dd, yyyy")
            $stCalendarDays = ([datetime]::Parse($lastProjDateStr) - (Get-Date)).Days
            $stWorkingDays = 0
            $d = Get-Date
            for ($i = 0; $i -lt $stCalendarDays; $i++) {
                $d = $d.AddDays(1)
                if ($d.DayOfWeek -ne 'Saturday' -and $d.DayOfWeek -ne 'Sunday') { $stWorkingDays++ }
            }
        } elseif ($stDevicesPerDay -gt 0 -and $stNotUptodate -gt 0) {
            # Fallback: linear projection if no exponential data available
            $daysNeeded = [math]::Ceiling($stNotUptodate / $stDevicesPerDay)
            $stProjectedDate = (Get-Date).AddDays($daysNeeded).ToString("MMM dd, yyyy")
            $stWorkingDays = 0; $stCalendarDays = $daysNeeded
            $d = Get-Date
            for ($i = 0; $i -lt $daysNeeded; $i++) {
                $d = $d.AddDays(1)
                if ($d.DayOfWeek -ne 'Saturday' -and $d.DayOfWeek -ne 'Sunday') { $stWorkingDays++ }
            }
        }
        
        # Build velocity HTML
        $velocityHtml = if ($stDevicesPerDay -gt 0) {
            "<div><strong>&#128640; Devices/Day:</strong> $($stDevicesPerDay.ToString('N0')) (source: $stVelocitySource)</div>" +
            "<div style='font-size:.8em;color:#888'>Deadline: Jun 24, 2026 (KEK certificate expiry) | Days remaining: $stDaysToDeadline</div>"
        } else {
            "<div style='padding:8px;background:#fff3cd;border-radius:4px;border-left:3px solid #ffc107'>" +
            "<strong>&#128197; Projected Completion:</strong> Insufficient data for velocity calculation. " +
            "Run aggregation at least twice with data changes to establish a rate.<br/>" +
            "<strong>Deadline:</strong> Jun 24, 2026 (KEK certificate expiry) | <strong>Days remaining:</strong> $stDaysToDeadline</div>"
        }
        
        # Cert expiry countdown
        $certToday = Get-Date
        $certKekExpiry = [datetime]"2026-06-24"
        $certUefiExpiry = [datetime]"2026-06-27"
        $certPcaExpiry = [datetime]"2026-10-19"
        $daysToKek = [math]::Max(0, ($certKekExpiry - $certToday).Days)
        $daysToUefi = [math]::Max(0, ($certUefiExpiry - $certToday).Days)
        $daysToPca = [math]::Max(0, ($certPcaExpiry - $certToday).Days)
        $certUrgency = if ($daysToKek -lt 30) { '#dc3545' } elseif ($daysToKek -lt 90) { '#fd7e14' } else { '#28a745' }
        
        # Helper: Read records from JSON, build bucket summary + first N device rows
        $maxInlineRows = 200
        function Build-InlineTable {
            param([string]$JsonPath, [int]$MaxRows = 200, [string]$CsvFileName = "")
            $bucketSummary = ""
            $deviceRows = ""
            $totalCount = 0
            if (Test-Path $JsonPath) {
                try {
                    $data = Get-Content $JsonPath -Raw | ConvertFrom-Json
                    $totalCount = $data.Count
                    
                    # BUCKET SUMMARY: Group by BucketId, show counts per bucket with Updated from global bucket stats
                    if ($totalCount -gt 0) {
                        $buckets = $data | Group-Object BucketId | Sort-Object Count -Descending
                        $bucketSummary = "<h3 style='font-size:.95em;color:#333;margin:10px 0 5px'>By Hardware Bucket ($($buckets.Count) buckets)</h3>"
                        $bucketSummary += "<div style='max-height:300px;overflow-y:auto;margin-bottom:15px'><table><thead><tr><th>BucketID</th><th style='text-align:right'>Total</th><th style='text-align:right;color:#28a745'>Updated</th><th style='text-align:right;color:#dc3545'>Not Updated</th><th>Manufacturer</th></tr></thead><tbody>"
                        foreach ($b in $buckets) {
                            $bid = if ($b.Name) { $b.Name } else { "(empty)" }
                            $mfr = ($b.Group | Select-Object -First 1).WMI_Manufacturer
                            # Get Updated count from global bucket stats (all devices in this bucket across the entire dataset)
                            $lookupKey = $bid
                            $globalBucket = if ($stAllBuckets.ContainsKey($lookupKey)) { $stAllBuckets[$lookupKey] } else { $null }
                            $bUpdatedGlobal = if ($globalBucket) { $globalBucket.Updated } else { 0 }
                            $bTotalGlobal = if ($globalBucket) { $globalBucket.Count } else { $b.Count }
                            $bNotUpdatedGlobal = $bTotalGlobal - $bUpdatedGlobal
                            $bucketSummary += "<tr><td style='font-size:.8em'>$bid</td><td style='text-align:right;font-weight:bold'>$bTotalGlobal</td><td style='text-align:right;color:#28a745;font-weight:bold'>$bUpdatedGlobal</td><td style='text-align:right;color:#dc3545;font-weight:bold'>$bNotUpdatedGlobal</td><td>$mfr</td></tr>`n"
                        }
                        $bucketSummary += "</tbody></table></div>"
                    }
                    
                    # DEVICE DETAIL: First N rows as flat list
                    $slice = $data | Select-Object -First $MaxRows
                    foreach ($d in $slice) {
                        $conf = $d.ConfidenceLevel
                        $confBadge = if ($conf -match "High") { '<span class="badge badge-success">High Conf</span>' }
                                     elseif ($conf -match "Not Sup") { '<span class="badge badge-danger">Not Supported</span>' }
                                     elseif ($conf -match "Under") { '<span class="badge badge-info">Under Obs</span>' }
                                     elseif ($conf -match "Paused") { '<span class="badge badge-warning">Paused</span>' }
                                     else { '<span class="badge badge-warning">Action Req</span>' }
                        $statusBadge = if ($d.IsUpdated) { '<span class="badge badge-success">Updated</span>' }
                                       elseif ($d.UEFICA2023Error) { '<span class="badge badge-danger">Error</span>' }
                                       else { '<span class="badge badge-warning">Pending</span>' }
                        $deviceRows += "<tr><td>$($d.HostName)</td><td>$($d.WMI_Manufacturer)</td><td>$($d.WMI_Model)</td><td>$confBadge</td><td>$statusBadge</td><td>$(if($d.UEFICA2023Error){$d.UEFICA2023Error}else{'-'})</td><td style='font-size:.75em'>$($d.BucketId)</td></tr>`n"
                    }
                } catch { }
            }
            if ($totalCount -eq 0) {
                return "<div style='padding:20px;color:#888;font-style:italic'>No devices in this category.</div>"
            }
            $showing = [math]::Min($MaxRows, $totalCount)
            $header = "<div style='margin:5px 0;font-size:.85em;color:#666'>Total: $($totalCount.ToString("N0")) devices"
            if ($CsvFileName) { $header += " | <a href='$CsvFileName' style='color:#1a237e;font-weight:bold'>&#128196; Download Full CSV for Excel</a>" }
            $header += "</div>"
            $deviceHeader = "<h3 style='font-size:.95em;color:#333;margin:10px 0 5px'>Device Details (showing first $showing)</h3>"
            $deviceTable = "<div style='max-height:500px;overflow-y:auto'><table><thead><tr><th>HostName</th><th>Manufacturer</th><th>Model</th><th>Confidence</th><th>Status</th><th>Error</th><th>BucketId</th></tr></thead><tbody>$deviceRows</tbody></table></div>"
            return "$header$bucketSummary$deviceHeader$deviceTable"
        }
        
        # Build inline tables from the JSON files already on disk, linking to CSVs
        $tblErrors = Build-InlineTable -JsonPath (Join-Path $dataDir "errors.json") -MaxRows $maxInlineRows -CsvFileName "SecureBoot_errors_$timestamp.csv"
        $tblKI = Build-InlineTable -JsonPath (Join-Path $dataDir "known_issues.json") -MaxRows $maxInlineRows -CsvFileName "SecureBoot_known_issues_$timestamp.csv"
        $tblKEK = Build-InlineTable -JsonPath (Join-Path $dataDir "missing_kek.json") -MaxRows $maxInlineRows -CsvFileName "SecureBoot_missing_kek_$timestamp.csv"
        $tblNotUpd = Build-InlineTable -JsonPath (Join-Path $dataDir "not_updated.json") -MaxRows $maxInlineRows -CsvFileName "SecureBoot_not_updated_$timestamp.csv"
        $tblTaskDis = Build-InlineTable -JsonPath (Join-Path $dataDir "task_disabled.json") -MaxRows $maxInlineRows -CsvFileName "SecureBoot_task_disabled_$timestamp.csv"
        $tblTemp = Build-InlineTable -JsonPath (Join-Path $dataDir "temp_failures.json") -MaxRows $maxInlineRows -CsvFileName "SecureBoot_temp_failures_$timestamp.csv"
        $tblPerm = Build-InlineTable -JsonPath (Join-Path $dataDir "perm_failures.json") -MaxRows $maxInlineRows -CsvFileName "SecureBoot_perm_failures_$timestamp.csv"
        $tblUpdated = Build-InlineTable -JsonPath (Join-Path $dataDir "updated_devices.json") -MaxRows $maxInlineRows -CsvFileName "SecureBoot_updated_devices_$timestamp.csv"
        $tblActionReq = Build-InlineTable -JsonPath (Join-Path $dataDir "action_required.json") -MaxRows $maxInlineRows -CsvFileName "SecureBoot_action_required_$timestamp.csv"
        $tblUnderObs = Build-InlineTable -JsonPath (Join-Path $dataDir "under_observation.json") -MaxRows $maxInlineRows -CsvFileName "SecureBoot_under_observation_$timestamp.csv"
        $tblNeedsReboot = Build-InlineTable -JsonPath (Join-Path $dataDir "needs_reboot.json") -MaxRows $maxInlineRows -CsvFileName "SecureBoot_needs_reboot_$timestamp.csv"
        $tblSBOff = Build-InlineTable -JsonPath (Join-Path $dataDir "secureboot_off.json") -MaxRows $maxInlineRows -CsvFileName "SecureBoot_secureboot_off_$timestamp.csv"
        $tblRolloutIP = Build-InlineTable -JsonPath (Join-Path $dataDir "rollout_inprogress.json") -MaxRows $maxInlineRows -CsvFileName "SecureBoot_rollout_inprogress_$timestamp.csv"
        # Custom table for Update Pending — includes UEFICA2023Status and UEFICA2023Error columns
        $tblUpdatePending = ""
        $upJsonPath = Join-Path $dataDir "update_pending.json"
        if (Test-Path $upJsonPath) {
            try {
                $upData = Get-Content $upJsonPath -Raw | ConvertFrom-Json
                $upCount = $upData.Count
                if ($upCount -gt 0) {
                    $upHeader = "<div style='margin:5px 0;font-size:.85em;color:#666'>Total: $($upCount.ToString("N0")) devices | <a href='SecureBoot_update_pending_$timestamp.csv' style='color:#1a237e;font-weight:bold'>&#128196; Download Full CSV for Excel</a></div>"
                    $upRows = ""
                    $upSlice = $upData | Select-Object -First $maxInlineRows
                    foreach ($d in $upSlice) {
                        $uefiSt = if ($d.UEFICA2023Status) { $d.UEFICA2023Status } else { '<span style="color:#999">null</span>' }
                        $uefiErr = if ($d.UEFICA2023Error) { "<span style='color:#dc3545'>$($d.UEFICA2023Error)</span>" } else { '-' }
                        $policyVal = if ($d.AvailableUpdatesPolicy) { $d.AvailableUpdatesPolicy } else { '-' }
                        $wincsVal = if ($d.WinCSKeyApplied) { '<span class="badge badge-success">Yes</span>' } else { '-' }
                        $upRows += "<tr><td>$($d.HostName)</td><td>$($d.WMI_Manufacturer)</td><td>$($d.WMI_Model)</td><td>$uefiSt</td><td>$uefiErr</td><td>$policyVal</td><td>$wincsVal</td><td style='font-size:.75em'>$($d.BucketId)</td></tr>`n"
                    }
                    $upShowing = [math]::Min($maxInlineRows, $upCount)
                    $upDevHeader = "<h3 style='font-size:.95em;color:#333;margin:10px 0 5px'>Device Details (showing first $upShowing)</h3>"
                    $upTable = "<div style='max-height:500px;overflow-y:auto'><table><thead><tr><th>HostName</th><th>Manufacturer</th><th>Model</th><th>UEFICA2023Status</th><th>UEFICA2023Error</th><th>Policy</th><th>WinCS Key</th><th>BucketId</th></tr></thead><tbody>$upRows</tbody></table></div>"
                    $tblUpdatePending = "$upHeader$upDevHeader$upTable"
                } else {
                    $tblUpdatePending = "<div style='padding:20px;color:#888;font-style:italic'>No devices in this category.</div>"
                }
            } catch {
                $tblUpdatePending = "<div style='padding:20px;color:#888;font-style:italic'>No devices in this category.</div>"
            }
        } else {
            $tblUpdatePending = "<div style='padding:20px;color:#888;font-style:italic'>No devices in this category.</div>"
        }
        
        # Cert expiry countdown
        $certToday = Get-Date
        $certKekExpiry = [datetime]"2026-06-24"
        $certUefiExpiry = [datetime]"2026-06-27"
        $certPcaExpiry = [datetime]"2026-10-19"
        $daysToKek = [math]::Max(0, ($certKekExpiry - $certToday).Days)
        $daysToUefi = [math]::Max(0, ($certUefiExpiry - $certToday).Days)
        $daysToPca = [math]::Max(0, ($certPcaExpiry - $certToday).Days)
        $certUrgency = if ($daysToKek -lt 30) { '#dc3545' } elseif ($daysToKek -lt 90) { '#fd7e14' } else { '#28a745' }
        
        # Build manufacturer chart data inline (Top 10 by device count)
        $mfrSorted = $stMfrCounts.GetEnumerator() | Sort-Object { $_.Value.Total } -Descending | Select-Object -First 10
        $mfrChartTitle = if ($stMfrCounts.Count -le 10) { "By Manufacturer" } else { "Top 10 Manufacturers" }
        $mfrLabels = ($mfrSorted | ForEach-Object { "'$($_.Key)'" }) -join ","
        $mfrUpdated = ($mfrSorted | ForEach-Object { $_.Value.Updated }) -join ","
        $mfrUpdatePending = ($mfrSorted | ForEach-Object { $_.Value.UpdatePending }) -join ","
        $mfrHighConf = ($mfrSorted | ForEach-Object { $_.Value.HighConf }) -join ","
        $mfrUnderObs = ($mfrSorted | ForEach-Object { $_.Value.UnderObs }) -join ","
        $mfrActionReq = ($mfrSorted | ForEach-Object { $_.Value.ActionReq }) -join ","
        $mfrTempPaused = ($mfrSorted | ForEach-Object { $_.Value.TempPaused }) -join ","
        $mfrNotSupported = ($mfrSorted | ForEach-Object { $_.Value.NotSupported }) -join ","
        $mfrSBOff = ($mfrSorted | ForEach-Object { $_.Value.SBOff }) -join ","
        $mfrWithErrors = ($mfrSorted | ForEach-Object { $_.Value.WithErrors }) -join ","
        
        # Build manufacturer table
        $mfrTableRows = ""
        $stMfrCounts.GetEnumerator() | Sort-Object { $_.Value.Total } -Descending | ForEach-Object {
            $mfrTableRows += "<tr><td>$($_.Key)</td><td>$($_.Value.Total.ToString("N0"))</td><td>$($_.Value.Updated.ToString("N0"))</td><td>$($_.Value.HighConf.ToString("N0"))</td><td>$($_.Value.ActionReq.ToString("N0"))</td></tr>`n"
        }
        
        # HTML close-tag fragments: broken into parts so web CMS platforms don't
        # interpret them as real HTML and inject invisible Unicode characters around them.
        $endScript = '</scr' + 'ipt>'
        $endStyle = '</sty' + 'le>'
        $endHead = '</he' + 'ad>'
        $endBody = '</bo' + 'dy>'
        $endHtml = '</ht' + 'ml>'
        
        $htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Secure Boot Certificate Status Dashboard</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js">$endScript
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',Tahoma,sans-serif;background:#f0f2f5;color:#333}
.header{background:linear-gradient(135deg,#1a237e,#0d47a1);color:#fff;padding:20px 30px}
.header h1{font-size:1.6em;margin-bottom:5px}
.header .meta{font-size:.85em;opacity:.9}
.container{max-width:1400px;margin:0 auto;padding:20px}
.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:12px;margin:20px 0}
.card{background:#fff;border-radius:10px;padding:15px;box-shadow:0 2px 8px rgba(0,0,0,.08);border-left:4px solid #ccc;transition:transform .2s}
.card:hover{transform:translateY(-2px);box-shadow:0 4px 15px rgba(0,0,0,.12)}
.card .value{font-size:1.8em;font-weight:700}
.card .label{font-size:.8em;color:#666;margin-top:4px}
.card .pct{font-size:.75em;color:#888}
.section{background:#fff;border-radius:10px;padding:20px;margin:15px 0;box-shadow:0 2px 8px rgba(0,0,0,.08)}
.section h2{font-size:1.2em;color:#1a237e;margin-bottom:10px;cursor:pointer;user-select:none}
.section h2:hover{text-decoration:underline}
.section-body{display:none}
.section-body.open{display:block}
.charts{display:grid;grid-template-columns:1fr 1fr;gap:20px;margin:20px 0}
.chart-box{background:#fff;border-radius:10px;padding:20px;box-shadow:0 2px 8px rgba(0,0,0,.08)}
table{width:100%;border-collapse:collapse;font-size:.85em}
th{background:#e8eaf6;padding:8px 10px;text-align:left;position:sticky;top:0;z-index:1}
td{padding:6px 10px;border-bottom:1px solid #eee}
tr:hover{background:#f5f5f5}
.badge{display:inline-block;padding:2px 8px;border-radius:10px;font-size:.75em;font-weight:700}
.badge-success{background:#d4edda;color:#155724}
.badge-danger{background:#f8d7da;color:#721c24}
.badge-warning{background:#fff3cd;color:#856404}
.badge-info{background:#d1ecf1;color:#0c5460}
.top-link{float:right;font-size:.8em;color:#1a237e;text-decoration:none}
.footer{text-align:center;padding:20px;color:#999;font-size:.8em}
a{color:#1a237e}
$endStyle
$endHead
<body>
<div class="header">
    <h1>Secure Boot Certificate Status Dashboard</h1>
    <div class="meta">Generated: $($stats.ReportGeneratedAt) | Total Devices: $($c.Total.ToString("N0")) | Unique Buckets: $($stAllBuckets.Count)</div>
</div>
<div class="container">

<!-- KPI Cards - clickable, linked to sections -->
<div class="cards">
    <a class="card" href="#s-nu" onclick="openSection('d-nu')" style="border-left-color:#dc3545;text-decoration:none;position:relative"><div style="position:absolute;top:8px;right:8px;background:#dc3545;color:#fff;padding:1px 6px;border-radius:8px;font-size:.65em;font-weight:700">PRIMARY</div><div class="value" style="color:#dc3545">$($stNotUptodate.ToString("N0"))</div><div class="label">NOT UPDATED</div><div class="pct">$($stats.PercentNotUptodate)% - NEEDS ACTION</div></a>
    <a class="card" href="#s-upd" onclick="openSection('d-upd')" style="border-left-color:#28a745;text-decoration:none;position:relative"><div style="position:absolute;top:8px;right:8px;background:#28a745;color:#fff;padding:1px 6px;border-radius:8px;font-size:.65em;font-weight:700">PRIMARY</div><div class="value" style="color:#28a745">$($c.Updated.ToString("N0"))</div><div class="label">Updated</div><div class="pct">$($stats.PercentCertUpdated)%</div></a>
    <a class="card" href="#s-sboff" onclick="openSection('d-sboff')" style="border-left-color:#6c757d;text-decoration:none;position:relative"><div style="position:absolute;top:8px;right:8px;background:#6c757d;color:#fff;padding:1px 6px;border-radius:8px;font-size:.65em;font-weight:700">PRIMARY</div><div class="value">$($c.SBOff.ToString("N0"))</div><div class="label">SecureBoot OFF</div><div class="pct">$(if($c.Total -gt 0){[math]::Round(($c.SBOff/$c.Total)*100,1)}else{0})% - Out of Scope</div></a>
    <a class="card" href="#s-nrb" onclick="openSection('d-nrb')" style="border-left-color:#ffc107;text-decoration:none"><div class="value" style="color:#ffc107">$($c.NeedsReboot.ToString("N0"))</div><div class="label">Needs Reboot</div><div class="pct">$(if($c.Total -gt 0){[math]::Round(($c.NeedsReboot/$c.Total)*100,1)}else{0})% - awaiting reboot</div></a>
    <a class="card" href="#s-upd-pend" onclick="openSection('d-upd-pend')" style="border-left-color:#6f42c1;text-decoration:none"><div class="value" style="color:#6f42c1">$($c.UpdatePending.ToString("N0"))</div><div class="label">Update Pending</div><div class="pct">$(if($c.Total -gt 0){[math]::Round(($c.UpdatePending/$c.Total)*100,1)}else{0})% - Policy/WinCS applied, awaiting update</div></a>
    <a class="card" href="#s-rip" onclick="openSection('d-rip')" style="border-left-color:#17a2b8;text-decoration:none"><div class="value">$($c.RolloutInProgress)</div><div class="label">Rollout In Progress</div><div class="pct">$(if($c.Total -gt 0){[math]::Round(($c.RolloutInProgress/$c.Total)*100,1)}else{0})%</div></a>
    <a class="card" href="#s-nu" onclick="openSection('d-nu')" style="border-left-color:#28a745;text-decoration:none"><div class="value" style="color:#28a745">$($c.HighConf.ToString("N0"))</div><div class="label">High Confidence</div><div class="pct">$($stats.PercentHighConfidence)% - Safe for rollout</div></a>
    <a class="card" href="#s-uo" onclick="openSection('d-uo')" style="border-left-color:#17a2b8;text-decoration:none"><div class="value" style="color:#ffc107">$($c.UnderObs.ToString("N0"))</div><div class="label">Under Observation</div><div class="pct">$(if($c.Total -gt 0){[math]::Round(($c.UnderObs/$c.Total)*100,1)}else{0})%</div></a>
    <a class="card" href="#s-ar" onclick="openSection('d-ar')" style="border-left-color:#fd7e14;text-decoration:none"><div class="value" style="color:#fd7e14">$($c.ActionReq.ToString("N0"))</div><div class="label">Action Required</div><div class="pct">$($stats.PercentActionRequired)% - must test</div></a>
    <a class="card" href="#s-err" onclick="openSection('d-err')" style="border-left-color:#dc3545;text-decoration:none"><div class="value" style="color:#dc3545">$($stAtRisk.ToString("N0"))</div><div class="label">At Risk</div><div class="pct">$($stats.PercentAtRisk)% - Similar to failed</div></a>
    <a class="card" href="#s-td" onclick="openSection('d-td')" style="border-left-color:#dc3545;text-decoration:none"><div class="value" style="color:#dc3545">$($c.TaskDisabled.ToString("N0"))</div><div class="label">Task Disabled</div><div class="pct">$(if($c.Total -gt 0){[math]::Round(($c.TaskDisabled/$c.Total)*100,1)}else{0})% - Blocked</div></a>
    <a class="card" href="#s-tf" onclick="openSection('d-tf')" style="border-left-color:#fd7e14;text-decoration:none"><div class="value" style="color:#fd7e14">$($c.TempPaused.ToString("N0"))</div><div class="label">Temp. Paused</div><div class="pct">$(if($c.Total -gt 0){[math]::Round(($c.TempPaused/$c.Total)*100,1)}else{0})%</div></a>
    <a class="card" href="#s-ki" onclick="openSection('d-ki')" style="border-left-color:#dc3545;text-decoration:none"><div class="value" style="color:#dc3545">$($c.WithKnownIssues.ToString("N0"))</div><div class="label">Known Issues</div><div class="pct">$(if($c.Total -gt 0){[math]::Round(($c.WithKnownIssues/$c.Total)*100,1)}else{0})%</div></a>
    <a class="card" href="#s-kek" onclick="openSection('d-kek')" style="border-left-color:#fd7e14;text-decoration:none"><div class="value" style="color:#fd7e14">$($c.WithMissingKEK.ToString("N0"))</div><div class="label">Missing KEK</div><div class="pct">$(if($c.Total -gt 0){[math]::Round(($c.WithMissingKEK/$c.Total)*100,1)}else{0})%</div></a>
    <a class="card" href="#s-err" onclick="openSection('d-err')" style="border-left-color:#dc3545;text-decoration:none"><div class="value" style="color:#dc3545">$($c.WithErrors.ToString("N0"))</div><div class="label">With Errors</div><div class="pct">$($stats.PercentWithErrors)% - UEFI errors</div></a>
    <a class="card" href="#s-tf" onclick="openSection('d-tf')" style="border-left-color:#dc3545;text-decoration:none"><div class="value" style="color:#dc3545">$($c.TempFailures.ToString("N0"))</div><div class="label">Temp. Failures</div><div class="pct">$(if($c.Total -gt 0){[math]::Round(($c.TempFailures/$c.Total)*100,1)}else{0})%</div></a>
    <a class="card" href="#s-pf" onclick="openSection('d-pf')" style="border-left-color:#721c24;text-decoration:none"><div class="value" style="color:#721c24">$($c.PermFailures.ToString("N0"))</div><div class="label">Not Supported</div><div class="pct">$(if($c.Total -gt 0){[math]::Round(($c.PermFailures/$c.Total)*100,1)}else{0})%</div></a>
</div>

<!-- Deployment Velocity & Cert Expiry -->
<div id="s-velocity" style="display:grid;grid-template-columns:1fr 1fr;gap:20px;margin:15px 0">
<div class="section" style="margin:0">
    <h2>&#128197; Deployment Velocity</h2>
    <div class="section-body open">
        <div style="font-size:2.5em;font-weight:700;color:#28a745">$($c.Updated.ToString("N0"))</div>
        <div style="color:#666">devices updated out of $($c.Total.ToString("N0"))</div>
        <div style="margin:10px 0;background:#e8eaf6;height:20px;border-radius:10px;overflow:hidden"><div style="background:#28a745;height:100%;width:$($stats.PercentCertUpdated)%;border-radius:10px"></div></div>
        <div style="font-size:.8em;color:#888">$($stats.PercentCertUpdated)% complete</div>
        <div style="margin-top:10px;padding:10px;background:#f8f9fa;border-radius:8px;font-size:.85em">
            <div><strong>Remaining:</strong> $($stNotUptodate.ToString("N0")) devices need action</div>
            <div><strong>Blocking:</strong> $($c.WithErrors + $c.PermFailures + $c.TaskDisabledNotUpdated) devices (errors + permanent + task disabled)</div>
            <div><strong>Safe to deploy:</strong> $($stSafeList.ToString("N0")) devices (same bucket as successful)</div>
            $velocityHtml
        </div>
    </div>
</div>
<div class="section" style="margin:0;border-left:4px solid #dc3545">
    <h2 style="color:#dc3545">&#9888; Certificate Expiry Countdown</h2>
    <div class="section-body open">
        <div style="display:flex;gap:15px;margin-top:10px">
            <div style="text-align:center;padding:15px;border-radius:8px;min-width:120px;background:linear-gradient(135deg,#fff5f5,#ffe0e0);border:2px solid #dc3545;flex:1">
                <div style="font-size:.65em;color:#721c24;text-transform:uppercase;font-weight:bold">&#9888; FIRST TO EXPIRE</div>
                <div style="font-size:.85em;font-weight:bold;color:#dc3545;margin:3px 0">KEK CA 2011</div>
                <div id="daysKek" style="font-size:2.5em;font-weight:700;color:#dc3545;line-height:1">$daysToKek</div>
                <div style="font-size:.8em;color:#721c24">days (Jun 24, 2026)</div>
            </div>
            <div style="text-align:center;padding:15px;border-radius:8px;min-width:120px;background:linear-gradient(135deg,#fffef5,#fff3cd);border:2px solid #ffc107;flex:1">
                <div style="font-size:.65em;color:#856404;text-transform:uppercase;font-weight:bold">UEFI CA 2011</div>
                <div id="daysUefi" style="font-size:2.2em;font-weight:700;color:#856404;line-height:1;margin:5px 0">$daysToUefi</div>
                <div style="font-size:.8em;color:#856404">days (Jun 27, 2026)</div>
            </div>
            <div style="text-align:center;padding:15px;border-radius:8px;min-width:120px;background:linear-gradient(135deg,#f0f8ff,#d4edff);border:2px solid #0078d4;flex:1">
                <div style="font-size:.65em;color:#0078d4;text-transform:uppercase;font-weight:bold">Windows PCA</div>
                <div id="daysPca" style="font-size:2.2em;font-weight:700;color:#0078d4;line-height:1;margin:5px 0">$daysToPca</div>
                <div style="font-size:.8em;color:#0078d4">days (Oct 19, 2026)</div>
            </div>
        </div>
        <div style="margin-top:15px;padding:10px;background:#f8d7da;border-radius:8px;font-size:.85em;border-left:4px solid #dc3545">
            <strong>&#9888; CRITICAL:</strong> All devices must be updated before certificate expiry. Devices not updated by the deadline cannot apply future Security updates for Boot Manager and Secure Boot after expiry.
        </div>
    </div>
</div>
</div>

<!-- Charts -->
<div class="charts">
    <div class="chart-box"><h3>Deployment Status</h3><canvas id="deployChart" height="200"></canvas></div>
    <div class="chart-box"><h3>$mfrChartTitle</h3><canvas id="mfrChart" height="200"></canvas></div>
</div>

$(if ($historyData.Count -ge 1) {
"<!-- Historical Trend Chart -->
<div class='section'>
    <h2 onclick=`"toggle('d-trend')`">&#128200; Update Progress Over Time <a class='top-link' href='#'>&#8593; Top</a></h2>
    <div id='d-trend' class='section-body open'>
        <canvas id='trendChart' height='120'></canvas>
        <div style='font-size:.75em;color:#888;margin-top:5px'>Solid lines = actual data$(if ($historyData.Count -ge 2) { " | Dashed line = projected (exponential doubling: 2&#x2192;4&#x2192;8&#x2192;16... devices per wave)" } else { " | Run aggregation again tomorrow to see trend lines and projection" })</div>
    </div>
</div>"
})

<!-- CSV Downloads -->
<div class="section">
    <h2 onclick="toggle('dl-csv')">&#128229; Download Full Data (CSV for Excel) <a class="top-link" href="#">Top</a></h2>
    <div id="dl-csv" class="section-body open" style="display:flex;flex-wrap:wrap;gap:5px">
        <a href="SecureBoot_not_updated_$timestamp.csv" style="display:inline-block;background:#dc3545;color:#fff;padding:6px 14px;border-radius:5px;text-decoration:none;font-size:.8em">Not Updated ($($stNotUptodate.ToString("N0")))</a>
        <a href="SecureBoot_errors_$timestamp.csv" style="display:inline-block;background:#dc3545;color:#fff;padding:6px 14px;border-radius:5px;text-decoration:none;font-size:.8em">Errors ($($c.WithErrors.ToString("N0")))</a>
        <a href="SecureBoot_action_required_$timestamp.csv" style="display:inline-block;background:#fd7e14;color:#fff;padding:6px 14px;border-radius:5px;text-decoration:none;font-size:.8em">Action Required ($($c.ActionReq.ToString("N0")))</a>
        <a href="SecureBoot_known_issues_$timestamp.csv" style="display:inline-block;background:#dc3545;color:#fff;padding:6px 14px;border-radius:5px;text-decoration:none;font-size:.8em">Known Issues ($($c.WithKnownIssues.ToString("N0")))</a>
        <a href="SecureBoot_task_disabled_$timestamp.csv" style="display:inline-block;background:#dc3545;color:#fff;padding:6px 14px;border-radius:5px;text-decoration:none;font-size:.8em">Task Disabled ($($c.TaskDisabled.ToString("N0")))</a>
        <a href="SecureBoot_updated_devices_$timestamp.csv" style="display:inline-block;background:#28a745;color:#fff;padding:6px 14px;border-radius:5px;text-decoration:none;font-size:.8em">Updated ($($c.Updated.ToString("N0")))</a>
        <a href="SecureBoot_Summary_$timestamp.csv" style="display:inline-block;background:#6c757d;color:#fff;padding:6px 14px;border-radius:5px;text-decoration:none;font-size:.8em">Summary</a>
        <div style="width:100%;font-size:.75em;color:#888;margin-top:5px">CSV files open in Excel. Available when hosted on web server.</div>
    </div>
</div>

<!-- Manufacturer Breakdown -->
<div class="section">
    <h2 onclick="toggle('mfr')">By Manufacturer <a class="top-link" href="#">Top</a></h2>
    <div id="mfr" class="section-body open">
    <table><thead><tr><th>Manufacturer</th><th>Total</th><th>Updated</th><th>High Confidence</th><th>Action Required</th></tr></thead>
    <tbody>$mfrTableRows</tbody></table>
    </div>
</div>

<!-- Device Sections (first 200 inline + CSV download) -->
<div class="section" id="s-err">
    <h2 onclick="toggle('d-err')">&#128308; Devices with Errors ($($c.WithErrors.ToString("N0"))) <a class="top-link" href="#">&#8593; Top</a></h2>
    <div id="d-err" class="section-body">$tblErrors</div>
</div>
<div class="section" id="s-ki">
    <h2 onclick="toggle('d-ki')" style="color:#dc3545">&#128308; Known Issues ($($c.WithKnownIssues.ToString("N0"))) <a class="top-link" href="#">&#8593; Top</a></h2>
    <div id="d-ki" class="section-body">$tblKI</div>
</div>
<div class="section" id="s-kek">
    <h2 onclick="toggle('d-kek')">&#128992; Missing KEK - Event 1803 ($($c.WithMissingKEK.ToString("N0"))) <a class="top-link" href="#">&#8593; Top</a></h2>
    <div id="d-kek" class="section-body">$tblKEK</div>
</div>
<div class="section" id="s-ar">
    <h2 onclick="toggle('d-ar')" style="color:#fd7e14">&#128992; Action Required ($($c.ActionReq.ToString("N0"))) <a class="top-link" href="#">&#8593; Top</a></h2>
    <div id="d-ar" class="section-body">$tblActionReq</div>
</div>
<div class="section" id="s-uo">
    <h2 onclick="toggle('d-uo')" style="color:#17a2b8">&#128309; Under Observation ($($c.UnderObs.ToString("N0"))) <a class="top-link" href="#">&#8593; Top</a></h2>
    <div id="d-uo" class="section-body">$tblUnderObs</div>
</div>
<div class="section" id="s-nu">
    <h2 onclick="toggle('d-nu')" style="color:#dc3545">&#128308; Not Updated ($($stNotUptodate.ToString("N0"))) <a class="top-link" href="#">&#8593; Top</a></h2>
    <div id="d-nu" class="section-body">$tblNotUpd</div>
</div>
<div class="section" id="s-td">
    <h2 onclick="toggle('d-td')" style="color:#dc3545">&#128308; Task Disabled ($($c.TaskDisabled.ToString("N0"))) <a class="top-link" href="#">&#8593; Top</a></h2>
    <div id="d-td" class="section-body">$tblTaskDis</div>
</div>
<div class="section" id="s-tf">
    <h2 onclick="toggle('d-tf')" style="color:#dc3545">&#128308; Temporary Failures ($($c.TempFailures.ToString("N0"))) <a class="top-link" href="#">&#8593; Top</a></h2>
    <div id="d-tf" class="section-body">$tblTemp</div>
</div>
<div class="section" id="s-pf">
    <h2 onclick="toggle('d-pf')" style="color:#721c24">&#128308; Permanent Failures / Not Supported ($($c.PermFailures.ToString("N0"))) <a class="top-link" href="#">&#8593; Top</a></h2>
    <div id="d-pf" class="section-body">$tblPerm</div>
</div>
<div class="section" id="s-upd-pend">
    <h2 onclick="toggle('d-upd-pend')" style="color:#6f42c1">&#9203; Update Pending ($($c.UpdatePending.ToString("N0"))) - Policy/WinCS Applied, Awaiting Update <a class="top-link" href="#">&#8593; Top</a></h2>
    <div id="d-upd-pend" class="section-body"><p style="color:#666;margin-bottom:10px">Devices where AvailableUpdatesPolicy or WinCS key is applied but UEFICA2023Status is still NotStarted, InProgress, or null.</p>$tblUpdatePending</div>
</div>
<div class="section" id="s-rip">
    <h2 onclick="toggle('d-rip')" style="color:#17a2b8">&#128309; Rollout In Progress ($($c.RolloutInProgress.ToString("N0"))) <a class="top-link" href="#">&#8593; Top</a></h2>
    <div id="d-rip" class="section-body">$tblRolloutIP</div>
</div>
<div class="section" id="s-sboff">
    <h2 onclick="toggle('d-sboff')" style="color:#6c757d">&#9899; SecureBoot OFF ($($c.SBOff.ToString("N0"))) - Out of Scope <a class="top-link" href="#">&#8593; Top</a></h2>
    <div id="d-sboff" class="section-body">$tblSBOff</div>
</div>
<div class="section" id="s-upd">
    <h2 onclick="toggle('d-upd')" style="color:#28a745">&#128994; Updated Devices ($($c.Updated.ToString("N0"))) <a class="top-link" href="#">&#8593; Top</a></h2>
    <div id="d-upd" class="section-body">$tblUpdated</div>
</div>
<div class="section" id="s-nrb">
    <h2 onclick="toggle('d-nrb')" style="color:#ffc107">&#128260; Updated - Needs Reboot ($($c.NeedsReboot.ToString("N0"))) <a class="top-link" href="#">&#8593; Top</a></h2>
    <div id="d-nrb" class="section-body">$tblNeedsReboot</div>
</div>

<div class="footer">Secure Boot Certificate Rollout Dashboard | Generated $($stats.ReportGeneratedAt) | StreamingMode | Peak Memory: ${stPeakMemMB} MB</div>
</div><!-- /container -->

<script>
function toggle(id){var e=document.getElementById(id);e.classList.toggle('open')}
function openSection(id){var e=document.getElementById(id);if(e&&!e.classList.contains('open')){e.classList.add('open')}}
new Chart(document.getElementById('deployChart'),{type:'doughnut',data:{labels:['Updated','Update Pending','High Confidence','Under Observation','Action Required','Temp. Paused','Not Supported','SecureBoot OFF','With Errors'],datasets:[{data:[$($c.Updated),$($c.UpdatePending),$($c.HighConf),$($c.UnderObs),$($c.ActionReq),$($c.TempPaused),$($c.NotSupported),$($c.SBOff),$($c.WithErrors)],backgroundColor:['#28a745','#6f42c1','#20c997','#17a2b8','#fd7e14','#6c757d','#721c24','#adb5bd','#dc3545']}]},options:{responsive:true,plugins:{legend:{position:'right',labels:{font:{size:11}}}}}});
new Chart(document.getElementById('mfrChart'),{type:'bar',data:{labels:[$mfrLabels],datasets:[{label:'Updated',data:[$mfrUpdated],backgroundColor:'#28a745'},{label:'Update Pending',data:[$mfrUpdatePending],backgroundColor:'#6f42c1'},{label:'High Confidence',data:[$mfrHighConf],backgroundColor:'#20c997'},{label:'Under Observation',data:[$mfrUnderObs],backgroundColor:'#17a2b8'},{label:'Action Required',data:[$mfrActionReq],backgroundColor:'#fd7e14'},{label:'Temp. Paused',data:[$mfrTempPaused],backgroundColor:'#6c757d'},{label:'Not Supported',data:[$mfrNotSupported],backgroundColor:'#721c24'},{label:'SecureBoot OFF',data:[$mfrSBOff],backgroundColor:'#adb5bd'},{label:'With Errors',data:[$mfrWithErrors],backgroundColor:'#dc3545'}]},options:{responsive:true,scales:{x:{stacked:true},y:{stacked:true}},plugins:{legend:{position:'top'}}}});
// Historical Trend Chart
if (document.getElementById('trendChart')) {
var allLabels = [$allChartLabels];
var actualUpdated = [$trendUpdated];
var actualNotUpdated = [$trendNotUpdated];
var actualTotal = [$trendTotal];
var projData = [$projDataJS];
var projNotUpdData = [$projNotUpdJS];
var histLen = actualUpdated.length;
var projLen = projData.length;
var paddedUpdated = actualUpdated.concat(Array(projLen).fill(null));
var paddedNotUpdated = actualNotUpdated.concat(Array(projLen).fill(null));
var paddedTotal = actualTotal.concat(Array(projLen).fill(null));
var projLine = Array(histLen).fill(null);
var projNotUpdLine = Array(histLen).fill(null);
if (projLen > 0) { projLine[histLen-1] = actualUpdated[histLen-1]; projLine = projLine.concat(projData); projNotUpdLine[histLen-1] = actualNotUpdated[histLen-1]; projNotUpdLine = projNotUpdLine.concat(projNotUpdData); }
var datasets = [
    {label:'Updated',data:paddedUpdated,borderColor:'#28a745',backgroundColor:'rgba(40,167,69,0.1)',fill:true,tension:0.3,borderWidth:2},
    {label:'Not Updated',data:paddedNotUpdated,borderColor:'#dc3545',backgroundColor:'rgba(220,53,69,0.1)',fill:true,tension:0.3,borderWidth:2},
    {label:'Total',data:paddedTotal,borderColor:'#6c757d',borderDash:[5,5],fill:false,tension:0,pointRadius:0,borderWidth:1}
];
if (projLen > 0) {
    datasets.push({label:'Projected Updated (2x doubling)',data:projLine,borderColor:'#28a745',borderDash:[8,4],borderWidth:3,fill:false,tension:0.3,pointRadius:3,pointStyle:'triangle'});
    datasets.push({label:'Projected Not Updated',data:projNotUpdLine,borderColor:'#dc3545',borderDash:[8,4],borderWidth:3,fill:false,tension:0.3,pointRadius:3,pointStyle:'triangle'});
}
new Chart(document.getElementById('trendChart'),{type:'line',data:{labels:allLabels,datasets:datasets},options:{responsive:true,scales:{y:{beginAtZero:true,title:{display:true,text:'Devices'}},x:{title:{display:true,text:'Date'}}},plugins:{legend:{position:'top'},title:{display:true,text:'Secure Boot Update Progress Over Time'}}}});
}
// Dynamic countdown
(function(){var t=new Date(),k=new Date('2026-06-24'),u=new Date('2026-06-27'),p=new Date('2026-10-19');var dk=document.getElementById('daysKek'),du=document.getElementById('daysUefi'),dp=document.getElementById('daysPca');if(dk)dk.textContent=Math.max(0,Math.ceil((k-t)/864e5));if(du)du.textContent=Math.max(0,Math.ceil((u-t)/864e5));if(dp)dp.textContent=Math.max(0,Math.ceil((p-t)/864e5))})();
$endScript
$endBody
$endHtml
"@
        [System.IO.File]::WriteAllText($htmlPath, $htmlContent, [System.Text.UTF8Encoding]::new($false))
        
        # Always keep a stable "Latest" copy so admins don't need to track timestamps
        $latestPath = Join-Path $OutputPath "SecureBoot_Dashboard_Latest.html"
        Copy-Item $htmlPath $latestPath -Force
        
        $stTotal = $streamSw.Elapsed.TotalSeconds
        
        # Save file manifest for incremental mode (quick no-change detection on next run)
        if ($IncrementalMode -or $StreamingMode) {
            $stManifestDir = Join-Path $OutputPath ".cache"
            if (-not (Test-Path $stManifestDir)) { New-Item -ItemType Directory -Path $stManifestDir -Force | Out-Null }
            $stManifestPath = Join-Path $stManifestDir "StreamingManifest.json"
            $stNewManifest = @{}
            Write-Log "Saving file manifest for incremental mode..." -ForegroundColor Gray
            foreach ($jf in $jsonFiles) {
                $stNewManifest[$jf.FullName.ToLowerInvariant()] = @{
                    LastWriteTimeUtc = $jf.LastWriteTimeUtc.ToString("o")
                    Size = $jf.Length
                }
            }
            Save-FileManifest -Manifest $stNewManifest -Path $stManifestPath
            Write-Log "   Saved manifest for $($stNewManifest.Count) files" -ForegroundColor DarkGray
        }
        
        # RETENTION CLEANUP
        # Orchestrator reusable folder (Aggregation_Current): keep only latest run (1)
        # Admin manual runs / other folders: keep last 7 runs
        # Summary CSVs are NEVER deleted — they're tiny (~1 KB) and are the backup source for trend history
        $outputLeaf = Split-Path $OutputPath -Leaf
        $retentionCount = if ($outputLeaf -eq 'Aggregation_Current') { 1 } else { 7 }
        # File prefixes safe to clean up (ephemeral per-run snapshots)
        $cleanupPrefixes = @(
            'SecureBoot_Dashboard_',
            'SecureBoot_action_required_',
            'SecureBoot_ByManufacturer_',
            'SecureBoot_ErrorCodes_',
            'SecureBoot_errors_',
            'SecureBoot_known_issues_',
            'SecureBoot_missing_kek_',
            'SecureBoot_needs_reboot_',
            'SecureBoot_not_updated_',
            'SecureBoot_secureboot_off_',
            'SecureBoot_task_disabled_',
            'SecureBoot_temp_failures_',
            'SecureBoot_perm_failures_',
            'SecureBoot_under_observation_',
            'SecureBoot_UniqueBuckets_',
            'SecureBoot_update_pending_',
            'SecureBoot_updated_devices_',
            'SecureBoot_rollout_inprogress_',
            'SecureBoot_NotUptodate_',
            'SecureBoot_Kusto_'
        )
        # Find all unique timestamps from cleanable files only
        $cleanableFiles = Get-ChildItem $OutputPath -File -EA SilentlyContinue |
            Where-Object { $f = $_.Name; ($cleanupPrefixes | Where-Object { $f.StartsWith($_) }).Count -gt 0 }
        $allTimestamps = @($cleanableFiles | ForEach-Object {
            if ($_.Name -match '(\d{8}-\d{6})') { $Matches[1] }
        } | Sort-Object -Unique -Descending)
        if ($allTimestamps.Count -gt $retentionCount) {
            $oldTimestamps = $allTimestamps | Select-Object -Skip $retentionCount
            $removedFiles = 0; $freedBytes = 0
            foreach ($oldTs in $oldTimestamps) {
                foreach ($prefix in $cleanupPrefixes) {
                    $oldFiles = Get-ChildItem $OutputPath -File -Filter "${prefix}${oldTs}*" -EA SilentlyContinue
                    foreach ($f in $oldFiles) {
                        $freedBytes += $f.Length
                        Remove-Item $f.FullName -Force -EA SilentlyContinue
                        $removedFiles++
                    }
                }
            }
            $freedMB = [math]::Round($freedBytes / 1MB, 1)
            Write-Log "Retention cleanup: removed $removedFiles files from $($oldTimestamps.Count) old runs, freed ${freedMB} MB (keeping last $retentionCount + all Summary/NotUptodate CSVs)" -ForegroundColor DarkGray
        }
        
        Write-Log "" "INFO"
        Write-Log ("=" * 60) "INFO" -ForegroundColor Cyan
        Write-Log "STREAMING AGGREGATION COMPLETE" -ForegroundColor Green
        Write-Log ("=" * 60) "INFO" -ForegroundColor Cyan
        Write-Log "  Total Devices:   $($c.Total.ToString("N0"))" -ForegroundColor White
        Write-Log "  NOT UPDATED:     $($stNotUptodate.ToString("N0")) ($($stats.PercentNotUptodate)%)" -ForegroundColor $(if ($stNotUptodate -gt 0) { "Yellow" } else { "Green" })
        Write-Log "  Updated:         $($c.Updated.ToString("N0")) ($($stats.PercentCertUpdated)%)" -ForegroundColor Green
        Write-Log "  With Errors:     $($c.WithErrors.ToString("N0"))" -ForegroundColor $(if ($c.WithErrors -gt 0) { "Red" } else { "Green" })
        Write-Log "  Peak Memory:     ${stPeakMemMB} MB" -ForegroundColor Cyan
        Write-Log "  Time:            $([math]::Round($stTotal/60,1)) min" -ForegroundColor White
        Write-Log "  Dashboard:       $htmlPath" -ForegroundColor White
        
        return [PSCustomObject]$stats
        Exit 0
    }
    #endregion STREAMING MODE
} else {
    Write-Error "Input path not found: $InputPath"
    exit 1
}