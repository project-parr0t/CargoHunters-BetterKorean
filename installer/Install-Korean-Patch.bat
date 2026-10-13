@echo off
setlocal
for %%I in ("%~dp0.") do set "PATCH_ROOT=%%~fI"
cd /d "%PATCH_ROOT%" || goto launch_error
if not exist "%PATCH_ROOT%\Install-Korean-Patch.ps1" goto launch_error
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PATCH_ROOT%\Install-Korean-Patch.ps1" -PackageRoot "%PATCH_ROOT%"
set "PATCH_RESULT=%errorlevel%"
if "%PATCH_RESULT%"=="9009" goto launch_error
exit /b %PATCH_RESULT%
:launch_error
echo E_PATCH_LAUNCH_FAILED
pause
exit /b 1
