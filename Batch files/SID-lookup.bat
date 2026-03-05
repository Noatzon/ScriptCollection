@ECHO OFF

rem ** SID LOOKUP & TRANSLATION **
rem Find the username (aXXXXXX) of the one logged in, not who's running the script. Used to add seperate .reg file to actual user and not MW_Admin. We split and discard the domain as we're not intrested in that.
for /f "tokens=1,2 delims=\" %%r in ('powershell -command "(Get-WMIObject -class Win32_ComputerSystem | select username)"') do set "usrname=%%s"
rem Gets the [full path] for our user with the correct SID
for /f "delims=" %%g in ('powershell -command "(ls 'hklm:software/microsoft/windows nt/currentversion/profilelist' | ? {$_.getvalue('ProfileImagePath') -match '%usrname%'} | select Name)"') do set "reg_sid=%%g"
rem Cutting of and keeping only the SID from our previous result. We then immedietly use it to construct the correct Registry path.
for /f "tokens=6* delims=\" %%i in ("%reg_sid%") do set "r_User=%%j"

echo usrname: %usrname%
echo.
echo.
echo.
echo reg_sid: %reg_sid%
echo.
echo.
echo.
echo r_user: %r_User%