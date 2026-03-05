@ECHO OFF
rem ---------------------------------------------------------------------------------------
rem =======================================================================================
rem ===                               					                                ===
rem ===    Automatic Data, Network Drives and Printers Backup & Restoration Script      ===
rem ===                                                                                 ===
rem ===                        https://github.com/Noatzon                     		    ===
rem =======================================================================================
rem ---------------------------------------------------------------------------------------


rem SYNOPSIS
REM This script was originally developed to deal with OneDrive being unreliable when it came to actually backing up a users files and uploading them to the cloud.
rem We needed a way to have better control of the backup process when migrating the entire organization's users to a new computer platform (Azure instead of onprem based AD).
rem Intended usage was: Run this script on a end users PC. > Right-click on OneDrive in File Explorer and select "Fre up space" option after completion > Verify the backup folder existed online for them > Have user run the script again once they recieved their new computer.






















rem Changelog
rem V1.0
rem     * Initial Version. Language dependent and unsuitable for widespread implementation

rem V1.1
rem     * Rewrite for maintainablility
rem     * Added configuration
rem     * Added commentation and documentation

rem V1.1.3
rem     * Fixed backup process on OnPrem machines
rem     * Cleanup of code

rem V1.2
rem     * Added Changelog
rem     * Added partial support for cloud printers
rem     * Updated Documentation
rem     * Cleanup of code
rem     * Removed Language Dependent configurations
rem     * Changed restore phase from configuration based directories to registry key based paths

rem V1.2.1
rem     * Fixed Networked Drives Restoration
rem     * Fixed Printer Restoration

rem V1.2.2
rem     * Fixed Networked Drives File Interpretation
rem     * Fixed Printer File Interpretation
rem     * Fixed Printer File Trailing Space Sensitivity

rem V1.2.3
rem     * Added backwards compatibility with v1.0 Network Drive File Format
rem     * Fixed recognition of unaccessable network drives

rem V1.2.4
rem     * Changed Network Drive Detection to Reg query
rem     * Added Support for Spaces in RemotePath for Network Drives
rem     * Added support for UTF-8

rem V1.2.5*
rem		* Several itterations and discarded versions with higher number. We stick with this as the "real" next versioning regardless.
rem		* Complete rework of Mapped Drives restoration. It now works for the first time in a while. Unfortunately no support for spaces in filepaths? Problem was in how we tried to add them. "Net use" don't work as we first thought.
rem		* IAdded support for the new Shared Account PCs. They start with "SCOP01-" instead of "ECOP01-".
rem		* Added more log file/troubleshhoting support, it now spells out all network drives & clarifies if it created a printer file or not during both processes.

rem	V1.2.6
REM		* Changed autodetect to manual. Same script can now be used to backup & restore regardless of device type.
rem     *  V DOESN'T WORK! NO WAY TO PROGRAMATICALLY EXPORT/IMPORT TASKBAR WITHOUT RELYING ON THIRDPARTY APPLICATIONS
rem		* Added experimental backup & restoration of taskbar icons/shortcuts. 

rem v.1.2.7
REM		* Removed code that was specific to it's initial development and usage.
REM		* Made slight tweaks to make it work better as a "generic" backup tool.








































rem -------------------------------------
rem ---           Settings            ---
rem --- For Technicians or Developers ---
rem -------------------------------------


rem Script Version
set "ScriptVersion=1.2.6"

rem Please adjust any settings in this section, do not attempt to alter the script itself past the do not edit line.
rem In case such changes need to be made, they should only be performed by a developer or technician with a proper understanding of the script and its functionality
rem to prevent issues and problems resulting in potential data loss for the end user.

rem OneDrive directory
rem If the user has followed the instructions, this is where desktop, pictures and documents are stored. 
rem If they have not, it will be under %userprofile%. The script will account for this possibility.
rem This may need to be translated, depending on configuration.
set "OneDrivePath=%userprofile%\"

rem Backup directory
rem This is the folder on the users OneDrive that will be used to house all the backup data. 
set "BackupPath=%OneDrivePath%\DO_NOT_USE_BACKUP"

rem Zip File Path
rem This is the name of the zip file that will be copied to the users OneDrive directory for the user to extract and run post-migration to restore data, printers and networked drives.
rem Essentially, it will copy this script into the users OneDrive in a zip file. 
rem When executed on the NGPC platform, this script will automatically identify that it is on a migrated PC and execute the restoration functionality.
set ZipFilePath='%OneDrivePath%\RUN_ME.zip'

rem Log file
rem All actions will be logged in this file with a standard or above standard level of verbosity.
rem This file path will be appended with "_YYYY_MM_DD_HH_MM_SS.log"
rem By default, this file is not synced to the users OneDrive. If this is desired, adjust the path accordingly
set "LogFilePath=%userprofile%/OneDrive_AutoBackup_"

rem CHCP
rem This controls the character set the script can handle. For UTF-8, keep at 65001
chcp 65001
setlocal enabledelayedexpansion
























rem ----------------------------------------------------------------------------------------
rem ========================================================================================
rem === Danger  Zone     Danger  Zone     Danger  Zone     Danger  Zone     Danger  Zone ===
rem === DO NOT TOUCH --- DO NOT TOUCH --- DO NOT TOUCH --- DO NOT TOUCH --- DO NOT TOUCH ===
rem ========================================================================================
rem ----------------------------------------------------------------------------------------
























rem Create Log file
for /f "tokens=2 delims==" %%a in ('wmic OS Get localdatetime /value') do set "dt=%%a"
set "YY=%dt:~2,2%" & set "YYYY=%dt:~0,4%" & set "MM=%dt:~4,2%" & set "DD=%dt:~6,2%"
set "HH=%dt:~8,2%" & set "Min=%dt:~10,2%" & set "Sec=%dt:~12,2%"
set "fullstamp=%YYYY%-%MM%-%DD%_%HH%%Min%-%Sec%"
set "LogFile=%LogFilePath%%fullstamp%.log"

rem Initiate logging
echo Script Execution Started at %fullstamp% >> "%LogFile%"
echo Script Version %ScriptVersion% >> "%LogFile%"

echo Displaying choice to user >> "%LogFile%"
rem Manual change.
choice /c:br /n /m "Press the [B] key for backup or [R] to restore your files."

if %errorlevel% == 2 (
cls
echo user selected Restore >> "%LogFile%"
goto:Restore
)

if %errorlevel% == 1 (
cls
echo user selected backup >> "%LogFile%"
goto:Backup
)





rem Backup
rem This performs the automatic backup of Desktop, Pictures, Documents, Printers and Network Drives to the backup folder location specified in the settings above.
:Backup
echo Backup Process Started... >> "%LogFile%"


rem Places a copy of this script into a zip file in the users OneDrive folder
rem This allows the user to run this script by themselves after recieving the computer post migration, reducing the time requirement for IT staff.
set ZipSourcePath=%0
set ZipSourcePath=%ZipSourcePath:"='%
powershell -Command "Compress-Archive -DestinationPath %ZipFilePath% -Path %ZipSourcePath% -Force"

rem Folder Creation
rem If the backup folder doesnt already exist, create it. If creation fails, this would constitute a fatal error and we should exit.
IF NOT EXIST "%BackupPath%" (
    mkdir "%BackupPath%"
    IF NOT EXIST "%BackupPath%" ( 
        rem Unable to find or create Backup Directory. Fatal Error, exiting.
        echo Failed to create backup directory "%BackupPath%" >> "%LogFile%"
        msg %username% "Failed to create folders, Restoration Failed. Please Contact IT"
        pause
        endlocal
        exit
    ) || (
        rem Successfully created backup Directory
        echo Created Backup Directory "%BackupPath%" >> "%LogFile%"
    )
) || (
    echo Backup Directory Found "%BackupPath%" >> "%LogFile%"
)
rem Create or find Desktop folder in the backup directory
IF NOT EXIST "%BackupPath%\Desktop" (
    mkdir "%BackupPath%\Desktop"
    IF NOT EXIST "%BackupPath%\Desktop" (
        rem Unable to find or create Backup Directory. Fatal Error, exiting.
        echo Failed to create backup directory "%BackupPath%\Desktop" >> "%LogFile%"
        msg %username% "Failed to create folders, Restoration Failed. Please Contact IT"
        pause
        endlocal
        exit
    ) || (
    rem Backup Directory Created
        echo Created Backup Directory "%BackupPath%\Desktop" >> "%LogFile%"
    )
) || (
    rem Backup Directory Found
    echo Found Backup Directory "%BackupPath%\Desktop" >> "%LogFile%"
)
rem Create or find Pictures folder in the backup directory
IF NOT EXIST "%BackupPath%\Pictures" (
    mkdir "%BackupPath%\Pictures"
    IF NOT EXIST "%BackupPath%\Pictures" (
        rem Unable to find or create Backup Directory. Fatal Error, exiting.
        echo Failed to create backup directory "%BackupPath%\Pictures" >> "%LogFile%"
        msg %username% "Failed to create folders, Restoration Failed. Please Contact IT"
        pause
        endlocal
        exit
    ) || (
    rem Backup Directory Created
        echo Created Backup Directory "%BackupPath%\Pictures" >> "%LogFile%"
    )
) || (
    rem Backup Directory Found
    echo Found Backup Directory "%BackupPath%\Pictures" >> "%LogFile%"
)
rem Create or find Documents folder in the backup directory
IF NOT EXIST "%BackupPath%\Documents" (
    mkdir "%BackupPath%\Documents"
    IF NOT EXIST "%BackupPath%\Documents" (
        rem Unable to find or create Backup Directory. Fatal Error, exiting.
        echo Failed to create backup directory "%BackupPath%\Documents" >> "%LogFile%"
        msg %username% "Failed to create folders, Restoration Failed. Please Contact IT"
        pause
        endlocal
        exit
    ) || (
    rem Backup Directory Created
        echo Created Backup Directory "%BackupPath%\Documents" >> "%LogFile%"
    )
) || (
    rem Backup Directory Found
    echo Found Backup Directory "%BackupPath%\Documents" >> "%LogFile%"
)

rem Create or find Taskbar folder in the backup directory
IF NOT EXIST "%BackupPath%\Taskbar" (
    mkdir "%BackupPath%\Taskbar"
    IF NOT EXIST "%BackupPath%\Taskbar" (
        rem Unable to find or create Backup Directory. Fatal Error, exiting.
        echo Failed to create backup directory "%BackupPath%\Taskbar" >> "%LogFile%"
        msg %username% "Failed to create folders, Restoration Failed. Please Contact IT"
        pause
        endlocal
        exit
    ) || (
    rem Backup Directory Created
        echo Created Backup Directory "%BackupPath%\Taskbar" >> "%LogFile%"
    )
) || (
    rem Backup Directory Found
    echo Found Backup Directory "%BackupPath%\Taskbar" >> "%LogFile%"
)

rem Perform File Backups
rem It will account for the possibility that the user has not set their documents, pictures and desktop to sync, preventing potential data loss.

echo File Copy Process Started... >> "%LogFile%"
rem UI stuff
cls
echo ================================
echo =      Backup In Progress      =
echo =   This May Take Some Time    =
echo =                              =
echo =     Backing Up Desktop...    =
echo =                              =
echo =      Please Wait...          =
echo =                              =
echo ================================

rem Find and Backup Desktop based on RegKey
for /f "tokens=2*" %%a in ('reg query "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "Desktop"') do call set DESKTOP=%%~b

robocopy "%DESKTOP%" "%BackupPath%/Desktop" /e /v /mt:6 /r:3 /w:20 /xo /z /np /log+:"%LogFile%"

rem UI stuff
cls
echo ================================
echo =      Backup In Progress      =
echo =   This May Take Some Time    =
echo =                              =
echo = Backing Up Desktop...   Done =
echo = Backing Up Documents...      =
echo =                              =
echo =      Please Wait...          =
echo =                              =
echo ================================

rem Find and Backup Documents based on RegKey
for /f "tokens=2*" %%a in ('reg query "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "Personal"') do call set DOCUMENTS=%%~b

robocopy "%DOCUMENTS%" "%BackupPath%/Documents" /e /v /mt:6 /r:3 /w:20 /xo /z /np /log+:"%LogFile%"

rem UI stuff
cls
echo ================================
echo =      Backup In Progress      =
echo =   This May Take Some Time    =
echo =                              =
echo = Backing Up Desktop...   Done =
echo = Backing Up Documents... Done =
echo = Backing Up Pictures...       =
echo =                              =
echo =      Please Wait...          =
echo =                              =
echo ================================

rem Find and Backup Pictures based on RegKey
for /f "tokens=3*" %%a in ('reg query "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "My Pictures"') do call set PICTURES=%%~b

robocopy "%PICTURES%" "%BackupPath%/Pictures" /e /v /mt:6 /r:3 /w:20 /xo /z /np /log+:"%LogFile%"


rem Network Drives 
rem Gets all currently listed network drives and saves them for later restoration

rem UI stuff
cls
echo ================================
echo =      Backup In Progress      =
echo =   This May Take Some Time    =
echo =                              =
echo = Backing Up Desktop...   Done =
echo = Backing Up Documents... Done =
echo = Backing Up Pictures...  Done =
echo = Backing Up NetDrives...      =
echo =                              =
echo =      Please Wait...          =
echo =                              =
echo ================================

rem Get all networked drives and save them in a config txt file
rem Each drive is listed as a single line.
rem The file may appear as complete gibberish in some cases, as invalid data may be entered. 
rem The incorrect values will fail to execute during restoration.

set "NetworkDrivesListFile=%BackupPath%/My-MappedDrives.txt"
echo:> "%NetworkDrivesListFile%"
echo Backing Up Network Drives... >> "%LogFile%"
for /f "delims=" %%a in ('powershell -Command "reg query HKEY_CURRENT_USER\Network"') do (
    set key=%%a
    for /f "tokens=3*" %%c in ('reg query "!key!" /v RemotePath') do (
    set Remote=%%c %%d
    set DriveLetter=!key:HKEY_CURRENT_USER\Network\=!
    echo !DriveLetter!^: !Remote! >> "%NetworkDrivesListFile%"
	echo Found drive !DriveLetter!^: !Remote! >> "%LogFile%"
    )
)


rem Printers
rem This gets all currently listed printers and saves them for later restoration. This only works for printers added through "normal" means and not any added iva a cloud printer solution/UPM.
rem UI stuff
cls
echo ================================
echo =      Backup In Progress      =
echo =   This May Take Some Time    =
echo =                              =
echo = Backing Up Desktop...   Done =
echo = Backing Up Documents... Done =
echo = Backing Up Pictures...  Done =
echo = Backing Up NetDrives... Done =
echo = Backing Up Printers...       =
echo =                              =
echo =      Please Wait...          =
echo =                              =
echo ================================

rem Get all printers and save them in a txt file
rem each printer is listed as a single line

set "PrinterListFile=%BackupPath%/My_Printers.txt"
set "PrinterAllListFile=%BackupPath%/My_Printers_All.txt"
rem "echo." is the .bat equilviant of "\n" in CMD/PS scripting. It creates a new/blank line. Used for better readability of logfile.
echo. >> "%LogFile%"
echo Checking Printers... >> "%LogFile%"
rem We only want to generate this file if it does not already exist, to prevent any potential loss of data.
IF NOT EXIST "%PrinterListFile%" (
    echo Backing Up Printers >> "%LogFile%"
    for /f "tokens=1 delims= " %%A in ('wmic printer get name ^| findstr "\\"') do (
        set UNCPath=%%A
        echo !UNCPath! >> "%PrinterListFile%"
        echo Found Printer: !UNCPath! >> "%LogFile%"
    )
) else (
    echo Printer File Already Generated, Skipping... >> "%LogFile%"
)
rem Raw printer list. Will contain printers not normally included in the regular file, such as cloud printers.
IF NOT EXIST "%PrinterAllListFile%" (
    wmic printer get name >> "%PrinterAllListFile%"
	echo Raw Printer File Generated >> "%LogFile%"
) else (
	echo Raw Printer File Already Generated, Skipping... >> "%LogFile%"
)

rem UI stuff
cls
echo ================================
echo =      Backup In Progress      =
echo =   This May Take Some Time    =
echo =                              =
echo = Backing Up Desktop...   Done =
echo = Backing Up Documents... Done =
echo = Backing Up Pictures...  Done =
echo = Backing Up NetDrives... Done =
echo = Backing Up Printers...  Done =
echo =                              =
echo =      Please Wait...          =
echo =                              =
echo ================================

rem Backup process complete, please check log for errors
echo Backup Process Complete >> "%LogFile%"
goto:Finish







REM rem Restore
REM rem this will restore the previously backup up printer and network drive configurations along with the backed up data. 
:Restore
echo Restoration Process Started... >> "%LogFile%"

rem At this point we where guaranteed to be on a new "model" of PC, so we can assume that at the time of execution, the Desktop, Documents and Pictures folders will be controlled by OneDrive.
rem Restore Desktop
echo Restoring Desktop >> "%LogFile%"
rem UI stuff
cls
echo ================================
echo =   Restoration In Progress    =
echo =   This May Take Some Time    =
echo =                              =
echo = Restoring Desktop...         =
echo =                              =
echo =      Please Wait...          =
echo =                              =
echo ================================
rem restore the desktop folder based on RegKey
for /f "tokens=2*" %%a in ('reg query "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "Desktop"') do call set DESKTOP_R=%%~b

robocopy "%BackupPath%/Desktop" "%DESKTOP_R%" /e /v /mt:6 /r:3 /w:20 /xo /z /np /log+:"%LogFile%"


rem Restore Documents
echo Restoring Documents >> "%LogFile%"
rem UI stuff
cls
echo ================================
echo =   Restoration In Progress    =
echo =   This May Take Some Time    =
echo =                              =
echo = Restoring Desktop...    Done =
echo = Restoring Documents...       =
echo =                              =
echo =      Please Wait...          =
echo =                              =
echo ================================
rem restore the desktop folder based on RegKey
for /f "tokens=2*" %%a in ('reg query "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "Personal"') do call set DOCUMENTS_R=%%~b

robocopy "%BackupPath%/Documents" "%DOCUMENTS_R%" /e /v /mt:6 /r:3 /w:20 /xo /z /np /log+:"%LogFile%"


rem Restore Pictures
echo Restoring Pictures >> "%LogFile%"
rem UI stuff
cls
echo ================================
echo =   Restoration In Progress    =
echo =   This May Take Some Time    =
echo =                              =
echo = Restoring Desktop...    Done =
echo = Restoring Documents...  Done =
echo = Restoring Pictures...   Done =
echo =                              =
echo =      Please Wait...          =
echo =                              =
echo ================================
rem restore the pictures folder based on regkey
for /f "tokens=3*" %%a in ('reg query "HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "My Pictures"') do call set PICTURES_R=%%~b

robocopy "%BackupPath%/Pictures" "%PICTURES_R%" /e /v /mt:6 /r:3 /w:20 /xo /z /np /log+:"%LogFile%"

rem Restore Network Drives
rem this will map all network drives that are stored in the NetworkDrivesListFile as persistent network drives using a CSV-like format for arguments.

set "NetworkDrivesListFile=%BackupPath%/My-MappedDrives.txt"
for /F "usebackq tokens=*" %%A in ("%NetworkDrivesListFile%") do (
    set networkdrive=%%~A
	echo Restoring Network Drives... >> "%LogFile%"
rem	We split the text to get the drive letter and the path as two seperate objects as the "net use" command takes two parameters "Drive Letter" & "Drive Path".	
	for /F "tokens=1,2 delims=: " %%a IN ("!networkdrive!") DO (
		set dletter=%%a:
		set dpath=%%b
		echo "!dletter!" "!dpath!", as persistent Network Drive >>"%LogFile%"
		powershell -command "(net use '!dletter!' '!dpath!' /persistent:yes)" >> "%LogFile%"
	)
    rem UI Stuff
    cls
    echo ================================
    echo =   Restoration In Progress    =
    echo =   This May Take Some Time    =
    echo =                              =
    echo = Restoring Desktop...    Done =
    echo = Restoring Documents...  Done =
    echo = Restoring Pictures...   Done =
    echo = Restoring NetDrives...       =
    echo =                              =
    echo =      Please Wait...          =
    echo =                              =
    echo ================================
)
cls
rem Restore printers
rem This will map all printers stored in the PrinterListFile.
echo. >> "%LogFile%"
echo Restoring Printers... >> "%LogFile%"
set "PrinterListFile=%BackupPath%/My_Printers.txt"
for /F "usebackq tokens=*" %%A in ("%PrinterListFile%") do (
    set printer=%%A
    set printer=!printer: =!
    rem UI stuff
    cls
    echo ================================
    echo =   Restoration In Progress    =
    echo =   This May Take Some Time    =
    echo =                              =
    echo = Restoring Desktop...    Done =
    echo = Restoring Documents...  Done =
    echo = Restoring Pictures...   Done =
    echo = Restoring NetDrives...  Done =
    echo = Restoring Printers...        =
    echo =                              =
    echo =      Please Wait...          =
    echo =                              =
    echo ================================
    echo Adding Printer: "!printer!" >> "%LogFile%"
    powershell -command "(New-Object -ComObject WScript.Network).AddWindowsPrinterConnection('!printer!')"
)

    rem UI stuff
    cls
    echo ================================
    echo =   Restoration In Progress    =
    echo =   This May Take Some Time    =
    echo =                              =
    echo = Restoring Desktop...    Done =
    echo = Restoring Documents...  Done =
    echo = Restoring Pictures...   Done =
    echo = Restoring NetDrives...  Done =
    echo = Restoring Printers...   Done =
    echo =                              =
    echo =      Please Wait...          =
    echo =                              =
    echo ================================

rem Restoration process complete, please check log for errors
echo Restoration Process Complete >> "%LogFile%"
goto:Finish













rem Finish
rem This will print the conclusion information to the console.
:Finish
echo. >> "%LogFile%"
echo Process Completed, Script Ready To Exit >> "%LogFile%"

rem UI stuff
cls
color a
echo ================================
echo ================================
echo =                              =
echo =          ALL DONE            =
echo =                              =
echo =  You May Close This Window   =
echo =                              =
echo ================================
echo ================================
rem Let user read the splashscreen and wait for the user to close the window.
set /p DelayedExitDummy = 