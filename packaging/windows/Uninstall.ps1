[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'deployment.ps1')
$setupKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{AE5327E7-474B-47B6-BF01-2D5352A418AF}_is1'
if (Test-Path -LiteralPath $setupKey) {
    $setupUninstaller = (Get-ItemProperty -LiteralPath $setupKey -Name UninstallString).UninstallString.Trim('"')
    if ([IO.Path]::GetDirectoryName($setupUninstaller) -ne (Get-FluxInstallDirectory) -or !(Test-Path -LiteralPath $setupUninstaller -PathType Leaf)) {
        throw 'The registered Flux uninstaller is missing or outside the managed installation.'
    }
    Start-Process -FilePath $setupUninstaller
    return
}
Uninstall-Flux (Get-FluxInstallDirectory)
