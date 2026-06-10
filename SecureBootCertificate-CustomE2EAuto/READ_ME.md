# SECURE BOOT CERTIFICATE UPDATE
>Scripts rewritten and documentation created by \Noatzon. Blame/thank me for this whole thing (^._.^)ﾉ

## Overview
The rough flow can be described as:\
Detect (Endpoint state/status) > Aggregate (the results) > Evaluate (based on history & current status) > Generate Wave > Progress Wave | Monitor current Wave > Repeat

Everything is constructed to work even if you're not a Domain admin and for both large & small-scale deployment. While the rest of the document talks about using a GPO that's not *strictly* required. Though it will involve a lot more manual labor without one. I should mention that the "Get-SecureBootRolloutStatus.ps1" is included "as-is" and I haven't made any changes to it. So I can't guarantee it'll perform as xpected.

### PREREQUISITES
1.	Access to edit a GPO that targets all relevant servers.
2.	Service account to run task.\
• Through the GPO, set up so it gets added to:\
└ [“Local Administrator”](#configuring-service-account-through-gpo) group.\
└	[“Log on as a batch job”](#location-to-configure-log-on-as-a-batch-job-part-in-gpo) security group. 
3.	[Configure](#configuring-startup-scripts-via-gpo) startup scripts to create and run scripts on endpoints (servers).
4.	Decide on a server you wish to use as your “hub”. Create at least one [network share](#setting-up-a-network-share) on it. \
└	I recommend creating three separate ones. One each for Logs, Scripts, Reports.\
└	Ensure you’ve added Read & Write permissions for your service account on each network share.

# Steps
1.	Start by following the instructions in the Scripts section if you haven’t.
2.	Copy over the tweaked scripts to the expected locations.
- 	The following should be in the startup folder of your GPO:
    -	Create-ManifestTask.ps1
    -	Create-SecurebootTask.ps1
    -	Detect-EndpointWave.ps1
    -	Detect-SecureBootCertStatus.ps1
- The rest should be placed in your network share script folder:
    -	Aggregate-SecureBootData.ps1
    -	Deploy-OrchestratorTask.ps1
    -	RolloutOrchestrator.ps1
    -	Enable-SecureBootUpdateTask.ps1
    -	Get-SecureBootUpdateTask.ps1
-	Either wait until you naturally restart servers or manually run PowerShell scripts to create task on servers and start collecting data.
3.	Give it an hour or two for data to be collected. Once you see a couple “_latest.json” files in your "SBC_Logs" folder you can proceed.
4.	Run Deploy-Orchestrator.ps1 script via interactive PowerShell session (change to your argument paths):
```
.\Deploy-OrchestratorTask.ps1 -AggregationInputPath "E:\SB_Logs" -ReportBasePath "E:\SBC_Reports" -ScriptFolder "E:\SBCscripts" -LocalPath "C:\temp"
```
>Please note down the commands it presents to you at the end. Especially the “View Dashboard”!
5.	If you need to update the Orchestrator or Aggregation scripts just paste the new ones in your scripts folder, run the kill command and then the above ("deploy" command line) again. Kill command:
```
Get-WmiObject Win32_Process | Where-Object {
    $_.CommandLine -like "*RolloutOrchestrator.ps1*"
 } | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force
}
```
6.	Logs will be found for both Orchestrator & Aggregation script under the path you specified as the $LocalPath when running *Deploy-Orchestrator.ps1*. I recommend using Notepad++ to open and monitor them to confirm everything is working. If you prefer to not have a new one generated for each day, just change the "Write-Log" function in the Rollout & Aggregate scripts.
7.	Run the command to “view Dashboard” to bring up a .html page with all the information about your current progress.

### Rough explanation of UEFICA2023Error codes
└	2147942750 Waiting for reboot\
└	2147500037 Firmware upgrade (issue)\
└	2147946825 Secure Boot disabled\
└	2147942402 Firmware up to date | missing new certs in firmware


# Scripts
Change the params/arguments specified below to target your own environment.

#### [Create-ManifestTask.ps1] & [Create-SecurebootTask.ps1]
*Current values are examples*
- **$taskName** = "SBC-WaveProgressor" | "SBC-Status-Collection"\
└ Name of the task, cosmetic
- **$ScriptPath** = "<ins>\\\DOMAIN\SysVol\DOMAIN\Policies\{POLICY-ID}\Machine\Scripts\Startup</ins>" \
└ Path to where you've placed your startup scripts for your GPO.
- **$OutputPath** = "<ins>\\\SERVER\SBC_Logs</ins>" \
└ FQDN/UNC path to network share that Aggregator script uses as input & Orchestrator writes WaveManifest.json to.  Folder obviously doesn’t have to be called “SBC_Logs”
- **$LocalPath** = "<ins>C:\Temp</ins>" \
└ Local path that [Detect-EndpointWave.ps1] gets saved to and (the) version actually used by Scheduled Task.
- **line 22**; "(New-TimeSpan -Minutes 240)" \
└ For [Create-ManifestTask.ps1]: Configures how often the script should run and check for a new WaveManifest.json. This is the file that it uses to check if it should be part of the current Wave. Default is 3h. \
└ For [Create-SecurebootTask.ps1]: Configures how often the script should run and check for status updates on device. Default is 4h. \
└ Recommendation is to leave default.

#### <ins>[Deploy-OrchestratorTask.ps1]</ins>
*The following are the “runtime arguments” you must supply values to when running the script*
- **[string]$AggregationInputPath**\
└ FQDN/UNC path to network share that Aggregator script uses as input & Orchestrator writes WaveManifest.json to
- **[string]$ReportBasePath**\
└ FQDN/UNC path to network share where all scripts save report and state files (can optionally be a local folder).\
└ Should be a seperate folder than the one used for $AggregationInputPath!
- **[string]$ScriptFolder**\
└ FQDN/UNC to central script repository. If there's any changes to the scripts used by Orchestrator they get put here and [Deploy-OrchestratorTask.ps1] re-run to "update" everything. Remeber to kill current Orchestrator object first!
- **[string]$LocalPath**\
└ Path to were local copies of scripts are saved by Deploy- script and used by the Scheduled Tasks

*Actual variables to configure inside script*
- **[string]$ServiceAccount** = "DOMAIN\<service account>"\
└ Service account to use for running the Scheduled Task, should be same as the one you've configured in GPO
- **Line 230:** Update *-Password ""*  and write the password for your service account inside the ""'s.

*Optional ones*
- **[int]$PollIntervalMinutes**
└ Sets how long the Orchestrator sleeps for when its entered monitoring state
- [string]$taskName = "SBC Rollout Orchestrator"
└ Name of the task, cosmetic

#### <ins>[Rollout-Orchestrator.ps1]</ins>
*Function Get-LatestAggregation* (Line 625 onward)
- **[int]$TimeoutSeconds** = 1200\
└ Configurable wait time for script to finish before assuming it failed. Number here is milliseconds. So, 600 = 1min.\
└ Recommendation is to leave default unless you have several hundred servers.
- **[int]$MaxRetries** = 3\
└ Configurable number of times to retry running script after it timed out.
- **$arguments** \
└ Refer to *Aggregate-SecureBootData.ps1* for the additional arguments we're sending. You can remove the "-IncludeAllConfidenceLevels" if you want, though I'd recommend running at least one or two "cycles" with it present to ensure you see all the devices properly.

*Inside main loop*
- **Line 1744 & line 1755**; "if ($age.TotalMinutes -lt 120)"\
└ How long to wait before rerunning [Aggregate-SecureBootData.ps1] to consolidate new device statuses (in minutes). Default is 2h.\
└ Do not set this too low as that will just create unnecessary script load. It should be coordinated with the update interval you configured in [Create-SecurebootTask.ps1]. 
- *'Line 1776**; "Start-Sleep -Seconds 300"\
└ Additional failsafe, if the Get-Latest-Aggregation function returns an error it sleeps/waits this long before "starting over" again. Orchestrator will not run unless it is sure the data is fresh.
- **Lines 1906, 1907, 1908**;\
└ Read .DESCRIPTION for explanations. Separate failsafe mechanism for determining device "participation" in Wave and accepted success rate.

# Instructions for related tasks
Putting down some instructions/info on how to do some things that might not be obvious. These will be linked to when relevant.

## Configuring service account through GPO

Location to configure Local Administrator part (in GPO):
```
Computer Configuration
 └ Preferences
   └ Control Panel Settings
      └ Local Users and Groups
```
•	Right-Click » New > Local Group » \
└ **Action**: Update\
└	**Group name**: Administrators (built-in)\
└	**Members**: <your service account>

## Location to configure Log on as a batch job part (in GPO):
```
Computer Configuration
 └ Policies
   └ Windows Settings
      └ Security Settings
        └ Local Policies
          └ User Rights Assignment
```
•	Locate the “log on as a batch job” policy from the list and add your service account to it.

## Configuring startup scripts via GPO
Location to configure Log on as a batch job part (in GPO):\
```
Computer Configuration\
 └ Policies\
   └ Windows Settings\
      └ Scripts (Startup/Shutdown)
```
1.	Double-click on Startup  
2.	Move over to Powershell Scripts tab
3.	Click Add… button > Browse… button
4.	Copy your startup scripts here
5.	Select one of the Create- scripts
6.	Repeat steps 3-5 for the other Create- script
7.	Click Apply & then OK button


## Setting up a network share
Create a new folder on your server, either directly under C:\ or on a seperate drive and call it something short. 
1.	Right-click » Properties » Sharing tab
2.	Click "Advanced Sharing…"
3.	Check the box in fron of ”Share this folder”  
4.	Click Permissions button » Add your service & admin account


# References
- Microsoft. (n.d.). E2E Automation Guide. Retrieved from support.microsoft.com: https://support.microsoft.com/en-gb/topic/sample-secure-boot-e2e-automation-guide-f850b329-9a6e-40d1-823a-0925c965b8a0
- Microsoft. (n.d.). Secure Boot Certificate update guidance. Retrieved from support.microsoft.com: https://support.microsoft.com/en-gb/topic/secure-boot-certificate-updates-guidance-for-it-professionals-and-organizations-e2b43f9f-b424-42df-bc6a-8476db65ab2f
- Microsoft. (n.d.). Task Scheduler Schema. Retrieved from learn.microsoft.com: https://learn.microsoft.com/en-us/windows/win32/taskschd/task-scheduler-schema
- Microsoft. (n.d.). Windows Server Secure Boot playbook for certificates expiring in 2026. Retrieved from techcommunity.microsoft.com: https://techcommunity.microsoft.com/blog/windowsservernewsandbestpractices/windows-server-secure-boot-playbook-for-certificates-expiring-in-2026/4495789

## Cheat-sheet/mixed info
the Change to the 2023 ~~will~~ should happen automatically with Windows Update or by setting the regkey:\
<ins>HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot AvailableUpdates</ins> to **0x5944** and triggering the task:\
(Task Scheduler) > "Microsoft\Windows\PI\Secure-Boot-Update" and doing **two** reboots. But that's just what Microsoft claims so ヽ( ~～~ )ノ

```
===================================
FUNCTION LIST (RolloutOrchestrator)
===================================
NAME                                  PURPOSE
function ConvertTo-Hashtable		  Compatibility for older PS
function Write-Log			          Write log

function Save-RolloutSummary		  Provides data for Dashboard
function Get-RolloutState		      Load RolloutState.json as list
function Save-RolloutState            Save to RolloutState.json
function Get-DeviceHistory		      Load DeviceHistory.json as list
function Save-DeviceHistory		      Save to DeviceHistory.json
function Get-BlockedBuckets		      Load BlockedBuckets.json as list
function Save-BlockedBuckets		  Save to BlockedBuckets.json
function Get-AdminApproved		      Load AdminApprovedBuckets.json

function Save-ProcessingCheckpoint	  Save current wave progress As json?
function Get-NotUpdatedIndexes		  Generates list of devices in specific
					                  buckets, uses function [Get-BucketKey]
	
function Get-BucketKey			      Constructs buckets from the raw json
function Get-LatestFile			      Checks for/load a file (specific use-case)
					
function Get-LatestAggregation		  Runs Aggr script to update files

function Update-DeviceHistory		  Tracks devices through wave/progress
function Test-DeviceReachable		  Check device activity	
function Update-AutoUnblockedBuckets  Checks if devices in blocked buckets have updated (Event 1808).


function Update-BlockedBuckets		  Main "bucket" state driver of Orchestrator. Decides what should be part of each wave based on previous waves/results. 
		                              Uses functions [Get-NotUpdatedIndexes], [Test-DeviceReachable]
		                              Loads jsons RolloutState, BlockedBuckets, AdminApproved

function New-RolloutWave		      State engine to create and manage rollout waves. Works alongside function [Update-BlockedBuckets] to manage the content of each wave.				
```