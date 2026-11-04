#requires -Version 7.0
# Shared, pinned compiler for production MSI and isolated integration packages.
$ErrorActionPreference = 'Stop'
function Get-FluxWix {
    $repo = Split-Path $PSScriptRoot -Parent
    $tools = Join-Path $repo 'target/tools/wix-production'
    $wix = Join-Path $tools 'wix.exe'
    if (!(Test-Path -LiteralPath $wix)) {
        & dotnet tool install wix --version 6.0.2 --tool-path $tools
        if ($LASTEXITCODE -ne 0) { throw 'Pinned WiX installation failed.' }
    }
    if ((& $wix --version) -notmatch '^6\.0\.2\+') { throw 'WiX 6.0.2 is required.' }
    $extension = Join-Path $tools '.wix/extensions/WixToolset.UI.wixext/6.0.2/wixext6/WixToolset.UI.wixext.dll'
    if (!(Test-Path -LiteralPath $extension)) {
        Push-Location $tools
        try {
            & $wix extension add WixToolset.UI.wixext/6.0.2
            if ($LASTEXITCODE -ne 0) { throw 'Pinned WiX UI installation failed.' }
        } finally { Pop-Location }
    }
    if (!(Test-Path -LiteralPath $extension)) { throw 'Pinned UI extension missing.' }
    return @{ Compiler=$wix; Extension=$extension }
}
function Assert-FluxMsiVersion([string]$Version) {
    if ($Version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') { throw 'A stable three-part version is required.' }
    $parts = $Version.Split('.')
    if ([int]$parts[0] -gt 255 -or [int]$parts[1] -gt 255 -or [int]$parts[2] -gt 65535) { throw 'Version exceeds MSI limits.' }
}
