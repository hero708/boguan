<#
Builds the Rust native core (rust/ -> libfqapi_core.so) for HarmonyOS
(arm64-v8a) and copies the library into ohos/entry/libs/arm64-v8a, which is
where hvigor packages it into the HAP.

Only the aarch64 triple is supported: the OHOS Flutter engine and Hvigor
currently reject 32-bit ARM (armeabi-v7a) application packages.

It cross-compiles with
the HarmonyOS SDK LLVM toolchain (no separate NDK download) and places the
shared library where hvigor picks it up. The Rust target is
aarch64-unknown-linux-ohos, a Tier-2-with-host-tools Rust target: its std is
installed by `rustup target add aarch64-unknown-linux-ohos`.

Usage:
  .\scripts\build_rust_backend_ohos.ps1
  .\scripts\build_rust_backend_ohos.ps1 -SkipCodegen
  .\scripts\build_rust_backend_ohos.ps1 -Profile debug

Comments are kept in ASCII on purpose so the file parses cleanly on
Windows PowerShell 5.1 without a UTF-8 BOM.
#>

param(
    [switch]$SkipCodegen,
    [ValidateSet('release', 'debug')][string]$Profile = 'release'
)

$ErrorActionPreference = 'Stop'

$RustTarget = 'aarch64-unknown-linux-ohos'
$FrbVersion = '2.13.0'
$AppDir = Split-Path -Parent $PSScriptRoot
$Manifest = Join-Path $AppDir 'rust\Cargo.toml'
$LibsDir = Join-Path $AppDir 'ohos\entry\libs\arm64-v8a'

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    Write-Error 'cargo not found in PATH. Install the Rust toolchain first.'
    exit 1
}
if (-not (Test-Path -LiteralPath $Manifest)) {
    Write-Error "rust core manifest not found at $Manifest"
    exit 1
}

# Native commands write progress to stderr and PowerShell would turn that into
# a terminating NativeCommandError before the copy step runs (CRIT-012 in the
# Android script). Keep the verdict on $LASTEXITCODE instead.
function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$FailureMessage
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe @Arguments
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($LASTEXITCODE -ne 0) { throw "$FailureMessage (exit code $LASTEXITCODE)" }
}

function Resolve-OhosSdkRoot {
    # Accept either the SDK root (contains default/openharmony) or the
    # openharmony directory itself; OHOS_SDK_HOME is set to the latter by
    # flutter_tools, while DEVECO_SDK_HOME points at the former.
    $candidates = @()
    if ($env:OHOS_SDK_HOME) { $candidates += $env:OHOS_SDK_HOME }
    if ($env:DEVECO_SDK_HOME) { $candidates += (Join-Path $env:DEVECO_SDK_HOME 'default\openharmony') }
    if ($env:HOS_SDK_HOME) { $candidates += (Join-Path $env:HOS_SDK_HOME 'default\openharmony') }
    $candidates += 'D:\ohsdk\default\openharmony'
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'native\sysroot'))) {
            return $candidate
        }
    }
    return $null
}

$OhosSdk = Resolve-OhosSdkRoot
if (-not $OhosSdk) {
    Write-Error 'HarmonyOS SDK not found. Set OHOS_SDK_HOME to <sdk>/default/openharmony (it must contain native/sysroot).'
    exit 1
}
if ($OhosSdk -match '\s') {
    Write-Error "HarmonyOS SDK path must not contain spaces (resolved to '$OhosSdk'). The clang wrapper splits TARGET_CFLAGS on whitespace, so ring and other C crates fail."
    exit 1
}
Write-Host "==> OHOS SDK: $OhosSdk"

$LlvmBin = Join-Path $OhosSdk 'native\llvm\bin'
$Sysroot = Join-Path $OhosSdk 'native\sysroot'
$Clang = Join-Path $LlvmBin 'clang.exe'
$Clangpp = Join-Path $LlvmBin 'clang++.exe'
$LlvmAr = Join-Path $LlvmBin 'llvm-ar.exe'
$LlvmRanlib = Join-Path $LlvmBin 'llvm-ranlib.exe'
foreach ($tool in @($Clang, $Clangpp, $LlvmAr)) {
    if (-not (Test-Path -LiteralPath $tool)) {
        Write-Error "HarmonyOS LLVM tool not found: $tool"
        exit 1
    }
}

# The environment variable names must use the full underscored target triple:
# cc-rs only looks at CC_<target with dashes replaced by underscores>, so
# CC_aarch64_linux_ohos (the short "linux" form) is silently ignored and the
# crate falls back to the host "cc".
$EnvTriple = $RustTarget -replace '-', '_'
$ForwardLlvm = $LlvmBin.Replace('\', '/')
$ForwardSysroot = $Sysroot.Replace('\', '/')
Set-Item -Path "env:CC_$EnvTriple" -Value (Join-Path $LlvmBin 'clang.exe').Replace('\', '/')
Set-Item -Path "env:CXX_$EnvTriple" -Value (Join-Path $LlvmBin 'clang++.exe').Replace('\', '/')
Set-Item -Path "env:AR_$EnvTriple" -Value $LlvmAr.Replace('\', '/')
Set-Item -Path "env:RANLIB_$EnvTriple" -Value $LlvmRanlib.Replace('\', '/')
Set-Item -Path "env:CFLAGS_$EnvTriple" -Value "--target=$RustTarget --sysroot=$ForwardSysroot -D__MUSL__"
Set-Item -Path "env:CXXFLAGS_$EnvTriple" -Value "--target=$RustTarget --sysroot=$ForwardSysroot -D__MUSL__"
Set-Item -Path "env:CARGO_TARGET_$($EnvTriple.ToUpper())_LINKER" -Value (Join-Path $LlvmBin 'clang.exe').Replace('\', '/')

# ring's build script assembles with clang, which needs a writable TMP; the
# default temp directory can be denied for the build user and the failure looks
# like "unable to make temporary file: Permission denied".
$TmpDir = Join-Path $AppDir 'rust\target-ohos\tmp'
New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null
Set-Item -Path env:TMP -Value $TmpDir
Set-Item -Path env:TEMP -Value $TmpDir
Set-Item -Path env:TMPDIR -Value $TmpDir

$ProfileArgs = @()
if ($Profile -eq 'release') { $ProfileArgs = @('--release') }
$ProfileDir = if ($Profile -eq 'release') { 'release' } else { 'debug' }

if (-not $SkipCodegen) {
    if (Get-Command flutter_rust_bridge_codegen -ErrorAction SilentlyContinue) {
        Write-Host '==> generating flutter_rust_bridge bindings...'
        Push-Location -LiteralPath $AppDir
        try {
            Invoke-NativeCommand -Exe 'flutter_rust_bridge_codegen' `
                -Arguments @('generate', '--config-file', 'flutter_rust_bridge.yaml') `
                -FailureMessage 'flutter_rust_bridge_codegen generate failed'
        }
        finally { Pop-Location }
    }
    else {
        Write-Host "==> flutter_rust_bridge_codegen $FrbVersion not found, reusing committed bindings (pass -SkipCodegen to silence)."
    }
}

Write-Host "==> cargo build --target $RustTarget ($Profile)..."
Push-Location -LiteralPath $AppDir
try {
    Invoke-NativeCommand -Exe 'cargo' `
        -Arguments (@('build', '--locked', '--manifest-path', $Manifest, '--target', $RustTarget) + $ProfileArgs) `
        -FailureMessage 'rust cross build failed'
}
finally { Pop-Location }

$BuiltSo = Join-Path $AppDir "rust\target-ohos\$RustTarget\$ProfileDir\libfqapi_core.so"
if (-not (Test-Path -LiteralPath $BuiltSo)) {
    Write-Error "rust build produced no $BuiltSo"
    exit 1
}

New-Item -ItemType Directory -Force -Path $LibsDir | Out-Null
$DestSo = Join-Path $LibsDir 'libfqapi_core.so'
Copy-Item -LiteralPath $BuiltSo -Destination $DestSo -Force
Write-Host "==> HAP libs: $DestSo"
Get-FileHash -Algorithm SHA256 -LiteralPath $DestSo | Format-List