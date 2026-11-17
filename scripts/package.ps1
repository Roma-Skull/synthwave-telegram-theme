#requires -Version 5.1
<#
.SYNOPSIS
    Packages Neon Horizon Synthwave Telegram theme release artifacts for Windows, Android, and iOS into dist/.
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Windows', 'Android', 'iOS')]
    [string]$Platform = 'All',
    [string]$Version,
    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$DistDir = Join-Path $RepoRoot 'dist'
New-Item -ItemType Directory -Path $DistDir -Force | Out-Null

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'generate_wallpapers.ps1') -RepoRoot $RepoRoot
    & (Join-Path $PSScriptRoot 'build_themes.ps1') -RepoRoot $RepoRoot
}

function Resolve-CleanVersion([string]$PlatformDir, [string]$OverrideVersion) {
    $raw = $OverrideVersion
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $vFile = Join-Path $PlatformDir 'VERSION'
        if (Test-Path $vFile) {
            $raw = (Get-Content -Path $vFile -Raw -Encoding UTF8).Trim()
        } else {
            $raw = '1.0.0'
        }
    }
    return ($raw.Trim() -replace '^(?:[a-zA-Z0-9_-]+-)?[vV]', '')
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

if ($Platform -eq 'All' -or $Platform -eq 'Windows') {
    $winDir = Join-Path $RepoRoot 'windows'
    $winVer = Resolve-CleanVersion $winDir $Version

    $srcTheme = Join-Path $winDir 'NeonHorizonSynthwave.tdesktop-theme'
    $srcColors = Join-Path $winDir 'colors.tdesktop-theme'
    $srcBg = Join-Path $winDir 'background.jpg'
    $srcReadme = Join-Path $winDir 'README.md'

    $distTheme = Join-Path $DistDir 'NeonHorizonSynthwave-windows.tdesktop-theme'
    Copy-Item -Path $srcTheme -Destination $distTheme -Force

    $pkgName = "NeonHorizonSynthwave-v$winVer-windows"
    $stage = Join-Path $DistDir $pkgName
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    Copy-Item $srcTheme (Join-Path $stage 'NeonHorizonSynthwave.tdesktop-theme') -Force
    Copy-Item $srcColors (Join-Path $stage 'colors.tdesktop-theme') -Force
    Copy-Item $srcBg (Join-Path $stage 'background.jpg') -Force
    if (Test-Path $srcReadme) { Copy-Item $srcReadme (Join-Path $stage 'README.md') -Force }

    $winZip = Join-Path $DistDir "$pkgName.zip"
    if (Test-Path $winZip) { Remove-Item $winZip -Force }
    Compress-Archive -Path "$stage\*" -DestinationPath $winZip -CompressionLevel Optimal -Force
    Remove-Item $stage -Recurse -Force

    $themeHash = (Get-FileHash -Path $distTheme -Algorithm SHA256).Hash.ToLowerInvariant()
    $zipHash = (Get-FileHash -Path $winZip -Algorithm SHA256).Hash.ToLowerInvariant()
    $themeSize = (Get-Item $distTheme).Length

    $winChecksums = Join-Path $DistDir 'checksums-windows-sha256.txt'
    [System.IO.File]::WriteAllLines($winChecksums, @(
        "$themeHash  $(Split-Path -Leaf $distTheme)"
        "$zipHash  $(Split-Path -Leaf $winZip)"
    ), $utf8NoBom)

    $winManifest = [ordered]@{
        schemaVersion = 1
        platform      = 'windows'
        client        = 'Telegram Desktop'
        tag           = "windows-v$winVer"
        version       = $winVer
        asset         = (Split-Path -Leaf $distTheme)
        zipAsset      = (Split-Path -Leaf $winZip)
        sha256        = $themeHash
        sizeBytes     = $themeSize
        releasedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    [System.IO.File]::WriteAllText((Join-Path $DistDir 'manifest-windows.json'), ($winManifest | ConvertTo-Json -Depth 4), $utf8NoBom)
}

if ($Platform -eq 'All' -or $Platform -eq 'Android') {
    $andDir = Join-Path $RepoRoot 'android'
    $andVer = Resolve-CleanVersion $andDir $Version

    $srcAt = Join-Path $andDir 'NeonHorizonSynthwave.attheme'
    $srcNoBg = Join-Path $andDir 'NeonHorizonSynthwave-no-bg.attheme'
    $srcBg = Join-Path $andDir 'background_android.jpg'
    $srcReadme = Join-Path $andDir 'README.md'

    $distAt = Join-Path $DistDir 'NeonHorizonSynthwave-android.attheme'
    $distNoBg = Join-Path $DistDir 'NeonHorizonSynthwave-no-bg-android.attheme'
    Copy-Item -Path $srcAt -Destination $distAt -Force
    Copy-Item -Path $srcNoBg -Destination $distNoBg -Force

    $pkgName = "NeonHorizonSynthwave-v$andVer-android"
    $stage = Join-Path $DistDir $pkgName
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    Copy-Item $srcAt (Join-Path $stage 'NeonHorizonSynthwave.attheme') -Force
    Copy-Item $srcNoBg (Join-Path $stage 'NeonHorizonSynthwave-no-bg.attheme') -Force
    Copy-Item $srcBg (Join-Path $stage 'background_android.jpg') -Force
    if (Test-Path $srcReadme) { Copy-Item $srcReadme (Join-Path $stage 'README.md') -Force }

    $andZip = Join-Path $DistDir "$pkgName.zip"
    if (Test-Path $andZip) { Remove-Item $andZip -Force }
    Compress-Archive -Path "$stage\*" -DestinationPath $andZip -CompressionLevel Optimal -Force
    Remove-Item $stage -Recurse -Force

    $atHash = (Get-FileHash -Path $distAt -Algorithm SHA256).Hash.ToLowerInvariant()
    $noBgHash = (Get-FileHash -Path $distNoBg -Algorithm SHA256).Hash.ToLowerInvariant()
    $zipHash = (Get-FileHash -Path $andZip -Algorithm SHA256).Hash.ToLowerInvariant()
    $atSize = (Get-Item $distAt).Length

    $andChecksums = Join-Path $DistDir 'checksums-android-sha256.txt'
    [System.IO.File]::WriteAllLines($andChecksums, @(
        "$atHash  $(Split-Path -Leaf $distAt)"
        "$noBgHash  $(Split-Path -Leaf $distNoBg)"
        "$zipHash  $(Split-Path -Leaf $andZip)"
    ), $utf8NoBom)

    $andManifest = [ordered]@{
        schemaVersion = 1
        platform      = 'android'
        client        = 'Telegram Android'
        tag           = "android-v$andVer"
        version       = $andVer
        asset         = (Split-Path -Leaf $distAt)
        noBgAsset     = (Split-Path -Leaf $distNoBg)
        zipAsset      = (Split-Path -Leaf $andZip)
        sha256        = $atHash
        sizeBytes     = $atSize
        releasedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    [System.IO.File]::WriteAllText((Join-Path $DistDir 'manifest-android.json'), ($andManifest | ConvertTo-Json -Depth 4), $utf8NoBom)
}

if ($Platform -eq 'All' -or $Platform -eq 'iOS') {
    $iosDir = Join-Path $RepoRoot 'ios'
    $iosVer = Resolve-CleanVersion $iosDir $Version

    $srcIos = Join-Path $iosDir 'NeonHorizonSynthwave.tgios-theme'
    $srcBg = Join-Path $iosDir 'background_ios.jpg'
    $srcReadme = Join-Path $iosDir 'README.md'

    $distIos = Join-Path $DistDir 'NeonHorizonSynthwave-ios.tgios-theme'
    Copy-Item -Path $srcIos -Destination $distIos -Force

    $pkgName = "NeonHorizonSynthwave-v$iosVer-ios"
    $stage = Join-Path $DistDir $pkgName
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    Copy-Item $srcIos (Join-Path $stage 'NeonHorizonSynthwave.tgios-theme') -Force
    Copy-Item $srcBg (Join-Path $stage 'background_ios.jpg') -Force
    if (Test-Path $srcReadme) { Copy-Item $srcReadme (Join-Path $stage 'README.md') -Force }

    $iosZip = Join-Path $DistDir "$pkgName.zip"
    if (Test-Path $iosZip) { Remove-Item $iosZip -Force }
    Compress-Archive -Path "$stage\*" -DestinationPath $iosZip -CompressionLevel Optimal -Force
    Remove-Item $stage -Recurse -Force

    $iosHash = (Get-FileHash -Path $distIos -Algorithm SHA256).Hash.ToLowerInvariant()
    $zipHash = (Get-FileHash -Path $iosZip -Algorithm SHA256).Hash.ToLowerInvariant()
    $iosSize = (Get-Item $distIos).Length

    $iosChecksums = Join-Path $DistDir 'checksums-ios-sha256.txt'
    [System.IO.File]::WriteAllLines($iosChecksums, @(
        "$iosHash  $(Split-Path -Leaf $distIos)"
        "$zipHash  $(Split-Path -Leaf $iosZip)"
    ), $utf8NoBom)

    $iosManifest = [ordered]@{
        schemaVersion = 1
        platform      = 'ios'
        client        = 'Telegram iOS'
        tag           = "ios-v$iosVer"
        version       = $iosVer
        asset         = (Split-Path -Leaf $distIos)
        zipAsset      = (Split-Path -Leaf $iosZip)
        sha256        = $iosHash
        sizeBytes     = $iosSize
        releasedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    [System.IO.File]::WriteAllText((Join-Path $DistDir 'manifest-ios.json'), ($iosManifest | ConvertTo-Json -Depth 4), $utf8NoBom)
}

Write-Host "Packaged release artifacts in ${DistDir}:"
Get-ChildItem $DistDir | Format-Table Name, Length -AutoSize
