#requires -Version 7.0
[CmdletBinding()]
param([string]$Version, [string]$PayloadDirectory, [switch]$TestHooks, [string]$OutputDirectory)
. "$PSScriptRoot/Msi.Common.ps1"
$repo = Split-Path $PSScriptRoot -Parent
if (!$Version) {
    $metadata = cargo metadata --locked --no-deps --format-version 1 --manifest-path "$repo/Cargo.toml" | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Cargo metadata failed.' }
    $Version = ($metadata.packages | Where-Object name -eq 'luma-desktop').version
}
Assert-LumaMsiVersion $Version
if (!$PayloadDirectory) { $PayloadDirectory = Join-Path $repo "target/releases/$Version/payload/Luma-windows-x64" }
$PayloadDirectory = (Resolve-Path -LiteralPath $PayloadDirectory).Path
foreach ($name in @('Luma.scr','LICENSE')) {
    if (!(Test-Path -LiteralPath (Join-Path $PayloadDirectory $name) -PathType Leaf)) { throw "Missing MSI payload: $name" }
}
$bytes = [IO.File]::ReadAllBytes((Join-Path $PayloadDirectory 'Luma.scr'))
if ($bytes.Length -lt 256 -or $bytes[0] -ne 77 -or $bytes[1] -ne 90 -or [BitConverter]::ToUInt16($bytes,[BitConverter]::ToInt32($bytes,60)+4) -ne 0x8664) { throw 'An x64 Windows payload is required.' }
$variant = if ($TestHooks) { 'test' } else { 'production' }
$out = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) } else { Join-Path $repo "target/msi/$Version/$variant" }
$null = New-Item -ItemType Directory -Path $out -Force
$nativeTarget = Join-Path $repo 'target/msi-native-production'
$arguments = @('build','--locked','--release','--manifest-path',"$repo/packaging/windows/msi/Cargo.toml",'--target-dir',$nativeTarget)
if ($TestHooks) { $arguments += @('--features','test-hooks') }
$savedRustFlags = $env:RUSTFLAGS
try {
    $env:RUSTFLAGS = (($savedRustFlags + ' -C target-feature=+crt-static').Trim())
    & cargo @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Native MSI custom-action build failed.' }
} finally { $env:RUSTFLAGS = $savedRustFlags }
$dll = Join-Path $out 'luma_msi_actions.dll'
Copy-Item -LiteralPath "$nativeTarget/release/luma_msi_actions.dll" -Destination $dll -Force
$license = Get-Content -LiteralPath "$repo/LICENSE" -Raw
$escaped = $license.Replace('\','\\').Replace('{','\{').Replace('}','\}').Replace("`r",'').Replace("`n",'\par ')
$escaped = -join ($escaped.ToCharArray() | ForEach-Object { if ([int]$_ -gt 127) { '\u' + [int][int16]$_ + '?' } else { [string]$_ } })
$rtf = Join-Path $out 'LICENSE.rtf'
Set-Content -LiteralPath $rtf -Value ('{\rtf1\ansi\deff0 {\fonttbl {\f0 Segoe UI;}}\f0\fs18 ' + $escaped + '}') -Encoding ASCII
$tools = Get-LumaWix
$msi = Join-Path $out "Luma-$Version-Setup-x64.msi"
& $tools.Compiler build -arch x64 -ext $tools.Extension -d "Version=$Version" -d "Payload=$PayloadDirectory" -d "Icon=$repo/packaging/windows/Luma.ico" -d "Actions=$dll" -d "LicenseRtf=$rtf" -d "TestHooks=$([int]$TestHooks.IsPresent)" -pdbtype none -o $msi "$repo/packaging/windows/msi/Setup.wxs"
if ($LASTEXITCODE -ne 0) { throw 'MSI compilation or validation failed.' }
& "$PSScriptRoot/verify-msi.ps1" -MsiPath $msi -PayloadDirectory $PayloadDirectory -Version $Version -TestHooks:$TestHooks
Write-Output $msi
