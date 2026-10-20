# Luma v0.1.2 — Windows application icon

This maintenance release adds the Luma icon to Windows Installed Apps and Programs and Features (`appwiz.cpl`). It uses the same symbol as the Luma website, with multiple sizes for different display scales.

## Downloads

- **Luma-0.1.2-Setup-x64.msi** — recommended graphical installer for the current user. No administrator rights are needed.
- **Luma-0.1.2-windows-x64.zip** — alternative package. Extract all files and run `Install.cmd`.
- **SHA256SUMS.txt** — SHA-256 checksums for these exact packages.

## Changes

- Embeds a dedicated Luma icon in the MSI and registers it for Windows Installed Apps and Programs and Features.
- Adds a reproducible multi-resolution icon asset derived from the existing website symbol.
- Verifies the embedded icon and its association during package validation.
- Updates the application and package version to 0.1.2. Animation, palettes and clock behavior are unchanged.

## Updating

Close Luma, its preview, and Windows Screen Saver Settings before updating.

- **Existing MSI installation:** run the new MSI. The updated Installed Apps entry includes the Luma icon. Appearance preferences are preserved.
- **Existing ZIP installation:** extract the new ZIP and run `Install.cmd`. ZIP scripts do not manage MSI-owned files or create an Installed Apps entry.
- **Old v0.1.0 Inno EXE installation → ZIP:** uninstall the old copy through Windows Installed Apps first, then install the ZIP. Appearance preferences are kept.

Open Windows Screen Saver Settings afterward to check your selection, preview, wait time and sign-in preference.

## Known MSI uninstall rollback limitation

The known limitation from v0.1.1 remains: if an MSI uninstall fails and rolls back, a later uninstall can report success while leaving files. Normal installation and removal tests pass; this release does not fix the rollback defect.

The tested recovery is to run the same MSI again to reinstall/repair, then retry removal. Keep the MSI if you need recovery. Do not manually delete Windows Installer registry entries. [Investigation and evidence](https://github.com/Ken5998/luma/blob/main/docs/MSI-RELEASE.md) · [Upstream report](https://github.com/wixtoolset/issues/issues/8574#issuecomment-6101186682).

Luma remains an independent MIT-licensed fork of Flux by Sander Melnikov. Appearance preferences in `%LOCALAPPDATA%\Luma\settings.json` are preserved.

<!-- luma-virustotal:start -->
## VirusTotal

These release files are public samples. Reports are informational: false positives are possible, and zero detections do not guarantee safety. This does not replace code signing or remove SmartScreen warnings.

Last checked: 2026-10-20 14:06 UTC.

- [Luma-0.1.2-Setup-x64.msi](https://www.virustotal.com/gui/file/51bf10f118f33583ee115f025f6c55d1defe3d34f5c31bd95d1e8f1f2b2bede6/detection) — submitted; analysis ID: `YjEyMzU1YjdhNWU1M2I5OTczNGVkM2E1Nzk1N2UyNzU6MTc5MjUwNDY3NA==`.
  Analysis completed: 0 malicious, 0 suspicious engine results. See report for context.
- [Luma-0.1.2-windows-x64.zip](https://www.virustotal.com/gui/file/1723690b480dee00717e8b2535f3cc3c951a35cb6265f9b135212da8e8799971/detection) — submitted; analysis ID: `MTBkYTM4NjlkOGJiM2EyM2ZiY2M3OGNlZTNjZmEwMTY6MTc5MjUwNDczOA==`.
  Analysis completed: 0 malicious, 0 suspicious engine results. See report for context.
<!-- luma-virustotal:end -->
