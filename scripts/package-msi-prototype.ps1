[CmdletBinding()]
param(
    [string]$Version = '0.1.0',
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
$out = Join-Path $repo "target/msi-prototype/$Version"
New-Item -ItemType Directory -Path $out -Force | Out-Null
$license = Get-Content (Join-Path $source 'LICENSE') -Raw
$escaped = $license.Replace('\','\\').Replace('{','\{').Replace('}','\}').Replace("`r",'').Replace("`n",'\par ')
$rtf = Join-Path $out 'LICENSE.rtf'
Set-Content -LiteralPath $rtf -Value ('{\rtf1\ansi\deff0 {\fonttbl {\f0 Segoe UI;}}\f0\fs18 ' + $escaped + '}') -Encoding ASCII
$msi = Join-Path $out "Flux-$Version-MSI-Prototype-x64.msi"
& $WixPath build -arch x64 -ext $UiExtension -d "Version=$Version" -d "Payload=$source" -d "LicenseRtf=$rtf" -o $msi (Join-Path $repo 'packaging/windows/msi/Flux.wxs')
if ($LASTEXITCODE -ne 0) { throw 'MSI compilation or validation failed.' }
Get-FileHash -LiteralPath $msi -Algorithm SHA256 | ForEach-Object {
    '{0}  {1}' -f $_.Hash.ToLowerInvariant(), (Split-Path $_.Path -Leaf)
} | Set-Content (Join-Path $out 'SHA256SUMS.txt') -Encoding ASCII
Write-Output $msi
