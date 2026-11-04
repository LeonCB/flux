#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$MsiPath, [Parameter(Mandatory)][string]$PayloadDirectory, [Parameter(Mandatory)][string]$Version, [switch]$TestHooks)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Msi.Common.ps1"
$installer = New-Object -ComObject WindowsInstaller.Installer
$db = $installer.OpenDatabase((Resolve-Path -LiteralPath $MsiPath).Path,0)
function Read-Table([string]$Sql, [int]$Columns = 2) {
    $view = $db.OpenView($Sql)
    try {
        $null = $view.Execute()
        while ($record = $view.Fetch()) {
            $values = for ($i=1; $i -le $Columns; $i++) { $record.StringData($i) }
            ,$values
        }
    } finally { $null = $view.Close(); [Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) | Out-Null }
}
function Assert($Value,$Message) { if (!$Value) { throw $Message } }
try {
    $properties = @{}
    foreach ($row in (Read-Table 'SELECT `Property`, `Value` FROM `Property`')) { $properties[$row[0]]=$row[1] }
    Assert ($properties.ProductName -eq 'Flux' -and $properties.ProductVersion -eq $Version) 'Incorrect MSI identity/version.'
    Assert ($properties.UpgradeCode -eq '{A51E59BE-C086-48C8-8BDA-B382C44316AE}') 'Incorrect production upgrade family.'
    Assert (!$properties.ALLUSERS) 'MSI must remain per-user.'
    Assert ($properties.ARPPRODUCTICON -ceq 'FluxAppIcon.ico') 'Installed Apps must use the Flux icon.'
    $icons = @(Read-Table 'SELECT `Name` FROM `Icon`' 1)
    Assert ($icons -ccontains $properties.ARPPRODUCTICON) 'The application icon must be embedded in the MSI Icon table.'
    $summary = $db.SummaryInformation(0)
    Assert ($summary.Property(7) -like 'x64*') 'MSI must be x64.'
    Assert (([int]$summary.Property(15) -band 8) -ne 0) 'MSI must declare that elevation is not required.'
    $files = @(Read-Table 'SELECT `File`, `FileName`, `FileSize` FROM `File`' 3)
    Assert ($files.Count -eq 2) 'Production payload must contain only the saver and MIT license.'
    foreach ($name in @('Flux.scr','LICENSE')) {
        $rows = @($files | Where-Object { ($_[1] -split '\|')[-1] -eq $name })
        Assert ($rows.Count -eq 1 -and [long]$rows[0][2] -eq (Get-Item -LiteralPath (Join-Path $PayloadDirectory $name)).Length) "Incorrect MSI payload: $name"
    }
    # Decompile without installing; compare the actual embedded bytes, not only sizes.
    $extract = Join-Path (Split-Path (Resolve-Path -LiteralPath $MsiPath).Path -Parent) ('verify-' + [guid]::NewGuid().ToString('N'))
    $tools = Get-FluxWix
    & $tools.Compiler msi decompile (Resolve-Path -LiteralPath $MsiPath).Path -x $extract -o (Join-Path $extract 'Package.wxs')
    if ($LASTEXITCODE -ne 0) { throw 'MSI extraction failed.' }
    $embeddedIcon = Join-Path $extract ('Icon/' + $properties.ARPPRODUCTICON)
    $sourceIcon = Join-Path (Split-Path $PSScriptRoot -Parent) 'packaging/windows/Flux.ico'
    Assert ((Test-Path -LiteralPath $embeddedIcon) -and (Get-FileHash -LiteralPath $embeddedIcon).Hash -eq (Get-FileHash -LiteralPath $sourceIcon).Hash) 'The embedded Installed Apps icon differs from the Flux asset.'
    foreach ($row in $files) {
        $name = ($row[1] -split '\|')[-1]
        $embedded = @(Get-ChildItem -LiteralPath $extract -Recurse -File | Where-Object Name -eq $row[0])
        Assert ($embedded.Count -eq 1 -and (Get-FileHash -LiteralPath $embedded[0].FullName).Hash -eq (Get-FileHash -LiteralPath (Join-Path $PayloadDirectory $name)).Hash) "Embedded MSI payload differs from ZIP: $name"
    }
    $actions = @(Read-Table 'SELECT `Action`, `Type`, `Target` FROM `CustomAction`' 3)
    Assert (@($actions | Where-Object { $_[2] -match '(?i)powershell|cmd\.exe|executionpolicy' }).Count -eq 0) 'MSI must not run an interpreter.'
    Assert (@($actions | Where-Object { $_[0] -match 'Test|FailFor|FailRemoval' }).Count -eq $(if ($TestHooks) {4} else {0})) 'Unexpected test hooks in MSI.'
    foreach ($name in @('RollbackSelection','ChangeSelection','ChangeRemoval','CommitLegacy')) {
        $row = @($actions | Where-Object { $_[0] -eq $name })[0]
        Assert ($null -ne $row -and ([int]$row[1] -band 2048) -eq 0) "Custom action must impersonate the current user: $name"
    }
    Assert ($properties.MSIRESTARTMANAGERCONTROL -eq 'Disable') 'MSI must not force-close running applications.'
    Assert ($properties.SecureCustomProperties -match 'LEGACY_UNINSTALL' -and $properties.MsiHiddenProperties -match 'LEGACY_UNINSTALL') 'Legacy client snapshot must be secure and hidden.'
    Write-Output 'PASS: MSI identity, version, per-user/no-elevation scope, native actions, Installed Apps icon and payload metadata.'
} finally {
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($db) | Out-Null
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer) | Out-Null
}
