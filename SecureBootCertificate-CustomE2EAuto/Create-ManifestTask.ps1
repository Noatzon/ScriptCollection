$taskName = "SBC-WaveProgressor"
$ScriptPath = "\\GPO startup folder"
$OutputPath = "\\server\SB_Logs"
$LocalPath = "C:\Temp"
$ScriptFile = Join-Path $ScriptPath "Detect-EndpointWave.ps1"
$LocalScript = Join-Path $LocalPath "Detect-EndpointWave.ps1"

# Ensure local folder exists
if (-not (Test-Path $LocalPath)) {
    New-Item -ItemType Directory -Path $LocalPath -Force | Out-Null
}
# Copy detection script over to local device
Copy-Item $ScriptFile $LocalScript -Force

$actionParams = @{
    Execute  = "powershell.exe"
    Argument = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$LocalScript"" -OutputPath ""$OutputPath"" -LocalfilePath ""$LocalPath"""
}
$action = New-ScheduledTaskAction @actionParams

$startupTrigger = New-ScheduledTaskTrigger -AtStartup
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(15) -RepetitionInterval (New-TimeSpan -Minutes 180) -RepetitionDuration (New-TimeSpan -Days 45)

$settingsParams = @{
    AllowStartIfOnBatteries    = $true
    DontStopIfGoingOnBatteries = $true
    StartWhenAvailable         = $true
    RunOnlyIfNetworkAvailable  = $true
    WakeToRun                  = $true
}
$settings = New-ScheduledTaskSettingsSet @settingsParams

$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Start-Sleep -Seconds 5
}

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($trigger, $startupTrigger) -Settings $settings -User "domain\service acc" -Password "YourPWD" -RunLevel Highest