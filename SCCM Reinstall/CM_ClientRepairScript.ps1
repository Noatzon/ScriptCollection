# Define the path to ccmsetup.exe
$ccmSetupPath = "C:\temp\ccmsetup.exe"

# Define installation parameters
$installationParameters = "/MP:<SSCM SERVER> SMSCACHESIZE=26000 SMSSITECODE= FSP= /forceinstall"

# Define log file path with date and timestamp
$logFilePath = "C:\temp\SCCM_Client_repair_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Function to write log
function Write-Log {
    param (
        [string]$Message,
        [string]$Color = "Green"
    )
    $FormattedMessage = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message"
    Write-Host $FormattedMessage -ForegroundColor $Color
    $FormattedMessage | Out-File -Append -FilePath $logFilePath
}

# Check if ccmsetup.exe exists
if (Test-Path -Path "C:\Windows\ccmsetup\ccmsetup.exe") {
    Write-Log "SCCM client detected. Starting SCCM client uninstallation..."
    
    # Uninstall SCCM client using ccmsetup.exe
    $uninstallProcess = Start-Process -FilePath $ccmSetupPath -ArgumentList "/uninstall" -Wait -PassThru
    Write-Log "SCCM client uninstallation completed successfully."
} else {
    Write-Log "SCCM client not detected. Skipping uninstallation."
}

# Stop the winmgmt service
Write-Log "Stopping Winmgmt service..."
$stopWinmgmtProcess = Stop-Service -Name "winmgmt" -Force
Write-Log "Winmgmt service stopped successfully."

# Define the path to the Repository folder
$repositoryPath = "C:\Windows\System32\wbem\Repository"

# Get the current timestamp
$timestamp = Get-Date -Format "yyyyMMddHHmmss"

# Rename Repository folder to Repository_<timestamp>
$newRepositoryName = "Repository_$timestamp"
Write-Log "Renaming Repository folder to $newRepositoryName..."
$renameRepositoryProcess = Rename-Item -Path $repositoryPath -NewName $newRepositoryName -Force
Write-Log "Repository folder renamed to $newRepositoryName."

# Start the winmgmt service
Write-Log "Starting Winmgmt service..."
$startWinmgmtProcess = Start-Service -Name "winmgmt" -PassThru
Write-Log "Winmgmt service started successfully."

# Run winmgmt /salvagerepository
Write-Log "Running Winmgmt /salvagerepository command..."
$salvageRepositoryProcess = Start-Process -FilePath "winmgmt" -ArgumentList "/salvagerepository" -Wait -PassThru
Write-Log "Winmgmt /salvagerepository command completed successfully."

# Install SCCM client using ccmsetup.exe
Write-Log "Starting SCCM client installation... Monitor the success of the installation at C:\Windows\ccmsetup\Logs\ccmsetup.log" -Color "Yellow"
$installProcess = Start-Process -FilePath $ccmSetupPath -ArgumentList $installationParameters -Wait -PassThru
Write-Log "Monitor the success of the installation at C:\Windows\ccmsetup\Logs\ccmsetup.log" -Color "Yellow"

Write-Log "Script execution completed."
