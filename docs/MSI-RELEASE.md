# Production MSI release preparation

Flux v0.1.2 adds the Windows Installed Apps icon to the stable MSI distribution.
It retains the known uninstall rollback limitation and tested recovery instructions.
The maintainer first authorized stable distribution with that limitation for
v0.1.1 on 2026-10-12, prioritizing installation/migration and withdrawal of the
old Inno EXE. The original v0.1.1 packages and checksums remain unchanged.
Stable publication does not turn the failing rollback test into a pass or claim
the defect is fixed.

The initial 2026-10-10 pre-release decision and investigation are historical
evidence; the stable publication decision below supersedes that distribution policy.
No automatic application updater is introduced by this installer work.

## Design

The existing native Rust selection/migration actions are reused. Windows
Installer owns the two payload files (`Flux.scr` and `LICENSE`). The production
MSI installs in `%LOCALAPPDATA%\Flux\MSI`, without administrator rights or UAC.
It has a separate upgrade family from the experimental prototype/candidate:
`A51E59BE-C086-48C8-8BDA-B382C44316AE`. Test hooks are absent from production.
WiX and its UI extension are pinned at 6.0.2; the native DLL uses a static CRT.
Windows Installed Apps and Programs and Features use an embedded `Flux.ico`
through `ARPPRODUCTICON` and the MSI Icon table. Windows Installer caches the
icon; it does not add a third payload file. The same `Flux.ico` is compiled into
`Flux.exe` and `Flux.scr` (`flux-desktop/flux.rc`) so Explorer shows it. It is a
custom pixel-art icon; do not run `./scripts/generate-windows-icon.ps1`, which
would overwrite it with a rendering of `site/icon.svg`.
Already installed copies receive the icon when updated with a newer MSI.
The [WiX maintenance-fee policy](https://docs.firegiant.com/wix/whatsnew/)
requires payment for revenue-generating use; Flux is an individual, noncommercial
open-source project. Reassess the tool policy if that changes.

Preferences at `%LOCALAPPDATA%\Flux\settings.json` are never installed, removed
or rewritten. Activation changes only the executable selection, not idle timeout,
password requirements or activation. Selection type and bytes are backed up and
rolled back. Removal restores the original selection only when Flux is still
selected. Repair and upgrades preserve a newer user selection.

Managed ZIP/Inno copies in the default legacy directory are migrated. Inno
registration is captured with native AppSearch, including the interactive client
registry view; the validated, directory-bound uninstaller runs only after MSI
commit. It is held read-only until process startup, then released so Inno can remove its own file. It is waited for and never forcibly killed.
Failure after commit is reported and can leave both installations present;
the old uninstaller is not part of Windows Installer's atomic transaction.
Unmanaged/invalid metadata or unreadable Inno registration fails before mutation.
Unknown legacy files remain. Reparse installation paths and custom production
install locations are rejected. Locked executables fail with instructions to
close the saver, preview and settings. Restart Manager is disabled.

ZIP installation remains supported independently. Do not use Install.cmd to
replace an MSI-owned file. Use Windows Installed Apps for MSI removal and a
newer MSI for updates. Open Windows Screen Saver Settings after installation
and check selection, preview, Settings, wait time and sign-in preference.

## Build and verify

Windows x64, stable Rust, PowerShell 7 and a .NET SDK (WiX build tool only):

```powershell
cargo test --locked --release -p flux -p flux-desktop
./scripts/test-deployment.ps1
./scripts/test-uninstall-handoff.ps1
./scripts/test-virustotal.ps1
./scripts/package-release.ps1
```

The user's PC needs neither Rust nor .NET for the MSI. The settings dialog still
uses Windows PowerShell. `package-release.ps1` builds the app, ZIP and MSI using
the existing pipeline, then verifies MSI metadata, exact ZIP contents and hashes.
There is no production dependency on Inno Setup.

The `Validate prepared MSI release` workflow builds/reviews the branch on a
disposable Windows runner, explicitly recording whether it is elevated. Such a
pass does not replace non-elevated acceptance. No review artifact is published
as a release or submitted to VirusTotal automatically.

The annotated v0.1.1 tag and final assets were created through the existing
Build draft Windows release workflow. It checks versions, tests and hashes,
creates a draft, and refuses to replace an existing release. Stable publication
is a separate maintainer decision after review. The 2026-10-12 promotion uses
the existing v0.1.1 tag and assets; neither binaries nor checksums are replaced.
Release notes retain the exact final VirusTotal report links and known issue.

## Regression checklist and unresolved acceptance items

- [ ] Non-elevated install, repair, upgrade, downgrade rejection and uninstall.
- [ ] Install rollback and uninstall rollback followed by successful removal.
- [ ] Managed ZIP migration, migration rollback and unknown-file preservation.
- [ ] Real v0.1.0 Inno migration and original selection restoration.
- [ ] Native Windows Screen Saver Settings selects the installed copy; preview
  and Settings work. All palettes, clock and multi-monitor exit still work.
- [ ] Existing appearance preferences remain byte-for-byte unchanged.
- [ ] Wait time, activation and sign-in preference remain unchanged.
- [ ] Final MSI and ZIP SHA-256 hashes verified; antivirus results refer to those
  exact files. Unsigned packages must never be described as code signed.
- [ ] README, website and release notes describe the published package accurately.

### Blocking evidence, 2026-10-10

The pure file-only rollback probe still fails on this Windows 11 26H2 host,
build 26300.9550, MSI 5.0.26100.9549, without elevation. A failed uninstall restores
the file, but a subsequent successful uninstall strands it. The runner repairs
ownership and then removes the probe; cleanup passes and selection is unchanged.
This occurs without any Flux DLL. It does not prove an OS-wide issue or justify
elevation.

An independent laptop run on 2026-10-10 reproduced the same sequence with
`Elevated=False`: install succeeded; the deliberately failed uninstall restored
the file; subsequent removal returned 0 but left it present. Repair followed by
removal then removed the file. The subsequently supplied report confirms the same
Windows 11 26H2 build 26300.9550 and MSI 5.0.26100.9549 as the desktop, with
`cleanupPassed=true` and `selectionUnchanged=true`. The supplied rollback log
shows the same failed registry restoration, including error 1307 (invalid owner)
for an Installer UpgradeCodes key, access-denied failures and skipped rollback
operations. File restoration itself succeeds. The laptop probe SHA-256 is
`4614c0495f5462617fb37b9498fba19f67f4c82668152f8d6c6ed7f181a7f261`.
The laptop result rules out a defect confined to the development PC, but does not
identify the underlying cause.

A fresh file-only probe built with WiX 6.0.2 and `InstallerVersion=200` also
reproduced the failure without elevation on the development PC; cleanup passed.
Lowering the minimum engine version alone did not resolve it.

[WiX issue #8574](https://github.com/wixtoolset/issues/issues/8574) reports a related
per-user rollback registration failure. That report concerns failed installation,
while this probe concerns failed uninstallation and subsequent removal. Its
existence is supporting context, not proof of a shared cause or a verified fix.
No installer downloaded from that issue was executed: its MSI metadata was only
read for comparison.

The full [GitHub validation run](https://github.com/LeonCB/flux/actions/runs/38076913244)
passed, including real v0.1.0 Inno migration and removal after uninstall rollback.
Downloaded MSI logs explicitly record `MsiRunningElevated=1`, `Privileged=1` and
`AdminUser=1`, so this pass does not establish the required non-elevated behavior.
At that investigation stage the no-administrator publication gate remained open.
The later stable release decision accepts the documented limitation; it does
not establish successful non-elevated uninstall rollback.

See [candidate evidence](msi-candidate.md) and
`scripts/test-msi-rollback-probe.ps1`. Never weaken the failing assertion or
manually delete files to manufacture a successful removal result.

### Local validation of prepared 0.1.1

- All 64 application tests pass, including the 11 GPU tests and embedded settings form normally ignored. Four native MSI unit tests also pass.
- Deployment, registered-uninstaller handoff, offline VirusTotal transport tests and preview resize/shutdown pass.
- Production MSI compilation and embedded MSI/ZIP payload hash comparison pass. Rust reports one informational localized linker-output warning for the action DLL; application build has no warnings.
- Non-elevated install, repair, normal removal, install rollback, upgrade, downgrade prevention, ZIP migration and failed migration rollback pass. Uninstall rollback followed by removal still fails as above; cleanup re-establishes MSI ownership and removes the test copy.
- No final production antivirus submission or signing result is claimed. Real Inno migration passes on the elevated CI runner; non-elevated release acceptance remains open.

### Standard-user comparison workflow

`msi-rollback-validation.yml` builds the isolated file-only probe with the same
pinned WiX 6.0.2 compiler and runs it on Windows Server 2022 and 2025 GitHub-hosted
runners. The CI harness creates a temporary standard account, loads its profile,
resolves its AppData paths, records its token and OS context, and rejects elevated
installer policies. A successful probe also requires MSI logs without elevated
execution properties. Diagnostics are retained as Actions artifacts on failure;
the normal repair/removal cleanup is kept, never replaced with file deletion.
The harness refuses to create accounts outside disposable GitHub-hosted runners.
Server results provide comparison evidence; they do not replace acceptance on the
supported Windows desktop builds. No publication is triggered by this workflow.
The first standard-user comparison run stopped before installation with 1625 on
both Server runners. Its logs report `DisableMsi=1`: unmanaged non-elevated MSI
is blocked by the runner policy. This is not a rollback result. The CI-only
harness temporarily sets `DisableMSI=0` on the disposable VM and restores the
previous policy afterward; it never enables `AlwaysInstallElevated`. No policy
is changed by Flux or by the portable probe on a user's PC. See Microsoft's
[DisableMSI policy documentation](https://learn.microsoft.com/en-us/windows/win32/msi/disablemsi).
### Completed standard-user comparison, 2026-10-10

The final [comparison run](https://github.com/LeonCB/flux/actions/runs/38078420379)
reproduces the stranded-file failure under standard-user tokens on both Server
images, after the unmanaged-install policy adjustment described above:

| Environment | Windows build | msi.dll | Elevated | Stranded file | Cleanup |
| --- | --- | --- | --- | --- | --- |
| Windows Server 2022 Datacenter | 20348.5622 | 5.0.20348.5622 | False | Yes | Passed |
| Windows Server 2025 Datacenter | 26100.33438 | 5.0.26100.33438 | False | Yes | Passed |

Both reports confirm unchanged screen saver selection. Both rollback logs contain
one invalid-owner note (1307), 79 access-denied notes (5) and 80 skipped rollback
errors, matching the laptop's diagnostic signature. Install logs do not set
MsiRunningElevated or Privileged. These results rule out a failure confined to the
development machines or build 26300.9550; they still do not establish the underlying
compiler/engine/authoring cause. The comparison workflow correctly fails rather
than treating the successful cleanup as a successful rollback test.

No production installer or application code was changed by this investigation.
[The upstream report](MSI-ROLLBACK-REPORT.md) was posted with explicit user
authorization on 2026-10-10 as [a comment on WiX #8574](https://github.com/wixtoolset/issues/issues/8574#issuecomment-6101186682).
The comment was read back and verified. No local user logs were uploaded.
At this stage the non-elevated rollback gate blocked stable promotion. The
2026-10-12 maintainer decision below supersedes that publication hold while
retaining the failed test and unresolved defect.
## Inno withdrawal and pre-release distribution

Retire only the public v0.1.0 Setup EXE after a hash-verified local backup has
been retained. Keep the v0.1.0 ZIP, historical SHA-256 records, tag and detection
investigation. Update its release notes to remove the installer recommendation.
Do not rehost the retired EXE as an alternative public fixture. Future automated
MSI validation no longer downloads it; the recorded real migration pass remains
available, and a retained local installer may be supplied to the integration
runner with -LegacySetupPath.

The initial pre-release website targeted the v0.1.1 ZIP explicitly. After stable
promotion, both download buttons open releases/latest so users can choose MSI
or ZIP and read the known limitation before downloading.
Existing Inno users switching to ZIP remove their graphical installation first;
appearance preferences survive. MSI users manage MSI files through Windows
Installer rather than overwriting them with ZIP scripts.

## Final v0.1.1 pre-release verification, 2026-10-10

The [tag build](https://github.com/LeonCB/flux/actions/runs/38081976023)
passed 52 default application tests, four native installer tests, deployment,
uninstaller handoff and VirusTotal script tests. The [MSI integration run](https://github.com/LeonCB/flux/actions/runs/38081974342)
passed activation, repair, upgrade, downgrade prevention, ZIP migration,
transaction rollback and subsequent removal on an elevated disposable runner.
This does not supersede the failed standard-user rollback evidence above.

Final assets were downloaded from the draft and independently verified, including
all ZIP payload checksums and exact embedded MSI payload equality.

| Final asset | SHA-256 |
| --- | --- |
| Flux-0.1.1-Setup-x64.msi | 19afabb4206f17367ca5f71fe10e4c3663ee71a73108fc0951a81c436f9ec6ad |
| Flux-0.1.1-windows-x64.zip | 70110109409bd9bad52b6867fec7dd952d982c98887dffc4e318792ba7cd496b |

The explicitly authorized [VirusTotal scan](https://github.com/LeonCB/flux/actions/runs/38082587207)
completed for both exact final assets: **0 malicious and 0 suspicious** results
for each, checked on 2026-10-10. Reports and recorded analysis IDs are in the
[v0.1.1 release notes](https://github.com/LeonCB/flux/releases/tag/v0.1.1).
Packages remain unsigned; this does not guarantee safety or remove SmartScreen.

## Stable promotion, 2026-10-12

The maintainer explicitly authorized publishing v0.1.1 as stable with the known
uninstall rollback defect disclosed. Normal installation/migration results and
the new packages' antivirus reports were the reasons for this release decision.
The defect and regression assertions remain unchanged. The non-elevated local
install, repair, install rollback, upgrade, ZIP migration and failed-migration
rollback passes above remain distinct from the failing uninstall rollback test;
the real Inno migration acceptance evidence is from elevated CI.

Promotion keeps the original tag, MSI, ZIP, SHA256SUMS.txt and their verified
hashes. Update the release's title/notes and mark it stable/latest; do not rebuild
or replace its assets. README and website disclose the uninstall limitation:
a failed uninstall rollback can leave files after the next removal. Run the same
MSI to reinstall/repair, then retry removal, as verified by the recovery tests.
This is acceptance of a known issue, not a correction of it.

## Flux v0.1.2 icon release, 2026-10-20

The release adds the existing Flux website symbol to Windows Installed Apps and
Programs and Features via the MSI Icon table and `ARPPRODUCTICON`. The exact
embedded icon is compared with the committed asset during package validation.
The ICO has eight sizes, from 16 to 256 pixels; native Windows icon loading was
checked at every size. An existing MSI install receives the icon through update.

- Release tag: `v0.1.2`, source commit `95b1150`.
- Local application tests: 52 passed, with GPU/interactive-only tests skipped.
- Native installer unit tests: 4 passed; deployment, uninstall handoff and
  VirusTotal integration tests passed.
- [Draft packaging workflow](https://github.com/LeonCB/flux/actions/runs/39433544379): passed.
- [MSI validation workflow](https://github.com/LeonCB/flux/actions/runs/39433543902): passed,
  including upgrade, downgrade prevention, selection restoration, ZIP migration,
  failed-install rollback, uninstall rollback and cleanup on an elevated runner.
  This does not establish that non-elevated uninstall rollback is fixed.
- The actual draft release packages were downloaded and independently checked
  for exact contents, embedded icon, no-elevation metadata and SHA-256 checksums.
- Animation, palettes and clock behavior are unchanged in this patch.

| Final release file | SHA-256 |
| --- | --- |
| Flux-0.1.2-Setup-x64.msi | 51bf10f118f33583ee115f025f6c55d1defe3d34f5c31bd95d1e8f1f2b2bede6 |
| Flux-0.1.2-windows-x64.zip | 1723690b480dee00717e8b2535f3cc3c951a35cb6265f9b135212da8e8799971 |

Final VirusTotal analyses completed on 2026-10-20 for both exact release files:
[MSI](https://www.virustotal.com/gui/file/51bf10f118f33583ee115f025f6c55d1defe3d34f5c31bd95d1e8f1f2b2bede6/detection)
reported 0 malicious and 0 suspicious results (62 undetected; 13 unsupported);
[ZIP](https://www.virustotal.com/gui/file/1723690b480dee00717e8b2535f3cc3c951a35cb6265f9b135212da8e8799971/detection)
reported 0 malicious and 0 suspicious results (68 undetected).
[Scan status refresh](https://github.com/LeonCB/flux/actions/runs/39436184536)
reused the original analysis IDs; the files were not reuploaded while queued.
These results do not imply that unsupported engines scanned the MSI.

The verified draft was published as [v0.1.2](https://github.com/LeonCB/flux/releases/tag/v0.1.2)
on 2026-10-20, with the same scanned assets and checksums. README and website
references were advanced to v0.1.2 after publication. The known non-elevated
uninstall rollback limitation remains documented in the release notes.
