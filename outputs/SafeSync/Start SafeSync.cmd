@echo off
if exist "%~dp0SafeSync.exe" (
    start "SafeSync" "%~dp0SafeSync.exe"
    exit /b
)
start "SafeSync" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0SafeSync.ps1"
