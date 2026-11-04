#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PortableDirectory,
    [switch]$Child,
    [string]$ExpectedSid
)
$ErrorActionPreference = 'Stop'
$portable = (Resolve-Path -LiteralPath $PortableDirectory).Path
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
$elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Child) {
    if ($elevated -or $principal.Identity.User.Value -ne $ExpectedSid) { throw 'Probe must run as the expected standard user.' }
    # Alternate-credential processes can inherit the parent's environment.
    # Resolve the loaded account profile instead of using the runner's AppData.
    $profileKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$ExpectedSid"
    $profilePath = [Environment]::ExpandEnvironmentVariables((Get-ItemProperty -LiteralPath $profileKey).ProfileImagePath)
    $env:LOCALAPPDATA = Join-Path $profilePath 'AppData\Local'
    $env:APPDATA = Join-Path $profilePath 'AppData\Roaming'
    $env:TEMP = Join-Path $env:LOCALAPPDATA 'Temp'
    $env:TMP = $env:TEMP
    $null = New-Item -ItemType Directory -Path $env:TEMP -Force
    foreach ($policy in @('HKCU:\Software\Policies\Microsoft\Windows\Installer','HKLM:\Software\Policies\Microsoft\Windows\Installer')) {
        if ((Get-ItemProperty -LiteralPath $policy -Name AlwaysInstallElevated -ErrorAction SilentlyContinue).AlwaysInstallElevated -eq 1) { throw 'Elevated installer policy invalidates this comparison.' }
    }
    $context = @{ elevated=$elevated; accountSid=$ExpectedSid; profilePath=$profilePath; osCaption=(Get-CimInstance Win32_OperatingSystem).Caption }
    $context | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $portable 'account-context.json') -Encoding utf8
    Write-Output "Standard-user probe: Elevated=$elevated; OS=$($context.osCaption)"
    & (Join-Path $portable 'test-msi-rollback-probe.ps1') -MsiPath (Join-Path $portable 'Probe.msi')
    # A pass must not be a managed/elevated installation in disguise.
    $installationLogs = Get-ChildItem -LiteralPath (Join-Path $portable 'logs') -Filter install.log -Recurse
    if (!$installationLogs -or (Select-String -LiteralPath $installationLogs.FullName -Pattern '^Property\(S\): (MsiRunningElevated|Privileged) = 1' -Quiet)) { throw 'Missing logs or elevated MSI execution invalidates the standard-user pass.' }
    exit 0
}
# Account creation is confined to disposable GitHub-hosted runners.
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or !$elevated) { throw 'Run this harness only on an elevated, disposable GitHub-hosted Windows runner.' }
if (!(Test-Path -LiteralPath (Join-Path $portable 'Probe.msi')) -or !(Test-Path -LiteralPath (Join-Path $portable 'test-msi-rollback-probe.ps1'))) { throw 'Portable rollback probe files are missing.' }
$accountName = 'FluxMsi' + [guid]::NewGuid().ToString('N').Substring(0,10)
$accountPassword = ConvertTo-SecureString ('Flux!' + [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)) + 'a1') -AsPlainText -Force
$testUser = $null
$process = $null
$comparisonFolder = Join-Path $env:PUBLIC ('Flux-Msi-' + [guid]::NewGuid().ToString('N'))
$artifactFolder = Join-Path $portable 'standard-user-results'
$installerPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Installer'
$priorPolicyProperties = Get-ItemProperty -LiteralPath $installerPolicy -ErrorAction SilentlyContinue
$previousPolicy = if ($priorPolicyProperties) { $priorPolicyProperties.PSObject.Properties['DisableMSI'] } else { $null }
try {
    # Server runner defaults block unmanaged per-user MSI (1625). Permit the test
    # without granting elevation; restore the original policy in finally.
    if (!(Test-Path -LiteralPath $installerPolicy)) { $null = New-Item -Path $installerPolicy -Force }
    $null = New-ItemProperty -LiteralPath $installerPolicy -Name DisableMSI -Value 0 -PropertyType DWord -Force
    Write-Output 'Disposable CI runner: unmanaged MSI permitted; AlwaysInstallElevated remains disabled.'
    $testUser = New-LocalUser -Name $accountName -Password $accountPassword -AccountNeverExpires -Description 'Temporary Flux MSI test account'
    Add-LocalGroupMember -SID ([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')) -Member $testUser
    $null = New-Item -ItemType Directory -Path $comparisonFolder
    Copy-Item -LiteralPath (Join-Path $portable 'Probe.msi'),(Join-Path $portable 'test-msi-rollback-probe.ps1'),$PSCommandPath -Destination $comparisonFolder
    $directoryAcl = Get-Acl -LiteralPath $comparisonFolder
    $directoryAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($testUser.SID,'Modify','ContainerInherit, ObjectInherit','None','Allow'))
    Set-Acl -LiteralPath $comparisonFolder -AclObject $directoryAcl
    Start-Service seclogon
    $credential = [pscredential]::new("$env:COMPUTERNAME\$accountName",$accountPassword)
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $comparisonFolder 'test-msi-standard-user-ci.ps1') + '" -Child -ExpectedSid ' + $testUser.SID.Value + ' -PortableDirectory "' + $comparisonFolder + '"'
    $process = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList $arguments -Credential $credential -LoadUserProfile -WorkingDirectory $comparisonFolder -WindowStyle Hidden -RedirectStandardOutput (Join-Path $comparisonFolder 'stdout.txt') -RedirectStandardError (Join-Path $comparisonFolder 'stderr.txt') -PassThru
    if (!$process.WaitForExit(540000)) { throw 'Standard-user probe timed out; the disposable runner retains diagnostics. No process was forcibly terminated.' }
    $process.Refresh()
    Get-Content -LiteralPath (Join-Path $comparisonFolder 'stdout.txt')
    Get-Content -LiteralPath (Join-Path $comparisonFolder 'stderr.txt')
    if ($process.ExitCode -ne 0) { throw "Standard-user rollback probe failed with exit $($process.ExitCode)." }
} finally {
    if (Test-Path -LiteralPath $comparisonFolder) {
        $null = New-Item -ItemType Directory -Path $artifactFolder -Force
        Copy-Item -Path (Join-Path $comparisonFolder '*') -Destination $artifactFolder -Recurse
    }
    if ($testUser -and (!$process -or $process.HasExited)) { Remove-LocalUser -SID $testUser.SID }
    if ($previousPolicy) {
        $null = New-ItemProperty -LiteralPath $installerPolicy -Name DisableMSI -Value $previousPolicy.Value -PropertyType DWord -Force
    } else {
        Remove-ItemProperty -LiteralPath $installerPolicy -Name DisableMSI -ErrorAction SilentlyContinue
    }
}