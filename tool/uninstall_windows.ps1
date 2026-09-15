[CmdletBinding()]
param(
    [string]$InstallRoot
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Join-Path $env:LOCALAPPDATA 'Programs/StickerManager'
}
$destinationRoot = [IO.Path]::GetFullPath($InstallRoot)
$markerPath = Join-Path $destinationRoot '.sticker-manager-install.json'
if (-not (Test-Path -LiteralPath $markerPath)) {
    throw "Sticker Manager install marker not found: $markerPath"
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
    throw "Close the installed Sticker Manager before uninstalling it (PID: $ids). No process was terminated."
}

$startShortcut = Join-Path $env:APPDATA 'Microsoft/Windows/Start Menu/Programs/Sticker Manager.lnk'
$desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Sticker Manager.lnk'
foreach ($shortcut in @($startShortcut, $desktopShortcut)) {
    if (Test-Path -LiteralPath $shortcut) {
        Remove-Item -LiteralPath $shortcut -Force
    }
}
Remove-Item -LiteralPath $destinationRoot -Recurse -Force
Write-Output "Uninstalled Sticker Manager from $destinationRoot"
