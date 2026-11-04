[CmdletBinding()]
param([switch]$Windowed)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$saver = Join-Path $repo 'target\release\Flux.scr'
if (!(Test-Path -LiteralPath $saver)) { throw 'Build Flux first with scripts\build-windows.ps1.' }
$argument = if ($Windowed) { '--windowed' } else { '/s' }
# Launch the PE executable directly: the .scr shell association can replace arguments.
$info = [System.Diagnostics.ProcessStartInfo]::new($saver, $argument)
$info.UseShellExecute = $false
$info.WorkingDirectory = $repo
$info.EnvironmentVariables["RUST_LOG"] = "info"
[System.Diagnostics.Process]::Start($info) | Out-Null
