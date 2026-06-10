<#
.SYNOPSIS
    Deploys the Secure Boot Rollout Orchestrator as a Windows Scheduled Task.

.DESCRIPTION
    Creates a scheduled task that runs the orchestrator continuously in the background.
    The task runs with bypass execution policy so no security prompts appear.
    
    The orchestrator will:
    - Poll for device updates on the specified interval
    - Automatically generate waves and deploy GPOs
    - Continue until all eligible devices are updated
    
    Monitor progress using: Get-SecureBootRolloutStatus.ps1

.PARAMETER AggregationInputPath
    UNC path to JSON device data (from detection GPO)

.PARAMETER ReportBasePath
    Local path for reports and state files

.PARAMETER TargetOU
    OU to link GPOs (optional - defaults to domain root)

.PARAMETER PollIntervalMinutes
    Minutes between status checks. Default: 30

.PARAMETER UseWinCS
    Use WinCS (Windows Configuration System) instead of AvailableUpdatesPolicy GPO.
    When enabled, deploys WinCsFlags.exe scheduled task to endpoints instead of registry GPO.

.PARAMETER WinCSKey
    The WinCS key for Secure Boot configuration. Default: F33E0C8E002

.PARAMETER ServiceAccount
    Account to run the task. Default: SYSTEM
    For domain operations, use a domain admin service account.

.PARAMETER AllowListPath
    Path to a file containing hostnames to ALLOW for rollout (targeted/pilot rollout).
    Supports .txt (one hostname per line) or .csv (with Hostname/ComputerName/Name column).
    When specified, ONLY these devices will be included in rollout.

.PARAMETER AllowADGroup
    Name of an AD security group containing computer accounts to ALLOW.
    Example: "SecureBoot-Pilot-Computers"

.PARAMETER ExclusionListPath
    Path to a file containing hostnames to EXCLUDE from rollout (VIP/executive devices).
    Supports .txt (one hostname per line) or .csv (with Hostname/ComputerName/Name column).

.PARAMETER ScriptPath
    Path to the orchestrator script. Default: Same folder as this script.

.PARAMETER Uninstall
    Remove the scheduled task

.EXAMPLE
    .\$ScriptName.ps1 -AggregationInputPath "\\server\SecureBootData$" -ReportBasePath "C:\SecureBootReports" -ServiceAccount "DOMAIN\svc_secureboot"

.EXAMPLE
    .\$ScriptName.ps1 -AggregationInputPath "\\server\SecureBootData$" -ReportBasePath "C:\SecureBootReports"

.EXAMPLE
    # Deploy using WinCS method instead of AvailableUpdatesPolicy
    .\$ScriptName.ps1 -AggregationInputPath "\\server\SecureBootData$" -ReportBasePath "C:\SecureBootReports" -UseWinCS

.EXAMPLE
    .\$ScriptName.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)] #UNC path to endpoint JSON files. Example: "E:\SB_Logs"
    [string]$AggregationInputPath,
    
    [Parameter(Mandatory = $false)] #Local path for reports and state Example: "E:\SBC_Reports"
    [string]$ReportBasePath,
    
    [Parameter(Mandatory = $false)] #Path to the orchestrator script Example: "E:\SBCscripts"
    [string]$ScriptFolder,

     [Parameter(Mandatory = $false)] 
    [string]$LocalPath,
    
    [Parameter(Mandatory = $false)] #Changed to not cause needless load. Checks every 1h
    [int]$PollIntervalMinutes = 60,

    [Parameter(Mandatory = $false)] #Name of task in Scheduler (set to whatever)
    [string]$taskName = "SBC Rollout Orchestrator",
    
    [Parameter(Mandatory = $false)] # Account to run the Scheduled Task
    [string]$ServiceAccount = "domain\service acc",
    
    [Parameter(Mandatory = $false)] #Path to file with hostnames to ALLOW for targeted/pilot rollout. Supports .txt or .csv. Hasn't been properly tested in rewrite version!
    [string]$AllowListPath,
    
    [Parameter(Mandatory = $false)] #Path to file with hostnames to EXCLUDE from rollout (VIP/executive devices)
    [string]$ExclusionListPath,
    
    [Parameter(Mandatory = $false)]
    [switch]$Uninstall
)
#To ensure output remains correct even if someone changes the name of the script we use a variable instead of hardcoded nae for it.
$ScriptInvocation = (Get-Variable MyInvocation -Scope Script).Value
$ScriptName = $ScriptInvocation.MyCommand.Name
$ErrorActionPreference = "Stop"

# ============================================================================
# UNINSTALL
# ============================================================================

if ($Uninstall) {
    Write-Host ""
    Write-Host "Removing scheduled task: $taskName" -ForegroundColor Yellow
    
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "Task removed successfully." -ForegroundColor Green
    } else {
        Write-Host "Task not found." -ForegroundColor Gray
    }
    exit 0
}

# ============================================================================
# VALIDATION
# ============================================================================

if (-not $AggregationInputPath -or -not $ReportBasePath -or -not $ScriptFolder) {
    Write-Host "ERROR: -AggregationInputPath AND -ReportBasePath AND -ScriptFolder are required." -ForegroundColor Red
    Write-Host ""
    Write-Host "Example:" -ForegroundColor Yellow
    Write-Host '  .\$ScriptName.ps1 -AggregationInputPath "\\server\SBC_Logs" -ReportBasePath "\\server\SBC_Reports" -ScriptFolder "\\server\SBC_Scripts"'
    exit 1
}
# ============================================================================
# SCRIPT STATUS
# ============================================================================

$RolloutScript = Join-Path $ScriptFolder "RolloutOrchestrator.ps1"
#Write-Host "Path: $RolloutScript"
if (-not (Test-Path $RolloutScript)) {
    Write-Host "WARNING: RolloutOrchestrator.ps1 not found in script directory" -ForegroundColor Yellow
    Write-Host "         Orchestrator will fail if it cannot find this script." -ForegroundColor Yellow
}

# Find aggregation script (needed by orchestrator)
$aggregateScript = Join-Path $ScriptFolder "Aggregate-SecureBootData.ps1"
#Write-Host "Path: $AggregateScript" 
if (-not (Test-Path $aggregateScript)) {
    Write-Host "WARNING: Aggregate-SecureBootData.ps1 not found in script directory" -ForegroundColor Yellow
    Write-Host "         Orchestrator will fail if it cannot find this script." -ForegroundColor Yellow
}

#Check if we can find reportbase folder too
if (-not (Test-Path $ReportBasePath)) {
    Write-Host "WARNING: '$ReportBasePath' not found" -ForegroundColor Yellow
    Write-Host "         Orchestrator will fail if it cannot reach this directory later." -ForegroundColor Yellow
}

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "  Secure Boot Rollout Orchestrator - Task Deployment" -ForegroundColor Cyan
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# CREATE SCHEDULED TASK
# ============================================================================

# Define local script location
$LocalScript = Join-Path $LocalPath "RolloutOrchestrator.ps1"
$LocalAggregateScript = Join-Path $LocalPath "Aggregate-SecureBootData.ps1"

# Ensure local folder exists
if (-not (Test-Path $LocalPath)) {
    New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null
}

# Copy orchestrator script (& the aggregation script it uses) locally
Copy-Item $RolloutScript $LocalScript -Force
Copy-Item $aggregateScript $LocalAggregateScript -Force

# Build powershell script parameters/arguments (to call)
$argument = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$LocalScript"" -AggregationInputPath ""$AggregationInputPath"" -ReportBasePath ""$ReportBasePath"" -LocalFilePath ""$LocalPath"" -PollIntervalMinutes $PollIntervalMinutes"
# Keepinf both options but don't see them being used.
if ($AllowListPath) {
    $argument += " -AllowListPath ""$AllowListPath"""
}
if ($ExclusionListPath) {
    $argument += " -ExclusionListPath ""$ExclusionListPath"""
}

$actionParams = @{
    Execute  = "powershell.exe"
    Argument = $argument
}

$action = New-ScheduledTaskAction @actionParams

# Create triggers
$startupTrigger = New-ScheduledTaskTrigger -AtStartup
$Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)

# Task settings
$settingsParams = @{
    AllowStartIfOnBatteries    = $true
    DontStopIfGoingOnBatteries = $true
    StartWhenAvailable         = $true
    RunOnlyIfNetworkAvailable  = $true
    WakeToRun                  = $true
    RestartCount               = 3
    RestartInterval            = (New-TimeSpan -Minutes 5)
    MultipleInstances = "IgnoreNew"
}
$settings = New-ScheduledTaskSettingsSet @settingsParams

# Check for existing task
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Write-Host "Task already exists. Updating..." -ForegroundColor Yellow
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

# Register task using domain service account
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($trigger, $startupTrigger) -Settings $settings -User $ServiceAccount -Password "YourPWD" -RunLevel Highest


# ============================================================================
# CREATE STATUS SHORTCUT
# ============================================================================

$statusScript = Join-Path $ScriptFolder "Get-SecureBootRolloutStatus.ps1"
if (Test-Path $statusScript) {
    Write-Host ""
    Write-Host "To check rollout status, run:" -ForegroundColor Yellow
    Write-Host "(start in '$ScriptFolder ')  .\Get-SecureBootRolloutStatus.ps1 -ReportBasePath `"$ReportBasePath`"" -ForegroundColor Cyan
}

# ============================================================================
# OUTPUT
# ============================================================================

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Green
Write-Host "  DEPLOYMENT COMPLETE" -ForegroundColor Green
Write-Host ("=" * 70) -ForegroundColor Green
Write-Host ""
#For display/status
Write-Host "Current configuration:" -ForegroundColor Yellow
Write-Host "  Task Name:         $taskName"
Write-Host "  Orchestrator:      $LocalPath "
Write-Host "  Input Path:        $AggregationInputPath"
Write-Host "  Report Path:       $ReportBasePath"
Write-Host "  Poll Interval:     $PollIntervalMinutes minutes"
Write-Host "  Service Account:   $ServiceAccount"
Write-Host "  Deployment Method: WinCS Flags"
Write-Host ""
Write-Host "  The Orchestrator task will start in a few minutes. It will keep running in the background (even after the task goes back to saying 'Ready')" -ForegroundColor White
Write-Host ""
Write-Host ""
Write-Host "MONITORING:" -ForegroundColor Yellow
Write-Host "  View latest task log:     Get-Content '$ReportBasePath\RolloutState\Orchestrator_$(Get-Date -Format 'yyyyMMdd').log' -Tail 50"
Write-Host "  View rollout state:       Get-Content '$ReportBasePath\RolloutState\RolloutState.json' | ConvertFrom-Json"
Write-Host "  View dashboard:           Start '$ReportBasePath\Aggregation_Current\SecureBoot_Dashboard_Latest.html'"
Write-Host "  Quick status:             .\Get-SecureBootRolloutStatus.ps1 -ReportBasePath $ReportBasePath"
Write-Host "  All Endpoint tasks generate local log files under 'C:\Temp' by default. Consult those when dealing with devices that don't show up." -ForegroundColor White
Write-Host ""
Write-Host "MANAGEMENT:" -ForegroundColor Yellow
Write-Host "  View task status:    Get-ScheduledTask -TaskName '$taskName' | Select State"
Write-Host "  Start manually:      Start-ScheduledTask -TaskName '$taskName'"
Write-Host "  Stop:                Stop-ScheduledTask -TaskName '$taskName'"
Write-Host "  Remove:              .\$ScriptName -Uninstall"
Write-Host ""
