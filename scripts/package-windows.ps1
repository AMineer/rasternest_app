# Builds the Windows release files (unsigned; the release workflow signs them, then zips rnest with -ZipOnly):
#   build/windows/RasterNest-<v>.msixbundle          the app, x64 + ARM64
#   build/windows/rnest-<v>-windows-x64.zip           rnest.exe (self-contained, one file)
#   build/windows/rnest-<v>-windows-arm64.zip
# Run from the repo root on Windows:  pwsh scripts/package-windows.ps1
param(
    [string]$Out = "build/windows",
    [string[]]$Arch = @("x64", "arm64"),
    # Leave rnest.exe unzipped in <Out>/rnest-<arch>/ so it can be signed first.
    [switch]$SkipZip,
    # Only zip the (signed) rnest.exe files left by an earlier -SkipZip run.
    [switch]$ZipOnly
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$version = (Get-Content VERSION -Raw).Trim()
$out = New-Item -ItemType Directory -Force -Path $Out

function Zip-Rnest($a) {
    $zip = Join-Path $out "rnest-$version-windows-$a.zip"
    if (Test-Path $zip) { Remove-Item $zip }
    Compress-Archive -Path (Join-Path $out "rnest-$a\rnest.exe"), "LICENSE" -DestinationPath $zip
}

if ($ZipOnly) {
    foreach ($a in $Arch) { Zip-Rnest $a; Remove-Item -Recurse -Force (Join-Path $out "rnest-$a") }
    Get-ChildItem $out | Format-Table Name, Length
    return
}

$work = Join-Path $out "work"
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory -Force -Path $work | Out-Null

# The app: one MSIX per architecture, then a bundle.
$bundleDir = New-Item -ItemType Directory -Force -Path (Join-Path $work "bundle")
foreach ($a in $Arch) {
    $pkgDir = Join-Path $work "msix-$a"
    dotnet publish windows/src/RasterNest.App -c Release -r "win-$a" -p:Platform=$a -p:WindowsPackageType=MSIX `
        "-p:AppxPackageDir=$pkgDir\" --nologo
    if ($LASTEXITCODE -ne 0) { throw "App build failed for $a" }
    $msix = Get-ChildItem $pkgDir -Recurse -Filter *.msix | Select-Object -First 1
    if (-not $msix) { throw "No MSIX was produced for $a" }
    Copy-Item $msix.FullName (Join-Path $bundleDir "RasterNest_$a.msix")
}

# MakeAppx comes with the Windows SDK build tools NuGet package the app already restores.
$makeappx = Get-ChildItem "$env:USERPROFILE\.nuget\packages\microsoft.windows.sdk.buildtools" -Recurse -Filter makeappx.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\x64\\' } | Sort-Object FullName -Descending | Select-Object -First 1
if (-not $makeappx) {
    $makeappx = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse -Filter makeappx.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\x64\\' } | Sort-Object FullName -Descending | Select-Object -First 1
}
if (-not $makeappx) { throw "makeappx.exe not found (Windows SDK build tools)." }
$bundle = Join-Path $out "RasterNest-$version.msixbundle"
& $makeappx.FullName bundle /d $bundleDir /p $bundle /bv "$version.0" /o
if ($LASTEXITCODE -ne 0) { throw "makeappx bundle failed" }

# The command-line tool: one self-contained exe per architecture, zipped.
foreach ($a in $Arch) {
    $pub = Join-Path $work "rnest-$a"
    dotnet publish windows/src/rnest -c Release -r "win-$a" -o $pub --nologo -p:DebugType=embedded
    if ($LASTEXITCODE -ne 0) { throw "rnest build failed for $a" }
    $dest = New-Item -ItemType Directory -Force -Path (Join-Path $out "rnest-$a")
    Copy-Item (Join-Path $pub "rnest.exe") $dest
    if (-not $SkipZip) { Zip-Rnest $a; Remove-Item -Recurse -Force $dest }
}

Remove-Item -Recurse -Force $work
Get-ChildItem $out | Format-Table Name, Length
