[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MsiPath,
    [Parameter(Mandatory)][string]$UpgradeMsiPath
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'packaging/windows/deployment.ps1')
$folder = Join-Path $env:LOCALAPPDATA 'Flux\MSI-Prototype'
$state = 'HKCU:\Software\Flux\MsiPrototype'
if (Test-Path $folder) { throw 'Remove the existing MSI prototype before running this test.' }
$original = Get-FluxSelection
$protected = @((Join-Path $env:LOCALAPPDATA 'Flux/settings.json'), (Join-Path $env:LOCALAPPDATA 'Flux/Screensaver/Flux.scr'))
$before = @($protected | ForEach-Object { if (Test-Path $_) { (Get-FileHash $_).Hash } else { 'absent' } })
$logs = Join-Path $repo ('target/msi-tests-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $logs -Force | Out-Null
$script:step = 0
function Run-Msi($Package, $Operation, $Expected = 0) {
    $script:step++
    $log = Join-Path $logs "$script:step.log"
    $arguments = "$Operation `"$((Resolve-Path $Package).Path)`" /qn /norestart /L*v `"$log`""
    $process = Start-Process msiexec.exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
    if (!$process.WaitForExit(120000)) { throw "MSI timed out. See $log." }
    if ($process.ExitCode -ne $Expected) { throw "Expected MSI exit $Expected, got $($process.ExitCode). See $log" }
    if ($Expected -eq 1603 -and !(Select-String -LiteralPath $log -SimpleMatch 'A newer Flux MSI prototype is already installed.' -Quiet)) {
        throw "Installation failed for a reason other than downgrade prevention. See $log"
    }
    if ((Get-FluxSelection) -cne $original) { throw 'The prototype changed the screensaver selection.' }
}
$installed = $null
try {
    Run-Msi $MsiPath '/i'
    $installed = $MsiPath
    if ((Get-FileHash (Join-Path $folder 'Flux.scr')).Hash.ToLowerInvariant() -ne 'd85ff71abb7de287da02acdb7d159bb6c7da302d6c8d42b0b6bf56012c458ffc') { throw 'The installed payload differs from the published release.' }
    if (!(Get-ItemProperty $state -Name InstallDirectory -ErrorAction SilentlyContinue)) { throw 'Installation registration is missing.' }
    Run-Msi $MsiPath '/fa'
    Write-Output 'PASS: installation, repair, identical release payload and unchanged screensaver selection.'
    Run-Msi $UpgradeMsiPath '/i'
    $installed = $UpgradeMsiPath
    Run-Msi $MsiPath '/i' 1603
    Write-Output 'PASS: MSI major upgrade and downgrade prevention.'
    Run-Msi $UpgradeMsiPath '/x'
    $installed = $null
    if (Test-Path (Join-Path $folder 'Flux.scr')) { throw 'The payload was not removed.' }
    if (Get-ItemProperty $state -Name InstallDirectory -ErrorAction SilentlyContinue) { throw 'Installation metadata was not removed.' }
    Write-Output 'PASS: uninstall removes the prototype and preserves screensaver selection.'
} finally {
    if ($installed) { Run-Msi $installed '/x' }
}
$after = @($protected | ForEach-Object { if (Test-Path $_) { (Get-FileHash $_).Hash } else { 'absent' } })
if (Compare-Object $before $after) { throw 'Existing production files or settings changed.' }
Write-Output "PASS: production binary and preferences unchanged. Logs: $logs"
