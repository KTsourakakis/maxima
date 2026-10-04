# ============================================================================
# Builds native_core.dll for Windows using the portable WinLibs MinGW GCC
# toolchain (or MSVC cl.exe if already on PATH via a Developer shell).
#
#   .\tools\build_native_desktop.ps1 [-GccDir C:\dev\toolchain\mingw64\bin]
#
# Output: .\native\windows\native_core.dll
# ============================================================================
param(
    [string]$GccDir = "C:\dev\toolchain\mingw64\bin",
    [string]$OutDir = ""
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $OutDir) { $OutDir = Join-Path $root 'native\windows' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$src = Join-Path $root 'src\native_core.cpp'
$bridge = Join-Path $root 'src\sip_bridge.cpp'
$out = Join-Path $OutDir 'native_core.dll'

$gxx = Join-Path $GccDir 'g++.exe'
if (Test-Path $gxx) {
    Write-Host "[*] Compiling with $gxx"
    & $gxx -std=c++23 -O2 -shared -fPIC -DNDEBUG `
        -o $out $src $bridge `
        -static -static-libgcc -static-libstdc++
    if ($LASTEXITCODE -ne 0) { throw "g++ failed with exit code $LASTEXITCODE" }
} else {
    Write-Host "[*] MinGW not found at $gxx; trying MSVC cl.exe"
    & cl.exe /std:c++latest /O2 /LD /EHsc $src $bridge "/Fe:$out"
    if ($LASTEXITCODE -ne 0) { throw "cl.exe failed with exit code $LASTEXITCODE" }
}

Write-Host "[+] Built $out"
