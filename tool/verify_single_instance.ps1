[CmdletBinding()]
param(
    [string]$Executable,
    [int]$LaunchCount = 5,
    [int]$TimeoutSeconds = 15
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($Executable)) {
    $Executable = Join-Path $scriptRoot '..\build\windows\x64\runner\Release\sticker_manager.exe'
}
$resolvedExecutable = (Resolve-Path -LiteralPath $Executable).Path
$processName = [IO.Path]::GetFileNameWithoutExtension($resolvedExecutable)

function Get-AppProcesses {
    Get-Process -Name $processName -ErrorAction SilentlyContinue | Where-Object {
        try {
            $_.Path -and ((Resolve-Path -LiteralPath $_.Path).Path -ieq $resolvedExecutable)
        } catch {
            $false
        }
    }
}

$existing = @(Get-AppProcesses)
if ($existing.Count -gt 0) {
    $ids = ($existing | ForEach-Object Id) -join ', '
    throw "Refusing to run while sticker-manager is already running (PID: $ids). Close it first."
}

$started = @()
try {
    1..$LaunchCount | ForEach-Object {
        $started += Start-Process -FilePath $resolvedExecutable -PassThru
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 200
        $running = @(Get-AppProcesses)
    } while ($running.Count -gt 1 -and [DateTime]::UtcNow -lt $deadline)

    $running = @(Get-AppProcesses)
    if ($running.Count -ne 1) {
        $ids = ($running | ForEach-Object Id) -join ', '
        throw "Expected exactly one surviving instance, found $($running.Count) (PID: $ids)."
    }

    $duplicateCount = $LaunchCount - $running.Count
    if ($duplicateCount -ne ($LaunchCount - 1)) {
        throw "Expected $($LaunchCount - 1) duplicate processes to exit, observed $duplicateCount."
    }

    Write-Output "Single-instance check passed: $LaunchCount launches left one process (PID $($running[0].Id))."
} finally {
    $survivors = @(Get-AppProcesses)
    foreach ($process in $survivors) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    foreach ($process in $started) {
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }
}
