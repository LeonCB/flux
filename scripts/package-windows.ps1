[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Push-Location $repo
try {
    & (Join-Path $PSScriptRoot 'build-windows.ps1')
    $cargo = Get-Command cargo -ErrorAction SilentlyContinue
    $cargoPath = if ($cargo) { $cargo.Source } else { Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe' }
    $metadata = & $cargoPath metadata --locked --no-deps --format-version 1 | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Failed to read Cargo metadata.' }
    $exe = Join-Path $metadata.target_directory 'release\Flux.exe'
    $bytes = [System.IO.File]::ReadAllBytes($exe)
    $peOffset = [BitConverter]::ToInt32($bytes, 60)
    if ([BitConverter]::ToUInt16($bytes, $peOffset + 4) -ne 0x8664) { throw 'This package requires a Windows x64 build.' }
    $output = Join-Path $metadata.target_directory 'distribution'
    $stage = Join-Path $output ('stage-' + [Guid]::NewGuid().ToString('N'))
    $package = Join-Path $stage 'Flux-windows-x64'
    [void][System.IO.Directory]::CreateDirectory($package)
    Copy-Item -LiteralPath $exe -Destination (Join-Path $package 'Flux.scr')
    Copy-Item -LiteralPath (Join-Path $repo 'LICENSE') -Destination (Join-Path $package 'LICENSE')
    foreach ($file in @('Install.cmd','Install.ps1','Uninstall.cmd','Uninstall.ps1','deployment.ps1','README.txt')) {
        Copy-Item -LiteralPath (Join-Path $repo "packaging\windows\$file") -Destination (Join-Path $package $file)
    }
    $checksums = Get-ChildItem -LiteralPath $package -File | Sort-Object Name | ForEach-Object {
        '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name
    }
    $checksums | Set-Content -LiteralPath (Join-Path $package 'SHA256SUMS.txt') -Encoding ASCII
    $archive = Join-Path $output 'Flux-windows-x64.zip'
    Compress-Archive -LiteralPath $package -DestinationPath $archive -Force
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  Flux-windows-x64.zip" | Set-Content -LiteralPath ($archive + '.sha256') -Encoding ASCII
    Write-Output "Package ready: $archive"
} finally { Pop-Location }
