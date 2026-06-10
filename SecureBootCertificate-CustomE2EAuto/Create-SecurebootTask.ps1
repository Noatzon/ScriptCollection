$taskName = "SBC-Status-Collection"
$ScriptPath = ""
$OutputPath = ""
$LocalPath = "C:\Temp"
$ScriptFile = Join-Path $ScriptPath "Detect-SecureBootCertUpdateStatus.ps1"
$LocalScript = Join-Path $LocalPath "Detect-SecureBootCertUpdateStatus.ps1"

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
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 240) -RepetitionDuration (New-TimeSpan -Days 45)

$settingsParams = @{
    AllowStartIfOnBatteries    = $true
    DontStopIfGoingOnBatteries = $true
    StartWhenAvailable         = $true
    RunOnlyIfNetworkAvailable  = $true
    WakeToRun                  = $true
}
$settings = New-ScheduledTaskSettingsSet @settingsParams

$existingTask = Get-ScheduledTask -TaskName "Detect-SBC-Status" -ErrorAction SilentlyContinue
if ($existingTask) {
    Unregister-ScheduledTask -TaskName "Detect-SBC-Status" -Confirm:$false
    Start-Sleep -Seconds 5
}

$existingTask2 = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existingTask2) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Start-Sleep -Seconds 5
}

$existingTask3 = Get-ScheduledTask -TaskName "SBC-Status-Aggregator" -ErrorAction SilentlyContinue
if ($existingTask3) {
    Unregister-ScheduledTask -TaskName "SBC-Status-Aggregator" -Confirm:$false
    Start-Sleep -Seconds 5
}

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($trigger, $startupTrigger) -Settings $settings -User "service acc" -Password "YourPWD" -RunLevel Highest