[CmdletBinding()]
param([Parameter(Mandatory)][string]$SetupPath)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'packaging\windows\deployment.ps1')
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{AE5327E7-474B-47B6-BF01-2D5352A418AF}_is1'
if (Test-Path $uninstallKey) { throw 'An existing graphical Flux installation is registered. Run this test in a clean user account.' }
$directory = Join-Path $repo ('target\installer-test-' + [Guid]::NewGuid().ToString('N'))
$original = Get-FluxSelection
function Run-Checked($Executable, $Arguments) {
    $process = Start-Process -FilePath $Executable -ArgumentList $Arguments -WindowStyle Hidden -PassThru
    if (!$process.WaitForExit(60000)) { throw 'Installer timed out.' }
    if ($process.ExitCode -ne 0) { throw "Installer exit code: $($process.ExitCode)" }
}
function Run-Uninstall {
    $command = (Get-ItemProperty -LiteralPath $uninstallKey -Name UninstallString).UninstallString
    $executable = $command.Trim('"')
    if ([IO.Path]::GetDirectoryName($executable) -ne $directory -or !(Test-Path -LiteralPath $executable)) {
        throw 'Registered uninstaller is missing or outside the test installation.'
    }
    Run-Checked $executable @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART')
}
try {
    # Use a known existing previous saver; the exact original registry value is restored below.
    $previous = Join-Path $repo 'target\release\Flux.scr'
    Set-FluxSelection $previous
    $arguments = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/DIR="' + $directory + '"'))
    Run-Checked $SetupPath $arguments
    if ((Get-FluxSelection) -ne (Join-Path $directory 'Flux.scr')) { throw 'Setup did not select the installed saver.' }
    if (!(Test-Path $uninstallKey)) { throw 'Installed Apps registration is missing.' }
    Run-Checked $SetupPath $arguments
    $manifest = Get-Content -LiteralPath (Join-Path $directory 'installation.json') -Raw | ConvertFrom-Json
    if ($manifest.previousScreenSaver -ne $previous) { throw 'Update replaced the original screensaver selection.' }
    Run-Uninstall
    if ((Get-FluxSelection) -ne $previous) { throw 'Uninstall did not restore the original saver.' }
    if (Test-Path -LiteralPath (Join-Path $directory 'Flux.scr')) { throw 'Installed binary was not removed.' }
    if (Test-Path $uninstallKey) { throw 'Installed Apps entry was not removed.' }
    $payload = Join-Path (Split-Path $SetupPath -Parent) 'payload\Flux-windows-x64'
    Install-Flux $payload $directory
    Run-Checked $SetupPath $arguments
    $manifest = Get-Content -LiteralPath (Join-Path $directory 'installation.json') -Raw | ConvertFrom-Json
    if ($manifest.previousScreenSaver -ne $previous) { throw 'Script installation migration lost the original selection.' }
    Set-FluxSelection $previous
    Run-Uninstall
    if ((Get-FluxSelection) -ne $previous) { throw 'Uninstall overwrote a newer selection.' }
    Write-Output 'PASS: migration from script install and preservation of a newer selection.'
    Write-Output 'PASS: graphical install, update, registration, uninstall, and previous selection restoration.'
} finally { Set-FluxSelection $original }
