# Writes, from the signed release files in build/windows:
#   build/windows/RasterNest.appinstaller   update feed: Windows checks it and installs new versions automatically
#   winget-out/manifests/...                winget manifests for A2M4.RasterNest (MSIX) and A2M4.rnest (portable CLI)
# Usage (in the release workflow, after signing):  pwsh scripts/render-windows-manifests.ps1 -Repo owner/name
param(
    [Parameter(Mandatory)][string]$Repo,
    [string]$Dir = "build/windows",
    [string]$WingetOut = "winget-out"
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$v = (Get-Content VERSION -Raw).Trim()
$publisher = ([xml](Get-Content windows/src/RasterNest.App/Package.appxmanifest)).Package.Identity.Publisher
$identity = "A2M4.RasterNest"
$release = "https://github.com/$Repo/releases/download/v$v"
$latest = "https://github.com/$Repo/releases/latest/download"

function Sha256([string]$path) { (Get-FileHash $path -Algorithm SHA256).Hash }

# The publisher ID part of a package family name: base32 of the first 8 bytes of SHA-256(UTF-16 publisher).
function PublisherId([string]$p) {
    $hash = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::Unicode.GetBytes($p))
    $bits = (($hash[0..7] | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join '') + '0'
    $alphabet = '0123456789abcdefghjkmnpqrstvwxyz'
    -join (0..12 | ForEach-Object { $alphabet[[Convert]::ToInt32($bits.Substring($_ * 5, 5), 2)] })
}

# winget wants the hash of the package's signature file for MSIX.
function SignatureSha256([string]$bundle) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path $bundle))
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq 'AppxSignature.p7x' }
        if (-not $entry) { return $null }
        $s = $entry.Open()
        try { -join ([Security.Cryptography.SHA256]::Create().ComputeHash($s) | ForEach-Object { $_.ToString('X2') }) } finally { $s.Dispose() }
    } finally { $zip.Dispose() }
}

$bundle = Join-Path $Dir "RasterNest-$v.msixbundle"
$family = "${identity}_$(PublisherId $publisher)"
$bundleHash = Sha256 $bundle
$signatureHash = SignatureSha256 $bundle
Write-Host "Package family name: $family"

# --- App Installer feed (auto-updates for people who install from rasternest.app) ---
@"
<?xml version="1.0" encoding="utf-8"?>
<AppInstaller Uri="$latest/RasterNest.appinstaller" Version="$v.0"
              xmlns="http://schemas.microsoft.com/appx/appinstaller/2018">
  <MainBundle Name="$identity" Publisher="$publisher" Version="$v.0" Uri="$latest/RasterNest.msixbundle" />
  <UpdateSettings>
    <OnLaunch HoursBetweenUpdateChecks="12" ShowPrompt="false" UpdateBlocksActivation="false" />
    <AutomaticBackgroundTask />
  </UpdateSettings>
</AppInstaller>
"@ | Set-Content -Encoding utf8 (Join-Path $Dir "RasterNest.appinstaller")

# --- winget manifests ---
$schema = "1.28.0"
function Write-Manifest($id, $name, $body) {
    $parts = $id.Split('.')
    $folder = Join-Path $WingetOut "manifests/$($parts[0].Substring(0,1).ToLower())/$($parts[0])/$($parts[1])/$v"
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $kind = @{ "version.yaml" = "version"; "installer.installer.yaml" = "installer"; "locale.locale.en-US.yaml" = "defaultLocale" }[$name]
    $header = "# yaml-language-server: `$schema=https://aka.ms/winget-manifest.$kind.$schema.schema.json`n`n"
    Set-Content -Encoding utf8 -Path (Join-Path $folder "$id$($name.Substring($name.IndexOf('.')))") -Value ($header + $body.Trim() + "`n")
}

$locale = {
    param($id, $packageName, $short, $description, $tags)
    # Free text may contain colons: single-quote it for YAML.
    $q = { param($t) "'" + $t.Replace("'", "''") + "'" }
@"
PackageIdentifier: $id
PackageVersion: $v
PackageLocale: en-US
Publisher: Anthony Mineer
PublisherUrl: https://rasternest.app
PublisherSupportUrl: https://github.com/$Repo/issues
PackageName: $packageName
PackageUrl: https://rasternest.app
License: MIT
LicenseUrl: https://github.com/$Repo/blob/main/LICENSE
Copyright: $(& $q 'Copyright (c) 2026 RasterNest contributors')
ShortDescription: $(& $q $short)
Description: $(& $q $description)
Tags:
$(($tags | ForEach-Object { "- $_" }) -join "`n")
ReleaseNotesUrl: https://github.com/$Repo/releases/tag/v$v
ManifestType: defaultLocale
ManifestVersion: $schema
"@
}

foreach ($pkg in @(
    @{ Id = $identity; Name = "RasterNest"; Short = "Capture, annotate, record and share screenshots.";
       Description = "Open-source screenshot tool: capture an area, window or screen, mark it up with arrows, numbered steps, text, blur and more, record the screen to MP4 or GIF, and combine captures into one image.";
       Tags = @("screenshot", "screen-capture", "annotation", "screen-recorder", "gif", "ocr");
       Installer = @"
PackageIdentifier: $identity
PackageVersion: $v
MinimumOSVersion: 10.0.19041.0
InstallerType: msix
PackageFamilyName: $family
Installers:
- Architecture: x64
  InstallerUrl: $release/RasterNest-$v.msixbundle
  InstallerSha256: $bundleHash
  SignatureSha256: $signatureHash
- Architecture: arm64
  InstallerUrl: $release/RasterNest-$v.msixbundle
  InstallerSha256: $bundleHash
  SignatureSha256: $signatureHash
ManifestType: installer
ManifestVersion: $schema
"@ },
    @{ Id = "A2M4.rnest"; Name = "rnest"; Short = "RasterNest on the command line: capture, OCR, annotate, record and an MCP server for AI agents.";
       Description = "rnest captures windows and screens, reads text with positions, adds markup by naming what's on screen, records MP4 and GIF, builds step-by-step guides, and runs a Model Context Protocol server (rnest mcp) for Claude and other AI agents.";
       Tags = @("screenshot", "cli", "ocr", "mcp", "ai-agents", "screen-recorder");
       Installer = @"
PackageIdentifier: A2M4.rnest
PackageVersion: $v
MinimumOSVersion: 10.0.19041.0
InstallerType: zip
NestedInstallerType: portable
NestedInstallerFiles:
- RelativeFilePath: rnest.exe
  PortableCommandAlias: rnest
Commands:
- rnest
Installers:
- Architecture: x64
  InstallerUrl: $release/rnest-$v-windows-x64.zip
  InstallerSha256: $(Sha256 (Join-Path $Dir "rnest-$v-windows-x64.zip"))
- Architecture: arm64
  InstallerUrl: $release/rnest-$v-windows-arm64.zip
  InstallerSha256: $(Sha256 (Join-Path $Dir "rnest-$v-windows-arm64.zip"))
ManifestType: installer
ManifestVersion: $schema
"@ })) {
    $id = $pkg.Id
    Write-Manifest $id "version.yaml" @"
PackageIdentifier: $id
PackageVersion: $v
DefaultLocale: en-US
ManifestType: version
ManifestVersion: $schema
"@
    Write-Manifest $id "installer.installer.yaml" $pkg.Installer
    Write-Manifest $id "locale.locale.en-US.yaml" (& $locale $id $pkg.Name $pkg.Short $pkg.Description $pkg.Tags)
}
Get-ChildItem $WingetOut -Recurse -File | ForEach-Object { $_.FullName.Substring((Resolve-Path $WingetOut).Path.Length + 1) }
