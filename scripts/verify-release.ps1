#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Directory,[Parameter(Mandatory)][string]$Version)
. "$PSScriptRoot/Msi.Common.ps1"
Assert-FluxMsiVersion $Version
$Directory = (Resolve-Path -LiteralPath $Directory).Path
$names = @("Flux-$Version-Setup-x64.msi","Flux-$Version-windows-x64.zip")
$lines = @(Get-Content -LiteralPath "$Directory/SHA256SUMS.txt")
if ($lines.Count -ne 2) { throw 'Exactly two release checksum entries are required.' }
foreach ($name in $names) {
    $rows = @($lines | Where-Object { $_ -cmatch ('\A[0-9a-f]{64}  '+[regex]::Escape($name)+'\z') })
    if ($rows.Count -ne 1 -or $rows[0].Substring(0,64) -cne (Get-FileHash -LiteralPath (Join-Path $Directory $name)).Hash.ToLowerInvariant()) { throw "Release checksum mismatch: $name" }
}
$work = Join-Path $Directory ('verify-' + [guid]::NewGuid().ToString('N'))
Expand-Archive -LiteralPath (Join-Path $Directory $names[1]) -DestinationPath $work
$payload = Join-Path $work 'Flux-windows-x64'
$expected = @('Flux.scr','LICENSE','deployment.ps1','Install.ps1','Install.cmd','Uninstall.ps1','Uninstall.cmd','README.txt','SHA256SUMS.txt')
$files = @(Get-ChildItem -LiteralPath $payload -File)
if ($files.Count -ne $expected.Count -or (Compare-Object ($files.Name | Sort-Object) ($expected | Sort-Object))) { throw 'Unexpected ZIP payload.' }
$inner = @(Get-Content -LiteralPath "$payload/SHA256SUMS.txt")
if ($inner.Count -ne 8) { throw 'Incorrect payload checksum count.' }
foreach ($name in ($expected | Where-Object { $_ -ne 'SHA256SUMS.txt' })) {
    $rows = @($inner | Where-Object { $_ -cmatch ('\A[0-9a-f]{64}  '+[regex]::Escape($name)+'\z') })
    if ($rows.Count -ne 1 -or $rows[0].Substring(0,64) -cne (Get-FileHash -LiteralPath "$payload/$name").Hash.ToLowerInvariant()) { throw "ZIP payload checksum mismatch: $name" }
}
& "$PSScriptRoot/verify-msi.ps1" -MsiPath (Join-Path $Directory $names[0]) -Version $Version -PayloadDirectory $payload
Write-Output 'PASS: exact release asset names, SHA-256 sums and all ZIP payload hashes.'
