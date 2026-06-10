<#
.SYNOPSIS
    Enables the Secure Boot Update scheduled task.

.DESCRIPTION
    This script ensures the Windows Secure Boot Update scheduled task 
    (\Microsoft\Windows\PI\Secure-Boot-Update) is enabled. If disabled,
    it enables it. If the task was deleted, it can recreate it.

.PARAMETER Action
    The action to perform. Valid values: check, enable, create
    - check:  Only check the task status
    - enable: (default) Enable the task if disabled. If task is missing, prompts to create.
    - create: Create the task if it doesn't exist

.PARAMETER ComputerName
    Optional. Array of computer names to check/enable the task on.
    If not specified, runs on the local machine.

.PARAMETER Credential
    Optional. Credentials for remote computer access.

.PARAMETER Quiet
    Suppresses prompts and automatically answers Yes. Useful for automation.

.EXAMPLE
    .\Enable-SecureBootTask.ps1
    # Enables the task status on local machine

.EXAMPLE
    .\Check-SecureBootScheduledTask.ps1 enable
    # Enables the task if disabled. Prompts to create if missing.

.EXAMPLE
    .\Check-SecureBootScheduledTask.ps1 create
    # Creates the task if it was deleted, then checks its status

.EXAMPLE
    .\Check-SecureBootScheduledTask.ps1 check -ComputerName "PC1", "PC2"
    # Checks the task on remote machines

.NOTES
    Requires administrator privileges to enable or create the task.
    Task Path: \Microsoft\Windows\PI\Secure-Boot-Update
    Task runs taskhostw.exe every 12 hours with elevated privileges.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position=0)]
    [ValidateSet('check', 'enable', 'create', '')]
    [string]$Action = 'enable',

    [Parameter()]
    [string[]]$ComputerName,

    [Parameter()]
    [PSCredential]$Credential,

    [Parameter()]
    [Alias('Force', 'Silent')]
    [switch]$Quiet
)

# Convert Action to switches for backward compatibility
$Enable = $Action -eq 'enable'
$Create = $Action -eq 'create'

# Download URL: https://aka.ms/getsecureboot -> "Deployment and Monitoring Samples"
# Note: This script runs on endpoints to enable the Secure Boot Update task.

$TaskPath = "\Microsoft\Windows\PI\"
$TaskName = "Secure-Boot-Update"

function Get-SecureBootTaskStatus {
    [CmdletBinding()]
    param(
        [string]$Computer = $env:COMPUTERNAME
    )

    $result = [PSCustomObject]@{
        ComputerName = $Computer
        TaskExists   = $false
        TaskState    = $null
        IsEnabled    = $false
        LastRunTime  = $null
        NextRunTime  = $null
        Error        = $null
    }

    try {
        if ($Computer -eq $env:COMPUTERNAME -or $Computer -eq "localhost" -or $Computer -eq ".") {
            # Use schtasks.exe for more reliable task detection
            $schtasksOutput = schtasks.exe /Query /TN "$TaskPath$TaskName" /FO CSV 2>&1
            
            if ($LASTEXITCODE -ne 0) {
                # Task not found is not an error - just means task doesn't exist
                $result.TaskExists = $false
                return $result
            }
            
            # Parse CSV output
            $taskData = $schtasksOutput | ConvertFrom-Csv
            if ($taskData) {
                $result.TaskExists = $true
                $result.TaskState = $taskData.Status
                $result.IsEnabled = ($taskData.Status -eq 'Ready' -or $taskData.Status -eq 'Running')
                
                # Try to get next run time from the data
                if ($taskData.'Next Run Time' -and $taskData.'Next Run Time' -ne 'N/A') {
                    try {
                        $result.NextRunTime = [DateTime]::Parse($taskData.'Next Run Time')
                    } catch { }
                }
            }
        }
        else {
            # Remote computer - use Invoke-Command with schtasks
            $remoteResult = Invoke-Command -ComputerName $Computer -ScriptBlock {
                param($fullTaskName)
                $output = schtasks.exe /Query /TN $fullTaskName /FO CSV 2>&1
                @{
                    ExitCode = $LASTEXITCODE
                    Output = $output
                }
            } -ArgumentList "$TaskPath$TaskName" -ErrorAction Stop

            if ($remoteResult.ExitCode -ne 0) {
                # Task not found is not an error - just means task doesn't exist
                $result.TaskExists = $false
                return $result
            }

            $taskData = $remoteResult.Output | ConvertFrom-Csv
            if ($taskData) {
                $result.TaskExists = $true
                $result.TaskState = $taskData.Status
                $result.IsEnabled = ($taskData.Status -eq 'Ready' -or $taskData.Status -eq 'Running')
            }
        }
    }
    catch {
        $result.Error = $_.Exception.Message
    }

    return $result
}

function New-SecureBootTask {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Computer = $env:COMPUTERNAME
    )

    $success = $false
    $errorMsg = $null

    # Task definition - matches the original Windows Secure Boot Update task
    # Uses ComHandler with SBServicing class, runs as LocalSystem
    $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.6" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Date>2012-02-07T16:39:20</Date>
    <SecurityDescriptor>O:BAG:BAD:P(A;;FA;;;BA)(A;;FA;;;SY)(A;;FRFX;;;LS)</SecurityDescriptor>
    <Source>`$(@%SystemRoot%\system32\TpmTasks.dll,-601)</Source>
    <Author>`$(@%SystemRoot%\system32\TpmTasks.dll,-600)</Author>
    <Description>`$(@%SystemRoot%\system32\TpmTasks.dll,-604)</Description>
    <URI>\Microsoft\Windows\PI\Secure-Boot-Update</URI>
  </RegistrationInfo>
  <Principals>
    <Principal id="LocalSystem">
      <UserId>S-1-5-18</UserId>
    </Principal>
  </Principals>
  <Settings>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <StartWhenAvailable>true</StartWhenAvailable>
    <IdleSettings>
      <StopOnIdleEnd>true</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
  </Settings>
  <Triggers>
    <BootTrigger>
      <Delay>PT5M</Delay>
      <Repetition>
        <Interval>PT12H</Interval>
      </Repetition>
    </BootTrigger>
  </Triggers>
  <Actions Context="LocalSystem">
    <ComHandler>
      <ClassId>{5014B7C8-934E-4262-9816-887FA745A6C4}</ClassId>
      <Data><![CDATA[SBServicing]]></Data>
    </ComHandler>
  </Actions>
</Task>
"@

    try {
        if ($Computer -eq $env:COMPUTERNAME -or $Computer -eq "localhost" -or $Computer -eq ".") {
            if ($PSCmdlet.ShouldProcess("$TaskPath$TaskName", "Create scheduled task")) {
                # Save XML to temp file and import
                $tempFile = [System.IO.Path]::GetTempFileName()
                $taskXml | Out-File -FilePath $tempFile -Encoding Unicode -Force
                
                $output = schtasks.exe /Create /TN "$TaskPath$TaskName" /XML $tempFile /F 2>&1
                
                Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
                
                if ($LASTEXITCODE -eq 0) {
                    $success = $true
                } else {
                    $errorMsg = $output -join " "
                }
            }
        }
        else {
            if ($PSCmdlet.ShouldProcess("$Computer\$TaskPath$TaskName", "Create scheduled task")) {
                $result = Invoke-Command -ComputerName $Computer -ScriptBlock {
                    param($taskPath, $taskName, $xml)
                    $tempFile = [System.IO.Path]::GetTempFileName()
                    $xml | Out-File -FilePath $tempFile -Encoding Unicode -Force
                    $output = schtasks.exe /Create /TN "$taskPath$taskName" /XML $tempFile /F 2>&1
                    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
                    @{ ExitCode = $LASTEXITCODE; Output = $output }
                } -ArgumentList $TaskPath, $TaskName, $taskXml -ErrorAction Stop
                
                if ($result.ExitCode -eq 0) {
                    $success = $true
                } else {
                    $errorMsg = $result.Output -join " "
                }
            }
        }
    }
    catch {
        $errorMsg = $_.Exception.Message
    }

    return @{
        Success = $success
        Error   = $errorMsg
    }
}

function Enable-SecureBootTask {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Computer = $env:COMPUTERNAME
    )

    $success = $false
    $errorMsg = $null

    try {
        if ($Computer -eq $env:COMPUTERNAME -or $Computer -eq "localhost" -or $Computer -eq ".") {
            if ($PSCmdlet.ShouldProcess("$TaskPath$TaskName", "Enable scheduled task")) {
                $output = schtasks.exe /Change /TN "$TaskPath$TaskName" /ENABLE 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $success = $true
                } else {
                    $errorMsg = $output -join " "
                }
            }
        }
        else {
            if ($PSCmdlet.ShouldProcess("$Computer\$TaskPath$TaskName", "Enable scheduled task")) {
                $result = Invoke-Command -ComputerName $Computer -ScriptBlock {
                    param($fullTaskName)
                    $output = schtasks.exe /Change /TN $fullTaskName /ENABLE 2>&1
                    @{ ExitCode = $LASTEXITCODE; Output = $output }
                } -ArgumentList "$TaskPath$TaskName" -ErrorAction Stop
                
                if ($result.ExitCode -eq 0) {
                    $success = $true
                } else {
                    $errorMsg = $result.Output -join " "
                }
            }
        }
    }
    catch {
        $errorMsg = $_.Exception.Message
    }

    return @{
        Success = $success
        Error   = $errorMsg
    }
}

# Main execution
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Secure Boot Update Task Enabler" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Task: $TaskPath$TaskName" -ForegroundColor Gray
Write-Host ""

# Determine target computers
$targets = if ($ComputerName) { $ComputerName } else { @($env:COMPUTERNAME) }

$results = @()

foreach ($computer in $targets) {
    Write-Host "Checking: $computer" -ForegroundColor Yellow
    
    $status = Get-SecureBootTaskStatus -Computer $computer
    
    if ($status.Error) {
        Write-Host "  Error: $($status.Error)" -ForegroundColor Red
    }
    elseif (-not $status.TaskExists) {
        Write-Host "  Task does not exist on this system" -ForegroundColor Red
        
        # Create if requested, or prompt if Enable was specified
        $shouldCreate = $Create
        if (-not $shouldCreate -and $Enable) {
            Write-Host ""
            Write-Host "  The task may have been deleted." -ForegroundColor Yellow
            if ($Quiet) {
                Write-Host "  Auto-creating task (Quiet mode)" -ForegroundColor Cyan
                $shouldCreate = $true
            } else {
                $confirm = Read-Host "  Do you want to recreate the task? (Y/N)"
                if ($confirm -eq 'Y' -or $confirm -eq 'y') {
                    $shouldCreate = $true
                }
            }
        }
        
        if ($shouldCreate) {
            Write-Host "  Creating task..." -ForegroundColor Yellow
            $createResult = New-SecureBootTask -Computer $computer
            
            if ($createResult.Success) {
                Write-Host "  Task created successfully" -ForegroundColor Green
                # Re-check status
                $status = Get-SecureBootTaskStatus -Computer $computer
                
                if ($status.TaskExists) {
                    $stateColor = if ($status.IsEnabled) { "Green" } else { "Red" }
                    Write-Host "  State: $($status.TaskState)" -ForegroundColor $stateColor
                }
            }
            else {
                Write-Host "  Failed to create: $($createResult.Error)" -ForegroundColor Red
            }
        }
    }
    else {
        $stateColor = if ($status.IsEnabled) { "Green" } else { "Red" }
        Write-Host "  State: $($status.TaskState)" -ForegroundColor $stateColor
        
        if ($status.LastRunTime -and $status.LastRunTime -ne [DateTime]::MinValue) {
            Write-Host "  Last Run: $($status.LastRunTime)" -ForegroundColor Gray
        }
        if ($status.NextRunTime -and $status.NextRunTime -ne [DateTime]::MinValue) {
            Write-Host "  Next Run: $($status.NextRunTime)" -ForegroundColor Gray
        }

        # Enable if requested and currently disabled
        if ($Enable -and -not $status.IsEnabled) {
            Write-Host "  Enabling task..." -ForegroundColor Yellow
            $enableResult = Enable-SecureBootTask -Computer $computer
            
            if ($enableResult.Success) {
                Write-Host "  Task enabled successfully" -ForegroundColor Green
                # Re-check status
                $status = Get-SecureBootTaskStatus -Computer $computer
            }
            else {
                Write-Host "  Failed to enable: $($enableResult.Error)" -ForegroundColor Red
            }
        }
        elseif ($Enable -and $status.IsEnabled) {
            Write-Host "  Task is already enabled" -ForegroundColor Green
        }
    }
    
    $results += $status
    Write-Host ""
}

# Summary
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$enabled = ($results | Where-Object { $_.IsEnabled }).Count
$disabled = ($results | Where-Object { $_.TaskExists -and -not $_.IsEnabled }).Count
$notFound = ($results | Where-Object { -not $_.TaskExists }).Count
$errors = ($results | Where-Object { $_.Error }).Count

Write-Host "Total Checked: $($results.Count)"
Write-Host "Enabled: $enabled" -ForegroundColor Green
if ($disabled -gt 0) { Write-Host "Disabled: $disabled" -ForegroundColor Red }
if ($notFound -gt 0) { Write-Host "Not Found: $notFound" -ForegroundColor Yellow }
if ($errors -gt 0) { Write-Host "Errors: $errors" -ForegroundColor Red }

# Return results for pipeline
$results

# SIG # Begin signature block
# MIIpxgYJKoZIhvcNAQcCoIIptzCCKbMCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDW2L0Cr34oYUhi
# YeOd6UyDWY4txYaleGp9z3B7llvZcqCCDeUwgga9MIIEpaADAgECAhMzAAAAHEif
# gd+hsLd3AAAAAAAcMA0GCSqGSIb3DQEBDAUAMIGIMQswCQYDVQQGEwJVUzETMBEG
# A1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWlj
# cm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0
# aWZpY2F0ZSBBdXRob3JpdHkgMjAxMDAeFw0yNDA4MDgyMTM2MjNaFw0zNTA2MjMy
# MjA0MDFaMF8xCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9y
# YXRpb24xMDAuBgNVBAMTJ01pY3Jvc29mdCBXaW5kb3dzIENvZGUgU2lnbmluZyBQ
# Q0EgMjAyNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAJp9a30nwXYq
# Lq7j1TT/zCtt7vxU+CCj+7BkifS/B2gXKGU7OV9SXRJGP1yFs5p6jpsYi4cYzF56
# AV0AEmmEjV8wT2lvPU5BhN3wV30HqYPIYEj5P3WXf0kXD9fvjUf1GAtXEriJ8w7A
# LNaVEm9Rs4ePA0ZsYHaCbU5kBUJQDXv76hafOcQgdFCA3I3zYtfzX2vOwx87uDOa
# CuyKORZih9c3zTf+TLC5QYLyhVMBnDXEHDOrvaw92DSyIqpdgRWpufzqDFy1egVj
# koXZhb+9pZ9heUzNXTXhOoXzexh6YzAL4flBWm+Bc1hQyESenEvBJznV+25u3h77
# jjgMUY44+WXQ4u9qddDe/U5SeAaKRvvibmi4z7QRpLvZsla0CPiOUGz00Do5sfkC
# 0EwlsSzfM3+8A9rsyFVOgWDVPzt98OJP2EoaEOq8GE9GCoN2i7/4C2FCwff1BSCT
# JWZO1Wcr2MteJE6UxGV+ihA8nN51YPKD2dYGoewrXvRzC/1HoUeSvlZf0mf9GHEt
# vvkbJVRRo6PBf0md5t87Vb1mM/fIp1eypyaxmXkgpcBwuylsOq2kSVOJ5wBPoaEs
# sJkeMcKnEuuu++UKdDHlS0DtsYjN0QnOucvTdSsdvhzKOSjJF3XVqr9f2C945LXT
# 5rxKIHUIEDBcNYU6BKDDH6rfpKOOCSilAgMBAAGjggFGMIIBQjAOBgNVHQ8BAf8E
# BAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFB6C3w7XjLPXAjSDDtqr
# rWW5r7jsMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMB
# Af8wHwYDVR0jBBgwFoAU1fZWy4/oolxiaNE9lJBb186aGMQwVgYDVR0fBE8wTTBL
# oEmgR4ZFaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMv
# TWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3JsMFoGCCsGAQUFBwEBBE4wTDBKBggr
# BgEFBQcwAoY+aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNS
# b29DZXJBdXRfMjAxMC0wNi0yMy5jcnQwDQYJKoZIhvcNAQEMBQADggIBAENf+N8/
# u+mUjDtc9btoA52RBc0XVDSBMQBMqxu56hXHBwuctUWs1XBqDDMIFCHu9c6Y/UF+
# TN8EIgjnujApKYmHP4f4EM3ARSmlzrpF5ozOJx0BA5FUv1jmpdf/2ZbqpvCxlxv/
# G1R4KjrSmmqPHzs6igw3b7RTbj7BxIS8fOIkwYWQhB2fLjlg+3HSrDGPFIhpIJWV
# amMIR7a72OGonjdf45rspwqIHuynZU4avy9ruB/Rhhbwm+fMb8BMecIaTmkohx/E
# ZZ5GNWcN6oTYW3G2BM3B3YznWkl9t4shP60fMue+2ksdHGWSE8EVTdSmGUdj0jrU
# c46lGVFJISF3/MxcxnlNeP1Khyr+ZzT4Ets/I7mufpaLnLalzMR2zIuhGOAWWswe
# sbjtFzkVUFgDR2SW903I0XKlbPEA6q8epHGJ9roxh85nsEKcBNUw4Scp68KCqSpF
# BaKiyV1skd+l8U50WNePMb9Bzz0OfASal8v5sQG+DW01kN+I+RKUIbM5I50wJjiH
# ymQFNDsbobFx9I95mCEEPU7fUZ3VT/HOUVbkmX7ltIC/eQAu5GO8fu+ceETMybvb
# oxUM4dYNC+PzooUxfmC0DuKRwB21bX9+acuIBkxIm4Ed3O19w1VLoA7UNOUuJ7z6
# NQ2W/+q7cnfOPl2QVL4qlgCblUT2vmQpllV3MIIHIDCCBQigAwIBAgITMwAAASJs
# BjOj0VK23QAAAAABIjANBgkqhkiG9w0BAQwFADBfMQswCQYDVQQGEwJVUzEeMBwG
# A1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTAwLgYDVQQDEydNaWNyb3NvZnQg
# V2luZG93cyBDb2RlIFNpZ25pbmcgUENBIDIwMjQwHhcNMjYwMzA1MTk1ODI0WhcN
# MjcwMzAzMTk1ODI0WjB0MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMR4wHAYDVQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24wggIiMA0GCSqGSIb3
# DQEBAQUAA4ICDwAwggIKAoICAQCeFlu3IJtMm0DcCUF5EKHUKh/L06a1JyvxX2aV
# aapyABxwDINwxmSS0MR5ObqvX4TKhYX2Ic7+HNhNjxZg7UJUTMamRDcmnS3QHYOe
# oqsgveL1mGQsvBqWROEi2tBe8PrwJrYd4tefld81kaQ1cnbzuUuou3fuAHNudJnA
# CW5SqPmZHF565Ij7jwMeJPxU5JHsPAs/Y11aWPxI85kVEUecjfOMpIx5oTXnNi9U
# nw7BSv/SSrXfkyAyFyqu+PN9ymIWLmOAPaAnJ+QxGRZ9D7jJy4fZK0RxO1GlPTaj
# h9xgbz7SDSeC70z8Ro8mgO3ImrCDv4KdJztT5dnCieVXLMSxCqWikfKznmoCaAqG
# 5skdylL5CFi8TQVKASb2QR0MjS1fqX0FpOkgibu7+m2EPzjp36SkgZ1TXVfAO3j5
# BjRZT/VXaWS0Zk+eNn8/SQf8U/LRRpnuJXhkOWVBNIGq5ew6EsKIQm5Dter5NTSK
# J8gUlqiwDKZ1HuaTEWn1PmgN0YYF9av8fDTeVbEPQe04yv47o8lYpldFM0B9kWOc
# kIc0U+hXNC/+pnDVUh2fjN+JtMaLKTTOciXM2F0tt3CbdKO+cCmlCzSuhN9aeQ2m
# GEnQY3v3V3W15uaUpYELTYOTeTwDVkYJXCZK/zNRXxU38rQ+LwxLOeRVNvEYh2Js
# 0nuX0QIDAQABo4IBvjCCAbowDgYDVR0PAQH/BAQDAgeAMB8GA1UdJQQYMBYGCisG
# AQQBgjc9BgEGCCsGAQUFBwMDMAwGA1UdEwEB/wQCMAAwHQYDVR0OBBYEFJ8ytbdA
# tti7ifaKbKxtPwbvlJiSMFQGA1UdEQRNMEukSTBHMS0wKwYDVQQLEyRNaWNyb3Nv
# ZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxFjAUBgNVBAUTDTIzMDg2NSs1
# MDY5NjUwHwYDVR0jBBgwFoAUHoLfDteMs9cCNIMO2qutZbmvuOwwagYDVR0fBGMw
# YTBfoF2gW4ZZaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWlj
# cm9zb2Z0JTIwV2luZG93cyUyMENvZGUlMjBTaWduaW5nJTIwUENBJTIwMjAyNC5j
# cmwwdwYIKwYBBQUHAQEEazBpMGcGCCsGAQUFBzAChltodHRwOi8vd3d3Lm1pY3Jv
# c29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFdpbmRvd3MlMjBDb2Rl
# JTIwU2lnbmluZyUyMFBDQSUyMDIwMjQuY3J0MA0GCSqGSIb3DQEBDAUAA4ICAQCY
# WFIyjTfk5OvOrxA8oAS2jbS6/P0DDLLiqZsyy6dY9vfid+P2uawuygeoVwkvGqMO
# 0UDWuupsy8VQ/5Fw+GXfx7n9AfvoVg30rHm883siWQ9/GaayCh219lbearlRziyq
# TZoz7ShvA23fRoKs3I9LlXWWOH1d5CeFtuyX0D4oRBU1pQS+ijDSv848ZiLwqjig
# Q7XBaYiPNVQI8xMkkVeIc6B575rVsxqLF5rQFMuXZhwU+BXEbVa4tmVAzY9geP3X
# dOP+L/OwWQV83Z6poT/RW6QMqkNpgf7Pc3oSGKGTpr32AwHIutwmWaEaj8asyDUj
# FABzJBG6AH8pugTf440r61uNlw6mDXppfOZVyuHuH93uNzaINvuW/Y/yEYSDdTvy
# 6Sn5GwWrHKNA23UR18Abu7B2uOeDhiTq69oePmKEAPjjHMTQBrZUX+VBwv+v7MJB
# r8A0s4zg/AY+A/LmN5veQpcAjTj9H+2mKEQobRTUHKBDW1T1fXYQb1JdWQXDK9In
# 6Lx8EaWOExYktAceGfzxC9NoCjxBUb8ba6QOQXNaqrzQlDzGwqxLsiClN+H6h58p
# BfFF2OoSaLlgpih0WRfp7sTGddsp6ajbAAX7VSI/W32o2G7KaDIc1jiok64BnBRo
# ewtKnNm3Ny0ulmJ6IgIZA5DOAxT9tPtEtNhwHmhshzGCGzcwghszAgEBMHYwXzEL
# MAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEwMC4G
# A1UEAxMnTWljcm9zb2Z0IFdpbmRvd3MgQ29kZSBTaWduaW5nIFBDQSAyMDI0AhMz
# AAABImwGM6PRUrbdAAAAAAEiMA0GCWCGSAFlAwQCAQUAoIH6MBkGCSqGSIb3DQEJ
# AzEMBgorBgEEAYI3AgEEMC8GCSqGSIb3DQEJBDEiBCCCZIC1CJgnXdiJTcEQNSI4
# 9cf3+WHc7jqWcE7Zb3hiCTBQBgorBgEEAYI3CgMcMUIMQEQ0MzRDQjVBNDE1M0ZC
# ODA2NDhFNTI1MjE4MjZDNzE2OUM5NTUwOEREODAyRTVBMDg3MDIwNTdCOUZDNzZB
# QjcwWgYKKwYBBAGCNwIBDDFMMEqgJIAiAE0AaQBjAHIAbwBzAG8AZgB0ACAAVwBp
# AG4AZABvAHcAc6EigCBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vd2luZG93czAN
# BgkqhkiG9w0BAQEFAASCAgACJPTj44nFy7j2yS5wj/DGb2KEnMvmOt3ts9VWYYGa
# wrIEBNN0RjXapJ3IzD6l2DTgYfeMkDXcoScNH3ZQ7yOqbu5i8OcGziZ6iTlFsHnQ
# YaqcI8WNsSxe+/l+nrFJWVrItvamVn2HTwpp1D0yk0+byY+r/ewp1zyZjpBmran+
# Q7dJfVZRR9vNfRLpHiMiR5fvesdNnJDyqbfSevkoYZZFJpV+3De/0MLZ9vnwQQTe
# 5L2w0Zsp7dXbldi0iGIc4NFeVsb3idRJ2xrrTiVyE+f4QrkWuzXUAR0GE4h9KEc7
# VhieCy/E1vh64yshg0sXvPt7qz20lcNHZiCnqMSa+78l5fMD8xJICxXzyQRZ4uDd
# 1AEWSpY4ko/Mdt9p+T4xFrKzIzMDvZdwHZtNXNhE2FkRUWZHILWK70q6B4lzUBNZ
# VEFtgxWlz6AavjZhgsHzAq7oZ92GWeNiAu/CEJEPRpr6KzQi5PzDle5UKxmDbueU
# v90YfdOj0uB8SFMSDARuYHWmtLorAZY6LvnZWp0JhkAFa4r0Z/i1gpWto90qLhFB
# /6TS4zWZlp+MCVD5+hPwkRaMa4q9KfkLZnSg3q6iDxCegZm+pcwofkiyd9J6RayX
# +ew+RSu/4yS0bMxrBADiWrn8EjWYdAjknn5uYJAR17Q2rASyz2IBE3SHTQJgW1aP
# vKGCF5UwgheRBgorBgEEAYI3AwMBMYIXgTCCF30GCSqGSIb3DQEHAqCCF24wghdq
# AgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFQBgsqhkiG9w0BCRABBKCCAT8EggE7MIIB
# NwIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCBK1lQx1Hl/tR3AB9zm
# RCRxdQ1R4DPggwAm9zPNUab+YQIGaefCvsoQGBEyMDI2MDUwODE0NTYwOC4zWjAE
# gAIB9KCB0aSBzjCByzELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24x
# EDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UE
# CxMeblNoaWVsZCBUU1MgRVNOOjM3MDMtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNy
# b3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNloIIR7TCCByAwggUIoAMCAQICEzMAAAIf
# OnBp5KIwLpUAAQAAAh8wDQYJKoZIhvcNAQELBQAwfDELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3Rh
# bXAgUENBIDIwMTAwHhcNMjYwMjE5MTkzOTUxWhcNMjcwNTE3MTkzOTUxWjCByzEL
# MAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1v
# bmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWlj
# cm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1Mg
# RVNOOjM3MDMtMDVFMC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFt
# cCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAyzvFxTnH
# xqgKoIs9PgJkJhZd3WdGkxuFBSZKqjXTB8tvA2oXggbOjjbn7pMnuceNglpM4ESM
# vZBNlVsBJ7WfGZIMq8pAtGyKrCA+/uhcYLrHk139VcL5tQ/NdOFZnraASZSeLhm7
# siWVL1w8eeZ1YedMoC082duFpELJz6b0Wb9pD3N/X924S8h1bZx7Gv1v/Ola37Xf
# gHxb3gPqjfxGPlxo+XPwzzFwmBAm9Gq2G/dnQyVrcM6cga6eIHx5YGNVBKXOJeAB
# hC639ieMK8U801vkjPF4VdXTjj62Iw9PNCG2ai/AfiBdEQnZ9uvWF6xiukCB4qc5
# ymXAkvIzd9GAB50yVTeWc7Orf9mLKgRg6rrw2ne/d+BRU8M71HDt1aCMnfd11sLz
# /P0ghVSYdtVvKBkE6bRh8pcvhZeIXp1TFWRdb+qLDrYq1/BhU4hIZ3/J0XToO8mW
# ACdMcvQrQ3212k5/3H9y6tzfxgmChYwvuZlAhPgCYZsTLjHb0lBpiogBXYjwI1E6
# rFlgQWSZtHgsIHhiRZpkAPle//fASnBPoFC+zvXlkQ0MCngHL6Oq8Tb9mOIyqxwO
# mf8It2v3ylISwjWREvKhna6QwJu6ofuhY2McrQG5IijOrkzcv1Cz5cLZWGaACQw0
# D+3mAssMFWzU2x10QUkvjXHAtLEgeFu1Ou8CAwEAAaOCAUkwggFFMB0GA1UdDgQW
# BBTZO9rBg5R9K+Q8L3xkeV8CSPAe2zAfBgNVHSMEGDAWgBSfpxVdAF5iXYP05dJl
# pxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAx
# MCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwGCCsGAQUFBzAChlBodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFRpbWUtU3Rh
# bXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQM
# MAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEA
# ZW7tyKMp5z89CtYj23jZ7Ho9m9eZebHZdhQBQQRk/ZUXXNoDVfCwCLrD2Bx4VL0Q
# 3LMeJWzDYVSjxruEwy2qjbfwiPkhbRrqnUS6VT9VxPXAi8iqyj6XCRSQqj6Vfnn6
# ALWAZiFEHMccE+1iEO4GoPPq5Cr6zJAqEaiktJir/CdbCn4vOfhtroWf9UbXklXW
# GTmTo/km+MM6J0wk4+xLYDDfwV9+VuXU83e8CXRnqWJFYvO9XUqwtk69WRcwEe0u
# OHawlmaSeqYSWm1TTrDcRSSoEspLoDhls0N9fEa9zEz4NrNwZ7PqVD1YDIo3eG1D
# h9gZRLCzDMDnKJU02aoNR2K3WNY8aVACPYqYwUESDS/zu9OWfv39i4zZiUKKAlSV
# V9uGnaWedfUrH2sxqKlxrfdW5qiqNHyNPSJeLFB4eIoeq6YkAwZci+75rwno8FcW
# Hr2OKlcE2f6N4L5fkdJRcWEvX3iDODXhtPlrA2e4y3IuTBXrjcKLEGN89ul4NaI9
# FPbvp3Efbk1PsQZifAbZQnYUNd0TTF+T/pK0WDwd1wqfSZul2jtffeat9gCGZtZs
# wRiOsh5b4l2hAuU8xojtS17j7V2VNl/d6ECWzKHt7/PuQjyq0GpRlsmLodmt1dac
# G4/ltBRJhBT6bvEyPqmDtSCEFlEkbxY17YeTm9NoTDIwggdxMIIFWaADAgECAhMz
# AAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQGEwJV
# UzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UE
# ChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9v
# dCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAxMDAeFw0yMTA5MzAxODIyMjVaFw0z
# MDA5MzAxODMyMjVaMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9u
# MRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRp
# b24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMIICIjAN
# BgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA5OGmTOe0ciELeaLL1yR5vQ7VgtP9
# 7pwHB9KpbE51yMo1V/YBf2xK4OK9uT4XYDP/XE/HZveVU3Fa4n5KWv64NmeFRiMM
# tY0Tz3cywBAY6GB9alKDRLemjkZrBxTzxXb1hlDcwUTIcVxRMTegCjhuje3XD9gm
# U3w5YQJ6xKr9cmmvHaus9ja+NSZk2pg7uhp7M62AW36MEBydUv626GIl3GoPz130
# /o5Tz9bshVZN7928jaTjkY+yOSxRnOlwaQ3KNi1wjjHINSi947SHJMPgyY9+tVSP
# 3PoFVZhtaDuaRr3tpK56KTesy+uDRedGbsoy1cCGMFxPLOJiss254o2I5JasAUq7
# vnGpF1tnYN74kpEeHT39IM9zfUGaRnXNxF803RKJ1v2lIH1+/NmeRd+2ci/bfV+A
# utuqfjbsNkz2K26oElHovwUDo9Fzpk03dJQcNIIP8BDyt0cY7afomXw/TNuvXsLz
# 1dhzPUNOwTM5TI4CvEJoLhDqhFFG4tG9ahhaYQFzymeiXtcodgLiMxhy16cg8ML6
# EgrXY28MyTZki1ugpoMhXV8wdJGUlNi5UPkLiWHzNgY1GIRH29wb0f2y1BzFa/Zc
# UlFdEtsluq9QBXpsxREdcu+N+VLEhReTwDwV2xo3xwgVGD94q0W29R6HXtqPnhZy
# acaue7e3PmriLq0CAwEAAaOCAd0wggHZMBIGCSsGAQQBgjcVAQQFAgMBAAEwIwYJ
# KwYBBAGCNxUCBBYEFCqnUv5kxJq+gpE8RjUpzxD/LwTuMB0GA1UdDgQWBBSfpxVd
# AF5iXYP05dJlpxtTNRnpcjBcBgNVHSAEVTBTMFEGDCsGAQQBgjdMg30BATBBMD8G
# CCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3Mv
# UmVwb3NpdG9yeS5odG0wEwYDVR0lBAwwCgYIKwYBBQUHAwgwGQYJKwYBBAGCNxQC
# BAweCgBTAHUAYgBDAEEwCwYDVR0PBAQDAgGGMA8GA1UdEwEB/wQFMAMBAf8wHwYD
# VR0jBBgwFoAU1fZWy4/oolxiaNE9lJBb186aGMQwVgYDVR0fBE8wTTBLoEmgR4ZF
# aHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9v
# Q2VyQXV0XzIwMTAtMDYtMjMuY3JsMFoGCCsGAQUFBwEBBE4wTDBKBggrBgEFBQcw
# AoY+aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNSb29DZXJB
# dXRfMjAxMC0wNi0yMy5jcnQwDQYJKoZIhvcNAQELBQADggIBAJ1VffwqreEsH2cB
# MSRb4Z5yS/ypb+pcFLY+TkdkeLEGk5c9MTO1OdfCcTY/2mRsfNB1OW27DzHkwo/7
# bNGhlBgi7ulmZzpTTd2YurYeeNg2LpypglYAA7AFvonoaeC6Ce5732pvvinLbtg/
# SHUB2RjebYIM9W0jVOR4U3UkV7ndn/OOPcbzaN9l9qRWqveVtihVJ9AkvUCgvxm2
# EhIRXT0n4ECWOKz3+SmJw7wXsFSFQrP8DJ6LGYnn8AtqgcKBGUIZUnWKNsIdw2Fz
# Lixre24/LAl4FOmRsqlb30mjdAy87JGA0j3mSj5mO0+7hvoyGtmW9I/2kQH2zsZ0
# /fZMcm8Qq3UwxTSwethQ/gpY3UA8x1RtnWN0SCyxTkctwRQEcb9k+SS+c23Kjgm9
# swFXSVRk2XPXfx5bRAGOWhmRaw2fpCjcZxkoJLo4S5pu+yFUa2pFEUep8beuyOiJ
# Xk+d0tBMdrVXVAmxaQFEfnyhYWxz/gq77EFmPWn9y8FBSX5+k77L+DvktxW/tM4+
# pTFRhLy/AsGConsXHRWJjXD+57XQKBqJC4822rpM+Zv/Cuk0+CQ1ZyvgDbjmjJnW
# 4SLq8CdCPSWU5nR0W2rRnj7tfqAxM328y+l7vzhwRNGQ8cirOoo6CGJ/2XBjU02N
# 7oJtpQUQwXEGahC0HVUzWLOhcGbyoYIDUDCCAjgCAQEwgfmhgdGkgc4wgcsxCzAJ
# BgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25k
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJTAjBgNVBAsTHE1pY3Jv
# c29mdCBBbWVyaWNhIE9wZXJhdGlvbnMxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVT
# TjozNzAzLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAg
# U2VydmljZaIjCgEBMAcGBSsOAwIaAxUASyDINT+7Dbgl6Zmx9iF09rV3hBCggYMw
# gYCkfjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYD
# VQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsF
# AAIFAO2n/2QwIhgPMjAyNjA1MDgwNjIxMjRaGA8yMDI2MDUwOTA2MjEyNFowdzA9
# BgorBgEEAYRZCgQBMS8wLTAKAgUA7af/ZAIBADAKAgEAAgIsuQIB/zAHAgEAAgIT
# czAKAgUA7alQ5AIBADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAow
# CAIBAAIDB6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEBCwUAA4IBAQDJGroZ4NNM
# xG0FZ6zgraVzxXQLOf1DCFqHAdScoGmVYqFEAKbUYb85okSu1cwexMNtfYFsWsEa
# gqWVolg5V7jI91/v1DZIITifhYUs5ZWezumRm3x1UvHxU0Oh422B9ghStqqbbHHU
# 8+4ns1GMXjeOMNuy6N1koCdEEkYD94kRzR6YckLESk8agQ5enjMSjTZ3hlvbIlDa
# X9kX/iBLzKaWxfa+0F1/y82UXeYsmEBq2F8iCOirqLbHbw0Vol+uyT/6UpNW8XYy
# BisDm/Mo4VvpM8xUXgHBYLvG5wTeiuLrPU07ZD8gSPQOppVRZv4VRY2S3LlZHGZm
# QE+Ub7yX7jGLMYIEDTCCBAkCAQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgT
# Cldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENB
# IDIwMTACEzMAAAIfOnBp5KIwLpUAAQAAAh8wDQYJYIZIAWUDBAIBBQCgggFKMBoG
# CSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQgnx3H/XPi
# tbyG7X+U13inEbMH3s6fH9Lc1yuwexdvsSswgfoGCyqGSIb3DQEJEAIvMYHqMIHn
# MIHkMIG9BCCwJArfVpArDLVEZBbuk2ND91F3UZwomLj2YXt8pC38FDCBmDCBgKR+
# MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMT
# HU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACHzpwaeSiMC6VAAEA
# AAIfMCIEINgIeuQT91AYM0zBf+jqv4eKaKFYJHinmLCG0K+00XPJMA0GCSqGSIb3
# DQEBCwUABIICAKEkn5p/O3ejqOE+cFWsuhJLcTiaYkzygXFnDE54US9waKH0bacg
# MNOVGTz3qmkjqRiw7rHupM40kWecA7iVDG4tNMNsf+3gzWaS3GNTmY86rJtCha03
# gwMuIGqaw7JefOvaP09czbDPLxMGF9shGj4GofxLiwRPL57LEmclDxEHxdWcxegm
# yTo4CbeJ9lfd3YkcHP/uH3lYyuorRw5BX9bi9l/PbK3G+2teorTo6tSSfVpDJXtG
# TZXrSkRX/haPk9ZPkb7Ev5B897hbSIqsstWLhP3eRBOhtLJkoKqmWAuTEasDnbf/
# P7h7z3d/fDjsTb//lY6PgledRuRWWN7gZXfS6EnLWeZ62FgpPwG8NGaWehp58MIU
# l6uuQ7Zw/NanwJU8p3FNeumUuQMqVytritpAANu5HB5TyvPGzJaLOlCvOiMs7B3p
# KA1RR8klf5ESXAtv+k7lTw2zac5QpBBvoYBsHM2cJ6Ix5sdS7nV2v8L60dOq+KnW
# jV2imP6jKBf16/DJh/yRxAmyEujF+rohWBtlwCeAfadqiHy1Rkz+tebjUL3bTqBy
# JIOmBuV/g5lILWnHTazHFgZ/WFAinbejJIy/R+AE+PeV4/DFT+4B58ldIAx/wR6G
# MxkC+p6Rv8+S5p396c14KO+mWTJKq5ildnX221Cdl2Y29afcT5Afmclk
# SIG # End signature block
