[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'packaging\windows\deployment.ps1')
# Substitute only the registry boundary: these tests never touch Windows settings.
$script:selection = $null
function Get-FluxSelection { return $script:selection }
function Set-FluxSelection($Path) { $script:selection = $Path }
function Assert($condition, $message) { if (!$condition) { throw $message } }
$root = Join-Path $repo ('target\deployment-test-' + [Guid]::NewGuid().ToString('N'))
$source = Join-Path $root 'package'
$installed = Join-Path $root 'Flux\Screensaver'
[void][System.IO.Directory]::CreateDirectory($source)
[void][System.IO.Directory]::CreateDirectory((Split-Path $installed -Parent))
foreach ($file in @('LICENSE','deployment.ps1','Uninstall.ps1','Uninstall.cmd')) {
    [System.IO.File]::WriteAllText((Join-Path $source $file), 'fixture')
}
[System.IO.File]::WriteAllBytes((Join-Path $source 'Flux.scr'), [byte[]](77,90,1))
$previous = Join-Path $root 'previous.scr'
[System.IO.File]::WriteAllText($previous, 'previous saver')
$script:selection = $previous
$preferences = Join-Path (Split-Path $installed -Parent) 'settings.json'
[System.IO.File]::WriteAllText($preferences, '{"palette":"Freedom"}')
Install-Flux $source $installed
$binary = Join-Path $installed 'Flux.scr'
Assert ($script:selection -eq $binary) 'Install did not select Flux.'
[System.IO.File]::WriteAllBytes((Join-Path $source 'Flux.scr'), [byte[]](77,90,2))
$lock = [System.IO.File]::Open($binary, 'Open', 'ReadWrite', 'None')
try {
    $failed = $false
    try { Install-Flux $source $installed } catch { $failed = $true }
    Assert $failed 'Locked update should fail.'
    $failed = $false
    try { Uninstall-Flux $installed } catch { $failed = $true }
    Assert $failed 'Locked uninstall should fail.'
    Assert ($script:selection -eq $binary) 'Locked operations changed selection.'
} finally { $lock.Dispose() }
Install-Flux $source $installed
Assert ([System.IO.File]::ReadAllBytes($binary)[2] -eq 2) 'Update did not replace the executable.'
$state = Get-Content (Join-Path $installed 'installation.json') -Raw | ConvertFrom-Json
Assert ($state.previousScreenSaver -eq $previous) 'Update lost the original selection.'
Uninstall-Flux $installed
Assert ($script:selection -eq $previous) 'Uninstall did not restore the previous saver.'
Assert ((Get-Content $preferences -Raw) -eq '{"palette":"Freedom"}') 'Preferences were changed.'
Install-Flux $source $installed
$script:selection = 'another-screensaver.scr'
Uninstall-Flux $installed
Assert ($script:selection -eq 'another-screensaver.scr') 'Uninstall overwrote a newer selection.'
$script:selection = $null
Install-Flux $source $installed
Uninstall-Flux $installed
Assert ($null -eq $script:selection) 'Uninstall did not restore no selection.'
Write-Output 'PASS: install, update, locked files, original selection, newer selection, uninstall, and preference preservation.'
