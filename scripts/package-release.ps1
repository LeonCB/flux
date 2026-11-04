#requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
& "$PSScriptRoot/package-windows.ps1"
Push-Location $repo
try {
    $metadata = cargo metadata --locked --no-deps --format-version 1 | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Cargo metadata failed.' }
    $version = ($metadata.packages | Where-Object name -eq 'flux-desktop').version
    $output = Join-Path $metadata.target_directory "releases/$version"
    $payload = Join-Path $output ('payload-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $payload
    Expand-Archive -LiteralPath "$($metadata.target_directory)/distribution/Flux-windows-x64.zip" -DestinationPath $payload
    $source = Join-Path $payload 'Flux-windows-x64'
    & "$PSScriptRoot/package-msi.ps1" -Version $version -PayloadDirectory $source
    Copy-Item -LiteralPath "$($metadata.target_directory)/msi/$version/production/Flux-$version-Setup-x64.msi" -Destination $output -Force
    Copy-Item -LiteralPath "$($metadata.target_directory)/distribution/Flux-windows-x64.zip" -Destination "$output/Flux-$version-windows-x64.zip" -Force
    @("Flux-$version-Setup-x64.msi","Flux-$version-windows-x64.zip") | ForEach-Object {
        '{0}  {1}' -f (Get-FileHash -LiteralPath (Join-Path $output $_) -Algorithm SHA256).Hash.ToLowerInvariant(), $_
    } | Set-Content -LiteralPath "$output/SHA256SUMS.txt" -Encoding ASCII
    & "$PSScriptRoot/verify-release.ps1" -Directory $output -Version $version
    Write-Output "Release packages: $output"
} finally { Pop-Location }
