@echo off
setlocal EnableExtensions
title Maxima - Local AI Gateway Host

REM =====================================================================
REM  Runtime launcher only - NO installers, NO downloads, NO admin.
REM  Assumes Ollama is already installed and the model already pulled.
REM  Starts: (1) Ollama AI gateway on the LAN
REM          (2) chan_dongle host tunnel (if Python is present)
REM =====================================================================

cd /d "%~dp0"
echo [*] Maxima local host services - runtime only

REM ---------- 1) Locate Ollama (user-space install paths) -----------------
set "OLLAMA_EXE="
where ollama >nul 2>nul && set "OLLAMA_EXE=ollama"
if not defined OLLAMA_EXE if exist "%LocalAppData%\Programs\Ollama\ollama.exe" set "OLLAMA_EXE=%LocalAppData%\Programs\Ollama\ollama.exe"
if not defined OLLAMA_EXE if exist "%ProgramFiles%\Ollama\ollama.exe"        set "OLLAMA_EXE=%ProgramFiles%\Ollama\ollama.exe"

if not defined OLLAMA_EXE (
    echo [FAIL] Ollama was not found. Install it once from https://ollama.com/download
    pause
    exit /b 1
)
echo [*] Ollama: %OLLAMA_EXE%

REM ---------- 2) Start the AI gateway on the LAN --------------------------
REM OLLAMA_HOST must be 0.0.0.0 so the phone can reach it over Wi-Fi.
set "OLLAMA_HOST=0.0.0.0"

"%OLLAMA_EXE%" list >nul 2>nul
if not errorlevel 1 goto ollama_ready

echo [*] Starting Ollama service...
start "Maxima Ollama" /min "%OLLAMA_EXE%" serve

set /a tries=0
:wait_ollama
"%OLLAMA_EXE%" list >nul 2>nul
if not errorlevel 1 goto ollama_ready
set /a tries+=1
if %tries% geq 30 (
    echo [FAIL] Ollama service did not come up within 30 seconds.
    pause
    exit /b 1
)
timeout /t 1 /nobreak >nul
goto wait_ollama

:ollama_ready
echo [*] Ollama gateway online on port 11434.

REM ---------- 2b) Confirm it answers on the LAN IP, not just localhost ----
REM Prefer physical adapters; skip VPN/tunnel interfaces (Surfshark, TAP...)
set "LAN_IP="
for /f "delims=" %%I in ('powershell -NoProfile -Command "(Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp,Manual -ErrorAction SilentlyContinue ^| Where-Object { $_.InterfaceAlias -notmatch 'VPN|WireGuard|TAP|Tunnel|Surfshark|NordVPN|OpenVPN' } ^| Select-Object -First 1).IPAddress"') do set "LAN_IP=%%I"
if not defined LAN_IP for /f "delims=" %%I in ('powershell -NoProfile -Command "(Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp,Manual -ErrorAction SilentlyContinue ^| Select-Object -First 1).IPAddress"') do set "LAN_IP=%%I"
if defined LAN_IP (
    powershell -NoProfile -Command "try { [void](Invoke-WebRequest -Uri 'http://%LAN_IP%:11434/api/tags' -TimeoutSec 3 -UseBasicParsing); exit 0 } catch { exit 1 }" >nul 2>nul
    if errorlevel 1 (
        echo [!] Ollama answers on localhost but NOT on %LAN_IP%:11434.
        echo     A tray copy bound to 127.0.0.1 is probably running.
        echo     Quit the Ollama tray icon, then double-click this file again.
        pause
        exit /b 1
    )
    echo [*] Ollama is reachable from the phone at http://%LAN_IP%:11434
)

REM ---------- 3) Verify the model is available ----------------------------
"%OLLAMA_EXE%" list 2>nul | findstr /i "qwen" >nul
if errorlevel 1 (
    echo [!] No qwen model found in 'ollama list'. Pull one manually:
    echo     %OLLAMA_EXE% pull qwen2.5:1.5b
) else (
    echo [*] Qwen model is present.
)

REM ---------- 4) Mount the local host tunnel (chan_dongle bridge) ----------
set "MAXIMA_HOST_BIND=0.0.0.0"
if "%MAXIMA_HOST_TOKEN%"=="" set "MAXIMA_HOST_TOKEN=maxima-local"

where python >nul 2>nul
if errorlevel 1 (
    echo [!] Python not on PATH - host tunnel skipped (Ollama still running).
    goto show_summary
)
if not exist "tools\chan_dongle_server.py" (
    echo [!] tools\chan_dongle_server.py missing - host tunnel skipped.
    goto show_summary
)
echo [*] Starting host tunnel on port 8080 ...
start "Maxima Host Tunnel" /min python "%~dp0tools\chan_dongle_server.py"

:show_summary
echo.
echo ============================================================
echo  Local services are up. Use these addresses when rebuilding
echo  the app or configuring endpoints:
echo.
if defined LAN_IP (
    echo    OLLAMA_BASE_URL      = http://%LAN_IP%:11434
    echo    REMOTE_HOST_BASE_URL = http://%LAN_IP%:8080
) else (
    for /f "delims=" %%I in ('powershell -NoProfile -Command "(Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp,Manual -ErrorAction SilentlyContinue ^| Where-Object { $_.InterfaceAlias -notmatch 'VPN|WireGuard|TAP|Tunnel|Surfshark|NordVPN|OpenVPN' }).IPAddress"') do (
        echo    OLLAMA_BASE_URL      = http://%%I:11434
        echo    REMOTE_HOST_BASE_URL = http://%%I:8080
    )
)
echo    REMOTE_HOST_TOKEN    = %MAXIMA_HOST_TOKEN%
echo.
echo  First run may pop a Windows Firewall prompt - click
echo  "Allow access" on Private networks. No admin needed.
echo ============================================================
echo.
pause
exit /b 0
