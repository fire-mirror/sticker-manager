[CmdletBinding()]
param(
    [string]$FlutterRoot = $env:FLUTTER_ROOT,
    [string]$JavaHome,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

if ([string]::IsNullOrWhiteSpace($FlutterRoot)) {
    $flutterCommand = Get-Command flutter.bat -ErrorAction SilentlyContinue
    if ($flutterCommand) {
        $FlutterRoot = Split-Path (Split-Path $flutterCommand.Source -Parent) -Parent
    }
}
if ([string]::IsNullOrWhiteSpace($FlutterRoot)) {
    throw 'Flutter SDK not found. Set FLUTTER_ROOT or add flutter.bat to PATH.'
}
$flutter = Join-Path $FlutterRoot 'bin/flutter.bat'
$androidSdk = if ($env:ANDROID_SDK_ROOT) {
    $env:ANDROID_SDK_ROOT
} elseif ($env:ANDROID_HOME) {
    $env:ANDROID_HOME
} else {
    $null
}

if (-not (Test-Path -LiteralPath $flutter)) {
    throw "Flutter executable not found: $flutter"
}

# Prefer SDK paths already configured in Flutter. This keeps the release
# command reproducible when Java and the Android SDK are not on global PATH.
$flutterConfig = $null
try {
    $flutterConfig = (& $flutter config --machine 2>$null | ConvertFrom-Json -ErrorAction Stop)
} catch {
    # Explicit command-line/environment values remain valid with older SDKs.
}
if ([string]::IsNullOrWhiteSpace($androidSdk) -and $flutterConfig.'android-sdk') {
    $androidSdk = [string]$flutterConfig.'android-sdk'
}

function Get-JavaMajorVersion {
    param([Parameter(Mandatory)][string]$JdkDirectory)
    $java = Join-Path $JdkDirectory 'bin/java.exe'
    if (-not (Test-Path -LiteralPath $java)) { return 0 }
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $versionOutput = @(& $java -version 2>&1)
    $ErrorActionPreference = $previousErrorAction
    $versionText = $versionOutput -join "`n"
    $match = [regex]::Match($versionText, 'version\s+"(?<major>\d+)')
    if (-not $match.Success) { return 0 }
    $major = [int]$match.Groups['major'].Value
    if ($major -eq 1) {
        $legacy = [regex]::Match($versionText, 'version\s+"1\.(?<minor>\d+)')
        if ($legacy.Success) { return [int]$legacy.Groups['minor'].Value }
    }
    $major
}

if ([string]::IsNullOrWhiteSpace($JavaHome)) {
    $candidates = @()
    if ($env:JAVA_HOME) { $candidates += $env:JAVA_HOME }
    if ($flutterConfig.'jdk-dir') { $candidates += [string]$flutterConfig.'jdk-dir' }
    $candidates += @(
        (Join-Path ${env:ProgramFiles} 'Java/jdk-*'),
        (Join-Path ${env:ProgramFiles} 'Eclipse Adoptium/jdk-*'),
        (Join-Path ${env:LOCALAPPDATA} 'Programs/Eclipse Adoptium/jdk-*')
    )
    $expandedCandidates = foreach ($candidate in $candidates) {
        if ($candidate.Contains('*')) {
            Get-Item -Path $candidate -ErrorAction SilentlyContinue
        } else {
            Get-Item -LiteralPath $candidate -ErrorAction SilentlyContinue
        }
    }
    $JavaHome = $expandedCandidates |
        Where-Object { (Get-JavaMajorVersion $_.FullName) -ge 17 } |
        Sort-Object { Get-JavaMajorVersion $_.FullName } -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

$javaMajor = if ($JavaHome) { Get-JavaMajorVersion $JavaHome } else { 0 }
if ($javaMajor -lt 17) {
    throw "A JDK 17 or newer is required. Selected JAVA_HOME '$JavaHome' has Java $javaMajor."
}
if ([string]::IsNullOrWhiteSpace($androidSdk) -or
    -not (Test-Path -LiteralPath $androidSdk)) {
    throw 'Android SDK not found. Set ANDROID_SDK_ROOT (or ANDROID_HOME).'
}

$projectRootPrefix = $projectRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$running = Get-Process -Name 'sticker_manager' -ErrorAction SilentlyContinue | Where-Object {
    try {
        if (-not $_.Path) { return $false }
        $processPath = [IO.Path]::GetFullPath($_.Path)
        $processPath.StartsWith($projectRootPrefix, [StringComparison]::OrdinalIgnoreCase)
    } catch {
        $false
    }
}
if ($running) {
    $ids = ($running | ForEach-Object Id) -join ', '
    throw "Close running sticker-manager instances before building (PID: $ids). No process was terminated."
}

$env:JAVA_HOME = $JavaHome
$env:ANDROID_SDK_ROOT = $androidSdk
$env:PATH = "$JavaHome/bin;$FlutterRoot/bin;$env:PATH"

function Invoke-Flutter {
    param([Parameter(Mandatory)][string[]]$Arguments)
    Push-Location $projectRoot
    try {
        & $flutter @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Flutter command failed with exit code ${LASTEXITCODE}: flutter $($Arguments -join ' ')"
        }
    } finally {
        Pop-Location
    }
}

Invoke-Flutter @('pub', 'get')
if (-not $SkipTests) {
    Invoke-Flutter @('test')
    Invoke-Flutter @('analyze')
}
Invoke-Flutter @('build', 'windows', '--release')
Invoke-Flutter @('build', 'apk', '--release', '--target-platform', 'android-arm64')

$version = (Get-Content (Join-Path $projectRoot 'pubspec.yaml') | Select-String '^version:' | ForEach-Object { $_.Line.Split(':', 2)[1].Trim() })
$windowsOutput = Join-Path $projectRoot 'build/windows/x64/runner/Release'
$dist = Join-Path $projectRoot 'dist'
$archive = Join-Path $dist "sticker-manager-windows-x64-$version.zip"
$releaseReadme = Join-Path $projectRoot 'tool/release/README_FIRST.txt'
$releaseLauncher = Join-Path $projectRoot 'tool/release/Start-StickerManager.cmd'
if (-not (Test-Path -LiteralPath (Join-Path $windowsOutput 'sticker_manager.exe'))) {
    throw "Windows release executable was not produced: $windowsOutput"
}
foreach ($supportFile in @($releaseReadme, $releaseLauncher)) {
    if (-not (Test-Path -LiteralPath $supportFile)) {
        throw "Windows package support file was not found: $supportFile"
    }
}
New-Item -ItemType Directory -Force -Path $dist | Out-Null
if (Test-Path -LiteralPath $archive) {
    Remove-Item -LiteralPath $archive -Force
}
Compress-Archive -Path (Join-Path $windowsOutput '*') -DestinationPath $archive -CompressionLevel Optimal
Compress-Archive -Path $releaseReadme, $releaseLauncher -DestinationPath $archive -Update

Write-Output "Windows package: $archive"
Write-Output "Android APK: $(Join-Path $projectRoot 'build/app/outputs/flutter-apk/app-release.apk')"
Write-Output "Gradle Java runtime: $JavaHome (Java $javaMajor)"
$signingConfigured = @(
    $env:STICKER_RELEASE_STORE_FILE,
    $env:STICKER_RELEASE_STORE_PASSWORD,
    $env:STICKER_RELEASE_KEY_ALIAS,
    $env:STICKER_RELEASE_KEY_PASSWORD
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
Write-Output "Android signing: $(if ($signingConfigured.Count -eq 4) { 'configured release keystore' } else { 'debug key (testing only)' })"
