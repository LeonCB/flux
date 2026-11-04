# Verify the real ZIP/graphical uninstall handoff without touching the registry or starting processes.
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('flux-handoff-' + [Guid]::NewGuid().ToString('N'))
$directory = Join-Path $root 'Flux/Screensaver'
$null = New-Item -ItemType Directory -Path $directory
$binary = Join-Path $directory 'unins001.exe'
[IO.File]::WriteAllText($binary, 'not an executable; process launching is mocked')
$oldLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = $root
$global:fluxHandoffTest = @{ Command = '"' + $binary + '"'; Launched = $null }
function Test-Path {
    param($LiteralPath, $PathType)
    if ($LiteralPath -like 'HKCU:*') { return $true }
    if ($PathType) { return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath -PathType $PathType }
    return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
}
function Get-ItemProperty {
    param($LiteralPath, $Name)
    if ($Name -ne 'UninstallString') { throw 'Unexpected registry lookup.' }
    return [pscustomobject]@{ UninstallString = $global:fluxHandoffTest.Command }
}
function Start-Process { param($FilePath) $global:fluxHandoffTest.Launched = $FilePath }
try {
    & "$PSScriptRoot/../packaging/windows/Uninstall.ps1"
    if ($global:fluxHandoffTest.Launched -ne $binary) { throw 'Did not use registered unins001.exe.' }
    foreach ($command in @('"C:\outside\unins001.exe"', ('"' + (Join-Path $directory 'missing.exe') + '"'))) {
        $global:fluxHandoffTest.Command = $command
        $global:fluxHandoffTest.Launched = $null
        $failed = $false
        try { & "$PSScriptRoot/../packaging/windows/Uninstall.ps1" } catch { $failed = $true }
        if (!$failed -or $null -ne $global:fluxHandoffTest.Launched) { throw 'Invalid uninstaller target was launched.' }
    }
    Write-Output 'PASS: registered unins001.exe, missing target, and installation-directory boundary; no registry writes or processes.'
} finally {
    $env:LOCALAPPDATA = $oldLocalAppData
    Remove-Variable -Name fluxHandoffTest -Scope Global
    Remove-Item -LiteralPath $binary
    Remove-Item -LiteralPath $directory
    Remove-Item -LiteralPath (Join-Path $root 'Flux')
    Remove-Item -LiteralPath $root
}
