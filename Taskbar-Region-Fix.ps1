Set-Executionpolicy -Executionpolicy Bypass -force

Write-Host "NOTE: This script does NOT remove taskbar pins!" -ForegroundColor Red

Write-Host ""


Write-Host "Changing taskbar layout..."
Write-Host ""
#Below part changes taskbar from center to left, taken from: https://stackoverflow.com/questions/76620781/ps-script-to-make-win11-taskbar-icons-go-to-left-doesnt-work/76828578#76828578
#Changing taskbar/start menu items is still imposible.
$currentusersid = Get-WmiObject -Class win32_computersystem |
Select-Object -ExpandProperty Username |
ForEach-Object { ([System.Security.Principal.NTAccount]$_).Translate([System.Security.Principal.SecurityIdentifier]).Value }

$regpath = "registry::HKEY_USERS\" + $currentusersid + "\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"

Set-ItemProperty -Path $regpath -Name "TaskbarAl" -Value 0 -Force


Write-Host "Configuring Power Button..."
Write-Host ""

powercfg -setdcvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 7648efa3-dd9c-4e3e-b566-50f929386280 3
powercfg -setacvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 7648efa3-dd9c-4e3e-b566-50f929386280 3

Write-Host "Configuring Lid Settings..."
Write-Host ""

powercfg -setdcvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 0
powercfg -setacvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 0

Write-Host "Configuring Sleep Timers"
Write-Host ""
Write-Host "Setting Screen Timeout To 10 Minutes."
Write-Host ""
powercfg -change -monitor-timeout-ac 10
powercfg -change -monitor-timeout-dc 10
Write-Host "Setting Sleep Timeout To Never"
Write-Host ""
powercfg -change -standby-timeout-ac 0
powercfg -change -standby-timeout-dc 0
Write-Host ""

Write-Host "Correcting timezone..."
Set-timezone -id  "W. Europe Standard Time"
Write-Host ""

Write-host "Done!" -ForegroundColor Green

pause