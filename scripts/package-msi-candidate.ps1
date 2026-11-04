[CmdletBinding()]
param(
    [string]$Version = '0.1.2',
    [switch]$TestHooks,
    [string]$WixPath,
    [string]$UiExtension
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (!$WixPath) { $WixPath = Join-Path $repo 'target/tools/wix/wix.exe' }
if (!$UiExtension) { $UiExtension = Join-Path $repo 'target/tools/wix/extensions/WixToolset.UI.wixext/5.0.2/wixext5/WixToolset.UI.wixext.dll' }
$source = Join-Path $repo 'target/releases/0.1.0/payload/Flux-windows-x64'
$expected = 'd85ff71abb7de287da02acdb7d159bb6c7da302d6c8d42b0b6bf56012c458ffc'
if ((Get-FileHash (Join-Path $source 'Flux.scr')).Hash.ToLowerInvariant() -ne $expected) {
    throw 'The prototype requires the exact published v0.1.0 Flux.scr for the antivirus comparison.'
}
$variant = if ($TestHooks) { 'test' } else { 'package' }
$out = Join-Path $repo "target/msi-candidate/$Version/$variant"
New-Item -ItemType Directory -Path $out -Force | Out-Null
$candidatePayload = Join-Path $out 'payload'
New-Item -ItemType Directory -Path $candidatePayload -Force | Out-Null
Copy-Item (Join-Path $source 'Flux.scr') $candidatePayload -Force
Copy-Item (Join-Path $repo 'LICENSE') $candidatePayload -Force
$nativeTarget = Join-Path $repo 'target/msi-native'
$cargoArguments = @('build','--locked','--offline','--release','--manifest-path',(Join-Path $repo 'packaging/windows/msi/Cargo.toml'),'--target-dir',$nativeTarget)
$features = if ($TestHooks) { 'candidate-identity,test-hooks' } else { 'candidate-identity' }
$cargoArguments += @('--features',$features)
$savedRustFlags = $env:RUSTFLAGS
try {
    $env:RUSTFLAGS = (($savedRustFlags + ' -C target-feature=+crt-static').Trim())
    & cargo @cargoArguments
    if ($LASTEXITCODE -ne 0) { throw 'Native MSI action compilation failed.' }
} finally { $env:RUSTFLAGS = $savedRustFlags }
if ($LASTEXITCODE -ne 0) { throw 'Native MSI action compilation failed.' }
$dll = Join-Path $out 'flux_msi_actions.dll'
Copy-Item (Join-Path $nativeTarget 'release/flux_msi_actions.dll') $dll -Force
$license = Get-Content (Join-Path $candidatePayload 'LICENSE') -Raw
$escaped = $license.Replace('\','\\').Replace('{','\{').Replace('}','\}').Replace("`r",'').Replace("`n",'\par ')
$rtf = Join-Path $out 'LICENSE.rtf'
$escaped = -join ($escaped.ToCharArray() | ForEach-Object { if ([int]$_ -gt 127) { '\u' + [int][int16]$_ + '?' } else { [string]$_ } })
Set-Content -LiteralPath $rtf -Value ('{\rtf1\ansi\deff0 {\fonttbl {\f0 Segoe UI;}}\f0\fs18 ' + $escaped + '}') -Encoding ASCII
$msi = Join-Path $out "Flux-$Version-MSI-Candidate-x64.msi"
& $WixPath build -arch x64 -ext $UiExtension -d "Version=$Version" -d "Payload=$candidatePayload" -d "Actions=$dll" -d "LicenseRtf=$rtf" -d "TestHooks=$([int]$TestHooks.IsPresent)" -o $msi (Join-Path $repo 'packaging/windows/msi/Candidate.wxs')
if ($LASTEXITCODE -ne 0) { throw 'MSI compilation or validation failed.' }
Get-FileHash -LiteralPath $msi,$dll -Algorithm SHA256 | ForEach-Object {
    '{0}  {1}' -f $_.Hash.ToLowerInvariant(), (Split-Path $_.Path -Leaf)
} | Set-Content (Join-Path $out 'SHA256SUMS.txt') -Encoding ASCII
Write-Output $msi
