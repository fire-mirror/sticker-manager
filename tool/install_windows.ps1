[CmdletBinding()]
param(
    [string]$Source,
    [string]$InstallRoot,
    [switch]$CreateDesktopShortcut,
    [switch]$Launch
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = (Resolve-Path (Join-Path $scriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($Source)) {
    $Source = Join-Path $projectRoot 'build/windows/x64/runner/Release'
}
if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs/StickerManager'
}

$sourceRoot = (Resolve-Path -LiteralPath $Source).Path
$sourceExecutable = Join-Path $sourceRoot 'sticker_manager.exe'
if (-not (Test-Path -LiteralPath $sourceExecutable)) {
    throw "Release executable not found: $sourceExecutable"
}

$destinationRoot = [IO.Path]::GetFullPath($InstallRoot)
$sourceKey = $sourceRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$destinationKey = $destinationRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if ($destinationRoot.TrimEnd('\', '/') -ieq $sourceRoot.TrimEnd('\', '/') -or
    $destinationKey.StartsWith($sourceKey, [StringComparison]::OrdinalIgnoreCase)) {
    throw "InstallRoot must be outside the Release source directory."
}
$destinationExecutable = Join-Path $destinationRoot 'sticker_manager.exe'
$processName = [IO.Path]::GetFileNameWithoutExtension($destinationExecutable)
$running = Get-Process -Name $processName -ErrorAction SilentlyContinue | Where-Object {
    try {
        $_.Path -and ((Resolve-Path -LiteralPath $_.Path).Path -ieq $destinationExecutable)
    } catch {
        $false
    }
}
if ($running) {
    $ids = ($running | ForEach-Object Id) -join ', '
    throw "Close the installed Sticker Manager before upgrading it (PID: $ids). No process was terminated."
}

New-Item -ItemType Directory -Force -Path $destinationRoot | Out-Null
Copy-Item -Path (Join-Path $sourceRoot '*') -Destination $destinationRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $scriptRoot 'uninstall_windows.ps1') `
    -Destination (Join-Path $destinationRoot 'uninstall_windows.ps1') -Force

$marker = [ordered]@{
    product = 'Sticker Manager'
    installedAt = [DateTime]::UtcNow.ToString('O')
    source = $sourceRoot
}
$marker | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $destinationRoot '.sticker-manager-install.json') -Encoding UTF8

$startMenu = Join-Path $env:APPDATA 'Microsoft/Windows/Start Menu/Programs'
New-Item -ItemType Directory -Force -Path $startMenu | Out-Null
$shell = New-Object -ComObject WScript.Shell
function New-AppShortcut {
    param([Parameter(Mandatory)][string]$Path)
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $destinationExecutable
    $shortcut.WorkingDirectory = $destinationRoot
    $shortcut.IconLocation = "$destinationExecutable,0"
    $shortcut.Save()
}

New-AppShortcut (Join-Path $startMenu 'Sticker Manager.lnk')
if ($CreateDesktopShortcut) {
    New-AppShortcut (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Sticker Manager.lnk')
}

Write-Output "Installed Sticker Manager to $destinationRoot"
Write-Output "Start menu shortcut: $(Join-Path $startMenu 'Sticker Manager.lnk')"
if ($Launch) {
    Start-Process -FilePath $destinationExecutable -WorkingDirectory $destinationRoot | Out-Null
}
