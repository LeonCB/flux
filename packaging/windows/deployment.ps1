Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FluxSelection {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Control Panel\Desktop')
    try { if ($key) { return $key.GetValue('SCRNSAVE.EXE', $null) } } finally { if ($key) { $key.Dispose() } }
}

function Set-FluxSelection($Path) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Control Panel\Desktop')
    try {
        if ($null -eq $Path) { $key.DeleteValue('SCRNSAVE.EXE', $false) }
        else { $key.SetValue('SCRNSAVE.EXE', [string]$Path, [Microsoft.Win32.RegistryValueKind]::String) }
    } finally { $key.Dispose() }
}

function Get-FluxInstallDirectory {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is unavailable.' }
    Join-Path $env:LOCALAPPDATA 'Flux\Screensaver'
}

function Write-FluxFile($Source, $Destination) {
    $temporary = $Destination + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [System.IO.File]::Copy($Source, $temporary, $false)
        if ([System.IO.File]::Exists($Destination)) {
            [System.IO.File]::Replace($temporary, $Destination, [System.Management.Automation.Language.NullString]::Value)
        } else { [System.IO.File]::Move($temporary, $Destination) }
    } finally {
        if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) }
    }
}

function Install-Flux($SourceDirectory, $InstallDirectory) {
    $SourceDirectory = [System.IO.Path]::GetFullPath($SourceDirectory)
    $InstallDirectory = [System.IO.Path]::GetFullPath($InstallDirectory)
    if ($SourceDirectory -eq $InstallDirectory) { throw 'Run Install from the extracted package, not the installation directory.' }
    $files = @('Flux.scr','LICENSE','deployment.ps1','Uninstall.ps1','Uninstall.cmd')
    foreach ($file in $files) {
        if (!(Test-Path -LiteralPath (Join-Path $SourceDirectory $file) -PathType Leaf)) { throw "Package file missing: $file" }
    }
    $binary = Join-Path $SourceDirectory 'Flux.scr'
    $stream = [System.IO.File]::OpenRead($binary)
    try { if ($stream.ReadByte() -ne 77 -or $stream.ReadByte() -ne 90) { throw 'Flux.scr is not a Windows executable.' } } finally { $stream.Dispose() }
    $destination = Join-Path $InstallDirectory 'Flux.scr'
    $manifestPath = Join-Path $InstallDirectory 'installation.json'
    $existing = Test-Path -LiteralPath $manifestPath
    if ($existing) {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ($manifest.schema -ne 1) { throw 'Unsupported installation metadata.' }
    } else {
        # Capture the original choice once. Updates must not replace it with Flux itself.
        $manifest = [ordered]@{ schema=1; previousScreenSaver=(Get-FluxSelection) }
        if (Test-Path -LiteralPath $destination) { throw 'Unmanaged Flux.scr found in the installation folder. Move it before installing.' }
    }
    [void][System.IO.Directory]::CreateDirectory($InstallDirectory)
    if (!$existing) {
        [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    }
    # Replace the binary first. A running saver/preview must fail before registry changes.
    try { Write-FluxFile $binary $destination }
    catch { throw "Could not install Flux.scr. Close Flux and Windows Screen Saver Settings, then retry. $($_.Exception.Message)" }
    foreach ($file in $files | Where-Object { $_ -ne 'Flux.scr' }) {
        Write-FluxFile (Join-Path $SourceDirectory $file) (Join-Path $InstallDirectory $file)
    }

    Set-FluxSelection $destination
    Write-Output "Installed for the current user: $destination"
}

function Uninstall-Flux($InstallDirectory) {
    $InstallDirectory = [System.IO.Path]::GetFullPath($InstallDirectory)
    $manifestPath = Join-Path $InstallDirectory 'installation.json'
    if (!(Test-Path -LiteralPath $manifestPath)) { throw 'No managed Flux installation was found.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.schema -ne 1) { throw 'Unsupported installation metadata.' }
    $destination = Join-Path $InstallDirectory 'Flux.scr'
    # Check the executable before changing the user's selection.
    if (Test-Path -LiteralPath $destination) {
        try {
            $probe = [System.IO.File]::Open($destination, 'Open', 'ReadWrite', 'None')
            $probe.Dispose()
        } catch { throw 'Flux is in use. Close the screensaver, its settings, and the Windows preview, then retry.' }
    }
    $selection = Get-FluxSelection
    $selected = $selection -eq $destination
    if ($selected) {
        $previous = $manifest.previousScreenSaver
        if ($previous -and (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($previous)))) {
            Set-FluxSelection $previous
        } else { Set-FluxSelection $null }
    }
    try {
        if (Test-Path -LiteralPath $destination) { [System.IO.File]::Delete($destination) }
    } catch {
        if ($selected) { Set-FluxSelection $selection }
        throw
    }
    # Delete only owned, explicit files. Never recurse into the user preferences folder.
    foreach ($file in @('LICENSE','deployment.ps1','Uninstall.ps1','Uninstall.cmd','installation.json','Flux.log')) {
        $path = Join-Path $InstallDirectory $file
        if (Test-Path -LiteralPath $path -PathType Leaf) { [System.IO.File]::Delete($path) }
    }
    if (@(Get-ChildItem -LiteralPath $InstallDirectory -Force).Count -eq 0) {
        [System.IO.Directory]::Delete($InstallDirectory, $false)
    }
    Write-Output 'Flux uninstalled. Your preferences have been kept.'
}
