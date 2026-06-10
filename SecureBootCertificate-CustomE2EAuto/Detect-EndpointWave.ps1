<#
.DESCRIPTION
Script runs at startup and then every N hours as a scheduled task. 
Periodically polls network share for a manifest file which contain all the devices that are part of the current wave. 
Those devices then need to try and run WinCS to start the update process if they haven't.
#>

param(
    [Parameter(Mandatory = $false)] #Must be a FQDN! You can't use a IP nor skip the ".domain" part!
    [string]$OutputPath,

    [Parameter(Mandatory = $false)] #Path to save local files. Used for saving the local manifest state file and logs
    [string]$LocalfilePath
)

#Actual "status" file for device, will be grabbed by Detection script and included in it's results later.
$statePath = Join-Path $LocalfilePath "WaveState.json"
$hostname = $env:COMPUTERNAME

# We sill want endpoint/local loging to fall back on in case of issues. That's why we don't bother logging successes.
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "OK"      { "Green" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        default   { "White" }
    }    
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
    # Also log to file
    $logFile = Join-Path $LocalfilePath "EPmanifest.log"
    "[$timestamp] [$Level] $Message" | Out-File $logFile -Append -Encoding UTF8
}


# Ensure local folder exists
if (-not (Test-Path $LocalPath)) {
    New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null
    Write-Log "Attempted to create $LocalfilePath because it wasn't found" "WARN"
}

# Load existing state
$state = @{}
if (Test-Path $statePath) {
    try {
        $state = Get-Content $statePath -Raw | ConvertFrom-Json
    } catch {
        $state = @{}
        Write-Log "State file is empty (maybe this is the first time script is called?)" "WARN"
    }
}

# Exit if $OutputPath is not accessible, otherwise attempt to laod the file
try {
    if (-not (Test-Path $OutputPath)) {
        Write-Log "Could not access $OutputPath, aborting" "ERROR"
        return
    }
    $manifest = Get-Content $OutputPath -Raw | ConvertFrom-Json
} catch {
    Write-Log "Unknown issue with loading Manifest json" "ERROR"
    return
}
#Load data from manifest.json to use for determining fi device is part of current wave or not
$currentWave = $manifest.WaveNumber
$manifestTimestamp = $manifest.CreatedAt

# Skip if already processed this wave
if ($state.LastWave -eq $currentWave) {
    return
}

# Determine membership
$isInWave = $hostname -in $manifest.Devices
$winCSStatus = "NotApplicable"

if ($isInWave) {
    try {
        $process = Start-Process "WinCsFlags.exe" -ArgumentList "/apply --key F33E0C8E002" -Wait -PassThru -WindowStyle Hidden
        if ($process.ExitCode -eq 0) {
            $winCSStatus = "Success"
        } else {
            $winCSStatus = "Failed"
        }
    } catch {
        $winCSStatus = "Failed"
    }
}

# Save state
$newState = @{
    LastWave           = $currentWave
    LastSeenManifest   = $manifestTimestamp
    IsInWave           = $isInWave
    WinCSStatus        = $winCSStatus
    LastChecked        = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
}

$newState | ConvertTo-Json -Depth 3 | Out-File $statePath -Encoding UTF8 -Force