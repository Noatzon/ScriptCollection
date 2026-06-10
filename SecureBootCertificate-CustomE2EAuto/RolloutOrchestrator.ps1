<#
.SYNOPSIS
    Continuous Secure Boot rollout orchestrator that runs until deployment is complete.

.PARAMETER AggregationInputPath
    Path to raw JSON device data (from Detect script)

.PARAMETER ReportBasePath
    Base path for aggregation reports

.PARAMETER MaxWaitHours
    Hours to wait for devices to update before checking reachability.
    After this time, devices that haven't updated are pinged.
    Unreachable devices cause the bucket to be blocked.
    Default: 72 (3 days)

.PARAMETER PollIntervalMinutes
    Minutes between status checks. Default: 1440 (1 day)

.PARAMETER AllowListPath
    Path to a file containing hostnames to ALLOW for rollout (targeted rollout).
    Supports .txt (one hostname per line) or .csv (with Hostname/ComputerName/Name column).
    When specified, ONLY these devices will be included in rollout.
    BlockList is still applied after AllowList.

.PARAMETER ExclusionListPath
    Path to a file containing hostnames to EXCLUDE from rollout (VIP/executive devices).
    Supports .txt (one hostname per line) or .csv (with Hostname/ComputerName/Name column).
    These devices will never be included in any rollout wave.
    BlockList is applied AFTER AllowList filtering.
    
.PARAMETER DryRun
    Show what would be done without making changes

.PARAMETER ListBlockedBuckets
    Display all currently blocked buckets and exit

.PARAMETER UnblockBucket
    Unblock a specific bucket by key and exit

.PARAMETER UnblockAll
    Unblock all buckets and exit

.PARAMETER EnableTaskOnDisabled
    Deploy Enable-SecureBootUpdateTask.ps1 to all devices with disabled scheduled task.
    Creates a GPO with a one-time scheduled task that runs the Enable script with -Quiet option.
    This is useful to fix devices that have the Secure-Boot-Update task disabled.

.EXAMPLE
    .\Start-SecureBootRolloutOrchestrator.ps1 `
        -AggregationInputPath "\\server\SecureBootLogs$\Json" `
        -ReportBasePath "\\SecureBootReports" `

.EXAMPLE
    # List blocked buckets
    .\Start-SecureBootRolloutOrchestrator.ps1 -ReportBasePath "\\SecureBootReports" -ListBlockedBuckets

.EXAMPLE
    # Unblock a specific bucket
    .\Start-SecureBootRolloutOrchestrator.ps1 -ReportBasePath "\\SecureBootReports" -UnblockBucket "Dell_Latitude5520_BIOS1.2.3"

.EXAMPLE
    # Exclude VIP devices from rollout using a text file
    .\Start-SecureBootRolloutOrchestrator.ps1 `
        -AggregationInputPath "\\server\SecureBootLogs$\Json" `
        -ReportBasePath "\\SecureBootReports" `
        -ExclusionListPath "C:\Admin\VIP-Devices.txt"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)] #FQDN/UNC path to endpoint JSON files
    [string]$AggregationInputPath,

    [Parameter(Mandatory = $false)] #Path to where local copies of scripts are saved by Deploy- script and used by the Scheduled Tasks. Typically C:\Temp
    [string]$LocalfilePath,
    
    [Parameter(Mandatory = $false)] #Local path for reports and state
    [string]$ReportBasePath,
    
    [Parameter(Mandatory = $false)] #Wave naming prefix
    [string]$WavePrefix = "SecureBoot-Rollout",
    
    [Parameter(Mandatory = $false)] #Hours before checking device reachability
    [int]$MaxWaitHours = 72,
    
    [Parameter(Mandatory = $false)] #Minutes between status checks (original default 24h)
    [int]$PollIntervalMinutes,

    [Parameter(Mandatory = $false)]
    [int]$ProcessingBatchSize = 5000,

    [Parameter(Mandatory = $false)]
    [int]$DeviceLogSampleSize = 25,

    [Parameter(Mandatory = $false)]
    [switch]$LargeScaleMode,

    # ============================================================================
    # WinCS (Windows Configuration System) Parameters
    # ============================================================================
    # WinCS is an alternative to AvailableUpdatesPolicy GPO deployment.
    # It uses WinCsFlags.exe on each endpoint to enable Secure Boot rollout.
    # WinCsFlags.exe runs under SYSTEM context on the endpoint.
    # Reference: https://support.microsoft.com/en-us/topic/windows-configuration-system-wincs-apis-for-secure-boot-d3e64aa0-6095-4f8a-b8e4-fbfda254a8fe
    
    [Parameter(Mandatory = $false)] #Legacy option, we always use it right now
    [switch]$UseWinCS,
    
    [Parameter(Mandatory = $false)]
    [string]$WinCSKey = "F33E0C8E002",
    
    [Parameter(Mandatory = $false)] #For testing purposes
    [switch]$DryRun,
    
    [Parameter(Mandatory = $false)] #Display currently blocked device buckets
    [switch]$ListBlockedBuckets,
    
    [Parameter(Mandatory = $false)] #Unblock a specific bucket. Format: "Manufacturer|Model|BIOS"
    [string]$UnblockBucket,
    
    [Parameter(Mandatory = $false)] #Unblock all blocked device buckets
    [switch]$UnblockAll,

    [Parameter(Mandatory = $false)]
    [switch]$EnableTaskOnDisabled
)

#To ensure helper output remains correct even if someone changes the name of the script we use a variable instead of hardcoded name for it.
$ScriptInvocation = (Get-Variable MyInvocation -Scope Script).Value
$ScriptName = $ScriptInvocation.MyCommand.Name


$ErrorActionPreference = "Stop"
#$ScriptRoot = $PSScriptRoot
# ============================================================================
# PARAMETER VALIDATION
# ============================================================================

# Admin commands only need ReportBasePath
$isAdminCommand = $ListBlockedBuckets -or $UnblockBucket -or $UnblockAll -or $EnableTaskOnDisabled

if (-not $ReportBasePath) {
    Write-Host "ERROR: -ReportBasePath is required." -ForegroundColor Red
    exit 1
}

if (-not $isAdminCommand -and -not $AggregationInputPath) {
    Write-Host "ERROR: -AggregationInputPath is required for rollout (not needed for -ListBlockedBuckets, -UnblockBucket, -UnblockAll)" -ForegroundColor Red
    exit 1
}

# ============================================================================
# STATE FILE PATHS
# ============================================================================

$stateDir = Join-Path $ReportBasePath "RolloutState"
if (-not (Test-Path $stateDir)) {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
}

$rolloutStatePath = Join-Path $stateDir "RolloutState.json"
$rolloutSummaryPath = Join-Path $StateDir "SecureBootRolloutSummary.json"
$blockedBucketsPath = Join-Path $stateDir "BlockedBuckets.json"
$adminApprovedPath = Join-Path $stateDir "AdminApprovedBuckets.json"
$deviceHistoryPath = Join-Path $stateDir "DeviceHistory.json"
$processingCheckpointPath = Join-Path $stateDir "ProcessingCheckpoint.json"
# Fixed output folder for Aggregation script
$AggregationPath = Join-Path $ReportBasePath "Aggregation_Current"

# ============================================================================
# PS 5.1 COMPATIBILITY: ConvertTo-Hashtable
# ============================================================================
# ConvertFrom-Json -AsHashtable is PS7+ only. This provides compatibility.

function ConvertTo-Hashtable {
    param(
        [Parameter(ValueFromPipeline = $true)]
        $InputObject
    )
    process {
        if ($null -eq $InputObject) { return @{} }
        if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject }
        if ($InputObject -is [PSCustomObject]) {
            # Use [ordered] for consistent key ordering and safe duplicate handling
            $hash = [ordered]@{}
            foreach ($prop in $InputObject.PSObject.Properties) {
                # Indexed assignment safely handles duplicates by overwriting
                $hash[$prop.Name] = ConvertTo-Hashtable $prop.Value
            }
            return $hash
        }
        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            return @($InputObject | ForEach-Object { ConvertTo-Hashtable $_ })
        }
        return $InputObject
    }
}

# ============================================================================
# ADMIN COMMANDS: List/Unblock Buckets
# ============================================================================

if ($ListBlockedBuckets) {
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Yellow
    Write-Host "   BLOCKED BUCKETS" -ForegroundColor Yellow
    Write-Host ("=" * 80) -ForegroundColor Yellow
    Write-Host ""
    
    if (Test-Path $blockedBucketsPath) {
        $blocked = Get-Content $blockedBucketsPath -Raw | ConvertFrom-Json | ConvertTo-Hashtable
        if ($blocked.Count -eq 0) {
            Write-Host "No blocked buckets." -ForegroundColor Green
        } else {
            Write-Host "Total blocked: $($blocked.Count)" -ForegroundColor Red
            Write-Host ""
            foreach ($key in $blocked.Keys) {
                $info = $blocked[$key]
                Write-Host "Bucket: $key" -ForegroundColor Red
                Write-Host "  Blocked At:    $($info.BlockedAt)" -ForegroundColor Gray
                Write-Host "  Reason:        $($info.Reason)" -ForegroundColor Gray
                Write-Host "  Failed Device: $($info.FailedDevices)" -ForegroundColor Gray
                Write-Host "  Last Reported: $($info.LastReported)" -ForegroundColor Gray
                Write-Host "  Wave:          $($info.WaveNumber)" -ForegroundColor Gray
                Write-Host "  Devices in Bucket: $($info.DevicesInBucket)" -ForegroundColor Gray
                Write-Host ""
            }
            Write-Host "To unblock a bucket:"
            Write-Host "  .\$ScriptName.ps1 -ReportBasePath '$ReportBasePath' -UnblockBucket 'BUCKET_KEY'" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "To unblock all:"
            Write-Host "  .\$ScriptName.ps1 -ReportBasePath '$ReportBasePath' -UnblockAll" -ForegroundColor Cyan
        }
    } else {
        Write-Host "No blocked buckets file found." -ForegroundColor Green
    }
    Write-Host ""
    exit 0
}

if ($UnblockBucket) {
    Write-Host ""
    if (Test-Path $blockedBucketsPath) {
        $blocked = Get-Content $blockedBucketsPath -Raw | ConvertFrom-Json | ConvertTo-Hashtable
        if ($blocked.Contains($UnblockBucket)) {
            $blocked.Remove($UnblockBucket)
            $blocked | ConvertTo-Json -Depth 10 | Out-File $blockedBucketsPath -Encoding UTF8 -Force
            
            # Add to admin-approved list to prevent re-blocking
            $adminApproved = @{}
            if (Test-Path $adminApprovedPath) {
                $adminApproved = Get-Content $adminApprovedPath -Raw | ConvertFrom-Json | ConvertTo-Hashtable
            }
            $adminApproved[$UnblockBucket] = @{
                ApprovedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                ApprovedBy = $env:USERNAME
            }
            $adminApproved | ConvertTo-Json -Depth 10 | Out-File $adminApprovedPath -Encoding UTF8 -Force
            
            Write-Host "Unblocked bucket: $UnblockBucket" -ForegroundColor Green
            Write-Host "Added to admin-approved list (will not be re-blocked automatically)" -ForegroundColor Cyan
        } else {
            Write-Host "Bucket not found: $UnblockBucket" -ForegroundColor Yellow
            Write-Host "Available buckets:" -ForegroundColor Gray
            $blocked.Keys | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
        }
    } else {
        Write-Host "No blocked buckets file found." -ForegroundColor Yellow
    }
    Write-Host ""
    exit 0
}

if ($UnblockAll) {
    Write-Host ""
    if (Test-Path $blockedBucketsPath) {
        $blocked = Get-Content $blockedBucketsPath -Raw | ConvertFrom-Json | ConvertTo-Hashtable
        $count = $blocked.Count
        @{} | ConvertTo-Json | Out-File $blockedBucketsPath -Encoding UTF8 -Force
        Write-Host "Unblocked all $count buckets." -ForegroundColor Green
    } else {
        Write-Host "No blocked buckets file found." -ForegroundColor Yellow
    }
    Write-Host ""
    exit 0
}

# ============================================================================
# ENABLE TASK ON DISABLED DEVICES
# ============================================================================
if ($EnableTaskOnDisabled) {
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Yellow
    Write-Host "  ENABLE TASK REMEDIATION - Fixing Disabled Scheduled Tasks" -ForegroundColor Yellow
    Write-Host ("=" * 70) -ForegroundColor Yellow
    Write-Host ""
    
    # Find devices with disabled task from aggregation data
    if (-not $AggregationInputPath) {
        Write-Host "ERROR: -AggregationInputPath is required to identify devices with disabled task" -ForegroundColor Red
        Write-Host "Usage: .\$ScriptName.ps1 -EnableTaskOnDisabled -AggregationInputPath $AggregationInputPath -ReportBasePath $ReportBasePath" -ForegroundColor Gray
        exit 1
    }
    
    Write-Host "Scanning for devices with disabled Secure-Boot-Update task..." -ForegroundColor Cyan
    Write-Log "User is running 'EnableTaskOnDisabled'." "START"
    
    # Load JSON files and find devices with disabled task
    $jsonFiles = Get-ChildItem -Path $AggregationInputPath -Filter "*.json" -Recurse -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -notmatch "ScanHistory|RolloutState|RolloutPlan" }
    
    $disabledTaskDevices = @()
    foreach ($file in $jsonFiles) {
        try {
            $device = Get-Content $file.FullName -Raw | ConvertFrom-Json
            if ($device.SecureBootTaskEnabled -eq $false -or 
                $device.SecureBootTaskStatus -eq 'Disabled' -or 
                $device.SecureBootTaskStatus -eq 'NotFound') {
                # Only include devices that haven't already updated (no Event 1808)
                if ([int]$device.Event1808Count -eq 0) {
                    $disabledTaskDevices += $device.HostName
                }
            }
        } catch {
            # Skip invalid files
        }
    }
    
    $disabledTaskDevices = $disabledTaskDevices | Select-Object -Unique
    
    if ($disabledTaskDevices.Count -eq 0) {
        Write-Host ""
        Write-Host "No devices found with disabled Secure-Boot-Update task." -ForegroundColor Green
        Write-Host "All devices either have the task enabled or have already updated." -ForegroundColor Gray
        Write-Log "No devices found with disabled Secure-Boot-Update task." "INFO"
        exit 0
    }
    
    Write-Host ""
    Write-Host "Found $($disabledTaskDevices.Count) devices with disabled task:" -ForegroundColor Yellow
    Write-Log "Found $($disabledTaskDevices.Count) devices with disabled task:"
    $disabledTaskDevices | Select-Object -First 20 | ForEach-Object { 
        Write-Host "  - $_" -ForegroundColor Gray
        Write-Log "  - $_" "INFO"
    }
    if ($disabledTaskDevices.Count -gt 20) {
        Write-Host "  ... and $($disabledTaskDevices.Count - 20) more" -ForegroundColor Gray
        Write-Log  "  ... and $($disabledTaskDevices.Count - 20) more"
    }
    Write-Host ""
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Get-RolloutState {
    if (Test-Path $rolloutStatePath) {
        try {
            $loaded = Get-Content $rolloutStatePath -Raw | ConvertFrom-Json | ConvertTo-Hashtable
            # Validate required properties exist
            if ($null -eq $loaded.CurrentWave) {
                throw "Invalid state file - missing CurrentWave"
            }
            # Ensure WaveHistory is always an array (fixes PS5.1 JSON deserialization)
            if ($null -eq $loaded.WaveHistory) {
                $loaded.WaveHistory = @()
            } elseif ($loaded.WaveHistory -isnot [array]) {
                $loaded.WaveHistory = @($loaded.WaveHistory)
            }
            #If Try succeeds return the real results:
            return $loaded
        } catch {
            Write-Log "Corrupted RolloutState.json detected: $($_.Exception.Message)" "WARN"
            Write-Log "Backing up corrupted file and starting fresh" "WARN"
            $backupPath = "$rolloutStatePath.corrupted.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Move-Item $rolloutStatePath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
    #If the Try didn't succeed. Return this result:
    return @{
        CurrentWave = 0
        StartedAt = $null
        LastAggregation = $null
        TotalDevicesTargeted = 0
        TotalDevicesUpdated = 0
        Status = "NotStarted"
        WaveHistory = @()
    }
}

function Save-RolloutState {
    param($State)
    $State | ConvertTo-Json -Depth 10 | Out-File $rolloutStatePath -Encoding UTF8 -Force
}

function Save-RolloutSummary {
    <#
    .SYNOPSIS
        Save rollout summary with projection information for dashboard display
    #>
    param(
        [hashtable]$State,
        [int]$TotalDevices,
        [int]$UpdatedDevices,
        [int]$NotUpdatedDevices,
        [double]$DevicesPerDay
    )
    
    $summaryPath = Join-Path $stateDir "SecureBootRolloutSummary.json"
    
    # Calculate weekend-aware projection
    # $projection = Get-WeekdayProjection -RemainingDevices $NotUpdatedDevices -DevicesPerDay $DevicesPerDay
    
    $summary = @{
        GeneratedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        RolloutStartDate = $State.StartedAt
        LastAggregation = $State.LastAggregation
        CurrentWave = $State.CurrentWave
        Status = $State.Status
        
        # Device counts
        TotalDevices = $TotalDevices
        UpdatedDevices = $UpdatedDevices
        NotUpdatedDevices = $NotUpdatedDevices
        PercentUpdated = if ($TotalDevices -gt 0) { [math]::Round(($UpdatedDevices / $TotalDevices) * 100, 1) } else { 0 }
        
        # Velocity metrics
        DevicesPerDay = [math]::Round($DevicesPerDay, 1)
        TotalDevicesTargeted = $State.TotalDevicesTargeted
        TotalWaves = $State.CurrentWave
        
        # Weekend-aware projection
        <# ProjectedCompletionDate = $projection.ProjectedDate
        WorkingDaysRemaining = $projection.WorkingDaysNeeded
        CalendarDaysRemaining = $projection.CalendarDaysNeeded #>
        
        # Note about weekend exclusion
        ProjectionNote = "Projected completion excludes weekends (Sat/Sun)"
    }
    
    $summary | ConvertTo-Json -Depth 5 | Out-File $summaryPath -Encoding UTF8 -Force
    Write-Log "Rollout summary saved: $summaryPath" "INFO"
    
    return $summary
}

function Get-BlockedBuckets {
    if (Test-Path $blockedBucketsPath) {
        return Get-Content $blockedBucketsPath -Raw | ConvertFrom-Json | ConvertTo-Hashtable
    }
    return @{}
}

function Save-BlockedBuckets {
    param($Blocked)
    $Blocked | ConvertTo-Json -Depth 10 | Out-File $blockedBucketsPath -Encoding UTF8 -Force
}

function Get-AdminApproved {
    if (Test-Path $adminApprovedPath) {
        return Get-Content $adminApprovedPath -Raw | ConvertFrom-Json | ConvertTo-Hashtable
    }
    return @{}
}

function Get-DeviceHistory {
    if (Test-Path $deviceHistoryPath) {
        return Get-Content $deviceHistoryPath -Raw | ConvertFrom-Json | ConvertTo-Hashtable
    }
    return @{}
}

function Save-DeviceHistory {
    param($History)
    $History | ConvertTo-Json -Depth 10 | Out-File $deviceHistoryPath -Encoding UTF8 -Force
}

function Save-ProcessingCheckpoint {
    param(
        [string]$Stage,
        [int]$Processed,
        [int]$Total,
        [hashtable]$Metrics = @{}
    )

    $checkpoint = @{
        Stage = $Stage
        UpdatedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Processed = $Processed
        Total = $Total
        Percent = if ($Total -gt 0) { [math]::Round(($Processed / $Total) * 100, 2) } else { 0 }
        Metrics = $Metrics
    }

    $checkpoint | ConvertTo-Json -Depth 6 | Out-File $processingCheckpointPath -Encoding UTF8 -Force
}

function Get-NotUpdatedIndexes {
    param([array]$Devices)

    $hostSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $bucketCounts = @{}

    foreach ($device in $Devices) {
        #Ensures schema consistency between different file formats (csv vs json).
        if ($device.Hostname) { 
             $hostname = $device.Hostname 
        } elseif ($device.HostName) { 
             $hostname = $device.HostName } 
            else { $null }

        # Adds the corrected host name to "list"
        if ($hostname) {
            [void]$hostSet.Add($hostname)
        }

        #Stats of how many devices fall into each of the different BucketID's. Do note that it'll ignore devices without a bucketID, meaning any device with "empty" or simple "" as BucketID is likely to be ignored
        $bucketKey = Get-BucketKey $device
        if ($bucketKey) {
            if ($bucketCounts.ContainsKey($bucketKey)) {
                $bucketCounts[$bucketKey]++
            } else {
                $bucketCounts[$bucketKey] = 1
            }
        }
    }

    return @{
        HostSet = $hostSet
        BucketCounts = $bucketCounts
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
    $logFile = Join-Path $stateDir "Orchestrator_$(Get-Date -Format 'yyyyMMdd').log"
    "[$timestamp] [$Level] $Message" | Out-File $logFile -Append -Encoding UTF8
}

function Get-BucketKey {
    param($Device)
    # Use BucketId from device JSON if available (SHA256 hash from detection script)
    if ($Device.BucketId -and "$($Device.BucketId)" -ne "") { return "$($Device.BucketId)" }
    # Fallback: construct from manufacturer|model|bios
    $mfr = if ($Device.WMI_Manufacturer) { $Device.WMI_Manufacturer } else { $Device.Manufacturer }
    $model = if ($Device.WMI_Model) { $Device.WMI_Model } else { $Device.Model }
    $bios = if ($Device.BIOSDescription) { $Device.BIOSDescription } else { $Device.BIOS }
    return "$mfr|$model|$bios"
}

# ============================================================================
# DATA FRESHNESS AND MONITORING
# ============================================================================

function Get-LatestFile {
    param(
        [string]$FilePath,
        [string]$fileName
    )

    if (-not (Test-Path $FilePath)) {
        return $null
    }

    $latestCsv = Get-ChildItem -Path $FilePath -Filter $fileName -File -Depth 10 |
        Where-Object { $_.Name -notlike "*Buckets*" } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    return $latestCsv
}


# ============================================================================
# DATA FRESHNESS PART 2
# ============================================================================
function Get-LatestAggregation {
     <#
    .SYNOPSIS
        Calls on Aggregate-SecureBootData.ps1 to force refresh of report files. Used to ensure New-RolloutWave doesn't rely on outdated information.
        Recommend to run Get-DataFreshness before.
    #>
    param(
        [string]$AggregateFile, #Script to run
        [string]$InputPath, #Where to look for the .json files to process
        [int]$TimeoutSeconds = 1200, #Configurable wait time for script to finish before continuing. 600 = 1min. 18000 =  30min
        [int]$MaxRetries = 3 #Configurabble number of times to retry running script
    )
    # Timestamp tracking, in memory only! "Save-RolloutState" is ran later in the loop to actually write to disk
    $RolloutState.LastAggregation = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Log "Last aggregation attempted: $($RolloutState.LastAggregation)" "INFO"

    for ($i = 1; $i -le $MaxRetries; $i++) {
        #Try to start Aggregate-SecureBootData.ps1 and give it Nminutes to finsih. If it's not done by then, tetry operation up to three times before giving up.
        try {
            Write-Log "Aggregation attempt $i..." "INFO"
            $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$AggregateFile`" -InputPath `"$InputPath`" -OutputPath `"$AggregationPath`" -LogPath `"$LocalfilePath`" -StreamingMode -IncrementalMode -IncludeAllConfidenceLevels -SkipReportIfUnchanged -ParallelThreads 8"
            # Pass rollout summary if it exists (for velocity/projection data)
           if ($rolloutSummaryPath -and (Test-Path $rolloutSummaryPath)) {
                $arguments += " -RolloutSummaryPath `"$rolloutSummaryPath`""
            }

            $proc = Start-Process powershell.exe -ArgumentList $arguments -PassThru -NoNewWindow
            $finished = $proc.WaitForExit($TimeoutSeconds * 1000)

            if (-not $finished) {
                $proc.Kill()
                throw "Timeout after $TimeoutSeconds seconds"
            }

            # Log exit code (signal only, not decision)
            if ($proc.ExitCode -ge 0) {
                Write-Log "Aggregation returned exit code $($proc.ExitCode)" "WARN"
            } 
            # How old the file is allowed to be and still be counted as Aggregate script having run successfully. Can be set to static number too. Current calculation is N minutes + the total maximum time allowed for retries.
            $maxAgeMinutes = 5 + ($TimeoutSeconds * 1000 * $MaxRetries)
            $now = Get-Date
            # Retrieve latest file
            $Latest = Get-LatestFile -FilePath $AggregationPath -fileName "SecureBoot_NotUptodate*.csv"

            if (-not $latest) {
                throw "No output file found"
            }

            $ageMinutes = ($now - $latest.LastWriteTime).TotalMinutes
            #Write-Log "Latest aggregation file: $($latest.Name)" "INFO"
            #Write-Log "File age: $([math]::Round($ageMinutes,2)) minutes" "INFO"

            if ($ageMinutes -le $maxAgeMinutes) {
                Write-Log "Aggregation succeeded (fresh output detected)" "OK"
                return $true
            } else {
                throw "Aggregation output is stale (${ageMinutes} min old)"
            }
        }
        catch {
            Write-Log "Aggregation error: $($_.Exception.Message)" "WARN"
            #If it fails we retry N amount of times before finally aborting
            if ($i -lt $MaxRetries) {
                Start-Sleep 30
            } else {
                Write-Log "Aggregation failed. Data could not be updated" "ERROR"
                return $false
            }
        }
    }
}

# ============================================================================
# DEVICE TRACKING (BY HOSTNAME)
# ============================================================================

function Update-DeviceHistory {
    <#
    .SYNOPSIS
        Tracks devices by hostname since we don't have a unique machine identifier.
        Note: BucketId is one-to-many (same hardware config = same bucket).
    #>
    param(
        [array]$CurrentDevices,
        [hashtable]$DeviceHistory
    )
    
    foreach ($device in $CurrentDevices) {
        $hostname = $device.Hostname
        if (-not $hostname) { continue }

        # Determine $Status (used to evaluate buckets/device for Rollout waves)
        if ($device.Event1808Count -gt 0) {
            $status = "Updated"
        }
        elseif ($device.Event1795Count -gt 0 -or $device.Event1796Count -gt 0) {
            $status = "Failed"
        }
        elseif ($device.RebootPending -or $device.Event1800Count -gt 0) {
            $status = "PendingReboot"
        }
        elseif ($device.Event1801Count -gt 0) {
            $status = "InProgress"
        }
        else {
            $status = "NotStarted"
        }
        # Build hashtable after we've confirmed what $Status should be
        $DeviceHistory[$hostname] = @{
            Hostname     = $hostname
            BucketId     = $device.BucketId
            Manufacturer = $device.WMI_Manufacturer
            Model        = $device.WMI_Model
            LastSeen     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Status       = $status
        }
    }
}

# ============================================================================
# BLOCKED BUCKET DETECTION (Based on Device Reachability)
# ============================================================================

<#
.DESCRIPTION
    Blocking Logic:
    - A bucket is ONLY blocked if:
      1. Device was targeted in a wave
      2. MaxWaitHours has passed since wave started
      3. Device is NOT REACHABLE (ping fails)
    
    - If device IS reachable but not yet updated, we keep waiting
      (update may be pending reboot - Event 1808 only fires after reboot)
    
    - Unreachable device indicates something went wrong and needs investigation
    
    Unblocking:
    - Use -ListBlockedBuckets to see blocked buckets
    - Use -UnblockBucket "BucketKey" to unblock specific bucket
    - Use -UnblockAll to unblock all buckets
#>

function Test-DeviceReachable {
    param(
        [string]$Hostname,
        [string]$DataPath  # Path to device JSON files
    )
    
    # Method 1: Check JSON file timestamp (fastest — no file parsing needed)
    # If the detection script ran recently, the file was written/updated, proving the device is alive
    if ($DataPath) {
        $deviceFile = Get-ChildItem -Path $DataPath -Filter "${Hostname}*" -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($deviceFile) {
            $hoursSinceWrite = ((Get-Date) - $deviceFile.LastWriteTime).TotalHours
            #Configurable, how many hours sincce the _latest.json file was created for it to consider the device "unreachable"
            if ($hoursSinceWrite -lt 72) { return $true } #Do we need a "else{return: false}" ?
        }
    }
}


function Update-BlockedBuckets {
    <#
.DESCRIPTION
    One of the main state engines for Orchestrator. Using a deterministic approach to categorize and distrubute devices that should be included in current/upcomming wave.
    Hillariously enough, original version if this function was extremely unfinished. And it did not include any calls or usage of the DeviceHistory.json file to evaluate and determine blocking actions. Rewrote most of the function based on the two lines of "code" that existed related to this. 
         # Check if this bucket has any successes (from updated devices data)
        $bucketHasSuccesses = $stSuccessBuckets -and $stSuccessBuckets.Contains($bucketKey)
    Plus what/how Microsoft describes the Orchestrator is supposed to work in their documentation. It also had no filters or ways to actually read and evaluate EventId's and similar things. Which were supposed to be a core function of the whole Orchestrator, again, lmao wtf are you doing Microsoft?

    The descision tree is now based on:
     1. What the system/Microsoft knows (Confidence level)
     2. What the device is currently doing 
        - With additional safteguard/check that runs when a device has had the same "status" for a long time.   
        2a. General check is done based on EventId's ("GPO")
        2b. Further refinement/checks run based on "WinCS" states
        2c. Lastly, we use a "independant" feedback loop system managed by the Wave generation/rollout procedure to also check progress and connectivity.
     3. What previous waves (DeviceHistory.json) says about similar devices.

    This is then used to further determine how to handle devices, block or allow, wait etc.
#>

    param(
        $RolloutState,
        $BlockedBuckets,
        $AdminApproved,
        [array]$NotUpdatedDevices,
        [hashtable]$NotUpdatedIndexes,
        [hashtable]$DeviceHistory,
        [int]$MaxWaitHours,
        [bool]$DryRun = $false
    )

    $now = Get-Date
    #What changed this run
    $newlyBlocked = @()
    # Keeping track of devices in "queue"
    $stillWaiting = @()
    # List of "candidates" (devices) to evaluate this time
    $devicesToCheck = @()

    #================================
    # Collect Historic data
    # Data generated by [Get-UpdatedIndexes] function. "Loads" the raw .scv (eww, slow and hard to work with) into memory (quick, efficient) to improve lookup speeds and decrease operations
    $hostSet = if ($NotUpdatedIndexes -and $NotUpdatedIndexes.HostSet) {
        $NotUpdatedIndexes.HostSet
    }
    else {
        (Get-NotUpdatedIndexes -Devices $NotUpdatedDevices).HostSet
    }

    $bucketCounts = if ($NotUpdatedIndexes -and $NotUpdatedIndexes.BucketCounts) {
        $NotUpdatedIndexes.BucketCounts
    }
    else {
        (Get-NotUpdatedIndexes -Devices $NotUpdatedDevices).BucketCounts
    }

    # Successful buckets based on history, trying to find at least one device in each bucket that has succeeded before. Used for the initial Confidence level based filtering.
    $SuccessBuckets = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($device in $DeviceHistory.Values) {
        if ($device.Status -eq "Updated" -and $device.BucketId) {
            [void]$SuccessBuckets.Add($device.BucketId)
        }
    }

    #================================
    # Collect eligible devices
    #Collects devices that should have updated by now. Runs further checks to skip any that should already be blocked (the "continue" line.)
    foreach ($wave in $RolloutState.WaveHistory) {
        if (-not $wave.StartedAt) { continue }

        $waveStart = [DateTime]::Parse($wave.StartedAt)
        $hoursSinceWave = ($now - $waveStart).TotalHours

        if ($hoursSinceWave -lt $MaxWaitHours) { continue }

        foreach ($deviceInfo in $wave.Devices) {

            $hostname = $deviceInfo.Hostname
            $bucketKey = $deviceInfo.BucketKey

            if ($BlockedBuckets.Contains($bucketKey)) { continue }

            #Allows for manual override for certain devices/buckets.
            if ($AdminApproved -and $AdminApproved.Contains($bucketKey)) {
                $approvalTime = [DateTime]::Parse($AdminApproved[$bucketKey].ApprovedAt)
                if ($waveStart -lt $approvalTime) { continue }
            }

            if ($hostSet.Contains($hostname)) {
                $devicesToCheck += @{
                    Hostname       = $hostname
                    BucketKey      = $bucketKey
                    WaveNumber     = $wave.WaveNumber
                    HoursSinceWave = [math]::Round($hoursSinceWave, 1)
                }
            }
        }
    }

    #Next checkpoint in function, prevents us from running code when we don't need to
    if ($devicesToCheck.Count -eq 0) {
        return $newlyBlocked
    }

    Write-Log "Evaluating $($devicesToCheck.Count) devices past wait period..." "INFO"

    #================================
    #= START :: Bucket classification 
    $bucketFailures = @{}

    foreach ($device in $devicesToCheck) {
        #Creating a "bucket status/device state" that is used to evaluate and determine action
        $hostname = $device.Hostname
        $bucketKey = $device.BucketKey
        Write-Log "Evaluating $hostname" "INFO" # Only really for logging/developing phase, nice to know which device it's trying to evaluate so we can cross-reference it's json files and see if there's anything odd with the results
        if (-not $bucketFailures.ContainsKey($bucketKey)) {
            $bucketFailures[$bucketKey] = @{
                HardBlocked    = @() # "Confidence level" determines it should be ignored
                Failed         = @() # EventID indicates it failed the update
                Pending        = @() # In "queue" and not part of current wave
                InProgress     = @() # Curently in the process of updating certificates
                NotStarted     = @() # Similar to Pending
                Unreachable    = @() # 2,5. step explained above.
                WaveNumber     = $device.WaveNumber
                HoursSinceWave = $device.HoursSinceWave
                # 2b & 2c checks/state signifiers    
                NoManifestSeen = @()
                WinCSFailed    = @()
                StuckDevices   = @()
                InWaveDevices  = @()

            }
        }

        # Working object containing all the devices to be worked on in this evaluation
        $current = $NotUpdatedDevices | Where-Object { $_.Hostname -eq $hostname }
        if (-not $current) { continue }
        # If multiple devices end up added into $current (unexpected), take first deterministically
        if ($current -is [System.Array]) {
            $current = $current[0]
        }
        # Adding further nuance to status/state
        $waveSeen = $current.WaveManifestSeen
        $inWave = $current.InWave -eq $true
        $winCSApplied = $current.WinCSKeyApplied -eq $true
        $winCSStatus = if ($current.WinCSKeyStatus) { $current.WinCSKeyStatus } else { "Unknown" }
        
        # Check 1 — CONFIDENCE
        if ($current.Confidence -in @(
                "Not Supported",
                "Temporarily Paused",
                #"Blocked - Known Issue",
                #"Under Observation",
                "Action Required"
            )) {
            # Adding the devices with the above "Confidence level" comments directly to blocked bucket.
            $confidenceValue = $current.Confidence
            $bucketFailures[$bucketKey].HardBlocked += @{
                Hostname   = $hostname
                Confidence = $confidenceValue
            }
            continue
        }

        # Check 2 — EVENT CLASSIFICATION
        # At this stage we instead have to determine the next course of action based on the current "state" the device is reporting
        $isFailure = ($current.Event1795Count -gt 0 -or $current.Event1796Count -gt 0)
        $isPending = ($current.RebootPending -or $current.Event1800Count -gt 0)
        $isProgress = ($current.Event1801Count -gt 0)

        if ($current.Event1808Count -gt 0) {
            continue
        }
        elseif ($isFailure) {
            $bucketFailures[$bucketKey].Failed += $hostname
        }
        elseif ($isPending) {
            $bucketFailures[$bucketKey].Pending += $hostname
            $stillWaiting += $hostname
        }
        elseif ($isProgress) {
            $bucketFailures[$bucketKey].InProgress += $hostname
            $stillWaiting += $hostname
        }
        else {
            $bucketFailures[$bucketKey].NotStarted += $hostname
        }

        # Secondary status signals
        # Track devices that *should* be part of wave
        if ($inWave) {
            if ($hostname -notin $bucketFailures[$bucketKey].InWaveDevices) {
                $bucketFailures[$bucketKey].InWaveDevices += $hostname
            }
        }

        # Devices that never saw manifest but are expected to participate (inWave)
        if ($inWave -and -not $waveSeen) {
            if ($hostname -notin $bucketFailures[$bucketKey].NoManifestSeen) {
                $bucketFailures[$bucketKey].NoManifestSeen += $hostname
            }
        }

        # WinCS failure (only if device should have executed)
        if ($inWave -and (-not $winCSApplied -or $winCSStatus -ne "Applied")) {
            if ($hostname -notin $bucketFailures[$bucketKey].WinCSFailed) {
                $bucketFailures[$bucketKey].WinCSFailed += $hostname
            }
        }
        <# Stuck detection. Must NOT be:
        - already updated
        - pending/rebooting
        - making progress
        #>
        if (
            $inWave -and
            $current.Event1808Count -eq 0 -and
            -not $current.RebootPending -and
            -not $isPending -and
            -not $isProgress -and
            $device.HoursSinceWave -gt 12 #How much leeway to give a device that might just be on a "bad" refresh cycle or is just slow in starting
        ) {
            if ($hostname -notin $bucketFailures[$bucketKey].StuckDevices) {
                $bucketFailures[$bucketKey].StuckDevices += $hostname
            }
        }

        # Check 2,5 — CONDITIONAL REACHABILITY TEST
        #Ensuring we only run the following check once we've ensured it meets all criteria to do so. The [Test-DeviceReachable] function (right now) checks for when the raw _lates.json file was last updated to determine if the device is stl lreporting back as it should or not.
        if (
            $isFailure -and
            -not $isPending -and
            -not $isProgress
        ) {
            if (-not $DryRun) {
                $isReachable = Test-DeviceReachable -Hostname $hostname -DataPath $AggregationInputPath

                if (-not $isReachable) {
                    $bucketFailures[$bucketKey].Unreachable += $hostname
                }
            }
        }
    }
    #= END :: Bucket classification
    #================================

    #================================
    #= START :: DECISION + TRACKING
    foreach ($bucketKey in $bucketFailures.Keys) {
        $bf = $bucketFailures[$bucketKey]
        $bucketHasSuccesses = $SuccessBuckets.Contains($bucketKey)
        $hardBlocked = $bf.HardBlocked.Count
        $failed = $bf.Failed.Count
        $pending = $bf.Pending.Count
        $progress = $bf.InProgress.Count
        $dead = $bf.Unreachable.Count

        #Logs the result of previous operations, giving us an overview of the current status, also log "nothing" just so we know there's "nothing" to report
        Write-Log "" "INFO"
        Write-Log "====== BUCKET [ $bucketKey ] STATUS ======" "INFO"
        if ($failed -gt 0)                  { Write-Log "  Failed: $($bf.Failed -join ', ')" "WARN" }               else { Write-Log "  Failed: 0" "INFO" }
        if ($pending -gt 0)                 { Write-Log "  Pending: $($bf.Pending -join ', ')" "INFO" }             else { Write-Log "  Pending: 0" "INFO" }
        if ($progress -gt 0)                { Write-Log "  InProgress: $($bf.InProgress -join ', ')" "INFO" }       else { Write-Log "  InProgress: 0" "INFO" }
        if ($dead -gt 0)                    { Write-Log "  Unreachable: $($bf.Unreachable -join ', ')" "WARN" }     else { Write-Log "  Unreachable: 0" "INFO" }
        if ($bf.NoManifestSeen.Count -gt 0) { Write-Log "  Manifest issue: $($bf.NoManifestSeen.Count)" "WARN" }    else { Write-Log "  Manifest issues: 0" "INFO" }
        if ($bf.WinCSFailed.Count -gt 0)    { Write-Log "  WinCSFailed: $($bf.WinCSFailed.Count)" "WARN" }          else { Write-Log "  WinCSFailed: 0" "INFO" }
        if ($bf.StuckDevices.Count -gt 0)   { Write-Log "  StaleDevices: $($bf.StuckDevices.Count)" "WARN" }        else { Write-Log "  StaleDevices: 0" "INFO" }
        #Write-Log "" "INFO"

        # Tracking devices that are currently failing but that we haven't yet blocked.
        if (-not $RolloutState.TemporaryFailures) {
            $RolloutState.TemporaryFailures = @{}
        }
        #Saving the state so we can use it later
        $RolloutState.TemporaryFailures[$bucketKey] = @{
            Failed      = $bf.Failed
            Pending     = $bf.Pending
            InProgress  = $bf.InProgress
            Unreachable = $bf.Unreachable
            LastChecked = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
        #===============
        # DECISION LOGIC
        #===============
        #  Confidence-based hard block
        if ($hardBlocked -gt 0) {
            $failedHostnames = $bf.HardBlocked | ForEach-Object { $_.Hostname }
            $confidenceValues = $bf.HardBlocked | ForEach-Object { $_.Confidence } | Select-Object -Unique
            $blockInfo = @{
                BlockedAt       = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                Reason          = "Confidence based block"
                BlockType       = "Confidence"
                BlockSubType    = ($confidenceValues -join ", ")
                FailedDevices   = ($failedHostnames -join ", ")
                WaveNumber      = $bf.WaveNumber
                DevicesInBucket = if ($bucketCounts.ContainsKey($bucketKey)) { $bucketCounts[$bucketKey] } else { 0 }
            }
            $BlockedBuckets[$bucketKey] = $blockInfo
            $newlyBlocked += $bucketKey
            Write-Log "BLOCKED: ($($blockInfo.Reason)), Subcategory: ($($blockInfo.BlockSubType)) - Bucket: $bucketKey - Devices: $($blockInfo.FailedDevices)" "WARN"
            continue
        }

        # History indicates this bucket has major issues
        if ($failed -gt 0 -and $dead -gt 0 -and -not $bucketHasSuccesses) {
            $blockInfo = @{
                BlockedAt       = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                Reason          = "Devices failing and unreachable"
                BlockType       = "Failure"
                BlockSubType    = "Unreachable"
                FailedDevices   = ($bf.Unreachable -join ", ")
                WaveNumber      = $bf.WaveNumber
                DevicesInBucket = if ($bucketCounts.ContainsKey($bucketKey)) { $bucketCounts[$bucketKey] } else { 0 }
            }
            $BlockedBuckets[$bucketKey] = $blockInfo
            $newlyBlocked += $bucketKey
            Write-Log "BLOCKED: ($($blockInfo.Reason)) - Bucket: $bucketKey - Devices: $($blockInfo.FailedDevices)" "WARN"
            continue
        }

        # Failures but activity → wait meaning it's failing but we've also seen state change, hoping that it's trying and just need some more time
        if ($failed -gt 0 -and ($pending -gt 0 -or $progress -gt 0)) {
            Write-Log "Not blocking $bucketKey — devices still progressing" "INFO"
        }

        # Failures but proven success (based on DeviceHistory.json)
        elseif ($failed -gt 0 -and $bucketHasSuccesses) {
            Write-Log "Not blocking $bucketKey — success history exists" "WARN"
        }
    }  
    #= END :: Decision loop
    #================================

    if ($stillWaiting.Count -gt 0) {
        Write-Log "Devices pending or progressing: $($stillWaiting.Count)" "INFO"
    }

    return $newlyBlocked
}

# ============================================================================
# AUTO-UNBLOCK: Unblock buckets when devices update successfully
# ============================================================================

function Update-AutoUnblockedBuckets {
    <#
    .DESCRIPTION
        Checks if devices in blocked buckets have updated (Event 1808).
        
        Auto-unblocks if ALL targeted devices in the bucket have updated.
        If only SOME devices updated, notifies admin who can manually unblock.
        
        Admin can manually unblock using:
          .\$ScriptName.ps1 -ReportBasePath "path" -UnblockBucket "BucketKey"
    #>
    param(
        $BlockedBuckets,
        $RolloutState,
        [array]$NotUpdatedDevices,
        [string]$ReportBasePath,
        [hashtable]$NotUpdatedIndexes,
        [int]$LogSampleSize = 25
    )
    
    $autoUnblocked = @()
    $bucketsToCheck = @($BlockedBuckets.Keys)
    $hostSet = if ($NotUpdatedIndexes -and $NotUpdatedIndexes.HostSet) { $NotUpdatedIndexes.HostSet } else { (Get-NotUpdatedIndexes -Devices $NotUpdatedDevices).HostSet }
    
    foreach ($bucketKey in $bucketsToCheck) {
        $bucketInfo = $BlockedBuckets[$bucketKey]
        
        # Get all devices we targeted from this bucket historically
        $targetedDevicesInBucket = @()
        foreach ($wave in $RolloutState.WaveHistory) {
            $targetedDevicesInBucket += @($wave.Devices | Where-Object { $_.BucketKey -eq $bucketKey })
        }
        
        if ($targetedDevicesInBucket.Count -eq 0) { continue }
        
        # Check how many targeted devices are still in NotUpdated vs updated
        $updatedDevices = @()
        $stillPendingDevices = @()
        
        foreach ($targetedDevice in $targetedDevicesInBucket) {
            if ($hostSet.Contains($targetedDevice.Hostname)) {
                $stillPendingDevices += $targetedDevice.Hostname
            }
            else {
                $updatedDevices += $targetedDevice.Hostname
            }
        }
        
        # We're actually tracking the exact "Confidence" based reason the bucket/device was blocked in the first place. This way we're able to here get more info to make a decition if we want to try and manually unblock a bucket.
        $blockType = $bucketInfo.BlockType
        if ($blockType -eq "Confidence") {
            Write-Log "SKIPPED AUTO-UNBLOCK (confidence block), $($bucketInfo.BlockSubType): Bucket - $bucketKey" "INFO"
            continue
        }
        # ============= BIG IF
        if ($updatedDevices.Count -gt 0 -and $stillPendingDevices.Count -eq 0) {
            # ALL targeted devices have updated - auto-unblock!
            $BlockedBuckets.Remove($bucketKey)
            $autoUnblocked += @{
                BucketKey           = $bucketKey
                UpdatedDevices      = $updatedDevices
                PreviouslyBlockedAt = $bucketInfo.BlockedAt
                Reason              = "All $($updatedDevices.Count) targeted device(s) successfully updated"
            }
            Write-Log "AUTO-UNBLOCKED: $bucketKey - All $($updatedDevices.Count) device(s) updated" "OK"
            
            $bucketOEM = if ($bucketKey -match '\|') {
                ($bucketKey -split '\|')[0]
            }
            else { 'Unknown' }

            if (-not $RolloutState.OEMWaveCounts) {
                $RolloutState.OEMWaveCounts = @{}
            }

            $currentWave = if ($RolloutState.OEMWaveCounts[$bucketOEM]) {
                $RolloutState.OEMWaveCounts[$bucketOEM]
            }
            else { 0 }

            $RolloutState.OEMWaveCounts[$bucketOEM] = $currentWave + 1
            Write-Log "  OEM '$bucketOEM' wave count incremented to $($currentWave + 1) (next allocation: $([int][Math]::Pow(2, $currentWave + 1)) devices)" "INFO"
        
            else {
                Write-Log "  OEM wave count NOT incremented for $bucketKey due to confidence-based block" "INFO"
            }
        } # ============= BIG IF/END

        elseif ($updatedDevices.Count -gt 0 -and $stillPendingDevices.Count -gt 0) {
            # SOME devices updated but others are still pending - notify admin (only once)
            if (-not $bucketInfo.UnblockCandidate) {
                $bucketInfo.UnblockCandidate = $true
                $bucketInfo.UpdatedDevices = $updatedDevices
                $bucketInfo.PendingDevices = $stillPendingDevices
                $bucketInfo.NotifiedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                
                Write-Log "" "INFO"
                Write-Log "========== PARTIAL UPDATE IN BLOCKED BUCKET ==========" "INFO"
                Write-Log "Bucket: $bucketKey" "INFO"
                $updatedSample = @($updatedDevices | Select-Object -First $LogSampleSize)
                $pendingSample = @($stillPendingDevices | Select-Object -First $LogSampleSize)
                $updatedSuffix = if ($updatedDevices.Count -gt $LogSampleSize) { " ... (+$($updatedDevices.Count - $LogSampleSize) more)" } else { "" }
                $pendingSuffix = if ($stillPendingDevices.Count -gt $LogSampleSize) { " ... (+$($stillPendingDevices.Count - $LogSampleSize) more)" } else { "" }
                Write-Log "Updated devices ($($updatedDevices.Count)): $($updatedSample -join ', ')$updatedSuffix" "OK"
                Write-Log "Still pending ($($stillPendingDevices.Count)): $($pendingSample -join ', ')$pendingSuffix" "WARN"
                Write-Log "" "INFO"
                Write-Log "To manually unblock this bucket after verification, run:" "INFO"
                Write-Log "  .\$ScriptName.ps1 -ReportBasePath `"$ReportBasePath`" -UnblockBucket `"$bucketKey`"" "INFO"
                Write-Log "=======================================================" "INFO"
                Write-Log "" "INFO"
            }
        }
    }
    
    return $autoUnblocked
}


# ============================================================================
# AUTO-UNBLOCK: Unblock buckets when devices update successfully
# ============================================================================

function Update-AutoUnblockedBuckets {
    <#
    .DESCRIPTION
        Checks if devices in blocked buckets have updated (Event 1808).
        
        Auto-unblocks if ALL targeted devices in the bucket have updated.
        If only SOME devices updated, notifies admin who can manually unblock.
        
        Admin can manually unblock using:
          .\$ScriptName.ps1 -ReportBasePath "path" -UnblockBucket "BucketKey"
    #>
    param(
        $BlockedBuckets,
        $RolloutState,
        [array]$NotUpdatedDevices,
        [string]$ReportBasePath,
        [hashtable]$NotUpdatedIndexes,
        [int]$LogSampleSize = 25
    )
    
    $autoUnblocked = @()
    $bucketsToCheck = @($BlockedBuckets.Keys)
    $hostSet = if ($NotUpdatedIndexes -and $NotUpdatedIndexes.HostSet) { $NotUpdatedIndexes.HostSet } else { (Get-NotUpdatedIndexes -Devices $NotUpdatedDevices).HostSet }
    
    foreach ($bucketKey in $bucketsToCheck) {
        $bucketInfo = $BlockedBuckets[$bucketKey]
        
        # Get all devices we targeted from this bucket historically
        $targetedDevicesInBucket = @()
        foreach ($wave in $RolloutState.WaveHistory) {
            $targetedDevicesInBucket += @($wave.Devices | Where-Object { $_.BucketKey -eq $bucketKey })
        }
        
        if ($targetedDevicesInBucket.Count -eq 0) { continue }
        
        # Check how many targeted devices are still in NotUpdated vs updated
        $updatedDevices = @()
        $stillPendingDevices = @()
        
        foreach ($targetedDevice in $targetedDevicesInBucket) {
            if ($hostSet.Contains($targetedDevice.Hostname)) {
                $stillPendingDevices += $targetedDevice.Hostname
            } else {
                $updatedDevices += $targetedDevice.Hostname
            }
        }
        
        # We're actually tracking the exact "Confidence" based reason the bucket/device was blocked in the first place. This way we're able to here get more info to make a decition if we want to try and manually unblock a bucket.
        $blockType = $bucketInfo.BlockType
        if ($blockType -eq "Confidence") {
            Write-Log "SKIPPED AUTO-UNBLOCK (confidence block), $($bucketInfo.BlockSubType): Bucket - $bucketKey" "INFO"
            continue
        }
        # ============= BIG IF
        if ($updatedDevices.Count -gt 0 -and $stillPendingDevices.Count -eq 0) {
            # ALL targeted devices have updated - auto-unblock!
            $BlockedBuckets.Remove($bucketKey)
            $autoUnblocked += @{
                BucketKey = $bucketKey
                UpdatedDevices = $updatedDevices
                PreviouslyBlockedAt = $bucketInfo.BlockedAt
                Reason = "All $($updatedDevices.Count) targeted device(s) successfully updated"
            }
            Write-Log "AUTO-UNBLOCKED: $bucketKey - All $($updatedDevices.Count) device(s) updated" "OK"
            
        $bucketOEM = if ($bucketKey -match '\|') {
            ($bucketKey -split '\|')[0]
        } else { 'Unknown' }

        if (-not $RolloutState.OEMWaveCounts) {
            $RolloutState.OEMWaveCounts = @{}
        }

        $currentWave = if ($RolloutState.OEMWaveCounts[$bucketOEM]) {
            $RolloutState.OEMWaveCounts[$bucketOEM]
        } else { 0 }

        $RolloutState.OEMWaveCounts[$bucketOEM] = $currentWave + 1
        Write-Log "  OEM '$bucketOEM' wave count incremented to $($currentWave + 1) (next allocation: $([int][Math]::Pow(2, $currentWave + 1)) devices)" "INFO"
        
        else {
            Write-Log "  OEM wave count NOT incremented for $bucketKey due to confidence-based block" "INFO"
        }
        } # ============= BIG IF/END

        elseif ($updatedDevices.Count -gt 0 -and $stillPendingDevices.Count -gt 0) {
            # SOME devices updated but others are still pending - notify admin (only once)
            if (-not $bucketInfo.UnblockCandidate) {
                $bucketInfo.UnblockCandidate = $true
                $bucketInfo.UpdatedDevices = $updatedDevices
                $bucketInfo.PendingDevices = $stillPendingDevices
                $bucketInfo.NotifiedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                
                Write-Log "" "INFO"
                Write-Log "========== PARTIAL UPDATE IN BLOCKED BUCKET ==========" "INFO"
                Write-Log "Bucket: $bucketKey" "INFO"
                $updatedSample = @($updatedDevices | Select-Object -First $LogSampleSize)
                $pendingSample = @($stillPendingDevices | Select-Object -First $LogSampleSize)
                $updatedSuffix = if ($updatedDevices.Count -gt $LogSampleSize) { " ... (+$($updatedDevices.Count - $LogSampleSize) more)" } else { "" }
                $pendingSuffix = if ($stillPendingDevices.Count -gt $LogSampleSize) { " ... (+$($stillPendingDevices.Count - $LogSampleSize) more)" } else { "" }
                Write-Log "Updated devices ($($updatedDevices.Count)): $($updatedSample -join ', ')$updatedSuffix" "OK"
                Write-Log "Still pending ($($stillPendingDevices.Count)): $($pendingSample -join ', ')$pendingSuffix" "WARN"
                Write-Log "" "INFO"
                Write-Log "To manually unblock this bucket after verification, run:" "INFO"
                Write-Log "  .\$ScriptName.ps1 -ReportBasePath `"$ReportBasePath`" -UnblockBucket `"$bucketKey`"" "INFO"
                Write-Log "=======================================================" "INFO"
                Write-Log "" "INFO"
            }
        }
    }
    
    return $autoUnblocked
}

# ============================================================================
# WAVE GENERATION (INLINED - excludes blocked buckets)
# ============================================================================

function New-RolloutWave {
    param(
        [array]$NotUpdated,
        [array]$UpdatedDevices,
        $BlockedBuckets,
        $RolloutState,
        [int]$MaxDevicesPerWave = 50 #Configure the max number of devices you want to allow in each wave. Default: 50
    )
    
    #Do a sanity-check to ensure previous steps have ran and we have a working device list
    if (-not $notUpdatedDevices) {
        Write-Log "No 'NotUptodate' CSV found" "ERROR"
        return $null
    } else {
        Write-Log "Using $notUpdatedDevices this Wave" "INFO"
    }
    
    # Normalize HostName -> Hostname for consistency (CSV uses HostName, code uses Hostname)
    foreach ($device in $notUpdatedDevices) {
        if ($device.PSObject.Properties['HostName'] -and -not $device.PSObject.Properties['Hostname']) {
            $device | Add-Member -NotePropertyName 'Hostname' -NotePropertyValue $device.HostName -Force
        }
    }
    
    # Filter out blocked buckets, it makes no distinction as to why the device is blocked. This is intentional as all that information gets provided to log through other functions. But worth pointing out
    $eligibleDevices = @($notUpdatedDevices | Where-Object {
        $bucketKey = Get-BucketKey $_
        -not $BlockedBuckets -or -not $BlockedBuckets.Contains($bucketKey)
    })
    
    #WARNING! This can potentially cause problems!
    if ($eligibleDevices.Count -eq 0) {
        Write-Log "No eligible devices remaining (all updated or blocked)" "OK"
        return $null
    }
    
    # Get devices already in rollout (from previous waves)
    $devicesAlreadyInRollout = @()
    if ($RolloutState.WaveHistory -and $RolloutState.WaveHistory.Count -gt 0) {
        $devicesAlreadyInRollout = @($RolloutState.WaveHistory | ForEach-Object { 
            $_.Devices | ForEach-Object { $_.Hostname }
        } | Where-Object { $_ })
    }
    
    Write-Log "Devices already in rollout: $($devicesAlreadyInRollout.Count)" "INFO"
    
    # Separate by confidence level
    $highConfidenceDevices = @($eligibleDevices | Where-Object { 
        $_.Confidence -eq "High Confidence" -and 
        $_.Hostname -notin $devicesAlreadyInRollout 
    })
    
    # Action Required includes:
    # - Explicit "Action Required" 
    # - Empty/null ConfidenceLevel
    # - ANY unknown/unrecognized ConfidenceLevel value (treated as Action Required)
    $knownSafeCategories = @(
        "High Confidence",
        "Temporarily Paused",
        "Under Observation",
        "Under Observation - More Data Needed",
        "Not Supported",
        "Not Supported - Known Limitation"
    )
    
    $actionRequiredDevices = @($eligibleDevices | Where-Object { 
        $_.Confidence -notin $knownSafeCategories -and
        $_.Hostname -notin $devicesAlreadyInRollout
    })
    
    Write-Log "High Confidence (not in rollout): $($highConfidenceDevices.Count)" "INFO"
    Write-Log "Action Required (not in rollout): $($actionRequiredDevices.Count)" "INFO"
    
    # Build wave devices
    $waveDevices = @()
    
    # HIGH CONFIDENC\ Include ALL (safe for rollout)
    if ($highConfidenceDevices.Count -gt 0) {
        Write-Log "Adding all $($highConfidenceDevices.Count) High Confidence devices" "WAVE"
        $waveDevices += $highConfidenceDevices
    }
    
# ACTION REQUIRED: Progressive rollout (bucket-based with OEM-spread for zero-success buckets)
    # Strategy:
    #   - Buckets with 0 successes: Spread across OEMs (1 per OEM -> 2 per OEM -> 4 per OEM)
    #   - Buckets with ≥1 success: Double freely without OEM restriction
    if ($actionRequiredDevices.Count -gt 0) {
        # Load bucket success counts from updated devices CSV (devices that successfully updated)
        $updatedCsv = Get-ChildItem -Path $AggregationPath -Filter "*updated_devices*.csv" |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        
        $bucketStats = @{}
        if ($updatedCsv) {
            $updatedDevices = Import-Csv $updatedCsv.FullName
            # Count successes per BucketId
            $updatedDevices | ForEach-Object {
                $key = Get-BucketKey $_
                if ($key) {
                    if (-not $bucketStats.ContainsKey($key)) {
                        $bucketStats[$key] = @{ Successes = 0; Pending = 0; Total = 0 }
                    }
                    $bucketStats[$key].Successes++
                    $bucketStats[$key].Total++
                }
            }
            Write-Log "Loaded $($updatedDevices.Count) updated devices across $($bucketStats.Count) buckets" "INFO"
        } else {
            # Fallback: try ActionRequired_Buckets CSV
            $bucketsCsv = Get-ChildItem -Path $AggregationPath -Filter "*ActionRequired_Buckets*.csv" |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($bucketsCsv) {
                Import-Csv $bucketsCsv.FullName | ForEach-Object {
                    $key = if ($_.BucketId) { $_.BucketId } else { "$($_.Manufacturer)|$($_.Model)|$($_.BIOS)" }
                    $bucketStats[$key] = @{
                        Successes = [int]$_.Successes
                        Pending   = [int]$_.Pending
                        Total     = [int]$_.TotalDevices
                    }
                }
            }
        }
        
        # Group NotUpdated devices by bucket (Manufacturer|Model|BIOS)
        $buckets = $actionRequiredDevices | Group-Object { Get-BucketKey $_ }
        
        # Separate buckets: zero-success vs has-success
        $zeroSuccessBuckets = @()
        $hasSuccessBuckets = @()
        
        foreach ($bucket in $buckets) {
            $bucketKey = $bucket.Name
            $bucketDevices = @($bucket.Group)
            $bucketHostnames = @($bucketDevices | ForEach-Object { $_.Hostname })
            
            # Count successes in this bucket
            $stats = $bucketStats[$bucketKey]
            $successes = if ($stats) { $stats.Successes } else { 0 }
            
            # Find devices deployed to this bucket from wave history
            $deployedToBucket = @()
            foreach ($wave in $RolloutState.WaveHistory) {
                foreach ($device in $wave.Devices) {
                    if ($device.BucketKey -eq $bucketKey -and $device.Hostname) {
                        $deployedToBucket += $device.Hostname
                    }
                }
            }
            $deployedToBucket = @($deployedToBucket | Sort-Object -Unique)
            
            # Check if ALL deployed devices reported success
            $stillPending = @($deployedToBucket | Where-Object { $_ -in $bucketHostnames })
            $confirmedSuccess = $deployedToBucket.Count - $stillPending.Count
            
            # If pending, skip this bucket until all confirm
            if ($stillPending.Count -gt 0) {
                $parts = $bucketKey -split '\|'
                $displayName = "$($parts[0]) - $($parts[1])"
                Write-Log "  Bucket: $displayName - Deployed=$($deployedToBucket.Count), Confirmed=$confirmedSuccess, Pending=$($stillPending.Count) (waiting)" "INFO"
                continue
            }
            
            # Remaining eligible = devices not yet deployed
            $devicesNotYetTargeted = @($bucketDevices | Where-Object {
                $_.Hostname -notin $deployedToBucket
            })
            
            if ($devicesNotYetTargeted.Count -eq 0) { continue }
            
            # Categorize by success count
            $bucketInfo = @{
                BucketKey = $bucketKey
                Devices = $devicesNotYetTargeted
                ConfirmedSuccess = $confirmedSuccess
                Successes = $successes
                OEM = if ($bucket.Group[0].WMI_Manufacturer) { $bucket.Group[0].WMI_Manufacturer } elseif ($bucketKey -match '\|') { ($bucketKey -split '\|')[0] } else { 'Unknown' }
            }
            
            if ($successes -eq 0) {
                $zeroSuccessBuckets += $bucketInfo
            } else {
                $hasSuccessBuckets += $bucketInfo
            }
        }
        
        # === PROCESS HAS-SUCCESS BUCKETS (≥1 success) ===
        # Double the number of successes — if 14 succeeded, deploy 28 next
        foreach ($bucketInfo in $hasSuccessBuckets) {
            $nextBatchSize = $bucketInfo.Successes * 2
            $nextBatchSize = [Math]::Min($nextBatchSize, $MaxDevicesPerWave)
            $nextBatchSize = [Math]::Min($nextBatchSize, $bucketInfo.Devices.Count)
            
            if ($nextBatchSize -gt 0) {
                $selectedDevices = @($bucketInfo.Devices | Select-Object -First $nextBatchSize)
                $waveDevices += $selectedDevices
                
                $parts = if ($bucketInfo.BucketKey -match '\|') { $bucketInfo.BucketKey -split '\|' } else { @($bucketInfo.OEM, $bucketInfo.BucketKey.Substring(0, [Math]::Min(12, $bucketInfo.BucketKey.Length))) }
                $displayName = "$($parts[0]) - $($parts[1])"
                Write-Log "  [HAS-SUCCESS] $displayName - Successes=$($bucketInfo.Successes), Deploying=$nextBatchSize (2x confirmed)" "INFO"
            }
        }
        
        # === PROCESS ZERO-SUCCESS BUCKETS (spread across OEMs with per-OEM tracking) ===
        # Goal: Spread risk across different OEMs, track progress per OEM independently
        # Each OEM progresses based on its own success history:
        #   - OEM with successes: Gets more devices next wave (2^waveCount)
        #   - OEM without successes: Stays at current level until success confirmed
        if ($zeroSuccessBuckets.Count -gt 0) {
            # Initialize per-OEM wave counts if not exists
            if (-not $RolloutState.OEMWaveCounts) {
                $RolloutState.OEMWaveCounts = @{}
            }
            
            # Group zero-success buckets by OEM
            $oemBuckets = $zeroSuccessBuckets | Group-Object { $_.OEM }
            
            $totalZeroSuccessAdded = 0
            $oemsDeployedTo = @()
            
            foreach ($oemGroup in $oemBuckets) {
                $oemName = $oemGroup.Name
                
                # Get this OEM's wave count (starts at 0)
                $oemWaveCount = if ($RolloutState.OEMWaveCounts[$oemName]) { 
                    $RolloutState.OEMWaveCounts[$oemName] 
                } else { 0 }
                
                # Calculate devices for THIS OEM: 2^waveCount (1, 2, 4, 8...)
                $devicesForThisOEM = [int][Math]::Pow(2, $oemWaveCount)
                $devicesForThisOEM = [Math]::Max(1, $devicesForThisOEM)
                
                $oemDevicesAdded = 0
                
                # Pick from each bucket under this OEM
                foreach ($bucketInfo in $oemGroup.Group) {
                    $remaining = $devicesForThisOEM - $oemDevicesAdded
                    if ($remaining -le 0) { break }
                    
                    $toTake = [Math]::Min($remaining, $bucketInfo.Devices.Count)
                    if ($toTake -gt 0) {
                        $selectedDevices = @($bucketInfo.Devices | Select-Object -First $toTake)
                        $waveDevices += $selectedDevices
                        $oemDevicesAdded += $toTake
                        $totalZeroSuccessAdded += $toTake
                        
                        $parts = if ($bucketInfo.BucketKey -match '\|') { $bucketInfo.BucketKey -split '\|' } else { @($bucketInfo.OEM, $bucketInfo.BucketKey.Substring(0, [Math]::Min(12, $bucketInfo.BucketKey.Length))) }
                        $displayName = "$($parts[0]) - $($parts[1])"
                        Write-Log "  [ZERO-SUCCESS] $displayName - Deploying=$toTake (OEM wave $oemWaveCount = ${devicesForThisOEM}/OEM)" "WARN"
                    }
                }
                
                if ($oemDevicesAdded -gt 0) {
                    Write-Log "    OEM: $oemName - Wave $oemWaveCount, Added $oemDevicesAdded devices" "INFO"
                    $oemsDeployedTo += $oemName
                }
            }
            
            # Track which OEMs we deployed to (for incrementing on next success check)
            if ($oemsDeployedTo.Count -gt 0) {
                $RolloutState.PendingOEMWaveIncrement = $oemsDeployedTo
                Write-Log "Zero-success deployment: $totalZeroSuccessAdded devices across $($oemsDeployedTo.Count) OEMs" "INFO"
            }
        }
    }
    
    if (@($waveDevices).Count -eq 0) {
        return $null
    }
    
    return $waveDevices
}









# ============================================================================
# MAIN ORCHESTRATION LOOP
# ============================================================================

Write-Host ""
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host "   SECURE BOOT ROLLOUT ORCHESTRATOR - CONTINUOUS DEPLOYMENT" -ForegroundColor Cyan
Write-Host ("=" * 80) -ForegroundColor Cyan
Write-Host ""

if ($DryRun) {
    Write-Host "[DRY RUN MODE]" -ForegroundColor Magenta
}

Write-Log "=================================================="
Write-Log "Starting Secure Boot Rollout Orchestrator" "START"
Write-Log "Input Path: $AggregationInputPath" "INFO"
Write-Log "Report Path: $ReportBasePath" "INFO"
Write-Log "Deployment Method: WinCSFlag" "INFO"
Write-Log "Max Wait Hours: $MaxWaitHours" "INFO"
Write-Log "Poll Interval: $PollIntervalMinutes minutes" "INFO"
<# if ($LargeScaleMode) {
    Write-Log "LargeScaleMode enabled (batch size: $ProcessingBatchSize, log sample: $DeviceLogSampleSize)" "INFO"
} #>


# ============================================================================
# PREREQUISITE CHECK: Verify detection is deployed and working
# ============================================================================

Write-Host ""
<# # Check data freshness - not required
$freshness = Get-DataFreshness -JsonPath $AggregationInputPath
Write-Log "Data freshness: $($freshness.TotalFiles) files, $($freshness.FreshFiles) fresh (<24h), $($freshness.StaleFiles) stale (>72h)" "INFO"
if ($freshness.Warning) {
    Write-Log $freshness.Warning "WARN"
}
 #>

# Load states
$rolloutState = Get-RolloutState
$blockedBuckets = Get-BlockedBuckets
$adminApproved = Get-AdminApproved
$deviceHistory = Get-DeviceHistory


if ($rolloutState.Status -eq "NotStarted") {
    $rolloutState.Status = "InProgress"
    $rolloutState.StartedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Log "Starting new rollout" "WAVE"
}

Write-Log "Current Wave: $($rolloutState.CurrentWave)" "INFO"
Write-Log "Blocked Buckets: $($blockedBuckets.Count)" "INFO"
$OrchestratorVersion = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

#=============================================================
# Main loop - runs until all eligible devices are updated
#=============================================================
$iterationCount = 0
while ($true) {
    $iterationCount++
    Write-Log "" "INFO"
    Write-Log ("=" * 20) "INFO"
    Write-Log "=== ITERATION $iterationCount ===" "WAVE"
    Write-Log ("=" * 20) "INFO"
    Write-Log "Running Orchestrator version: $OrchestratorVersion" "INFO"
    Write-Log "" "INFO"

#=============================================================
# Step 1: Run aggregation
#=============================================================

   #Baseline assumption is that we need new data.
    $needsAggregation = $true
   # Bootstrap scenario, when this is the very first time we run
    if (-not (Test-Path $AggregationPath)) {
        Write-Log "Aggregation path does not exist yet. Forcing initial aggregation run" "WARN"
        if (-not (Test-Path $AggregationPath)) {
            Write-Log "Trying to generate the folder for results" "INFO"
            New-Item -ItemType Directory -Path $AggregationPath -Force | Out-Null
        }
        $needsAggregation = $true
        $NotUpdatedcsv = $null
    }
    else {
        # Check to see if Orchestrator is using fresh enough data. Runs Aggregate-SecureBootData.ps1 after a set amount of time to grab new data.
        # Retrieve the latest file by grabbing all available, sorting by create date and keeping the most recent one. 
        $NotUpdatedcsv = Get-LatestFile -FilePath $AggregationPath -fileName "SecureBoot_NotUptodate*.csv"
        #Write-Log "Retrieved NotUpdatedcsv" "INFO"
        $needsAggregation = $true
        if ($NotUpdatedcsv) {
            $age = (Get-Date) - $NotUpdatedcsv.LastWriteTime
            #Change number here to tweak how often it should fetch new data. Recommended in production: Faster updates: 120/240 = 2/4h Slow: 480 = 8h
            if ($age.TotalMinutes -lt 120) {
                $needsAggregation = $false
            }
        }
    }
  
    #Retrieve
    if (-not $DryRun){
        if ($NotUpdatedcsv) {
            #Change number here to tweak how often it should fetch new data. Recommended in production, Fast: 120/240 = 2/4h | Slow: 480 = 8h (Swedens "default" is configured around 120 = 2h)
            $age = (Get-Date) - $NotUpdatedcsv.LastWriteTime
            if ($age.TotalMinutes -lt 120) {
                $needsAggregation = $false
            }
        }
        #Calls on actual Aggregate script to compile new data for Orchestrator.
        if ($needsAggregation) {
            Write-Log "Step 1: Running aggregation..." "WAVE"
            Write-Log "Aggregation required (data stale or missing)" "WARN"
            
            #START start by building params/arguments to feed function, provide values
            $params = @{
                AggregateFile = Join-Path $LocalfilePath "Aggregate-SecureBootData.ps1"
                InputPath = $AggregationInputPath
            }

            #Run function, attempts to update aggregation data for orchestrator
            $success = Get-LatestAggregation @params
            #END
            if (-not $success) {
                Write-Log "Canceling iteration due to aggregation failure" "BLOCKED"
                #Something went wrong when running Aggregate script. waiting five minutes before starting entire loop from beginning again. This means Orchestrator won't actually do anything unless it's sure the data it's using is fresh!
                Start-Sleep -Seconds 300
                continue
            } else {
                Write-Log "Aggregation data updated" "INFO"
                #Refresh the file after we've ran Aggregation, otherwise Step 2 will break
                $NotUpdatedcsv = Get-LatestFile -FilePath $AggregationPath -fileName "SecureBoot_NotUptodate*.csv"
                Write-Log "Refreshed NotUpdatedcsv after aggregation" "INFO"
            }
        }else {
            Write-Log "Aggregation skipped (data still fresh)" "INFO"
        }
    } else { #Result if doing testruns (-DryRun enabled)
            Write-Log "[DRYRUN] Would run aggregation" "INFO"
            # In DryRun, use existing aggregation data from ReportBasePath directly
            $AggregationPath = $ReportBasePath
            #Rest of DryRun code here?-->
    }


#=============================================================
# Step 2: Gathering device status
#=============================================================

    if ($needsAggregation){
        # Removing noise from log
        Write-Log "Step 2: Preparing device status..." "WAVE"
    }
    $notUpdatedDevices = @()
    #Try to handle import failures. Currently only logging that an issue occured but won't halt the loop
    if ($NotUpdatedcsv){
        try {
           $notUpdatedDevices = Import-Csv $NotUpdatedcsv.FullName
           Write-Log "Devices not updated: $($notUpdatedDevices.Count)" "INFO"
        }
        catch {
            Write-Log "Failed to import CSV: $($_.Exception.Message)" "ERROR"
        }
    }
    #Variable has terrible name. Can't change without risking problems with other Functions/code. Generates a hashtable with hostnames & number of different buckets from list of devices that aren't updated yet.
    $notUpdatedIndexes = Get-NotUpdatedIndexes -Devices $notUpdatedDevices
    #Orchestrator tracks unique devices by hostnames
    # Write-Log "Updating device history..." "INFO"
    Update-DeviceHistory -CurrentDevices $notUpdatedDevices -DeviceHistory $deviceHistory
    Save-DeviceHistory -History $deviceHistory


#=============================================================
# Step 3: Evaluating buckets for current itteration
#=============================================================
#Get a "status"/baseline of how many blocked buckets we currently have before running any chekcs on them.
$existingBlockedCount = if ($blockedBuckets) { $blockedBuckets.Count } else { 0 }

# Removing noise from log
if ($needsAggregation){
    Write-Log "Step 3: Evaluating buckets (confidence + lifecycle + history)..." "WAVE"
}
if ($existingBlockedCount -gt 0) {
    Write-Log "Currently blocked buckets from previous runs: $existingBlockedCount" "INFO"
}
#You can manually unblock buckets using the "admin" override, so this respects that argument.
if ($adminApproved -and $adminApproved.Count -gt 0) {
    Write-Log "Admin-approved buckets (will not be re-blocked): $($adminApproved.Count)" "INFO"
}

# IMPORTANT! THIS SINGLE LINE OF CODE IS THE SECOND MOST IMPORTANT PART OF THE WHOLE SYSTEM, no joke <.< This is the function call that evaluates and determines which "buckets" (and thus devcies) that should be included in this "wave".
$newlyBlocked = Update-BlockedBuckets -RolloutState $rolloutState -BlockedBuckets $blockedBuckets -AdminApproved $adminApproved -NotUpdatedDevices $notUpdatedDevices -NotUpdatedIndexes $notUpdatedIndexes -DeviceHistory $deviceHistory -MaxWaitHours $MaxWaitHours -DryRun:$DryRun
# Save results of above function and also logs it, seperate from the entries already generated by function.
if ($newlyBlocked -and $newlyBlocked.Count -gt 0) {
    Save-BlockedBuckets -Blocked $blockedBuckets
    foreach ($bucket in $newlyBlocked) {
        $info = $blockedBuckets[$bucket]
        Write-Log " NOW BLOCKING: $bucket - Type=$($info.Reason) - $($info.BlockSubType)" "BLOCKED"
    }
    Write-Log "Newly blocked buckets (this iteration): $($newlyBlocked.Count)" "INFO"
}

# Auto-unblock step, unblocking buckets that had been blocked in previous itteration/waves
$autoUnblocked = Update-AutoUnblockedBuckets -BlockedBuckets $blockedBuckets -RolloutState $rolloutState -NotUpdatedDevices $notUpdatedDevices -ReportBasePath $ReportBasePath -NotUpdatedIndexes $notUpdatedIndexes -LogSampleSize $DeviceLogSampleSize

if ($autoUnblocked -and $autoUnblocked.Count -gt 0) {
    Save-BlockedBuckets -Blocked $blockedBuckets
    foreach ($entry in $autoUnblocked) {
        Write-Log "AUTO-UNBLOCKED: $($entry.BucketKey)" "OK"
    }
    Write-Log "Auto-unblocked buckets (this iteration): $($autoUnblocked.Count)" "INFO"
}



#=============================================================
# Step 4: Calculate remaining eligible devices
#=============================================================
    $eligibleCount = 0 #Always assume the worst
    foreach ($device in $notUpdatedDevices) {
        $bucketKey = Get-BucketKey $device
        if (-not $blockedBuckets -or -not $blockedBuckets.Contains($bucketKey)) {
            $eligibleCount++
        }
    }
    Write-Log "" "INFO"
    Write-Log "================== PRE-WAVE CHECKS ALL COMPLETED ===============" "WAVE"
    Write-Log "Eligible devices remaining: $eligibleCount" "WAVE"
    Write-Log "Blocked buckets: $($blockedBuckets.Count)" "WAVE"
        # Check completion
    if ($eligibleCount -eq 0) {
        Write-Log "======= ROLLOUT COMPLETE - All eligible devices updated! =======" "OK"
        $rolloutState.Status = "Completed"
        $rolloutState.CompletedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Save-RolloutState -State $rolloutState
        Write-Log "================================================================" "WAVE"
        Write-Log "" "INFO"
        break
    }
    Write-Log "================================================================" "WAVE"
    Write-Log "" "INFO"

#=============================================================
# Step 5: Generate and deploy next wave
#=============================================================     
    # ========================================================
    # PREFLIGHT WAVE PROGRESS GATE
    # ========================================================
    <# .DESCRIPTION
    Configurable parameters that determine:
        - The % of devices that need to report back that they succeeded before Orchestrator considers wave to be "successful". Represented as percentile (1.0 = 100%)
        - The number of hours it waits after reaching the target for any remaining devices before ending this wave regardless.
        - The total number of hours each Wave is allowed to last, regardless of outcome.
    This is all so we don't end up in a scenario where X number of devices that passed the prerequisites actually end up stalling/failing and then freezing the entire wave.
    All three values are set low during development/testing to facilitate rapid log & data generation.
    #>
    $SuccessThreshold = 0.70
    $WaveGraceHours   = 8
    $WaveMaxHours     = 72

    # Default is always to allow Wave generation, the comming condition blocks acts as a conditional gate that can close
    $canStartNextWave = $true

    #Has any wave been generated previously?
    if ($rolloutState.WaveHistory -and $rolloutState.WaveHistory.Count -gt 0) {
        #Get the latest Wave deployed
        $lastWave = $rolloutState.WaveHistory | Sort-Object WaveNumber -Descending | Select-Object -First 1
        #We only evaluate the wave if it's not marked as "completed"
        if (-not $lastWave.CompletedAt) {
            # How long has this wave ran? Primarily so we can match it against or max allowed timer
            $waveStart = [datetime]::Parse($lastWave.StartedAt)
            $hoursSinceWave = ((Get-Date) - $waveStart).TotalHours

            #The values that will be used to calculate our "success rate". success% = updated ($devices) / total (# of devices that are part of the wave). 
            $devices = @($lastWave.Devices)
            $total = $devices.Count

            # Get the number for the "updated" part of calculation. We also cover for the likely scenario that a device has succeeded but is waiting for a reboot to finish, which we count as a Wave success.
            $updatedCount = 0
            foreach ($d in $devices) {
                $hn = $d.Hostname
                if ($deviceHistory -and $deviceHistory.Contains($hn)) {
                    if (
                        $deviceHistory[$hn].Status -eq "Updated" -or
                        $deviceHistory[$hn].Status -eq "RebootPending"
                        ) { $updatedCount++ }
                }
            }

            #Actual success calculation
            $successRate = if ($total -gt 0) { $updatedCount / $total } else { 0 }
            Write-Log "Wave $($lastWave.WaveNumber) progress: $updatedCount/$total ($([math]::Round($successRate*100,1))%)" "WAVE"
            # Decition/break logic - we start with assuming the wave isn't ready to end yet
            $shouldProceed = $false

            # Ideal scenario - Condition: 100% succeeded
            if ($total -gt 0 -and $updatedCount -eq $total) {
                Write-Log "Wave $($lastWave.WaveNumber): reached 100% updated devices" "OK"
                $shouldProceed = $true
            }

            # % threshold fallback reached - Condition: If at least some devices have succeeded AND we haven't yet reached the max time for a Wave
            elseif ($successRate -ge $SuccessThreshold) {
                if (-not $lastWave.ThresholdReachedAt) {
                    $lastWave.ThresholdReachedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                    Write-Log "Wave $($lastWave.WaveNumber): THRESHOLD REACHED ($([math]::Round($successRate*100,1))%). Starting grace period of ($WaveGraceHours)h before marking Wave as success" "WARN"
                    #Save the current state
                    Save-RolloutState -State $rolloutState
                }

                #We make note of *when* threshold was reached to allow for grace period math
                $thresholdTime = [datetime]::Parse($lastWave.ThresholdReachedAt)
                $hoursSinceThreshold = ((Get-Date) - $thresholdTime).TotalHours

                # Grace period fallback reached - Condition: Minimum acceptable % of devices report "Updated" AND we've waited Nh more
                if ($hoursSinceThreshold -ge $WaveGraceHours) {
                    Write-Log "Wave $($lastWave.WaveNumber): ($([math]::Round($successRate*100,1))%) of devices report 'Updated' and grace period has expired" "WARN"
                    $shouldProceed = $true
                }
                else {
                    Write-Log "Wave $($lastWave.WaveNumber): Still in grace period. ($([math]::Round($hoursSinceThreshold,1))/$WaveGraceHours h) remaining" "INFO"
                }
            }

            # Max duration fallback reached - Condition: There are stil ldevices in wave that don't report status as 'Updated' AND % of devices reporting 'Updated' has *not* been reached AND max allowed time for each wave has been reached
            elseif ($hoursSinceWave -ge $WaveMaxHours) {
                Write-Log "Wave $($lastWave.WaveNumber): EXPIRED! (max duration reached: $([math]::Round($hoursSinceWave,1))h) without devices reporting back 'Updated' status" "WARN"
                $shouldProceed = $true
            }
            else {
                Write-Log "Wave $($lastWave.WaveNumber): still in progress (looking OK)" "INFO"
            }

            # Enforce gate - blocking new Wave creation
            if (-not $shouldProceed) {
                $canStartNextWave = $false
                #WWrite-Log "Wave $($lastWave.WaveNumber): still in progress, still monitoring" "INFO"
            }
            else {
                #Persists Wave completion timestamp across itterations. Prevents repeat evaluations (resource intensive)
                if (-not $lastWave.CompletedAt) {
                    $lastWave.CompletedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                    Save-RolloutState -State $rolloutState
                }
            }
        }
    }


    # ========================================================
    # WAVE GENERATION
    # ========================================================

    <# Breakdown/explanation of all the arguments sent to [New-RolloutWave] function:
        -AllNotUpdated      comes from the NotUpdated.scv, a file with all devices that stil lhaven't been updated.
        -UpdatedDevices     comes from Update-AutoUnblockedBuckets function. All the devices that have actually updated so far in the itteration7wave (?).
        - BlockedBuckets    all the Buckets that have been blocked bu Update-BlockedBuckets function. Devices/buckets/groups that should be ignored this time for noe reason or another.
        -RolloutState       .json file with current progress of rollout/wave (?).
        -AllowedHostnames
        -ExcludedHostnames  Legacy functions not used/expected in the current Orchestrator design. But specific devices you want to allow or exclude. Circumventing Bucket logic.#>
    if ($canStartNextWave) {
        Write-Log "Step 5: Generating rollout wave..." "WAVE"
        $waveDevices = New-RolloutWave  -AllNotUpdated $notUpdatedDevices -UpdatedDevices $updatedDevices -BlockedBuckets $blockedBuckets -RolloutState $rolloutState -AllowedHostnames $allowedHostnames -ExcludedHostnames $excludedHostnames
    }
    else {
        Write-Log "Skipping Wave generation: Waiting for curent wave to complete" "WAVE"
        #Making $waveDevices empty to force upcomming section to switch to monitoring mode
        $waveDevices = @()
    }

    # Check if we have devices to deploy ($waveDevices could be $null, empty, or with actual devices)
    $hasDevices = $waveDevices -and @($waveDevices | Where-Object { $_ }).Count -gt 0
    
    if ($hasDevices) {
        # Only increment wave number when we actually have devices to deploy
        $rolloutState.CurrentWave++
        Write-Log "Wave $($rolloutState.CurrentWave): contains $(@($waveDevices).Count) device-s" "WAVE"
        
        # Deploy GPO using inlined function
        <# $gpoName = "${WavePrefix}-Wave$($rolloutState.CurrentWave)"
        $securityGroup = "${WavePrefix}-Wave$($rolloutState.CurrentWave)" #>
        $hostnames = @($waveDevices | ForEach-Object { 
            if ($_.Hostname) { $_.Hostname } elseif ($_.HostName) { $_.HostName } else { $null }
        } | Where-Object { $_ })
        
        # Save hostnames file for reference/audit
        $hostnamesFile = Join-Path $stateDir "Wave$($rolloutState.CurrentWave)_Hostnames.txt"
        $hostnames | Out-File $hostnamesFile -Encoding UTF8
        
        # Validate we have hostnames to deploy to
        if ($hostnames.Count -eq 0) {
            Write-Log "No valid hostnames found in wave $($rolloutState.CurrentWave) - devices may be missing Hostname property" "ERROR"
            Write-Log "Skipping deployment for this wave - check device data!" "BLOCKED"
            # If we don't, wait some time before next iteration
            if (-not $DryRun) {
                Write-Log "Sleeping for $PollIntervalMinutes minutes before retry..." "INFO"
                Write-Log "" "INFO"
                Start-Sleep -Seconds ($PollIntervalMinutes * 60)
            }
            continue
        }
        #Write-Log "Deploying to $($hostnames.Count) hostnames in Wave $($rolloutState.CurrentWave)" "INFO"
        # =====================================================================
        # Build manifest - used to have devices self-apply updates/progess
        # =====================================================================
        <# In order for the Orchestrator to actually have any effect and not just monitor. 
            1. We generate a file with the hostnames that are part of the wave. 
            2. Store it on the network share and have endpoints (via locally running Scheduled Tasks) periodically poll for this file. 
            3. If it detects it, read it and see if hostname matches. In that case it tries to start WinCSFlags.exe to set its flag to mark that it needs to update certificates.
            4. other logic inside Orchestrator handles verifying successrate and progress of them.#>
        $manifestPath = Join-Path $AggregationInputPath "WaveManifest.json"
        $manifest = @{
            WaveNumber = $rolloutState.CurrentWave
            Devices    = $hostnames
            CreatedAt  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
        $manifest | ConvertTo-Json -Depth 3 | Out-File $manifestPath -Encoding UTF8 -Force
        Write-Log "" "INFO"
        Write-Log "  Wave $($rolloutState.CurrentWave): manifest created" "WAVE"
        Write-Log "  Path: $manifestPath" "INFO"
        Write-Log "  Devices: $($hostnames.Count)" "INFO"
        Write-Log "  CreatedAt: $($manifest.CreatedAt)" "INFO"
        Write-Log "" "INFO"

        # Record wave in $rolloutState, ensuring history & state tracking across itterations
        $waveRecord = @{
            WaveNumber = $rolloutState.CurrentWave
            StartedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            DeviceCount = @($waveDevices).Count
            Devices = @($waveDevices | ForEach-Object {
                @{
                    Hostname = if ($_.Hostname) { $_.Hostname } elseif ($_.HostName) { $_.HostName } else { $null }
                    BucketKey = Get-BucketKey $_
                }
            })
        }
        # Ensure WaveHistory is always an array before appending (prevents hashtable merge issues)
        $rolloutState.WaveHistory = @($rolloutState.WaveHistory) + @($waveRecord)
        $rolloutState.TotalDevicesTargeted += @($waveDevices).Count
        Save-RolloutState -State $rolloutState
        
        #Write-Log "Wave $($rolloutState.CurrentWave) deployed. Waiting $PollIntervalMinutes minutes..." "OK"

    } else {
        try {
        # ========================================================
        # MONITORING MODE
        # ========================================================
        # =  if it doesn't have devices? THen switch over to "monitoring" mode
        # Show status of deployed devices waiting for updates
        Write-Log "" "INFO"
        Write-Log "========== MONITORING - WAITING FOR STATUS ==========" "INFO"
        
        # Get all deployed devices from wave history
        $allDeployedLookup = @{}
        foreach ($wave in $rolloutState.WaveHistory) {
            foreach ($device in $wave.Devices) {
                if ($device.Hostname) {
                    $allDeployedLookup[$device.Hostname] = @{
                        Hostname = $device.Hostname
                        BucketKey = $device.BucketKey
                        DeployedAt = $wave.StartedAt
                        WaveNumber = $wave.WaveNumber
                    }
                }
            }
        }
        $allDeployedDevices = @($allDeployedLookup.Values)
        if ($allDeployedDevices.Count -gt 0) {
            # Find which deployed devices are still pending (in NotUpdated list)
            $stillPendingCount = 0
            $noLongerPendingCount = 0
            $pendingSample = @()
            foreach ($deployed in $allDeployedDevices) {
                if ($notUpdatedIndexes -and $notUpdatedIndexes.HostSet -and $notUpdatedIndexes.HostSet.Contains($deployed.Hostname)) {
                    $stillPendingCount++
                    if ($pendingSample.Count -lt $DeviceLogSampleSize) {
                        $pendingSample += $deployed.Hostname
                    }
                } else {
                    $noLongerPendingCount++
                }
            }
            # Get actual Updated counts from aggregation - differentiate Event 1808 vs UEFICA2023Status
            $summaryCsv = Get-LatestFile -FilePath $aggregationPath -fileName "*Summary*.csv"
            $actualUpdated = 0
            $totalDevicesFromSummary = 0
            $event1808Count = 0
            $uefiStatusUpdated = 0
            $needsRebootSample = @()
            if ($summaryCsv) {
                $summary = Import-Csv $summaryCsv.FullName | Select-Object -First 1
                if ($summary.Updated) { $actualUpdated = [int]$summary.Updated }
                if ($summary.TotalDevices) { $totalDevicesFromSummary = [int]$summary.TotalDevices }
            }
            # Calculate velocity from wave history (devices updated per day)
            $devicesPerDay = 0

            if ($rolloutState.StartedAt -and $actualUpdated -gt 0) {
                $startDate = [datetime]::Parse($rolloutState.StartedAt)
                $daysElapsed = ((Get-Date) - $startDate).TotalDays
                if ($daysElapsed -gt 0) {
                    $devicesPerDay = $actualUpdated / $daysElapsed
                }
            }

            # Save rollout summary with weekend-aware projections
            # Use aggregator's NotUptodate count (excludes SB OFF devices) for consistency
            $notUpdatedCount = if ($summary -and $summary.NotUptodate) { [int]$summary.NotUptodate } else { $totalDevicesFromSummary - $actualUpdated }

            # Update rollout state with actual counts from aggregation
            $rolloutState.TotalDevicesUpdated = $actualUpdated
            if ($totalDevicesFromSummary -gt 0) {
                $rolloutState.TotalDevicesTargeted = $totalDevicesFromSummary
            }
            Save-RolloutState -State $rolloutState
             $summaryparams = @{
                State               = $rolloutState
                TotalDevices        = $totalDevicesFromSummary
                UpdatedDevices      = $actualUpdated
                NotUpdatedDevices   = $notUpdatedCount
                DevicesPerDay       = $devicesPerDay
            }
            Save-RolloutSummary $summaryparams
            
            
            # Check raw data for devices with UEFICA2023Status=Updated but no Event 1808 (needs reboot)
            $dataFiles = Get-ChildItem -Path $AggregationInputPath -Filter "*.json" -ErrorAction SilentlyContinue
            $totalDataFiles = @($dataFiles).Count
            $batchSize = [Math]::Max(500, $ProcessingBatchSize)
            if ($LargeScaleMode) {
                $batchSize = [Math]::Max(2000, $ProcessingBatchSize)
            }

            if ($totalDataFiles -gt 0) {
                for ($idx = 0; $idx -lt $totalDataFiles; $idx += $batchSize) {
                    $end = [Math]::Min($idx + $batchSize - 1, $totalDataFiles - 1)
                    if ($idx -le $end) {
                        $batchFiles = $dataFiles[$idx..$end]
                    } else { continue }

                    foreach ($file in $batchFiles) {
                        try {
                            $deviceData = Get-Content $file.FullName -Raw | ConvertFrom-Json
                            $hostname = $deviceData.Hostname
                            if (-not $hostname) { continue }
                            
                            $has1808 = [int]$deviceData.Event1808Count -gt 0
                            $hasUefiUpdated = $deviceData.UEFICA2023Status -eq "Updated"
                            if ($has1808) {
                                $event1808Count++
                            } elseif ($hasUefiUpdated) {
                                $uefiStatusUpdated++
                                if ($needsRebootSample.Count -lt $DeviceLogSampleSize) {
                                    $needsRebootSample += $hostname
                                }
                            }
                        } catch { }
                    }

                    Save-ProcessingCheckpoint -Stage "RebootStatusScan" -Processed ($end + 1) -Total $totalDataFiles -Metrics @{
                        Event1808Count = $event1808Count
                        UEFIUpdatedAwaitingReboot = $uefiStatusUpdated
                    }
                }
            }
           
            if ($stillPendingCount -gt 0) {
                $pendingSuffix = if ($stillPendingCount -gt $DeviceLogSampleSize) { " ... (+$($stillPendingCount - $DeviceLogSampleSize) more)" } else { "" }
                Write-Log "Pending devices (in Wave): $($pendingSample -join ', ')$pendingSuffix" "WARN"
            }
        } else {
            Write-Log "No devices have been deployed yet" "INFO"
        }
        <#  Write-Log "" "INFO"
            #Just reminder that this might be a culprit if things start breaking V
            Write-Log "Total deployed: $($allDeployedDevices.Count)" "INFO"
            Write-Log "Updated (Event 1808 confirmed): $event1808Count" "OK"
            if ($uefiStatusUpdated -gt 0) {
                Write-Log "Updated (UEFICA2023Status=Updated, awaiting reboot): $uefiStatusUpdated" "OK"
                $rebootSuffix = if ($uefiStatusUpdated -gt $DeviceLogSampleSize) { " ... (+$($uefiStatusUpdated - $DeviceLogSampleSize) more)" } else { "" }
                Write-Log "  Devices needing reboot for Event 1808 (sample): $($needsRebootSample -join ', ')$rebootSuffix" "INFO"
                Write-Log "  These devices will report Event 1808 after next reboot" "INFO"
            }
            Write-Log "No longer pending: $noLongerPendingCount (includes SecureBoot OFF, missing devices)" "INFO"
            Write-Log "Awaiting status: $stillPendingCount" "INFO"
        Write-Log "================================================================" "INFO"
        Write-Log "" "INFO" #>
        }
        catch {
            Write-Log "Monitoring block failure: $($_.Exception.Message)" "ERROR"
        }

    }   
    # Wait before next iteration
    if (-not $DryRun) {
        Write-Log "Sleeping for $PollIntervalMinutes minutes..." "INFO"
        Start-Sleep -Seconds ($PollIntervalMinutes * 60)
    } else {
        Write-Log "[DRYRUN] Would wait $PollIntervalMinutes minutes" "INFO"
        break  # Exit after one iteration in dry run
    }
}
# <== end of main loop

# ============================================================================
# FINAL SUMMARY
# ============================================================================
#Completely unchanged, who cares (^._.^)/
Write-Host ""
Write-Host ("=" * 80) -ForegroundColor Green
Write-Host "   ROLLOUT ORCHESTRATOR SUMMARY" -ForegroundColor Green
Write-Host ("=" * 80) -ForegroundColor Green
Write-Host ""

$finalState = Get-RolloutState
$finalBlocked = Get-BlockedBuckets

Write-Host "Status:              $($finalState.Status)" -ForegroundColor $(if ($finalState.Status -eq "Completed") { "Green" } else { "Yellow" })
Write-Host "Total Waves:         $($finalState.CurrentWave)"
Write-Host "Devices Targeted:    $($finalState.TotalDevicesTargeted)"
Write-Host "Blocked Buckets:     $($finalBlocked.Count)" -ForegroundColor $(if ($finalBlocked.Count -gt 0) { "Red" } else { "Green" })
Write-Host "Devices Tracked:     $($deviceHistory.Count)" -ForegroundColor Gray
Write-Host ""

if ($finalBlocked.Count -gt 0) {
    Write-Host "BLOCKED BUCKETS (require manual review):" -ForegroundColor Red
    foreach ($key in $finalBlocked.Keys) {
        $info = $finalBlocked[$key]
        Write-Host "  - $key" -ForegroundColor Red
        Write-Host "    Reason: $($info.Reason)" -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "Blocked buckets file: $blockedBucketsPath" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "State files:" -ForegroundColor Cyan
Write-Host "  Rollout State:    $rolloutStatePath"
Write-Host "  Blocked Buckets:  $blockedBucketsPath"
Write-Host "  Device History:   $deviceHistoryPath"
Write-Host ""
