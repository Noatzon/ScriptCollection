<#
.SYNOPSIS
    Shows the current status of the Secure Boot rollout orchestrator.

.DESCRIPTION
    Provides real-time visibility into the rollout progress:
    - Current wave number and devices targeted
    - Devices updated vs pending
    - Blocked buckets requiring attention
    - Recent activity log
    - Dashboard link
    
    Run this anytime to see how the rollout is progressing.

.PARAMETER ReportBasePath
    Path to the report/state directory used by the orchestrator

.PARAMETER ShowLog
    Display recent log entries (last 50 lines)

.PARAMETER ShowBlocked
    Show details of blocked buckets

.PARAMETER ShowWaves
    Show wave history with device counts

.PARAMETER Watch
    Continuously refresh status every N seconds

.PARAMETER OpenDashboard
    Open the latest HTML dashboard in browser

.EXAMPLE
    .\Get-SecureBootRolloutStatus.ps1 -ReportBasePath "C:\SecureBootReports"

.EXAMPLE
    .\Get-SecureBootRolloutStatus.ps1 -ReportBasePath "C:\SecureBootReports" -Watch 30

.EXAMPLE
    .\Get-SecureBootRolloutStatus.ps1 -ReportBasePath "C:\SecureBootReports" -OpenDashboard
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)] #Local path for reports and state
    [string]$ReportBasePath,
    
    [Parameter(Mandatory = $false)] #Update in case you changed the task name in "Create-SecurebootTask.ps1"
    [string]$MyTaskName,

    [Parameter(Mandatory = $false)]
    [switch]$ShowLog,
    
    [Parameter(Mandatory = $false)]
    [switch]$ShowBlocked,
    
    [Parameter(Mandatory = $false)]
    [switch]$ShowWaves,
    
    [Parameter(Mandatory = $false)]
    [int]$Watch = 0,
    
    [Parameter(Mandatory = $false)]
    [switch]$OpenDashboard
)

$ErrorActionPreference = "Stop"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function ConvertTo-Hashtable {
    param([Parameter(ValueFromPipeline = $true)]$InputObject)
    process {
        if ($null -eq $InputObject) { return @{} }
        if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject }
        if ($InputObject -is [PSCustomObject]) {
            $hash = @{}
            foreach ($prop in $InputObject.PSObject.Properties) {
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

function Show-Status {
    $stateDir = Join-Path $ReportBasePath "RolloutState"
    $rolloutStatePath = Join-Path $stateDir "RolloutState.json"
    $blockedBucketsPath = Join-Path $stateDir "BlockedBuckets.json"
    
    Clear-Host
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host "   SECURE BOOT ROLLOUT STATUS" -ForegroundColor Cyan
    Write-Host "   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host ""
    
    # Check if orchestrator task is running
    $task = Get-ScheduledTask -TaskName "$MyTaskName" -ErrorAction SilentlyContinue
    if ($task) {
        $taskState = $task.State
        $color = if ($taskState -eq "Running") { "Green" } elseif ($taskState -eq "Ready") { "Yellow" } else { "Red" }
        Write-Host "Scheduled Task: " -NoNewline
        Write-Host $taskState -ForegroundColor $color
    } else {
        Write-Host "Scheduled Task: " -NoNewline
        Write-Host "Not Installed" -ForegroundColor Gray
    }
    
    # Load rollout state
    if (-not (Test-Path $rolloutStatePath)) {
        Write-Host ""
        Write-Host "No rollout state found. Orchestrator may not have started yet." -ForegroundColor Yellow
        Write-Host "State path: $rolloutStatePath" -ForegroundColor Gray
        return
    }
    
    $state = Get-Content $rolloutStatePath -Raw | ConvertFrom-Json | ConvertTo-Hashtable
    
    Write-Host ""
    Write-Host "ROLLOUT PROGRESS" -ForegroundColor Yellow
    Write-Host ("-" * 40)
    
    $status = $state.Status
    $statusColor = switch ($status) {
        "Completed" { "Green" }
        "InProgress" { "Cyan" }
        "NotStarted" { "Gray" }
        default { "White" }
    }
    
    Write-Host "Status:              " -NoNewline
    Write-Host $status -ForegroundColor $statusColor
    Write-Host "Current Wave:        $($state.CurrentWave)"
    Write-Host "Total Devices:       $($state.TotalDevicesTargeted)"
    Write-Host "Total Updated:       $($state.TotalDevicesUpdated)"
    $notUpdated = $state.TotalDevicesTargeted - $state.TotalDevicesUpdated
    if ($notUpdated -gt 0) {
        Write-Host "Not Updated:         " -NoNewline
        Write-Host "$notUpdated" -ForegroundColor Yellow
    }
    
    if ($state.StartedAt) {
        Write-Host "Started:             $($state.StartedAt)"
    }
    if ($state.LastAggregation) {
        Write-Host "Last Check:          $($state.LastAggregation)"
    }
    if ($state.CompletedAt) {
        Write-Host "Completed:           $($state.CompletedAt)" -ForegroundColor Green
    }
    
    # Show progress bar
    if ($state.TotalDevicesTargeted -gt 0) {
        $pct = if ($state.TotalDevicesUpdated -and $state.TotalDevicesTargeted) {
            [math]::Round(($state.TotalDevicesUpdated / $state.TotalDevicesTargeted) * 100, 1)
        } else { 0 }
        
        Write-Host ""
        Write-Host "Progress: " -NoNewline
        $barWidth = 40
        $filled = [math]::Floor($barWidth * $pct / 100)
        $empty = $barWidth - $filled
        $pctColor = if ($pct -ge 90) { "Green" } elseif ($pct -ge 50) { "Cyan" } elseif ($pct -ge 25) { "Yellow" } else { "Red" }
        Write-Host "[" -NoNewline
        if ($filled -gt 0) {
            Write-Host ("=" * ($filled - 1) + ">") -ForegroundColor $pctColor -BackgroundColor DarkGreen -NoNewline
        }
        if ($empty -gt 0) {
            Write-Host (" " * $empty) -BackgroundColor DarkGray -NoNewline
        }
        Write-Host "] " -NoNewline
        Write-Host "$pct%" -ForegroundColor $pctColor
        Write-Host "         $($state.TotalDevicesUpdated) / $($state.TotalDevicesTargeted) devices" -ForegroundColor Gray
    }
    
    # Blocked buckets summary
    if (Test-Path $blockedBucketsPath) {
        $blocked = Get-Content $blockedBucketsPath -Raw | ConvertFrom-Json | ConvertTo-Hashtable
        if ($blocked.Count -gt 0) {
            Write-Host ""
            Write-Host "BLOCKED BUCKETS: " -NoNewline -ForegroundColor Red
            Write-Host "$($blocked.Count) buckets need attention" -ForegroundColor Red
            
            if ($ShowBlocked) {
                Write-Host ""
                foreach ($key in $blocked.Keys) {
                    $info = $blocked[$key]
                    Write-Host "  ► $key" -ForegroundColor Red
                    Write-Host "    Reason:  $($info.Reason)" -ForegroundColor Gray
                    $devices = if ($info.FailedDevices) { $info.FailedDevices } else { "(unknown)" }
                    Write-Host "    Devices: " -NoNewline -ForegroundColor Gray
                    Write-Host "$devices" -ForegroundColor Yellow
                    Write-Host "    Since:   $($info.BlockedAt)" -ForegroundColor Gray
                    Write-Host "    Unblock: " -NoNewline -ForegroundColor Gray
                    Write-Host ".\Start-SecureBootRolloutOrchestrator.ps1 -ReportBasePath '$ReportBasePath' -UnblockBucket '$key'" -ForegroundColor Cyan
                    Write-Host ""
                }
                Write-Host "  To unblock ALL buckets:" -ForegroundColor Gray
                Write-Host "  .\Start-SecureBootRolloutOrchestrator.ps1 -ReportBasePath '$ReportBasePath' -UnblockAll" -ForegroundColor Cyan
            } else {
                Write-Host "  Run with -ShowBlocked for details" -ForegroundColor Gray
            }
        }
    }
    
    # Wave history
    if ($ShowWaves -and $state.WaveHistory -and $state.WaveHistory.Count -gt 0) {
        Write-Host ""
        Write-Host "WAVE HISTORY" -ForegroundColor Yellow
        Write-Host ("-" * 40)
        
        foreach ($wave in $state.WaveHistory) {
            Write-Host "Wave $($wave.WaveNumber): " -NoNewline -ForegroundColor Cyan
            Write-Host "$($wave.DeviceCount) devices" -NoNewline
            Write-Host " - $($wave.StartedAt)" -ForegroundColor Gray
        }
    }
    
    # Latest dashboard
    $latestAggregation = Get-ChildItem -Path $ReportBasePath -Directory -Filter "Aggregation_*" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        Select-Object -First 1
    
    if ($latestAggregation) {
        # Prefer the stable Latest.html link (always current, never deleted by retention)
        $latestDashboard = Join-Path $latestAggregation.FullName "SecureBoot_Dashboard_Latest.html"
        $timestampedDashboard = Get-ChildItem -Path $latestAggregation.FullName -Filter "SecureBoot_Dashboard_2*.html" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        
        if ((Test-Path $latestDashboard) -or $timestampedDashboard) {
            Write-Host ""
            Write-Host "DASHBOARD" -ForegroundColor Yellow
            if (Test-Path $latestDashboard) {
                Write-Host "  Latest:      $latestDashboard" -ForegroundColor White
            }
            if ($timestampedDashboard) {
                Write-Host "  Timestamped: $($timestampedDashboard.FullName)" -ForegroundColor Gray
            }
            
            if ($OpenDashboard) {
                $openPath = if (Test-Path $latestDashboard) { $latestDashboard } else { $timestampedDashboard.FullName }
                Start-Process $openPath
            }
        }
    }
    
    # Recent log
    if ($ShowLog) {
        $logFile = Get-ChildItem -Path $stateDir -Filter "Orchestrator_*.log" -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            Select-Object -First 1
        
        if ($logFile) {
            Write-Host ""
            Write-Host "RECENT LOG" -ForegroundColor Yellow
            Write-Host ("-" * 40)
            
            Get-Content $logFile.FullName -Tail 20 | ForEach-Object {
                if ($_ -match '\[ERROR\]') {
                    Write-Host $_ -ForegroundColor Red
                } elseif ($_ -match '\[WARN\]') {
                    Write-Host $_ -ForegroundColor Yellow
                } elseif ($_ -match '\[OK\]') {
                    Write-Host $_ -ForegroundColor Green
                } elseif ($_ -match '\[WAVE\]') {
                    Write-Host $_ -ForegroundColor Cyan
                } else {
                    Write-Host $_ -ForegroundColor Gray
                }
            }
        }
    }
    
    Write-Host ""
    Write-Host ("-" * 80) -ForegroundColor DarkGray
    
    if (-not $ShowLog -or -not $ShowWaves -or -not $ShowBlocked) {
        Write-Host "Options: -ShowLog | -ShowWaves | -ShowBlocked | -OpenDashboard | -Watch 30" -ForegroundColor DarkGray
    }
}

# ============================================================================
# MAIN
# ============================================================================

if (-not (Test-Path $ReportBasePath)) {
    Write-Host "Report path not found: $ReportBasePath" -ForegroundColor Red
    exit 1
}

if ($Watch -gt 0) {
    Write-Host "Watching status every $Watch seconds. Press Ctrl+C to stop." -ForegroundColor Cyan
    while ($true) {
        Show-Status
        Start-Sleep -Seconds $Watch
    }
} else {
    Show-Status
}

# SIG # Begin signature block
# MIIp3gYJKoZIhvcNAQcCoIIpzzCCKcsCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDbsPrPR3i7syzC
# oFo3mYB0caMelipWAp1XVHjLH1ZDraCCDeUwgga9MIIEpaADAgECAhMzAAAAHEif
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
# ewtKnNm3Ny0ulmJ6IgIZA5DOAxT9tPtEtNhwHmhshzGCG08wghtLAgEBMHYwXzEL
# MAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEwMC4G
# A1UEAxMnTWljcm9zb2Z0IFdpbmRvd3MgQ29kZSBTaWduaW5nIFBDQSAyMDI0AhMz
# AAABImwGM6PRUrbdAAAAAAEiMA0GCWCGSAFlAwQCAQUAoIH6MBkGCSqGSIb3DQEJ
# AzEMBgorBgEEAYI3AgEEMC8GCSqGSIb3DQEJBDEiBCAQh5xeZe4ZmThy/cbKD9h/
# yYraaYMAkwk+etSXkOjB8zBQBgorBgEEAYI3CgMcMUIMQDc2MzcyNkQyRDNCMjY2
# QUU0NjNEMEY5MDczRURFRTczNTQxNzUxMTVGNkNCNkIwOTJEQTU3MzRBRTNBOTk2
# QzIwWgYKKwYBBAGCNwIBDDFMMEqgJIAiAE0AaQBjAHIAbwBzAG8AZgB0ACAAVwBp
# AG4AZABvAHcAc6EigCBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vd2luZG93czAN
# BgkqhkiG9w0BAQEFAASCAgBFdA/5Tc/sTzf44oItoWQdmLE7+z8ek1EMkk0yeldT
# Eg2F17mqrHeotiXonxzqWnjFKiPRGxruNUAvb++G7QZEsN3r1CGl/Nq1/Rgu40jX
# t5Vd42mzvFsZts9JfpXacERHF4ZgcMuirZaz09lsWwbgtc/Jcg0CFS40O0H1UhNi
# /704lF0kAQ290QP/1K6YOkLoy5y/jjBv8wYa03ec0pBHl+BpBKeY+Zg/LtGDLUE/
# gHnjyuhUp6xvd85sgMDnagCA9KUKLdlCgCtHfCsVFo+WMaRotBj8vh3+VdZS9SNB
# ANeN5IX1ARkhluTb1yP9xf77uE7B0vLcdq/8DvP9d2jofRMiJ7p/1hco0T1H4dxV
# sl+eS83doTCiXTHOq69ZUhwEHjnwhtfWlIwE+EwUv3fWs55QJupsuC9G/wMjM9Wx
# Fcd7gnPMe/JxCsTLCXY60qruf19oQsszzov+TOP9bedAPz9InlwzaMuEHCYkUMK2
# lMXozCiPq5kkWhSvnw9kfMTii8bUTNAbGofqy5vfdTlUcsWQiitBw3esbxVP46an
# hlce0gxiEGB2k00skSh1gIjNZJi4bYzSlJGN5b+EwmYCol2pB5etU7lnIj6CNFoI
# wbZYVDRgW1uad5KvZy6H9orokMoHomvMrsMZ0zIcAlp7gf4Kfiw+UsP+O9E5fZgx
# OKGCF60wghepBgorBgEEAYI3AwMBMYIXmTCCF5UGCSqGSIb3DQEHAqCCF4YwgheC
# AgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG9w0BCRABBKCCAUkEggFFMIIB
# QQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCCSsW5eUxPiBbe8EktB
# ozwYDmQVym76KbtdZy0r9GENAAIGaevW9DumGBMyMDI2MDUwODE0NTYwOC44MzVa
# MASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo0QzFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaCCEfswggcoMIIFEKAD
# AgECAhMzAAACGCXZkgXi5+XkAAEAAAIYMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNV
# BAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4w
# HAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29m
# dCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI1MDgxNDE4NDgyNVoXDTI2MTExMzE4
# NDgyNVowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xLTAr
# BgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJhdGlvbnMgTGltaXRlZDEnMCUG
# A1UECxMeblNoaWVsZCBUU1MgRVNOOjRDMUEtMDVFMC1EOTQ3MSUwIwYDVQQDExxN
# aWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIICIjANBgkqhkiG9w0BAQEFAAOC
# Ag8AMIICCgKCAgEAsdzo6uuQJqAfxLnvEBfIvj6knK+p6bnMXEFZ/QjPOFywlcjD
# fzI8Dg1nzDlxm7/pqbvjWhyvazKmFyO6qbPwClfRnI57h5OCixgpOOCGJJQIZSTi
# Mgui3B8DPiFtJPcfzRt3FsnxjLXwBIjGgnjGfmQl7zejA1WoYL/qBmQhw/FDFTWe
# bxfo4m0RCCOxf2qwj31aOjc2aYUePtLMXHsXKPFH0tp5SKIF/9tJxRSg0NYEvQqV
# ilje8aQkPd3qzAux2Mc5HMSK4NMTtVVCYAWDUZ4p+6iDI9t5BNCBIsf5ooFNUWtx
# CqnpFYiLYkHfFfxhVUBZ8LGGxYsA36snD65s2Hf4t86k0e8WelH/usfhYqOM3z2y
# aI8rg08631IkwqUzyQoEPqMsHgBem1xpmOGSIUnVvTsAv+lmECL2RqrcOZlZax8K
# 0aiij8h6UkWBN2IA/ikackTSGVRBQmWWZuLFWV/T4xuNzscC0X7xo4fetgpsqaEA
# 0jY/QevkTvLv4OlNN9eOL8LNh7Vm0R65P7oabOQDqtUFAwCgjgPJ0iV/jQCaMAcO
# 3SYpG5wSAYiJkk4XLjNSlNxU2Idjs1sORhl7s7LC6hOb7bVAHVwON74GxfFNiEIA
# 6BfudANjpQJ0nUc/ppEXpT4pgDBHsYtV8OyKSjKsIxOdFR7fIJIjDc8DvUkCAwEA
# AaOCAUkwggFFMB0GA1UdDgQWBBQkLqHEXDobY7dHuoQCBa4sX7aL0TAfBgNVHSME
# GDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNVHR8EWDBWMFSgUqBQhk5odHRw
# Oi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBUaW1l
# LVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYIKwYBBQUHAQEEYDBeMFwGCCsG
# AQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01p
# Y3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAyMDEwKDEpLmNydDAMBgNVHRMB
# Af8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDAN
# BgkqhkiG9w0BAQsFAAOCAgEAnkjRhjwPgdoIpvt4YioT/j0LWuBxF3ARBKXDENgg
# raKvC0oRPwbjAmsXnPEmtuo5MD8uJ9Xw9eYrxqqkK4DF9snZMrHMfooxCa++1irL
# z8YoozC4tci+a4N37Sbke1pt1xs9qZtvkPgZGWn5BcwVfmAwSZLHi2CuZ06Y0/X+
# t6fNBnrbMVovNaDX4WPdyI9GEzxfIggDsck2Ipo4VXL/Arcz7p2F7bEZGRuyxjgM
# C+woCkDJaH/yk/wcZpAsixe4POdN0DW6Zb35O3Dg3+a6prANMc3WIdvfKDl75P0a
# qcQbQAR7b0f4gH4NMkUct0Wm4GN5KhsE1YK7V/wAqDKmK4jx3zLz3a8Hsxa9HB3G
# yitlmC5sDhOl4QTGN5kRi6oCoV4hK+kIFgnkWjHhSRNomz36QnbCSG/BHLEm2GRU
# 9u3/I4zUd9E1AC97IJEGfwb+0NWb3QEcrkypdGdWwl0LEObhrQR9B1V7+edcyNms
# X0p2BX0rFpd1PkXJSbxf8IcEiw/bkNgagZE+VlDtxXeruLdo5k3lGOv7rPYuOEao
# ZYxDvZtpHP9P36wmW4INjR6NInn2UM+krP/xeLnRbDBkm9RslnoDhVraliKDH62B
# xhcgL9tiRgOHlcI0wqvVWLdv8yW8rxkawOlhCRqT3EKECW8ktUAPwNbBULkT+oWc
# vBcwggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZAAAAAAAVMA0GCSqGSIb3DQEB
# CwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMTIwMAYD
# VQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAxMDAe
# Fw0yMTA5MzAxODIyMjVaFw0zMDA5MzAxODMyMjVaMHwxCzAJBgNVBAYTAlVTMRMw
# EQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVN
# aWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0
# YW1wIFBDQSAyMDEwMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA5OGm
# TOe0ciELeaLL1yR5vQ7VgtP97pwHB9KpbE51yMo1V/YBf2xK4OK9uT4XYDP/XE/H
# ZveVU3Fa4n5KWv64NmeFRiMMtY0Tz3cywBAY6GB9alKDRLemjkZrBxTzxXb1hlDc
# wUTIcVxRMTegCjhuje3XD9gmU3w5YQJ6xKr9cmmvHaus9ja+NSZk2pg7uhp7M62A
# W36MEBydUv626GIl3GoPz130/o5Tz9bshVZN7928jaTjkY+yOSxRnOlwaQ3KNi1w
# jjHINSi947SHJMPgyY9+tVSP3PoFVZhtaDuaRr3tpK56KTesy+uDRedGbsoy1cCG
# MFxPLOJiss254o2I5JasAUq7vnGpF1tnYN74kpEeHT39IM9zfUGaRnXNxF803RKJ
# 1v2lIH1+/NmeRd+2ci/bfV+AutuqfjbsNkz2K26oElHovwUDo9Fzpk03dJQcNIIP
# 8BDyt0cY7afomXw/TNuvXsLz1dhzPUNOwTM5TI4CvEJoLhDqhFFG4tG9ahhaYQFz
# ymeiXtcodgLiMxhy16cg8ML6EgrXY28MyTZki1ugpoMhXV8wdJGUlNi5UPkLiWHz
# NgY1GIRH29wb0f2y1BzFa/ZcUlFdEtsluq9QBXpsxREdcu+N+VLEhReTwDwV2xo3
# xwgVGD94q0W29R6HXtqPnhZyacaue7e3PmriLq0CAwEAAaOCAd0wggHZMBIGCSsG
# AQQBgjcVAQQFAgMBAAEwIwYJKwYBBAGCNxUCBBYEFCqnUv5kxJq+gpE8RjUpzxD/
# LwTuMB0GA1UdDgQWBBSfpxVdAF5iXYP05dJlpxtTNRnpcjBcBgNVHSAEVTBTMFEG
# DCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29m
# dC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wEwYDVR0lBAwwCgYIKwYB
# BQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwCwYDVR0PBAQDAgGGMA8G
# A1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU1fZWy4/oolxiaNE9lJBb186aGMQw
# VgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9j
# cmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIwMTAtMDYtMjMuY3JsMFoGCCsGAQUF
# BwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3Br
# aS9jZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcnQwDQYJKoZIhvcNAQEL
# BQADggIBAJ1VffwqreEsH2cBMSRb4Z5yS/ypb+pcFLY+TkdkeLEGk5c9MTO1OdfC
# cTY/2mRsfNB1OW27DzHkwo/7bNGhlBgi7ulmZzpTTd2YurYeeNg2LpypglYAA7AF
# vonoaeC6Ce5732pvvinLbtg/SHUB2RjebYIM9W0jVOR4U3UkV7ndn/OOPcbzaN9l
# 9qRWqveVtihVJ9AkvUCgvxm2EhIRXT0n4ECWOKz3+SmJw7wXsFSFQrP8DJ6LGYnn
# 8AtqgcKBGUIZUnWKNsIdw2FzLixre24/LAl4FOmRsqlb30mjdAy87JGA0j3mSj5m
# O0+7hvoyGtmW9I/2kQH2zsZ0/fZMcm8Qq3UwxTSwethQ/gpY3UA8x1RtnWN0SCyx
# TkctwRQEcb9k+SS+c23Kjgm9swFXSVRk2XPXfx5bRAGOWhmRaw2fpCjcZxkoJLo4
# S5pu+yFUa2pFEUep8beuyOiJXk+d0tBMdrVXVAmxaQFEfnyhYWxz/gq77EFmPWn9
# y8FBSX5+k77L+DvktxW/tM4+pTFRhLy/AsGConsXHRWJjXD+57XQKBqJC4822rpM
# +Zv/Cuk0+CQ1ZyvgDbjmjJnW4SLq8CdCPSWU5nR0W2rRnj7tfqAxM328y+l7vzhw
# RNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0HVUzWLOhcGbyoYIDVjCCAj4C
# AQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0
# ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo0QzFBLTA1RTAtRDk0NzElMCMG
# A1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2VydmljZaIjCgEBMAcGBSsOAwIa
# AxUAnWtGrXWiuNE8QrKfm4CtGr57z+mggYMwgYCkfjB8MQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1T
# dGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIFAO2oILkwIhgPMjAyNjA1MDgw
# ODQzMzdaGA8yMDI2MDUwOTA4NDMzN1owdDA6BgorBgEEAYRZCgQBMSwwKjAKAgUA
# 7agguQIBADAHAgEAAgIaXTAHAgEAAgITMTAKAgUA7alyOQIBADA2BgorBgEEAYRZ
# CgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0G
# CSqGSIb3DQEBCwUAA4IBAQA+Zfyf1TVJT6ewl65IjITGh/dYL3p0Nn1ORdDwbMxB
# iHIDva/Eyv7jonTy+qRSxLVu/1B9arUYUTgr1ZTRtAsDAGSuUJQl6o7k41Ai3OTn
# 4EyM/OXWSNTiHPf4OClDOIZbyzMfutonMDkMzrepQU56Vg+JRabw42/994/WLbXX
# ul4Caq2pOwVAmhAYpeE+p1ZxOTpbsyweQ00ZbMHWiVsKINyJW4rVDi19oF/35OHa
# S8SL2W713cAN2Q0WDsvCDWIj6pUqh3v91P6gwS6CJAThiePZ+vtm84/NgY6Q6z9D
# fnCLVx1r5X3E7dZ3XPYl3HnoiiWgcOg+012NyF1nOw47MYIEDTCCBAkCAQEwgZMw
# fDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1Jl
# ZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMd
# TWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIwMTACEzMAAAIYJdmSBeLn5eQAAQAA
# AhgwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRAB
# BDAvBgkqhkiG9w0BCQQxIgQgNrkln7W30ZH2p/iO/j3/qtqHR0gV1jMN3rDFUfDB
# WZkwgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHkMIG9BCCZE9yJuOTItIwWaES6lzGK
# K1XcSoz1ynRzaOVzx9eFajCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBD
# QSAyMDEwAhMzAAACGCXZkgXi5+XkAAEAAAIYMCIEIKyKPZex3JjkwB45jalcfB6x
# p5KxcBeEVmx3mN7u2mymMA0GCSqGSIb3DQEBCwUABIICAKABshjwa099vZbrzRDR
# iohNYcBPZoCAZCPbccvpz8KogUkUVV1NLGcXJrtbaU6S2dHt/D3H59QsGS+tq2hl
# P19R9dagYgdHg6Bnsfq2pc9VgvMk+yfVxePO8LY8nCFw3ULtrE8GtAZGqLmY/3Ik
# Yn37zYAv2gdkCaLvohYaGgGI7KMJtZGZn2np+2KSuXkb4XeMBVTteU6TsgBIFNX/
# +pXqRcHWglYoeNBRk1sU3d0KGUuqfnKqxiWn4gOdl0gQokmDOLiB6d6gajpZzKQ4
# pYAazXXSjiMaVCbxOhLZyRAtSL4ZEF/XC8CjuTBiKYAuwwgDu9bFoShxcJUHtWNQ
# 2d8TItbdY9OWNPXl0+JAsc/SeXt8PDS0izyiogEzJbAdEuK1X9giYiS8+CdMvpEm
# ApgHp4CQlS+yW4k9+6fGr8IqCwLs3wlCACWqLIBjjJtimIujnAiTB6SRElv2zV0i
# OOBIqsZh9Zwju3nRCKbfGSxoy356itIjkFx3wEoKRBZpO+noPPkV8b+BThYCb6Fk
# mtvjLRS9z+lerDSkXtnei9av1XW9BHKhiXq1zl9f91np2o36NmWHos56CweufNdQ
# TnMyYT28KJLULv1hVSSkXxbdVCa9WZvR8SsftgDR70HH9Lzl0knz0w7spxaAdjKV
# UKYsRceQGIhsPe5iQDEcOKJO
# SIG # End signature block
