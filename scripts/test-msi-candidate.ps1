[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MsiPath,
    [Parameter(Mandatory)][string]$UpgradeMsiPath,
    [string]$LegacySetupPath
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$folder = Join-Path $env:LOCALAPPDATA 'Flux\WindowsInstaller'
if (Test-Path $folder) { throw 'Remove the existing MSI candidate before running the tests.' }
$logs = Join-Path $repo ('target\msi-candidate-tests-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $logs -Force | Out-Null
$noLegacy = Join-Path $logs 'no-legacy-installation'
$legacy = Join-Path $logs 'legacy'
$payload = Join-Path $repo 'target\releases\0.1.0\payload\Flux-windows-x64'
$binary = Join-Path $folder 'Flux.scr'
$protectedFiles = @((Join-Path $env:LOCALAPPDATA 'Flux\settings.json'), (Join-Path $env:LOCALAPPDATA 'Flux\Screensaver\Flux.scr'))
$before = @($protectedFiles | ForEach-Object { if (Test-Path $_) { (Get-FileHash $_).Hash } else { 'absent' } })
$script:step = 0
$baseline = $null
$script:installed = $null
function Encode-Selection($Value) {
    if ($null -eq $Value) { return '-' }
    $bytes = [Text.Encoding]::Unicode.GetBytes($Value + [char]0)
    '1:' + [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
}
function Run-Msi($Package, $Operation, [string[]]$Options = @(), $Expected = 0, $LegacyFolder = $noLegacy) {
    # msiexec /f drops extra properties. Use the equivalent install/repair form.
    if ($Operation -eq '/fa') { $Operation = '/i'; $Options += @('REINSTALL=ALL','REINSTALLMODE=amus') }
    $script:step++
    $log = Join-Path $logs "$script:step.log"
    $report = Join-Path $logs "$script:step.json"
    $arguments = "$Operation `"$((Resolve-Path $Package).Path)`" /qn /norestart /L*v `"$log`" FLUX_REPORT=`"$report`" LEGACYFOLDER=`"$LegacyFolder`" " + ($Options -join ' ')
    $process = Start-Process msiexec.exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
    if (!$process.WaitForExit(120000)) { throw "MSI timed out: $log" }
    if ($process.ExitCode -ne $Expected) { throw "Expected exit $Expected, got $($process.ExitCode): $log" }
    if ($Options -contains 'FLUX_TEST_FAIL=1') {
        if (!(Select-String -LiteralPath $log -Pattern 'CustomAction Fail(Removal)?ForTest returned actual error code 1603' -Quiet)) { throw "The injected failure was not reached: $log" }
    } elseif ($Expected -eq 1603) {
        if (!(Select-String -LiteralPath $log -Pattern 'A newer Flux MSI candidate is already installed.' -SimpleMatch -Quiet)) { throw "Downgrade failed for an unexpected reason: $log" }
        return $null
    }
    Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
}
function Assert-Value($Actual, $Expected, $Message) { if ($Actual -cne $Expected) { throw $Message } }
function Run-Legacy($Executable, [string[]]$Options) {
    $process = Start-Process -FilePath $Executable -ArgumentList $Options -WindowStyle Hidden -PassThru
    if (!$process.WaitForExit(120000) -or $process.ExitCode -ne 0) { throw 'Legacy Inno Setup operation failed.' }
}
try {
    $script:installed = $MsiPath
    $r = Run-Msi $MsiPath '/i'
    $baseline = $r.original
    $initialOriginal = $baseline
    $oldPrototypeBinary = Join-Path $env:LOCALAPPDATA 'Flux\MSI-Prototype\Flux.scr'
    if ($baseline -eq (Encode-Selection $oldPrototypeBinary) -and !(Test-Path $oldPrototypeBinary) -and (Test-Path $protectedFiles[1])) {
        $baseline = Encode-Selection $protectedFiles[1]
        Write-Output 'Cleanup will replace a leftover, missing prototype selection with the existing production Flux copy.'
    }
    Assert-Value $r.selection (Encode-Selection $binary) 'Install did not select Flux in the Windows Installer user context.'
    if ((Get-FileHash $binary).Hash.ToLowerInvariant() -ne 'd85ff71abb7de287da02acdb7d159bb6c7da302d6c8d42b0b6bf56012c458ffc') { throw 'The payload differs from the published release.' }
    $backup = $r.previous
    $r = Run-Msi $MsiPath '/fa'
    Assert-Value $r.previous $backup 'Repair changed the previous-selection backup.'
    $r = Run-Msi $MsiPath '/x'
    $script:installed = $null
    Assert-Value $r.selection $initialOriginal 'Uninstall did not restore the exact original selection.'
    if (Test-Path $binary) { throw 'Uninstall left its payload behind.' }
    Write-Output 'PASS: activation, exact release payload, repair and previous-selection restoration.'

    $other = Join-Path $payload 'Flux.scr'
    $otherEncoded = Encode-Selection $other
    $r = Run-Msi $MsiPath '/i' @('FLUX_TEST_FAIL=1', "FLUX_TEST_SELECTION=$otherEncoded") 1603
    Assert-Value $r.selection $otherEncoded 'Install rollback did not restore the selection.'
    Assert-Value $r.previous '-' 'Install rollback left metadata behind.'
    if (Test-Path $binary) { throw 'Install rollback left its payload behind.' }
    $script:installed = $MsiPath
    $r = Run-Msi $MsiPath '/i' @('FLUX_TEST_SELECTION=-')
    $r = Run-Msi $MsiPath '/x'
    $script:installed = $null
    Assert-Value $r.selection '-' 'Uninstall did not restore an originally absent selection.'
    Write-Output 'PASS: install rollback and an originally absent screen saver.'

    $script:installed = $MsiPath
    $r = Run-Msi $MsiPath '/i'
    $backup = $r.previous
    $r = Run-Msi $MsiPath '/fa' @("FLUX_TEST_SELECTION=$otherEncoded")
    Assert-Value $r.selection $otherEncoded 'Repair overwrote a newer choice.'
    $r = Run-Msi $UpgradeMsiPath '/i'
    $script:installed = $UpgradeMsiPath
    Assert-Value $r.selection $otherEncoded 'Major upgrade overwrote a newer choice.'
    Assert-Value $r.previous $backup 'Major upgrade lost the original backup.'
    $null = Run-Msi $MsiPath '/i' @() 1603
    $r = Run-Msi $UpgradeMsiPath '/x'
    $script:installed = $null
    Assert-Value $r.selection $otherEncoded 'Uninstall overwrote a newer choice.'
    Write-Output 'PASS: major upgrade, downgrade prevention and preservation of a newer selection.'

    New-Item -ItemType Directory -Path $legacy -Force | Out-Null
    Copy-Item (Join-Path $payload 'Flux.scr') (Join-Path $legacy 'Flux.scr')
    $manifestJson = @{schema=1; previousScreenSaver=$other} | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $legacy 'installation.json'), $manifestJson, (New-Object Text.UTF8Encoding($false)))
    Set-Content (Join-Path $legacy 'keep.txt') 'User-owned file; migration must retain it.'
    $oldSelected = Encode-Selection (Join-Path $legacy 'Flux.scr')
    $r = Run-Msi $MsiPath '/i' @('FLUX_TEST_FAIL=1', "FLUX_TEST_SELECTION=$oldSelected") 1603 $legacy
    Assert-Value $r.selection $oldSelected 'Failed migration did not restore the old saver.'
    if (!(Test-Path (Join-Path $legacy 'Flux.scr'))) { throw 'Failed migration removed the legacy payload.' }
    $script:installed = $MsiPath
    $r = Run-Msi $MsiPath '/i' @() 0 $legacy
    Assert-Value $r.selection (Encode-Selection $binary) 'ZIP migration did not activate the new copy.'
    if ((Test-Path (Join-Path $legacy 'Flux.scr')) -or !(Test-Path (Join-Path $legacy 'keep.txt'))) { throw 'ZIP migration file ownership is incorrect.' }
    $r = Run-Msi $MsiPath '/x'
    $script:installed = $null
    Assert-Value $r.selection $otherEncoded 'ZIP migration lost the pre-Flux selection.'
    Write-Output 'PASS: ZIP migration, failed-migration rollback and preservation of unknown files.'

    if ($LegacySetupPath) {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{AE5327E7-474B-47B6-BF01-2D5352A418AF}_is1'
        if (Test-Path $key) { throw 'Use a clean Windows account for the actual Inno Setup migration test.' }
        Run-Legacy $LegacySetupPath @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',('/DIR="' + $legacy + '"'))
        $legacyManifest = Get-Content (Join-Path $legacy 'installation.json') -Raw | ConvertFrom-Json
        $expectedOriginal = Encode-Selection $legacyManifest.previousScreenSaver
        $script:installed = $MsiPath
        $r = Run-Msi $MsiPath '/i' @("FLUX_TEST_SELECTION=$oldSelected") 0 $legacy
        Assert-Value $r.selection (Encode-Selection $binary) 'Inno migration did not activate the new copy.'
        if (Test-Path $key) { throw 'Inno Setup registration survived migration.' }
        if (Test-Path (Join-Path $legacy 'Flux.scr')) { throw 'The registered uninstaller did not remove the old payload.' }
        $r = Run-Msi $MsiPath '/x'
        $script:installed = $null
        Assert-Value $r.selection $expectedOriginal 'Inno migration lost the pre-Flux selection.'
        Write-Output 'PASS: migration from the actual published Inno Setup installer.'
    }

    # Run this last: a broken Windows Installer rollback must not contaminate later cases.
    $script:installed = $MsiPath
    $r = Run-Msi $MsiPath '/i'
    $backup = $r.previous
    $r = Run-Msi $MsiPath '/x' @('FLUX_TEST_FAIL=1') 1603
    Assert-Value $r.selection (Encode-Selection $binary) 'Uninstall rollback did not restore the selected saver.'
    Assert-Value $r.previous $backup 'Uninstall rollback did not restore metadata.'
    if (!(Test-Path $binary)) { throw 'Uninstall rollback did not restore the payload.' }
    $r = Run-Msi $MsiPath '/x'
    $script:installed = $null
    if (Test-Path $binary) { throw 'Uninstall after rollback left its payload behind.' }
    Write-Output 'PASS: uninstall rollback and subsequent removal.'
} finally {
    if ($LegacySetupPath -and (Test-Path (Join-Path $legacy 'unins000.exe'))) {
        $legacyKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{AE5327E7-474B-47B6-BF01-2D5352A418AF}_is1'
        $registeredFolder = (Get-ItemProperty $legacyKey -Name InstallLocation -ErrorAction SilentlyContinue).InstallLocation
        if ($registeredFolder -and $registeredFolder.TrimEnd('\') -eq $legacy) {
            Run-Legacy (Join-Path $legacy 'unins000.exe') @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART')
        }
    }
    if ($null -ne $baseline) {
        # Run restoration inside the native MSI context, not a potentially different registry view.
        if (!$script:installed) { $null = Run-Msi $MsiPath '/i' @("FLUX_TEST_RESTORE=$baseline"); $script:installed = $MsiPath }
        # Restore MSI component ownership too if an injected failure broke engine rollback.
        $null = Run-Msi $script:installed '/fa'
        $r = Run-Msi $script:installed '/x' @("FLUX_TEST_RESTORE=$baseline")
        Assert-Value $r.postRestore $baseline 'Native test cleanup did not restore the original selection.'
    }
}
$after = @($protectedFiles | ForEach-Object { if (Test-Path $_) { (Get-FileHash $_).Hash } else { 'absent' } })
if (Compare-Object $before $after) { throw 'Production binary or preferences were changed.' }
Write-Output "PASS: production files and settings preserved; native user selection restored. Logs: $logs"
