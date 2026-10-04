@echo off
setlocal EnableExtensions
title Maxima Master Key Core - init_setup

REM =====================================================================
REM  Double-click wrapper for init_setup.sh on Windows.
REM  Finds (or installs) Git Bash, points the script at the portable
REM  toolchain Flutter when present, then runs the bootstrap pipeline.
REM =====================================================================

cd /d "%~dp0"

if not exist "init_setup.sh" (
    echo [FAIL] init_setup.sh not found next to this .bat file.
    pause
    exit /b 1
)

set "BASH_EXE="

REM --- 1) Existing Git for Windows installs -------------------------------
if exist "%ProgramFiles%\Git\bin\bash.exe"        set "BASH_EXE=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH_EXE if exist "%LocalAppData%\Programs\Git\bin\bash.exe" set "BASH_EXE=%LocalAppData%\Programs\Git\bin\bash.exe"
if not defined BASH_EXE if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH_EXE=%ProgramFiles(x86)%\Git\bin\bash.exe"

REM --- 2) Derive bash.exe from a git.exe already on PATH -------------------
if not defined BASH_EXE (
    for /f "delims=" %%G in ('where git.exe 2^>nul') do (
        if not defined BASH_EXE if exist "%%~dpG..\bin\bash.exe" set "BASH_EXE=%%~dpG..\bin\bash.exe"
    )
)

REM --- 3) Install Git for Windows via winget (provides Git Bash) -----------
if not defined BASH_EXE (
    echo [*] Git Bash not found. Installing Git for Windows via winget...
    where winget >nul 2>nul
    if errorlevel 1 (
        echo [FAIL] winget is unavailable. Install Git for Windows manually:
        echo        https://git-scm.com/download/win
        pause
        exit /b 1
    )
    winget install --id Git.Git --exact --silent --accept-source-agreements --accept-package-agreements
    if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH_EXE=%ProgramFiles%\Git\bin\bash.exe"
    if not defined BASH_EXE if exist "%LocalAppData%\Programs\Git\bin\bash.exe" set "BASH_EXE=%LocalAppData%\Programs\Git\bin\bash.exe"
)

if not defined BASH_EXE (
    echo [FAIL] Could not locate or install Git Bash.
    pause
    exit /b 1
)

echo [*] Using Bash: %BASH_EXE%

REM --- 4) Prefer the portable toolchain Flutter if it exists ---------------
if exist "C:\dev\toolchain\flutter-sdk\flutter\bin\flutter" (
    set "FLUTTER_HOME=/c/dev/toolchain/flutter-sdk/flutter"
    echo [*] FLUTTER_HOME=%FLUTTER_HOME%
)

REM --- 5) Convert this directory to a POSIX path for bash ------------------
set "WIN_DIR=%~dp0"
set "POSIX_DIR=%WIN_DIR:\=/%"
set "DRIVE=%POSIX_DIR:~0,1%"
set "POSIX_DIR=/%DRIVE%%POSIX_DIR:~2%"
set "POSIX_DIR=%POSIX_DIR:~0,-1%"

echo [*] Running init_setup.sh ...
"%BASH_EXE%" -c "cd '%POSIX_DIR%' && ./init_setup.sh"
set "EXITCODE=%ERRORLEVEL%"

echo.
if "%EXITCODE%"=="0" (
    echo [OK] init_setup.sh completed successfully.
) else (
    echo [FAIL] init_setup.sh exited with code %EXITCODE%.
)
pause
exit /b %EXITCODE%
