<#
.SYNOPSIS
    Detects Secure Boot certificate update status for fleet-wide monitoring.

.DESCRIPTION
    This detection script collects Secure Boot status, certificate update registry values,
    and device information. It outputs a JSON string for monitoring and reporting.

    Compatible with Intune Remediations, GPO-based collection, and other management tools.
    No remediation script is needed — this is monitoring only.

    Exit 0 = "Without issue"  (certificates updated)
    Exit 1 = "With issue"     (certificates not updated — informational only)

.PARAMETER OutputPath
    Optional. Path to a folder where the JSON file will be saved.
    If provided, saves HOSTNAME_latest.json to this folder.
    If not provided, outputs JSON to stdout (original behavior).

.EXAMPLE
    # Output to stdout (Intune/SCCM detection)
    .\Detect-SecureBootCertUpdateStatus.ps1

.EXAMPLE
    # Save to network share (GPO deployment)
    .\Detect-SecureBootCertUpdateStatus.ps1 -OutputPath "\\server\SecureBootLogs$"

.NOTES
    Registry paths per https://aka.ms/securebootplaybook:
      HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot
      HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
#>
param(
    [Parameter(Mandatory = $false)] #Must be a FQDN! You can't use a IP nor skip the ".domain" part! This is were it'll store the output. I've named mine "SBC_Logs" throughout the scripts.
    [string]$OutputPath,

    [Parameter(Mandatory = $false)] #Path to save local log files. Used primarily for development & troubleshooting related to deployment
    [string]$LocalfilePath
)


# Added Log function to assist with deployment. "Stolen" from Orchestrator script (^._,.^)/
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "OK"      { "Green" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "BLOCKED" { "DarkRed" }
        default   { "White" }
    }
    #If you for some reason run script through interactive PS
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
    # Also log to file
    $logFile = Join-Path $LocalfilePath "SBClog_$(Get-Date -Format 'yyyyMMdd').log"
    "[$timestamp] [$Level] $Message" | Out-File $logFile -Append -Encoding UTF8
}

Write-Log "======================ono======================" "INFO"
Write-Log "Log destination: $OutputPath " "INFO"

# 1. HostName
try {
    $hostname = $env:COMPUTERNAME
    if ([string]::IsNullOrEmpty($hostname)) {
        Write-Log "Hostname could not be determined" "WARN"
        $hostname = "Unknown"
    }
    Write-Log "Hostname: $hostname" "INFO"
} catch {
    Write-Log "Error retrieving hostname: $_" "ERROR"
    $hostname = "Error"
    #Write-Log "Hostname: $hostname" "ERROR"
}

# 2. CollectionTime
try {
    $collectionTime = Get-Date
    if ($null -eq $collectionTime) {
        Write-Log "Could not retrieve current date/time" "WARN"
        $collectionTime = "Unknown"
    }
    Write-Log "Collection Time: $collectionTime" "INFO"
} catch {
    Write-Log "Error retrieving date/time: $_" "ERROR"
    $collectionTime = "Error"
    #Write-Log "Collection Time: $collectionTime" "ERROR"
}

# Registry: Secure Boot Main Key (3 values)
# SEMI-LEGACY CODE - CORRENT ORCHESTRATOR RELIES ON WINCS FLAGS!

# 3. SecureBootEnabled
#System Requirements: UEFI/Secure Boot capable system
try {
    $secureBootEnabled = Confirm-SecureBootUEFI -ErrorAction Stop
    Write-Log "Secure Boot Enabled: $secureBootEnabled" "INFO"
} catch {
    Write-Log "Unable to determine Secure Boot status via cmdlet: $_" "WARN"
    # Try registry fallback
    try {
        $regValue = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State" -Name UEFISecureBootEnabled -ErrorAction Stop
        $secureBootEnabled = [bool]$regValue.UEFISecureBootEnabled
        Write-Log "Secure Boot Enabled: $secureBootEnabled" "INFO"
    } catch {
        Write-Log "Unable to determine Secure Boot status via registry. System may not support UEFI/Secure Boot." "ERROR"
        $secureBootEnabled = $null
        #Write-Log "Secure Boot Enabled: Not Available" "WARN"
    }
}

# 4. HighConfidenceOptOut
try {
    $regValue = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot" -Name HighConfidenceOptOut -ErrorAction Stop
    $highConfidenceOptOut = $regValue.HighConfidenceOptOut
    Write-Log "High Confidence Opt Out: $highConfidenceOptOut" "INFO"
} catch {
    # HighConfidenceOptOut is optional - not present on most systems
    $highConfidenceOptOut = $null
    Write-Log "High Confidence Opt Out: Not Set" "INFO"
}

# 4b. MicrosoftUpdateManagedOptIn
try {
    $regValue = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot" -Name MicrosoftUpdateManagedOptIn -ErrorAction Stop
    $microsoftUpdateManagedOptIn = $regValue.MicrosoftUpdateManagedOptIn
    Write-Log "Microsoft Update Managed Opt In: $microsoftUpdateManagedOptIn" "INFO"
} catch {
    # MicrosoftUpdateManagedOptIn is optional - not present on most systems
    $microsoftUpdateManagedOptIn = $null
    Write-Log "Microsoft Update Managed Opt In: Not Set" "INFO"
}

# 5. AvailableUpdates
try {
    $regValue = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot" -Name AvailableUpdates -ErrorAction Stop
    $availableUpdates = $regValue.AvailableUpdates
    if ($null -ne $availableUpdates) {
        # Convert to hexadecimal format
        $availableUpdatesHex = "0x{0:X}" -f $availableUpdates
        Write-Log "Available Updates: $availableUpdatesHex" "INFO"
    } else {
        Write-Log "Available Updates: Not Available" "WARN"
    }
} catch {
    Write-Log "AvailableUpdates registry key not found or inaccessible" "BLOCKED"
    $availableUpdates = $null
    #Write-Log "Available Updates: Not Available" "WARN"
}

# 5b. AvailableUpdatesPolicy (GPO-controlled persistent value)
try {
    $regValue = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot" -Name AvailableUpdatesPolicy -ErrorAction Stop
    $availableUpdatesPolicy = $regValue.AvailableUpdatesPolicy
    if ($null -ne $availableUpdatesPolicy) {
        # Convert to hexadecimal format
        $availableUpdatesPolicyHex = "0x{0:X}" -f $availableUpdatesPolicy
        Write-Log "Available Updates Policy: $availableUpdatesPolicyHex" "INFO"
    } else {
        Write-Log "Available Updates Policy: Not Set" "INFO"
    }
} catch {
    # AvailableUpdatesPolicy is optional - only set when GPO is applied
    $availableUpdatesPolicy = $null
    Write-Log "Available Updates Policy: Not Set"  "INFO"
}

# Registry: Servicing Key (3 values)
# 6. UEFICA2023Status
try {
    $regValue = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing" -Name UEFICA2023Status -ErrorAction Stop
    $uefica2023Status = $regValue.UEFICA2023Status
    Write-Log "Windows UEFI CA 2023 Status: $uefica2023Status" "INFO"
} catch {
    Write-Log "Windows UEFI CA 2023 Status registry key not found or inaccessible" "BLOCKED"
    $uefica2023Status = $null
    #Write-Log "Windows UEFI CA 2023 Status: Not Available" "BLOCKED"
}

# 7. UEFICA2023Error

try {
    $regValue = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing" -Name UEFICA2023Error -ErrorAction Stop
    $uefica2023Error = $regValue.UEFICA2023Error
    Write-Log "UEFI CA 2023 Error: $uefica2023Error" "ERROR"
} catch {
    # UEFICA2023Error only exists if there was an error - absence is good
    $uefica2023Error = $null
    Write-Log "UEFI CA 2023 Error: None" "INFO"
}

# 8. UEFICA2023ErrorEvent

try {
    $regValue = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing" -Name UEFICA2023ErrorEvent -ErrorAction Stop
    $uefica2023ErrorEvent = $regValue.UEFICA2023ErrorEvent
    Write-Log "UEFI CA 2023 Error Event: $uefica2023ErrorEvent" "INFO"
} catch {
    $uefica2023ErrorEvent = $null
    Write-Log "UEFI CA 2023 Error Event: Not Available" "WARN"
}

# Registry: Device Attributes (7 values: 9-15)

# 9. OEMManufacturerName

try {
    $regValue = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing\DeviceAttributes" -Name OEMManufacturerName -ErrorAction Stop
    $oemManufacturerName = $regValue.OEMManufacturerName
    if ([string]::IsNullOrEmpty($oemManufacturerName)) {
        Write-Log "OEMManufacturerName is empty" "ERROR"
        $oemManufacturerName = "Unknown"
    }
    Write-Log "OEM Manufacturer Name: $oemManufacturerName" "INFO"
} catch {
    Write-Log "OEMManufacturerName registry key not found or inaccessible" "BLOCKED"
    $oemManufacturerName = $null
    #Write-Log "OEM Manufacturer Name: Not Available" "BLOCKED"
}

# 10. OEMModelSystemFamily

try {
    $regValue = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing\DeviceAttributes" -Name OEMModelSystemFamily -ErrorAction Stop
    $oemModelSystemFamily = $regValue.OEMModelSystemFamily
    if ([string]::IsNullOrEmpty($oemModelSystemFamily)) {
        Write-Log "OEMModelSystemFamily is empty" "ERROR"
        $oemModelSystemFamily = "Unknown"
    }
    Write-Log "OEM Model System Family: $oemModelSystemFamily" "INFO"
} catch {
    Write-Log "OEMModelSystemFamily registry key not found or inaccessible" "ERROR"
    $oemModelSystemFamily = $null
    #Write-Log "OEM Model System Family: Not Available" "BLOCKED"
}

# 11. OEMModelNumber

try {
    $regValue = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing\DeviceAttributes" -Name OEMModelNumber -ErrorAction Stop
    $oemModelNumber = $regValue.OEMModelNumber
    if ([string]::IsNullOrEmpty($oemModelNumber)) {
        Write-Log "OEMModelNumber is empty" "ERROR"
        $oemModelNumber = "Unknown"
    }
    Write-Log "OEM Model Number: $oemModelNumber" "INFO"
} catch {
    Write-Log "OEMModelNumber registry key not found or inaccessible" "BLOCKED"
    $oemModelNumber = $null
    #Write-Log "OEM Model Number: Not Available" "WARN"
}

# 12. FirmwareVersion

try {
    $regValue = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing\DeviceAttributes" -Name FirmwareVersion -ErrorAction Stop
    $firmwareVersion = $regValue.FirmwareVersion
    if ([string]::IsNullOrEmpty($firmwareVersion)) {
        Write-Log "FirmwareVersion is empty" "ERROR"
        $firmwareVersion = "Unknown"
    }
    Write-Log "Firmware Version: $firmwareVersion" "INFO"
} catch {
    Write-Log "FirmwareVersion registry key not found or inaccessible" "BLOCKED"
    $firmwareVersion = $null
    #Write-Log "Firmware Version: Not Available" "WARN"
}

# 13. FirmwareReleaseDate

try {
    $regValue = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing\DeviceAttributes" -Name FirmwareReleaseDate -ErrorAction Stop
    $firmwareReleaseDate = $regValue.FirmwareReleaseDate
    if ([string]::IsNullOrEmpty($firmwareReleaseDate)) {
        Write-Log "FirmwareReleaseDate is empty" "ERROR"
        $firmwareReleaseDate = "Unknown"
    }
    Write-Log "Firmware Release Date: $firmwareReleaseDate" "INFO"
} catch {
    Write-Log "FirmwareReleaseDate registry key not found or inaccessible" "WARN"
    $firmwareReleaseDate = $null
    #Write-Log "Firmware Release Date: Not Available" "WARN"
}

# 14. OSArchitecture
# PS Version: All | Admin: No | System Requirements: None
try {
    $osArchitecture = $env:PROCESSOR_ARCHITECTURE
    if ([string]::IsNullOrEmpty($osArchitecture)) {
        # Try registry fallback
        $regValue = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing\DeviceAttributes" -Name OSArchitecture -ErrorAction Stop
        $osArchitecture = $regValue.OSArchitecture
    }
    if ([string]::IsNullOrEmpty($osArchitecture)) {
        Write-Log "OSArchitecture could not be determined" "ERROR"
        $osArchitecture = "Unknown"
    }
    Write-Log "OS Architecture: $osArchitecture" "INFO"
} catch {
    Write-Log "Error retrieving OSArchitecture: $_" "ERROR"
    $osArchitecture = "Unknown"
    #Write-Log "OS Architecture: $osArchitecture" "WARN"
}

# 15. CanAttemptUpdateAfter (FILETIME)

try {
    $regValue = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing\DeviceAttributes" -Name CanAttemptUpdateAfter -ErrorAction Stop
    $canAttemptUpdateAfter = $regValue.CanAttemptUpdateAfter
    # Convert FILETIME to UTC DateTime — registry stores as REG_BINARY (byte[]) or REG_QWORD (long)
    if ($null -ne $canAttemptUpdateAfter) {
        try {
            if ($canAttemptUpdateAfter -is [byte[]]) {
                $fileTime = [BitConverter]::ToInt64($canAttemptUpdateAfter, 0)
                $canAttemptUpdateAfter = [DateTime]::FromFileTime($fileTime).ToUniversalTime()
            } elseif ($canAttemptUpdateAfter -is [long]) {
                $canAttemptUpdateAfter = [DateTime]::FromFileTime($canAttemptUpdateAfter).ToUniversalTime()
            }
        } catch {
            Write-Log "Could not convert CanAttemptUpdateAfter FILETIME to DateTime" "WARN"
        }
    }
    Write-Log "Can Attempt Update After: $canAttemptUpdateAfter" "INFO"
} catch {
    Write-Log "CanAttemptUpdateAfter registry key not found or inaccessible" "BLOCKED"
    $canAttemptUpdateAfter = $null
    #Write-Log "Can Attempt Update After: Not Available"
}

# Event Logs: System Log (10 values: 16-25)

# 16-25. Event Log queries
# Event IDs:
#   1801 - Update initiated, reboot required
#   1808 - Update completed successfully
#   1795 - Firmware returned error (capture error code)
#   1796 - Error logged with error code (capture code)
#   1800 - Reboot needed (NOT an error - update will proceed after reboot)
#   1802 - Known firmware issue blocked update (capture KI_<number> from SkipReason)
#   1803 - Matching KEK update not found (OEM needs to supply PK signed KEK)
# PS Version: 3.0+ | Admin: May be required for System log | System Requirements: None
try {
    # Query all relevant Secure Boot event IDs
    $allEventIds = @(1795, 1796, 1800, 1801, 1802, 1803, 1808)
    $events = @(Get-WinEvent -FilterHashtable @{LogName='System'; ID=$allEventIds} -MaxEvents 50 -ErrorAction Stop)

    if ($events.Count -eq 0) {
        Write-Log "No Secure Boot events found in System log" "WARN"
        $latestEventId = $null
        $bucketId = $null
        $confidence = $null
        $skipReasonKnownIssue = $null
        $event1801Count = 0
        $event1808Count = 0
        $event1795Count = 0
        $event1795ErrorCode = $null
        $event1796Count = 0
        $event1796ErrorCode = $null
        $event1800Count = 0
        $rebootPending = $false
        $event1802Count = 0
        $knownIssueId = $null
        $event1803Count = 0
        $missingKEK = $false
        Write-Log "Latest Event ID: Not Available" "WARN"
        Write-Log "Bucket ID: Not Available" "WARN"
        Write-Log "Confidence: Not Available" "WARN"
        Write-Log "Event 1801 Count: 0" "WARN"
        Write-Log "Event 1808 Count: 0" "WARN"
    } else {
        # 16. LatestEventId
        $latestEvent = $events | Sort-Object TimeCreated -Descending | Select-Object -First 1
        if ($null -eq $latestEvent) {
            Write-Log "Could not determine latest event" "ERROR"
            $latestEventId = $null
            #Write-Log "Latest Event ID: Not Available" "WARN"
        } else {
            $latestEventId = $latestEvent.Id
            Write-Log "Latest Event ID: $latestEventId" "INFO"
        }

        # 17. BucketID - Extracted from Event 1801/1808
        if ($null -ne $latestEvent -and $null -ne $latestEvent.Message) {
            if ($latestEvent.Message -match 'BucketId:\s*(.+)') {
                $bucketId = $matches[1].Trim()
                Write-Log "Bucket ID: $bucketId" "INFO"
            } else {
                Write-Log "BucketId not found in event message" "WARN"
                $bucketId = $null
                #Write-Log "Bucket ID: Not Found in Event"
            }
        } else {
            Write-Log "Latest event or message is null, cannot extract BucketId" "ERROR"
            $bucketId = $null
            #Write-Log "Bucket ID: Not Available"
        }

        # 18. Confidence - Extracted from Event 1801/1808
        if ($null -ne $latestEvent -and $null -ne $latestEvent.Message) {
            if ($latestEvent.Message -match 'BucketConfidenceLevel:\s*(.+)') {
                $confidence = $matches[1].Trim()
                Write-Log "Confidence: $confidence" "INFO"
            } else {
                Write-Log "Confidence level not found in event message" "WARN"
                $confidence = $null
                #Write-Log "Confidence: Not Found in Event"
            }
        } else {
            Write-Log "Latest event or message is null, cannot extract Confidence" "WARN"
            $confidence = $null
            #Write-Log "Confidence: Not Available"
        }

        # 18b. SkipReason - Extract KI_<number> from SkipReason in the same event as BucketId
        # This captures Known Issue IDs that appear alongside BucketId/Confidence (not just Event 1802)
        $skipReasonKnownIssue = $null
        if ($null -ne $latestEvent -and $null -ne $latestEvent.Message) {
            if ($latestEvent.Message -match 'SkipReason:\s*(KI_\d+)') {
                $skipReasonKnownIssue = $matches[1]
                Write-Log "SkipReason Known Issue: $skipReasonKnownIssue" "INFO"
            }
        }

        # 19. Event1801Count
        $event1801Array = @($events | Where-Object {$_.Id -eq 1801})
        $event1801Count = $event1801Array.Count
        Write-Log "Event 1801 Count: $event1801Count" "INFO"

        # 20. Event1808Count
        $event1808Array = @($events | Where-Object {$_.Id -eq 1808})
        $event1808Count = $event1808Array.Count
        Write-Log "Event 1808 Count: $event1808Count" "INFO"
        
        # Initialize error event variables
        $event1795Count = 0
        $event1795ErrorCode = $null
        $event1796Count = 0
        $event1796ErrorCode = $null
        $event1800Count = 0
        $rebootPending = $false
        $event1802Count = 0
        $knownIssueId = $null
        $event1803Count = 0
        $missingKEK = $false
        
        # Only check for error events if update is NOT complete
        # Skip error analysis if: 1808 is latest event OR UEFICA2023Status is "Updated"
        $updateComplete = ($latestEventId -eq 1808) -or ($uefica2023Status -eq "Updated")
        
        if (-not $updateComplete) {
            Write-Log "Update not complete - checking for error events..." "INFO"
            
            # 21. Event1795 - Firmware Error (capture error code)
            $event1795Array = @($events | Where-Object {$_.Id -eq 1795})
            $event1795Count = $event1795Array.Count
            if ($event1795Count -gt 0) {
                $latestEvent1795 = $event1795Array | Sort-Object TimeCreated -Descending | Select-Object -First 1
                if ($latestEvent1795.Message -match '(?:error|code|status)[:\s]*(?:0x)?([0-9A-Fa-f]{8}|[0-9A-Fa-f]+)') {
                    $event1795ErrorCode = $matches[1]
                }
                Write-Log "Event 1795 (Firmware Error) Count: $event1795Count" $(if ($event1795ErrorCode) { "Code: $event1795ErrorCode" }) "BLOCKED"
            }
            
            # 22. Event1796 - Error Code Logged (capture error code)
            $event1796Array = @($events | Where-Object {$_.Id -eq 1796})
            $event1796Count = $event1796Array.Count
            if ($event1796Count -gt 0) {
                $latestEvent1796 = $event1796Array | Sort-Object TimeCreated -Descending | Select-Object -First 1
                if ($latestEvent1796.Message -match '(?:error|code|status)[:\s]*(?:0x)?([0-9A-Fa-f]{8}|[0-9A-Fa-f]+)') {
                    $event1796ErrorCode = $matches[1]
                }
                Write-Log "Event 1796 (Error Logged) Count: $event1796Count" $(if ($event1796ErrorCode) { "Code: $event1796ErrorCode" }) "BLOCKED"
            }
            
            # 23. Event1800 - Reboot Needed (NOT an error - update will proceed after reboot)
            $event1800Array = @($events | Where-Object {$_.Id -eq 1800})
            $event1800Count = $event1800Array.Count
            $rebootPending = $event1800Count -gt 0
            if ($rebootPending) {
                Write-Log "Event 1800 (Reboot Pending): Update will proceed after reboot" "INFO"
            }
            
            # 24. Event1802 - Known Firmware Issue (capture KI_<number> from SkipReason)
            $event1802Array = @($events | Where-Object {$_.Id -eq 1802})
            $event1802Count = $event1802Array.Count
            if ($event1802Count -gt 0) {
                $latestEvent1802 = $event1802Array | Sort-Object TimeCreated -Descending | Select-Object -First 1
                if ($latestEvent1802.Message -match 'SkipReason:\s*(KI_\d+)') {
                    $knownIssueId = $matches[1]
                }
                Write-Log "Event 1802 (Known Firmware Issue) Count: $event1802Count" $(if ($knownIssueId) { "KI: $knownIssueId" }) "WARN"
            }
            
            # 25. Event1803 - Missing KEK Update (OEM needs to supply PK signed KEK)
            $event1803Array = @($events | Where-Object {$_.Id -eq 1803})
            $event1803Count = $event1803Array.Count
            $missingKEK = $event1803Count -gt 0
            if ($missingKEK) {
                Write-Log "Event 1803 (Missing KEK): OEM needs to supply PK signed KEK" "BLOCKED"
            }
        } else {
            Write-Log "Update complete (Event 1808 or Status=Updated) - skipping error analysis" "OK"
        }
    }
} catch {
    Write-Log "Error retrieving event logs. May require administrator privileges: $_" "BLOCKED"
    $latestEventId = $null
    $bucketId = $null
    $confidence = $null
    $skipReasonKnownIssue = $null
    $event1801Count = 0
    $event1808Count = 0
    $event1795Count = 0
    $event1795ErrorCode = $null
    $event1796Count = 0
    $event1796ErrorCode = $null
    $event1800Count = 0
    $rebootPending = $false
    $event1802Count = 0
    $knownIssueId = $null
    $event1803Count = 0
    $missingKEK = $false
    Write-Log "Latest Event ID: Error" "WARN"
    Write-Log "Bucket ID: Error" "WARN"
    Write-Log "Confidence: Error" "WARN"
    Write-Log "Event 1801 Count: 0" "WARN"
    Write-Log "Event 1808 Count: 0" "WARN"
}

# WMI/CIM Queries (5 values)

# 26. OSVersion
# PS Version: 3.0+ (use Get-WmiObject for 2.0) | Admin: No | System Requirements: None
try {
    $osInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    if ($null -eq $osInfo -or [string]::IsNullOrEmpty($osInfo.Version)) {
        Write-Log "Could not retrieve OS version" "ERROR"
        $osVersion = "Unknown"
    } else {
        $osVersion = $osInfo.Version
    }
    Write-Log "OS Version: $osVersion" "INFO"
} catch {
    # CIM may fail in some environments - use fallback
    $osVersion = [System.Environment]::OSVersion.Version.ToString()
    if ([string]::IsNullOrEmpty($osVersion)) { $osVersion = "Unknown" }
    Write-Log "OS Version: $osVersion" "INFO"
}

# 27. LastBootTime
# PS Version: 3.0+ (use Get-WmiObject for 2.0) | Admin: No | System Requirements: None
try {
    $osInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    if ($null -eq $osInfo -or $null -eq $osInfo.LastBootUpTime) {
        Write-Log "Could not retrieve last boot time" "WARN"
        $lastBootTime = $null
        #Write-Log "Last Boot Time: Not Available"
    } else {
        $lastBootTime = $osInfo.LastBootUpTime
        Write-Log "Last Boot Time: $lastBootTime" "INFO"
    }
} catch {
    # CIM may fail in some environments - use fallback
    try {
        $lastBootTime = (Get-Process -Id 0 -ErrorAction SilentlyContinue).StartTime
    } catch {
        $lastBootTime = $null
    }
    if ($lastBootTime) { Write-Log "Last Boot Time: $lastBootTime" "INFO" } else { Write-Log "Last Boot Time: Not Available" "WARN"}
}

# 28. BaseBoardManufacturer
# PS Version: 3.0+ (use Get-WmiObject for 2.0) | Admin: No | System Requirements: None
try {
    $baseBoard = Get-CimInstance Win32_BaseBoard -ErrorAction Stop
    if ($null -eq $baseBoard -or [string]::IsNullOrEmpty($baseBoard.Manufacturer)) {
        Write-Log "Could not retrieve baseboard manufacturer" "ERROR"
        $baseBoardManufacturer = "Unknown"
    } else {
        $baseBoardManufacturer = $baseBoard.Manufacturer
    }
    Write-Log "Baseboard Manufacturer: $baseBoardManufacturer" "INFO"
} catch {
    # CIM may fail - baseboard info is supplementary
    $baseBoardManufacturer = "Unknown"
    Write-Log "Baseboard Manufacturer: $baseBoardManufacturer" "INFO"
}

# 29. BaseBoardProduct
# PS Version: 3.0+ (use Get-WmiObject for 2.0) | Admin: No | System Requirements: None
try {
    $baseBoard = Get-CimInstance Win32_BaseBoard -ErrorAction Stop
    if ($null -eq $baseBoard -or [string]::IsNullOrEmpty($baseBoard.Product)) {
        Write-Log "Could not retrieve baseboard product" "ERROR"
        $baseBoardProduct = "Unknown"
    } else {
        $baseBoardProduct = $baseBoard.Product
    }
    Write-Log "Baseboard Product: $baseBoardProduct" "INFO"
} catch {
    # CIM may fail - baseboard info is supplementary
    $baseBoardProduct = "Unknown"
    Write-Log "Baseboard Product: $baseBoardProduct" "INFO"
}

# 30. SecureBootTaskEnabled
# PS Version: All | Admin: No | System Requirements: Scheduled Task exists
# Checks if the Secure-Boot-Update scheduled task is enabled
$secureBootTaskEnabled = $null
$secureBootTaskStatus = "Unknown"
try {
    $taskOutput = schtasks.exe /Query /TN "\Microsoft\Windows\PI\Secure-Boot-Update" /FO CSV 2>&1
    if ($LASTEXITCODE -eq 0) {
        $taskData = $taskOutput | ConvertFrom-Csv
        if ($taskData) {
            $secureBootTaskStatus = $taskData.Status
            $secureBootTaskEnabled = ($taskData.Status -eq 'Ready' -or $taskData.Status -eq 'Running')
        }
    } else {
        $secureBootTaskStatus = "NotFound"
        $secureBootTaskEnabled = $false
    }
    if ($secureBootTaskEnabled -eq $false) {
        Write-Log "SecureBoot Update Task: $secureBootTaskStatus (Enabled: $secureBootTaskEnabled)" "INFO"
    } else {
        Write-Log "SecureBoot Update Task: $secureBootTaskStatus (Enabled: $secureBootTaskEnabled)" "INFO"
    }
} catch {
    $secureBootTaskStatus = "Error"
    $secureBootTaskEnabled = $false
    Write-Log "SecureBoot Update Task: Error checking - $_"  "ERROR"
}

# 31. WinCS Key Status (F33E0C8E002 - Secure Boot Certificate Update)
# PS Version: All | Admin: Yes (for query) | System Requirements: WinCsFlags.exe
$wincsKeyApplied = $null
$wincsKeyStatus = "Unknown"
try {
    # Check common locations for WinCsFlags.exe
    $wincsFlagsPath = $null
    $possiblePaths = @(
        "$env:SystemRoot\System32\WinCsFlags.exe",
        "$env:SystemRoot\SysWOW64\WinCsFlags.exe"
    )
    foreach ($p in $possiblePaths) {
        if (Test-Path $p) { $wincsFlagsPath = $p; break }
    }
    
    if ($wincsFlagsPath) {
        # Query specific key - requires admin rights
        $queryOutput = & $wincsFlagsPath /query --key F33E0C8E002 2>&1
        $queryOutputStr = $queryOutput -join "`n"
        
        if ($LASTEXITCODE -eq 0) {
            # Check if key is applied (look for "Active Configuration" or similar indicator)
            if ($queryOutputStr -match "Active Configuration.*:.*enabled" -or $queryOutputStr -match "Configuration.*applied") {
                $wincsKeyApplied = $true
                $wincsKeyStatus = "Applied"
                Write-Log "WinCS Key F33E0C8E002: Applied"  "OK"
            } elseif ($queryOutputStr -match "not found|No configuration") {
                $wincsKeyApplied = $false
                $wincsKeyStatus = "NotApplied"
                Write-Log "WinCS Key F33E0C8E002: Not Applied" "INFO"
            } else {
                # Key exists - check output for state
                $wincsKeyApplied = $true
                $wincsKeyStatus = "Applied"
                Write-Log "WinCS Key F33E0C8E002: Applied" "INFO"
            }
        } else {
            # Check for specific error messages
            if ($queryOutputStr -match "Access denied|administrator") {
                $wincsKeyStatus = "AccessDenied"
                Write-Log "WinCS Key F33E0C8E002: Access denied (run as admin)" "BLOCKED"
            } elseif ($queryOutputStr -match "not found|No configuration") {
                $wincsKeyApplied = $false
                $wincsKeyStatus = "NotApplied"
                Write-Log "WinCS Key F33E0C8E002: Not Applied" "WARN"
            } else {
                $wincsKeyStatus = "QueryFailed"
                Write-Log "WinCS Key F33E0C8E002: Query failed" "WARN"
            }
        }
    } else {
        $wincsKeyStatus = "WinCsFlagsNotFound"
        Write-Log "WinCS Key F33E0C8E002: WinCsFlags.exe not found" "INFO"
    }
} catch {
    $wincsKeyStatus = "Error"
    Write-Log "WinCS Key F33E0C8E002: Error checking - $_" "ERROR"
}

# =============================================================================
# Certificate Presence Detection (UEFI db and KEK)
# =============================================================================

# Initialize cert detection variables
$FirstPartyDB2023Updated = 0
$FirstPartyKEK2023Updated = 0
$ThirdParty2011CAPresent = 0
$ThirdParty2023CertsRequired = 0
$ThirdParty2023CertUpdated = 0
$ThirdPartyOptionRom2023CertUpdated = 0

try {
    # Read the UEFI db (Signature Database) once
    $dbBytes = (Get-SecureBootUEFI db -ErrorAction Stop).bytes
    $dbString = [System.Text.Encoding]::ASCII.GetString($dbBytes)

    # 1P DB: Windows UEFI CA 2023 (required on ALL systems)
    if ($dbString -match 'Windows UEFI CA 2023') {
        $FirstPartyDB2023Updated = 1
    }

    # Check if 3P 2011 CA is trusted (determines whether 3P 2023 certs are required)
    if ($dbString -match 'Microsoft Corporation UEFI CA 2011') {
        $ThirdParty2011CAPresent = 1
        $ThirdParty2023CertsRequired = 1
    }

    # 3P DB: Microsoft UEFI CA 2023 (required only if 3P 2011 CA present)
    if ($dbString -match 'Microsoft UEFI CA 2023') {
        if ($ThirdParty2023CertsRequired -eq 1) {
            $ThirdParty2023CertUpdated = 1
        }
    }

    # 3P DB: Microsoft Option ROM UEFI CA 2023 (required only if 3P 2011 CA present)
    if ($dbString -match 'Microsoft Option ROM UEFI CA 2023') {
        if ($ThirdParty2023CertsRequired -eq 1) {
            $ThirdPartyOptionRom2023CertUpdated = 1
        }
    }
} catch {
    Write-Log "Unable to read UEFI Secure Boot db variable: $_" "ERROR"
    Write-Log "UEFI db certificate detection: Not Available (requires admin and UEFI system)" "ERROR"
}

try {
    # Read the UEFI KEK once
    $kekBytes = (Get-SecureBootUEFI kek -ErrorAction Stop).bytes
    $kekString = [System.Text.Encoding]::ASCII.GetString($kekBytes)

    # 1P KEK: Microsoft Corporation KEK 2K CA 2023 (required on ALL systems)
    if ($kekString -match 'Microsoft Corporation KEK 2K CA 2023') {
        $FirstPartyKEK2023Updated = 1
    }
} catch {
    Write-Log "Unable to read UEFI Secure Boot KEK variable: $_" "ERROR"
    Write-Log "UEFI KEK certificate detection: Not Available (requires admin and UEFI system)" "ERROR"
}

# 3P cert updated flags are only meaningful when 1P certs are both updated
# If 1P certs are not updated, reset 3P updated flags to 0 since the base requirement is not met
if ($FirstPartyDB2023Updated -eq 0 -or $FirstPartyKEK2023Updated -eq 0) {
    $ThirdParty2023CertUpdated = 0
    $ThirdPartyOptionRom2023CertUpdated = 0
}

# =============================================================================
# Wave Manifest / Execution State (from local WaveState.json)
# =============================================================================

$waveStatePath = Join-Path $LocalfilePath "WaveState.json"
$InWave = $false
$WaveManifestSeen = $null

if (Test-Path $waveStatePath) {
    try {
        $waveState = Get-Content $waveStatePath -Raw | ConvertFrom-Json
        if ($null -ne $waveState.IsInWave) {
            $InWave = [bool]$waveState.IsInWave
        }
        if ($waveState.LastSeenManifest) {
            $WaveManifestSeen = $waveState.LastSeenManifest
        }
    }
    catch {
        Write-Log "Failed to parse WaveState.json: $_" "ERROR"
    }
}

# =============================================================================
# Remediation Detection - Status Output & Exit Code
# =============================================================================

# Build status object from all collected inventory data
$status = [ordered]@{
    UEFICA2023Status           = $uefica2023Status
    UEFICA2023Error            = $uefica2023Error
    UEFICA2023ErrorEvent       = $uefica2023ErrorEvent
    AvailableUpdates           = if ($null -ne $availableUpdates) { $availableUpdatesHex } else { $null }
    AvailableUpdatesPolicy     = if ($null -ne $availableUpdatesPolicy) { $availableUpdatesPolicyHex } else { $null }
    Hostname                   = $hostname
    CollectionTime             = if ($collectionTime -is [datetime]) { $collectionTime.ToString("o") } else { "$collectionTime" }
    SecureBootEnabled          = $secureBootEnabled
    HighConfidenceOptOut       = $highConfidenceOptOut
    MicrosoftUpdateManagedOptIn        = $microsoftUpdateManagedOptIn
    OEMManufacturerName        = $oemManufacturerName
    OEMModelSystemFamily       = $oemModelSystemFamily
    OEMModelNumber             = $oemModelNumber
    FirmwareVersion            = $firmwareVersion
    FirmwareReleaseDate        = $firmwareReleaseDate
    OSArchitecture             = $osArchitecture
    CanAttemptUpdateAfter      = if ($canAttemptUpdateAfter -is [datetime]) { $canAttemptUpdateAfter.ToString("o") } else { "$canAttemptUpdateAfter" }
    LatestEventId              = $latestEventId
    BucketId                   = $bucketId
    Confidence                 = $confidence
    SkipReasonKnownIssue       = $skipReasonKnownIssue  # KI_<number> from SkipReason in BucketId event
    Event1801Count             = $event1801Count
    Event1808Count             = $event1808Count
    # Error events with captured details
    Event1795Count             = $event1795Count          # Firmware returned error
    Event1795ErrorCode         = $event1795ErrorCode      # Error code from firmware
    Event1796Count             = $event1796Count          # Error code logged
    Event1796ErrorCode         = $event1796ErrorCode      # Captured error code
    Event1800Count             = $event1800Count          # Reboot needed (NOT an error)
    RebootPending              = $rebootPending           # True if Event 1800 present
    Event1802Count             = $event1802Count          # Known firmware issue
    KnownIssueId               = $knownIssueId            # KI_<number> from SkipReason
    Event1803Count             = $event1803Count          # Missing KEK update
    MissingKEK                 = $missingKEK              # OEM needs to supply PK signed KEK
    OSVersion                  = $osVersion
    LastBootTime               = if ($lastBootTime -is [datetime]) { $lastBootTime.ToString("o") } else { "$lastBootTime" }
    BaseBoardManufacturer      = $baseBoardManufacturer
    BaseBoardProduct           = $baseBoardProduct
    SecureBootTaskEnabled      = $secureBootTaskEnabled
    SecureBootTaskStatus       = $secureBootTaskStatus
    WinCSKeyApplied            = $wincsKeyApplied         # True if F33E0C8E002 key is applied
    WinCSKeyStatus             = $wincsKeyStatus          # Applied, NotApplied, WinCsFlagsNotFound, etc.
    # Certificate presence detection (UEFI db/KEK)
    FirstPartyDB2023Updated          = $FirstPartyDB2023Updated         # 1 if Windows UEFI CA 2023 present in db
    FirstPartyKEK2023Updated         = $FirstPartyKEK2023Updated        # 1 if Microsoft Corporation KEK 2K CA 2023 present
    ThirdParty2011CAPresent           = $ThirdParty2011CAPresent         # 1 if Microsoft Corporation UEFI CA 2011 present in db
    ThirdParty2023CertsRequired       = $ThirdParty2023CertsRequired     # 1 if 3P 2011 CA present (system trusts 3P)
    ThirdParty2023CertUpdated         = $ThirdParty2023CertUpdated       # 1 if Microsoft UEFI CA 2023 present (when 1P certs updated)
    ThirdPartyOptionRom2023CertUpdated = $ThirdPartyOptionRom2023CertUpdated  # 1 if Microsoft Option ROM UEFI CA 2023 present (when 1P certs updated)
    #Wave mechanism status
    InWave                     = $InWave            # TRUE | FALSE, depending on if device *thinks* it's part of current wave or not
    WaveManifestSeen          = $WaveManifestSeen  # Timestamp of the last manifest file the local endpoint/device read
}

$jsonOutput = $status | ConvertTo-Json -Depth 10 -Compress
#TEST/DEBUGG
if ([string]::IsNullOrWhiteSpace($jsonOutput)) {
    Write-Log "Primary JSON conversion failed, retrying with normalized object" "WARN"

    $flat = @{}
    foreach ($k in $status.Keys) { $flat[$k] = "$($status[$k])" }

    $jsonOutput = $flat | ConvertTo-Json -Compress
} else {
    Write-Log "JSON length: $($jsonOutput.Length)" "INFO"
}


# If OutputPath provided, save to file; otherwise output to stdout
if (-not [string]::IsNullOrEmpty($OutputPath)) {
    #Write-Output $jsonOutput
    # Ensure the output folder exists
    if (-not (Test-Path $OutputPath)) {
        try {
            New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
            Write-Log "Tried creating folder because it couldn't be found" "INFO"
        } catch {
            Write-Log "Could not create output folder: $OutputPath - $_" "ERROR"
        }
    }
    # Save to HOSTNAME_latest.json
    $outputFile = Join-Path $OutputPath "$($hostname)_latest.json"
    try {
        $jsonOutput | Out-File -FilePath $outputFile -Encoding UTF8 -Force
        Write-Log "JSON saved to: $outputFile" "OK"
    } catch {
        Write-Log "Could not write to file: $outputFile - $_" "ERROR"
        # Fall back save location
        $jsonOutput | Out-File -FilePath $LogfilePath -Encoding UTF8 -Force
    }
} else {
    Write-Log "Unexpected error writing to $OutputPath and unable to write to fallback path $LogfilePath" "ERROR"
}

# Visual summary with full certificate names
Write-Log "" "INFO"
Write-Log "================ Certificate Update Summary ================" "INFO"
Write-Log "  [1P] Windows UEFI CA 2023 (db):                    $(if ($FirstPartyDB2023Updated) { 'Updated' } else { 'Not Updated' })" "INFO"
Write-Log "  [1P] Microsoft Corporation KEK 2K CA 2023 (KEK):   $(if ($FirstPartyKEK2023Updated) { 'Updated' } else { 'Not Updated' })" "INFO"
Write-Log "  [3P] Microsoft Corporation UEFI CA 2011 (db):      $(if ($ThirdParty2011CAPresent) { 'Present - 3P 2023 certs required' } else { 'Not Present - 3P 2023 certs not required' })" "INFO"
if ($ThirdParty2023CertsRequired) {
    Write-Log "  [3P] Microsoft UEFI CA 2023 (db):                  $(if ($ThirdParty2023CertUpdated) { 'Updated' } else { 'Not Updated' })" "INFO"
    Write-Log "  [3P] Microsoft Option ROM UEFI CA 2023 (db):       $(if ($ThirdPartyOptionRom2023CertUpdated) { 'Updated' } else { 'Not Updated' })" "INFO"
}
Write-Log "============================================================" "INFO"
#Write-Log "" "INFO"