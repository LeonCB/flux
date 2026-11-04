# MSI packaging experiment

This is an isolated antivirus comparison package, not a replacement for the
published installer. The release workflow, downloads and existing installation
remain unchanged.

## Behavior

- Product name: **Flux MSI Prototype**.
- Per-user installation in `%LOCALAPPDATA%\Flux\MSI-Prototype`.
- Installs the exact published v0.1.0 `Flux.scr` and its accompanying MIT license.
- Standard Windows Installer file ownership, repair, major upgrades and removal.
- Does not select or activate a screen saver, change preferences, or launch scripts.
- Does not migrate or uninstall an existing Inno Setup / ZIP installation.
- Remove **Flux MSI Prototype** through Windows Installed Apps after testing.

The package is for packaging/antivirus tests. Do not select its copy as the default
screen saver: this prototype does not restore the previous selection on removal.
The normal Flux installation continues to work independently.

An experimental native action could write and read back the selection during MSI
execution, but integration tests observed the previous value after MSI exited.
That implementation was removed. Its cause and reliable activation/restoration
must be investigated before promoting MSI to the production installer.

An expanded [native MSI candidate](msi-candidate.md) is now available for further
validation. It reproduces differing registry visibility between the automated
PowerShell and MSI contexts; the exact cause remains unresolved. Its new behavior
and binaries are not covered by this prototype's VirusTotal report.

## Reproduce

Prerequisites: Windows x64, PowerShell 7 and a .NET SDK. WiX 5.0.2 is pinned for
this experiment, with tools kept under ignored `target/`. Review the supported
WiX version and current license terms before adopting the production toolchain.

Run from the repository root:

```powershell
dotnet tool install wix --version 5.0.2 --tool-path target/tools/wix --allow-roll-forward
$extensionRoot = Join-Path $PWD 'target/tools/wix/extensions'
New-Item -ItemType Directory -Path $extensionRoot -Force | Out-Null
Invoke-WebRequest 'https://api.nuget.org/v3-flatcontainer/wixtoolset.ui.wixext/5.0.2/wixtoolset.ui.wixext.5.0.2.nupkg' -OutFile (Join-Path $extensionRoot 'ui.zip')
Expand-Archive (Join-Path $extensionRoot 'ui.zip') -DestinationPath (Join-Path $extensionRoot 'WixToolset.UI.wixext/5.0.2') -Force
```

The build expects the v0.1.0 ZIP extracted under
`target/releases/0.1.0/payload/Flux-windows-x64`. Use the published asset from
[release v0.1.0](https://github.com/LeonCB/flux/releases/tag/v0.1.0), not a rebuilt
binary. The build rejects a different screensaver SHA-256:

```text
d85ff71abb7de287da02acdb7d159bb6c7da302d6c8d42b0b6bf56012c458ffc
```

```powershell
./scripts/package-msi-prototype.ps1
# A second MSI version is exclusively for the upgrade test; payload is identical.
./scripts/package-msi-prototype.ps1 -Version 0.1.1
./scripts/test-msi-prototype.ps1 `
  -MsiPath target/msi-prototype/0.1.0/Flux-0.1.0-MSI-Prototype-x64.msi `
  -UpgradeMsiPath target/msi-prototype/0.1.1/Flux-0.1.1-MSI-Prototype-x64.msi
```

Run integration tests outside a restricted filesystem/registry sandbox. They
install and remove the isolated prototype under the current user, and refuse to
run over an existing prototype directory. Existing production files and settings
are hashed before and after. The currently selected screensaver is checked after
each operation. MSI logs remain in `target/msi-tests-*`.

## Validation on 2026-10-06

- WiX compilation and MSI validation passed for both versions.
- Installation and repair passed; installed `Flux.scr` matches the release hash.
- MSI major upgrade and downgrade rejection passed.
- Uninstall removed the payload and installation metadata.
- Current screen saver selection, production binary and settings remained unchanged.
- VirusTotal analysis completed on 2026-10-06 at 21:41:21 Europe/Zurich:
  **0/51** detections. Microsoft and BitDefender returned Undetected.
- DeepInstinct and SecureAge returned **Unable to process file type**;
  Skyhigh (SWG) returned **Timeout**. These are the three engines that flagged
  the original EXE. The MSI result therefore does not establish that those
  detections have been withdrawn, or that Inno Setup caused them.

[MSI VirusTotal report](https://www.virustotal.com/gui/file/aa3ec1a138386d8baddc32e2c17cb739b700cc8258c6a81c91d1e8f82cb3f3d2/detection).

The evaluated v0.1.0 MSI is 2,527,232 bytes, SHA-256:

```text
aa3ec1a138386d8baddc32e2c17cb739b700cc8258c6a81c91d1e8f82cb3f3d2
```

Any comparison measures the complete packaging change, including removal of
PowerShell actions. It cannot establish that Inno Setup alone caused detections.
Rebuilding creates a new MSI identity/hash; scan the exact package being evaluated.
