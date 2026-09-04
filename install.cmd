@echo off
rem Merak for ComfyUI installer for Windows Command Prompt.

setlocal
set "URL=https://raw.githubusercontent.com/snarkify/merak-comfyui-node/main/install.ps1"
set "SCRIPT=%TEMP%\merak-install-%RANDOM%%RANDOM%.ps1"

where curl.exe >nul 2>&1
if errorlevel 1 goto webrequest
curl.exe -fsSL "%URL%" -o "%SCRIPT%"
if errorlevel 1 goto failed
goto run

:webrequest
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; try { Invoke-WebRequest -Uri '%URL%' -OutFile '%SCRIPT%' -UseBasicParsing } catch { exit 1 }"
if errorlevel 1 goto failed
goto run

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "CODE=%ERRORLEVEL%"
del /q "%SCRIPT%" >nul 2>&1
exit /b %CODE%

:failed
del /q "%SCRIPT%" >nul 2>&1
echo Download failed. Check your internet connection and try again.
exit /b 1
