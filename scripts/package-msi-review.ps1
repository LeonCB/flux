#requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$metadata = cargo metadata --locked --no-deps --format-version 1 --manifest-path "$repo/Cargo.toml" | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Cargo metadata failed.' }
$version = ($metadata.packages | Where-Object name -eq 'luma-desktop').version
$parts = $version.Split('.')
if ([int]$parts[2] -ge 65535) { throw 'Integration upgrade version exceeds MSI limits.' }
$upgradeVersion = "$($parts[0]).$($parts[1]).$([int]$parts[2] + 1)"
$release=Join-Path $repo "target/releases/$version"
& "$PSScriptRoot/verify-release.ps1" -Directory $release -Version $version
$stage=Join-Path $repo ('target/msi-review-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $stage
Expand-Archive -LiteralPath "$release/Luma-$version-windows-x64.zip" -DestinationPath $stage
$payload=Join-Path $stage 'Luma-windows-x64'
& "$PSScriptRoot/package-msi.ps1" -Version $version -PayloadDirectory $payload -TestHooks
& "$PSScriptRoot/package-msi.ps1" -Version $upgradeVersion -PayloadDirectory $payload -TestHooks
foreach($testVersion in @($version,$upgradeVersion)) {
    Copy-Item -LiteralPath "$repo/target/msi/$testVersion/test/Luma-$testVersion-Setup-x64.msi" -Destination "$stage/Luma-$testVersion-Integration-Test-x64.msi"
}
& "$PSScriptRoot/test-msi-rollback-probe.ps1" -WixPath "$repo/target/tools/wix-production/wix.exe" -BuildOnly | ForEach-Object {
    if($_ -is [string] -and $_.EndsWith('Probe.msi')) { Copy-Item -LiteralPath $_ -Destination "$stage/Probe.msi" }
}
foreach($script in @('test-msi-release.ps1','test-msi-rollback-probe.ps1')) { Copy-Item -LiteralPath "$PSScriptRoot/$script" -Destination $stage }
$instructions=@'
LUMA MSI TEST — NOT A PUBLIC RELEASE

Extract this folder on the comparison Windows PC. Close Luma, its preview and
Windows Screen Saver Settings. Use normal Windows PowerShell, NOT Run as admin.
No Rust, WiX or .NET SDK is needed. Tests temporarily change the selected saver
and attempt restoration/cleanup. Use a disposable Windows user if possible.
Do not run integration tests over an existing Luma MSI installation.

1. Open Windows PowerShell in this extracted folder and run:
   powershell -NoProfile -ExecutionPolicy Bypass -File .\test-msi-rollback-probe.ps1 -MsiPath .\Probe.msi

2. If that passes, run:
   powershell -NoProfile -ExecutionPolicy Bypass -File .\test-msi-release.ps1 -MsiPath .\Luma-__BASE_VERSION__-Integration-Test-x64.msi -UpgradeMsiPath .\Luma-__UPGRADE_VERSION__-Integration-Test-x64.msi -PayloadDirectory .\Luma-windows-x64

The two integration MSIs contain deliberate failure/report hooks and use the
production upgrade family. Never use them as your normal installed copy or scan
them as production release artifacts. Tests remove their installations.
If any step fails, keep the logs and report the error; do not delete installed
files manually. Logs contain local paths/user identifiers; do not publish them
without review. No data is sent over the network by these tests.

3. After both pass, test the separate production MSI manually: no UAC, Settings
and preview work, appearance settings retained, uninstall restores the prior saver.
Real Inno migration still needs its own check; these ZIP tests don't prove it.
'@
$instructions = $instructions.Replace('__BASE_VERSION__',$version).Replace('__UPGRADE_VERSION__',$upgradeVersion)
Set-Content -LiteralPath "$stage/README.txt" -Value $instructions -Encoding utf8
Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName | ForEach-Object {
    '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant(), [IO.Path]::GetRelativePath($stage,$_.FullName)
} | Set-Content -LiteralPath "$stage/SHA256SUMS.txt" -Encoding ASCII
$zip=Join-Path $repo 'target/Luma-MSI-Review.zip'
Compress-Archive -LiteralPath $stage -DestinationPath $zip -Force
Write-Output $zip
