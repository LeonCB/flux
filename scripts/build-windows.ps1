[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Push-Location $repo
try {
    $cargoCommand = Get-Command cargo -ErrorAction SilentlyContinue
    if ($cargoCommand) { $cargo = $cargoCommand.Source }
    else { $cargo = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe' }
    if (!(Test-Path -LiteralPath $cargo)) { throw 'Rust/Cargo was not found. Install Rust with rustup.' }
    & $cargo build --locked --release -p flux-desktop
    if ($LASTEXITCODE -ne 0) { throw 'Flux build failed.' }
    $metadata = & $cargo metadata --locked --no-deps --format-version 1 | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Failed to read Cargo metadata.' }
    $release = Join-Path $metadata.target_directory 'release'
    $scrUpdated = $false
    try {
        Copy-Item -LiteralPath (Join-Path $release 'Flux.exe') -Destination (Join-Path $release 'Flux.scr')
        $scrUpdated = $true
    } catch {
        Write-Warning 'Flux.exe was built, but Flux.scr could not be replaced. Close the screensaver and Windows preview, then rebuild; or run scripts\package-windows.ps1 for a fresh install package.'
    }
    Copy-Item -LiteralPath (Join-Path $repo 'LICENSE') -Destination (Join-Path $release 'LICENSE')
    if ($scrUpdated) { Write-Host "Ready: $(Join-Path $release 'Flux.scr')" }
} finally { Pop-Location }
