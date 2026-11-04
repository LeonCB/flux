# Published upstream report: non-elevated per-user uninstall rollback

Posted as Ken5998 on 2026-10-10 with the user's explicit authorization:
[WiX issue #8574 comment](https://github.com/wixtoolset/issues/issues/8574#issuecomment-6101186682).
The report does not attribute the root cause to WiX or Windows Installer.

## Submitted comment on WiX issue #8574

We have an independent, file-only reproduction related to the per-user rollback
registration failures in this issue. Ours occurs during **uninstallation**:
rollback restores the payload, but the next uninstall returns success and leaves
the file installed. A repair/reinstallation followed by uninstall removes it.

The package is built with WiX 6.0.2. It contains only a license file, one HKCU
registry value as its component key path, and a standard Type 19 error action.
There is no DLL, custom executable, application selection code or registry ACL
modification in the MSI. Fresh product/upgrade/component identities are used.

The failure is placed after InstallExecute, which is explicitly enabled during
uninstall. The harness checks that FileRemove actually ran before the deliberate
failure: a failure before the transaction executes is not counted as rollback.

Observed sequence, from a non-administrator launch:

| Step | msiexec exit | Payload present |
| --- | --- | --- |
| Install | 0 | Yes |
| Deliberately fail uninstall after execution | 1603 | Yes, restored |
| Uninstall again | 0 | **Yes, unexpectedly stranded** |
| Reinstall to re-establish ownership | 0 | Yes |
| Cleanup uninstall | 0 | No |

The failed-uninstall logs contain one registry error 1307 (invalid owner) and
79 access-denied notes (system error 5), with 80 skipped rollback errors.
The registry restoration fails around Installer product/feature/upgrade/component
registration, while the file copy back succeeds. These observations are not a
claim that the package compiler, engine, or ACL ownership is the established cause.

The same sequence reproduces on:

| Environment | Windows build | msi.dll version | Elevated | Cleanup |
| --- | --- | --- | --- | --- |
| Desktop Windows 11 26H2 | 26300.9550 | 5.0.26100.9549 | False | Passed |
| Separate laptop Windows 11 26H2 | 26300.9550 | 5.0.26100.9549 | False | Passed |
| GitHub Windows Server 2022 Datacenter | 20348.5622 | 5.0.20348.5622 | False | Passed |
| GitHub Windows Server 2025 Datacenter | 26100.33438 | 5.0.26100.33438 | False | Passed |

The Server tests use freshly created standard accounts with loaded profiles.
Their first attempt was blocked before installation by DisableMSI=1 (1625).
The disposable CI harness therefore permits unmanaged MSI via DisableMSI=0 and
restores the original policy afterward. AlwaysInstallElevated remains disabled.
The test process is not an administrator and the MSI install logs do not set
MsiRunningElevated or Privileged. No such policy change is part of the package
or the normal portable probe.

An elevated test of the application MSI's corresponding rollback/removal
assertions passes. Replacing InstallerVersion=500 with 200 in a fresh file-only
probe does not fix the non-elevated case. Earlier x86 and x64 probes both fail.
A perUserOrMachine authoring trial with ALLUSERS=2/MSIINSTALLPERUSER=1 also failed
and was reverted. Moving the failure before execution can produce a pass but
does not exercise the same rollback, so it is not a solution.

Reproduction source:

- [File-only authoring and portable runner](https://github.com/LeonCB/flux/blob/279afe08abaed7f5c1e061f9fddeb5815ee2e2d4/scripts/test-msi-rollback-probe.ps1)
- [Standard-user CI harness](https://github.com/LeonCB/flux/blob/279afe08abaed7f5c1e061f9fddeb5815ee2e2d4/scripts/test-msi-standard-user-ci.ps1)
- [CI workflow](https://github.com/LeonCB/flux/blob/279afe08abaed7f5c1e061f9fddeb5815ee2e2d4/.github/workflows/msi-rollback-validation.yml)
- [Reproduction on both Server versions, with diagnostic artifacts](https://github.com/LeonCB/flux/actions/runs/38078420379)

To build on Windows with PowerShell 7 and a .NET SDK:

```powershell
. ./scripts/Msi.Common.ps1
$wix = Get-FluxWix
./scripts/test-msi-rollback-probe.ps1 -WixPath $wix.Compiler
```

Run the probe without elevation, in an account without an existing probe.
The script performs repair/removal cleanup before raising its Confirmed error.
For a portable comparison, build with -BuildOnly, copy Probe.msi together with
test-msi-rollback-probe.ps1, then execute the latter with -MsiPath ./Probe.msi.
No Rust, WiX or .NET SDK is needed on the comparison PC.

Could you help determine whether an authoring difference could explain the
registry restoration failures, or suggest
an additional minimal comparison? We need per-user installation without an
administrator prompt and do not want to disable rollback, alter MSI-owned
registry permissions, or hide the failure with manual payload deletion.
## Privacy and publication

Only the disposable-runner diagnostics are linked above. Local laptop/desktop
logs contain user identifiers and paths and were not included in the comment.
The posted body was read back from GitHub and verified against the submitted report.
