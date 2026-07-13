@echo off
setlocal EnableExtensions
title GitLab Duo CLI Switcher 8.3.2

set "SCRIPT=%~dp0GitLabDuoCLI-Switcher.ps1"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%PS%" goto no_powershell
if not exist "%SCRIPT%" goto missing_script
if not exist "%~dp0DuoTerminalRecorder.cs" goto missing_recorder

echo Checking PowerShell syntax...
"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$tokens=$null;$errors=$null;[System.Management.Automation.Language.Parser]::ParseFile($env:SCRIPT,[ref]$tokens,[ref]$errors)|Out-Null;if($errors.Count -gt 0){$errors|ForEach-Object{Write-Host ('Line ' +$_.Extent.StartLineNumber+', column '+$_.Extent.StartColumnNumber+': '+$_.Message)};exit 41}"
if not "%ERRORLEVEL%"=="0" goto syntax_error

"%PS%" -NoLogo -NoProfile -Sta -ExecutionPolicy Bypass -File "%SCRIPT%"
set "CODE=%ERRORLEVEL%"

if "%CODE%"=="0" goto end
echo.
echo Switcher failed. Exit code: %CODE%
echo Log: %LOCALAPPDATA%\GitLabDuoCLISwitcher\crash.log
echo Open the Hub again and use M then 6 for diagnostics.
pause
goto end

:syntax_error
echo.
echo PowerShell syntax check failed.
echo The Switcher was not started.
echo Re-extract the original ZIP and replace all four files.
pause
exit /b 41

:no_powershell
echo Windows PowerShell 5.1 was not found.
pause
exit /b 10

:missing_script
echo GitLabDuoCLI-Switcher.ps1 is missing.
echo Extract the complete ZIP into a normal folder.
pause
exit /b 11

:missing_recorder
echo DuoTerminalRecorder.cs is missing.
echo Extract the complete ZIP into a normal folder.
pause
exit /b 12

:end
endlocal & exit /b %CODE%
