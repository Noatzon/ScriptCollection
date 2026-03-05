@ECHO OFF

echo Run as Admin!
echo Please input path to map you wish to 'unlock':
set /p input = full path then Enter
echo Path set to %input%
rem Change to relevant depending on your region
icacls "%input%" /grant:r BUILTIN\User:(OI)(CI)M

echo permissions changed! You may close this window
set /p delay =