[CmdletBinding()]
param(
    [string]$WixPath,
    [ValidateSet('x64','x86')][string]$Architecture = 'x64',
    [string]$MsiPath,
    [switch]$BuildOnly
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (!$WixPath) { $WixPath = Join-Path $repo 'target\tools\wix\wix.exe' }
$folder = Join-Path $env:LOCALAPPDATA 'Flux\MSI-Rollback-Probe'
if (Test-Path -LiteralPath $folder) { throw 'An existing rollback probe is present. Remove it through Windows Installer before testing.' }
$outputRoot = if ($MsiPath) { Join-Path $PSScriptRoot 'logs' } else { Join-Path $repo 'target' }
$out = Join-Path $outputRoot ('msi-rollback-probe-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $out | Out-Null
$source = Join-Path $out 'Probe.wxs'
$package = Join-Path $out 'Probe.msi'
$upgrade = [guid]::NewGuid().ToString()
$component = [guid]::NewGuid().ToString()
$wxs = @'
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">
  <Package Name="Flux MSI Rollback Probe" Manufacturer="Flux" Version="0.0.1" UpgradeCode="$(var.Upgrade)" Scope="perUser">
    <MediaTemplate EmbedCab="yes" />
    <StandardDirectory Id="LocalAppDataFolder">
      <Directory Id="FluxFolder" Name="Flux">
        <Directory Id="ProbeDir" Name="MSI-Rollback-Probe">
          <Component Id="Probe" Guid="$(var.Component)">
            <File Source="$(var.License)" />
            <RegistryValue Root="HKCU" Key="Software\Flux\RollbackProbe\$(var.Component)" Name="Installed" Value="1" Type="integer" KeyPath="yes" />
            <RemoveFolder Id="CleanProbe" On="uninstall" />
          </Component>
        </Directory>
      </Directory>
    </StandardDirectory>
    <Feature Id="Main"><ComponentRef Id="Probe" /></Feature>
    <CustomAction Id="ProbeFailure" Error="Deliberate standard MSI rollback probe failure." />
    <InstallExecuteSequence>
      <!-- Force execution on uninstall too; otherwise Type 19 tests only a pre-execution failure. -->
      <InstallExecute Sequence="6500" Condition="1" />
      <Custom Action="ProbeFailure" After="InstallExecute" Condition="PROBE_FAIL = 1" />
    </InstallExecuteSequence>
  </Package>
</Wix>
'@
if ($MsiPath) {
    $package = (Resolve-Path -LiteralPath $MsiPath).Path
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $db = $installer.OpenDatabase($package, 0)
    $view = $db.OpenView('SELECT `Value` FROM `Property` WHERE `Property` = ''ProductName''')
    $view.Execute()
    $row = $view.Fetch()
    if (!$row -or $row.StringData(1) -ne 'Flux MSI Rollback Probe') { throw 'This is not a Flux rollback probe package.' }
    $view.Close()
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) | Out-Null
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($db) | Out-Null
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer) | Out-Null
} else {
    [IO.File]::WriteAllText($source, $wxs, (New-Object Text.UTF8Encoding($false)))
    & $WixPath build -arch $Architecture -d "Upgrade=$upgrade" -d "Component=$component" -d "License=$(Join-Path $repo 'LICENSE')" -o $package $source
    if ($LASTEXITCODE -ne 0) { throw 'Rollback probe build failed.' }
}
if ($BuildOnly) { Write-Output $package; return }
$selection = (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -Name 'SCRNSAVE.EXE' -ErrorAction SilentlyContinue).'SCRNSAVE.EXE'
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$results = New-Object 'Collections.Generic.List[object]'
function Run-Probe([string]$Operation, [string]$Name, [string]$Extra, [int]$Expected) {
    $log = Join-Path $out ($Name + '.log')
    $p = Start-Process msiexec.exe -ArgumentList "$Operation `"$package`" /qn /norestart /L*v `"$log`" $Extra" -WindowStyle Hidden -PassThru
    if (!$p.WaitForExit(120000)) { throw "Probe timed out: $log" }
    $p.Refresh()
    $row = [pscustomobject]@{step=$Name; exitCode=$p.ExitCode; filePresent=(Test-Path (Join-Path $folder 'LICENSE'))}
    $results.Add($row)
    Write-Output "$Name`: exit=$($row.exitCode), file present=$($row.filePresent)"
    if ($p.ExitCode -ne $Expected) { throw "Unexpected exit code: $log" }
    if ($Extra -eq 'PROBE_FAIL=1') {
        if (!(Select-String -LiteralPath $log -SimpleMatch -Pattern 'Deliberate standard MSI rollback probe failure.' -Quiet)) { throw 'The deliberate failure was not reached.' }
        if (!(Select-String -LiteralPath $log -SimpleMatch -Pattern 'Executing op: FileRemove' -Quiet)) { throw 'The failure occurred before file removal; this is not an equivalent uninstall rollback test.' }
    }
}
$stranded = $null
try {
    Run-Probe '/i' 'install' '' 0
    if (!(Test-Path (Join-Path $folder 'LICENSE'))) { throw 'Probe payload was not installed.' }
    Run-Probe '/x' 'failed-uninstall' 'PROBE_FAIL=1' 1603
    if (!(Test-Path (Join-Path $folder 'LICENSE'))) { throw 'Uninstall rollback did not restore the probe payload.' }
    Run-Probe '/x' 'uninstall-after-rollback' '' 0
    $stranded = Test-Path (Join-Path $folder 'LICENSE')
} finally {
    # Restore MSI ownership first, then use MSI for removal; never delete the payload manually.
    Run-Probe '/i' 'cleanup-install' 'ADDLOCAL=Main REINSTALLMODE=amus' 0
    Run-Probe '/x' 'cleanup-uninstall' '' 0
    $clean = !(Test-Path -LiteralPath $folder)
    $selectionAfter = (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -Name 'SCRNSAVE.EXE' -ErrorAction SilentlyContinue).'SCRNSAVE.EXE'
    $os = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $report = [ordered]@{elevated=$elevated; architecture=$Architecture; packageSha256=(Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant(); windowsVersion=$os.DisplayVersion; windowsBuild=($os.CurrentBuild + '.' + $os.UBR); msiVersion=(Get-Item "$env:SystemRoot\System32\msi.dll").VersionInfo.FileVersion; payloadStranded=$stranded; cleanupPassed=$clean; selectionUnchanged=($selection -ceq $selectionAfter); steps=@($results.ToArray())}
    [IO.File]::WriteAllText((Join-Path $out 'result.json'), ($report | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    if (!$clean) { throw "Probe cleanup left files. Logs: $out" }
    if ($selection -cne $selectionAfter) { throw 'The screen saver selection changed during a file-only probe.' }
}
if ($stranded) { throw "Confirmed: a standard MSI rollback stranded its file without any Flux DLL. Elevated=$elevated. Logs: $out" }
Write-Output "PASS: standard MSI uninstall rollback and subsequent removal. Elevated=$elevated. Logs: $out"
