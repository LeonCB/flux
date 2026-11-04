# Native MSI candidate — validation in progress

This experimental package adds screen saver activation and restoration to the
earlier file-only MSI prototype. It is **not ready to replace the published
installer**. The release workflow and public downloads still use the existing
v0.1.0 package.

## Behavior

- Per-user installation in `%LOCALAPPDATA%\Flux\WindowsInstaller`.
- Exact published v0.1.0 `Flux.scr`, plus the current repository MIT license,
  including both upstream and Flux copyright notices.
- Native Rust DLL actions; no PowerShell is shipped or launched for normal MSI
  activation, restoration, repair or ZIP migration. The legacy Inno uninstaller,
  if used for migration, still runs its existing PowerShell helper.
- First installation selects Flux and saves the previous selection's registry
  type and bytes. Uninstall restores that value only if this copy is still
  selected. Repair and upgrade preserve a newer user choice.
- Selection changes have matching rollback actions.
- Managed ZIP migration retains the pre-Flux selection, removes only explicitly
  owned legacy files after installation commits, and preserves unknown files and
  preferences. Unmanaged or invalid metadata stops installation before changes.
- Inno migration requires a valid registration pointing to the matching legacy
  directory. If an Inno uninstaller is present but registration is unavailable,
  installation stops: it must never delete that installation as if it were a ZIP.
  Uninstall the old installer through Windows Installed Apps before retrying.
- Legacy cleanup is a commit action. A cleanup failure is logged and can leave
  the old installation present; installation of the new copy has already committed.
- Close Flux and its Windows preview/settings before installation or removal.

The candidate uses the prototype's upgrade family; remove any old MSI prototype
before manual testing. Its test version numbers do not change Flux's public version.

## Build

Use Windows x64, Rust, PowerShell 7, and the WiX 5.0.2 tool/UI extension prepared
as described in [msi-prototype.md](msi-prototype.md). The native dependency lockfile
is committed. Cargo builds offline, so those locked crates must already be cached.
The build uses a static CRT and restores any existing `RUSTFLAGS` afterward.

```powershell
./scripts/package-msi-candidate.ps1
```

The output is under `target/msi-candidate/0.1.2/package/`. This build excludes the
test-only registry seeding, reporting, restoration and injected failure hooks.

For integration testing, build two dedicated test packages:

```powershell
./scripts/package-msi-candidate.ps1 -TestHooks
./scripts/package-msi-candidate.ps1 -Version 0.1.3 -TestHooks
./scripts/test-msi-candidate.ps1 `
  -MsiPath target/msi-candidate/0.1.2/test/Flux-0.1.2-MSI-Candidate-x64.msi `
  -UpgradeMsiPath target/msi-candidate/0.1.3/test/Flux-0.1.3-MSI-Candidate-x64.msi
```

The test runner supports Windows PowerShell 5.1 and PowerShell 7. Run the tests
directly from a normal PowerShell session outside Codex's restricted
execution environment, preferably in a dedicated Windows test account. They
temporarily change the screen saver selection and deliberately fail transactions.
They refuse an existing candidate directory and attempt to repair/remove the
candidate and restore the native initial selection in `finally`.

The optional `-LegacySetupPath` tests migration from the actual published Inno EXE.
It refuses an existing Inno registration; use a clean test account. Test logs and
receipts remain under `target/msi-candidate-tests-*`.

## Evidence on 2026-10-07

WiX compilation and validation pass. Production MSI custom-action tables contain
no test actions, and its DLL contains none of the test hook names.

The integration tests passed these cases in the automated environment:

- Installation, exact release payload hash, repair and normal removal.
- Exact restoration of the initial value, including an absent selection.
- Failed installation restores selection and removes its newly installed payload.
- Major upgrade, downgrade prevention, preservation of a newer selection.
- Managed ZIP migration, failed migration rollback and unknown-file preservation.

**Outstanding:** an injected uninstall failure restores Flux's selection, but
Windows Installer's own rollback logs registry errors (including access denied and
invalid owner). Subsequent uninstall can leave files because component ownership
was lost. Test cleanup repairs the MSI before removing it. The full test command
exits with a failure when run without elevation. The user reproduced the same failure from Windows
PowerShell 5.1 outside Codex on 2026-10-07, so it is not confined to the automated
environment. Do not interpret the passing selection assertion alone as a
successful uninstall rollback.

A separate minimal per-user MSI installing only `LICENSE` reproduced the same
failure when a deferred DLL action simply returned 1603. It did not run any Flux
selection, restoration or migration code. Subsequent removal returned 0 but left
the license file, with the same registry errors 5 and 1307 in rollback. This
narrows the issue to the per-user MSI transaction/rollback path on this system;
it does not establish whether the cause is Windows Installer, system state or
packaging configuration. An earlier Type 19 immediate-error probe passed, but
its uninstall error happened before the deferred transaction executed, so that
result is not an equivalent rollback test. Changing failure impersonation and
moving preparation before transaction initialization did not fix the problem.

The user then ran the same full suite from an elevated PowerShell session on
2026-10-07. Every assertion passed, including uninstall rollback, subsequent
removal, protected production-file hashes and restoration of the initial selection.
Logs: `target/msi-candidate-tests-20261007-215510`. The registry ownership/access
errors reported by the non-elevated uninstall rollback are absent from that
elevated run. A generic "Error in rollback skipped. Return: 5" remains at the end
of injected-failure logs; functional assertions pass, so this warning is retained
as a diagnostic rather than silently declaring the logs error-free.

This comparison supports a privileges-related failure on this system. Passing
only with elevation is not a resolution for an installer intended to work without
elevation. Retain the failing assertions. Decide the supported installer privilege
model before promotion, validate that model from a normal launch, and manually
verify Windows Screen Saver Settings. No installer privilege or scope changes
have been made merely to bypass the failing test.

The user confirmed that the final installer must continue to work without
administrator privileges. An additional trial with WiX `perUserOrMachine`
(default per-user, explicit `ALLUSERS=2` and `MSIINSTALLPERUSER=1`) still failed
the same non-elevated uninstall rollback assertion. That trial was reverted;
the candidate remains strictly per-user. An elevated test pass therefore does
not satisfy the chosen release requirements.

### Pure MSI reproduction

Further isolation removes even the failure/rollback DLL from the comparison.
`scripts/test-msi-rollback-probe.ps1` builds an MSI containing only `LICENSE`,
one HKCU component key and a standard Type 19 error action. It explicitly runs
`InstallExecute` on uninstall before raising the error. The runner checks that
file removal actually executed; a pre-execution failure is not counted as a
rollback test. Each build gets fresh product/upgrade/component identities.

Both x64 and x86 packages reproduce the stranded-file failure without elevation.
The x64 result also reproduces in Windows PowerShell 5.1, including portable mode
with a prebuilt MSI. The observed host is Windows 11 26H2, build 26300.9550;
`msi.dll` reports 5.0.26100.9549. These observations do not establish an OS-wide
regression: a second Windows installation is still needed for comparison.

```powershell
# Builds with the existing local WiX tool, runs, and cleans up the file-only probe.
./scripts/test-msi-rollback-probe.ps1
./scripts/test-msi-rollback-probe.ps1 -Architecture x86
# Build without installing, for an independent test environment.
./scripts/test-msi-rollback-probe.ps1 -BuildOnly
# A prebuilt probe requires only Windows PowerShell 5.1 or PowerShell 7.
./scripts/test-msi-rollback-probe.ps1 -MsiPath ./Probe.msi
```

An expected reproduction exits with a `Confirmed` error after recording the
stranded-file result. Cleanup first re-establishes MSI ownership with a normal
installation, then removes the probe through MSI. It never deletes the file by
hand to make removal assertions pass. Reports capture elevation, package hash,
Windows/MSI versions, stage results, cleanup, and unchanged screen saver selection.

An ignored, portable comparison ZIP was prepared at
`target/debug-packages/Flux-MSI-Rollback-Probe.zip`. It contains the prebuilt x64
MSI, runner, license, instructions and checksums, with no Rust/WiX dependency on
the comparison PC. Run the included script from a non-elevated PowerShell.
The tested portable report confirms `cleanupPassed=true` and
`selectionUnchanged=true`. Do not include locally generated verbose logs in a
public bundle without reviewing their local paths and user identifiers.

The actual Inno test also exposed different registry visibility: PowerShell could
read its registration while the native MSI action could not. The new guard stops
this case before deleting old files. Inno migration remains unvalidated.

Earlier selection discrepancies also reproduce between PowerShell and MSI actions
for the same user SID and registry key. Receipts therefore read values inside the
native action context. The cause is not established; these receipts do not replace
manual verification in Windows Screen Saver Settings.

The complete candidate has **not** been submitted to VirusTotal. The earlier
file-only prototype's 0/51 report does not apply to this new MSI or native DLL.
Scan both final artifacts after functional validation, and retain their SHA-256
checksums from `SHA256SUMS.txt` with the reports.
