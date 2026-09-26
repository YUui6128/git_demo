@echo off
setlocal enabledelayedexpansion
title Fix Code Upload - Auto Proxy

echo.
echo ==========================================
echo    FIX CODE UPLOAD  (auto set git proxy)
echo ==========================================
echo.
echo  [1/3] Reading your proxy address...
echo.

set "PROXY="
for /f "usebackq delims=" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings').ProxyServer"`) do set "PROXY=%%A"

if "!PROXY!"=="" goto NOPROXY

echo        Found proxy: !PROXY!
echo.
echo  [2/3] Writing git settings...
git config --global http.proxy  "!PROXY!"
git config --global https.proxy "!PROXY!"
if errorlevel 1 goto FAIL
echo        Done.
echo.
echo  [3/3] Testing connection to GitHub...
git -C "%~dp0." ls-remote --heads origin >nul 2>&1
if errorlevel 1 goto FAIL

echo.
echo ==========================================
echo    SUCCESS - go back to VS Code and push
echo ==========================================
goto DONE

:NOPROXY
echo.
echo ==========================================
echo    NO PROXY FOUND
echo ==========================================
echo.
echo    Your proxy app is not running.
echo    Step 1: open your proxy app first.
echo    Step 2: run this file again.
goto DONE

:FAIL
echo.
echo ==========================================
echo    STILL CANNOT CONNECT
echo ==========================================
echo.
echo    1. Make sure your proxy app is running.
echo    2. Open the proxy app and fix its port
echo       to 7890, then run this file again.

:DONE
echo.
echo Press any key to close...
pause >nul
endlocal
