@echo off
rem Merak for ComfyUI - installer for the Windows Command Prompt.
rem
rem   curl -fsSL https://raw.githubusercontent.com/snarkify/merak-comfyui-node/main/install.cmd -o install.cmd && install.cmd && del install.cmd
rem
rem CMD is a poor language for this, so it does nothing but fetch install.ps1
rem and hand over to PowerShell, passing along any options it was given.

setlocal
set "URL=https://raw.githubusercontent.com/snarkify/merak-comfyui-node/main/install.ps1"
set "SCRIPT=%TEMP%\merak-install-%RANDOM%.ps1"

where curl.exe >nul 2>&1
if %ERRORLEVEL%==0 (
  curl -fsSL "%URL%" -o "%SCRIPT%"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -Uri '%URL%' -OutFile '%SCRIPT%' -UseBasicParsing } catch { exit 1 }"
)

if not exist "%SCRIPT%" (
  echo Download failed - check your internet connection and try again.
  exit /b 1
)

rem -ExecutionPolicy Bypass because a downloaded .ps1 will not run otherwise.
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "CODE=%ERRORLEVEL%"
del "%SCRIPT%" >nul 2>&1

rem Keep the window open when this was started by double-clicking it.
echo %cmdcmdline% | find /i "%~nx0" >nul && pause
exit /b %CODE%
