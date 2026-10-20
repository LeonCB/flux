![Luma — Windows screensaver](docs/luma-banner.svg)

# Luma

A Windows screensaver with flowing, GPU-rendered light. Based on [Flux by Sander Melnikov](https://github.com/sandydoo/flux), inspired by the Drift screensaver on macOS.

Luma is an independent MIT-licensed fork, currently under development.

[Website](https://luma.ksmvc.ch) · [Releases](https://github.com/Ken5998/luma/releases)

## Features

- Fullscreen animation on each display connected at startup.
- Independent scenes with per-monitor resolution and DPI scaling.
- Five color palettes, including Aurora: teal, violet, and pink inspired by northern lights.
- An optional local-time clock, centered at the top of a chosen display.
- Hidden cursor in screensaver mode.
- Exit all screens with a key press, mouse click, scroll, or mouse movement.
- A two-second input grace period after each window's first frame prevents accidental startup exits. Keyboard auto-repeat is ignored; mouse movement uses an 8-logical-pixel threshold.
- A windowed desktop mode for development and testing.

## Install, update, or uninstall

**[v0.1.2 is the latest stable release](https://github.com/Ken5998/luma/releases/tag/v0.1.2), with a native per-user MSI installer and an alternative ZIP package.**

- **[Luma-0.1.2-Setup-x64.msi](https://github.com/Ken5998/luma/releases/download/v0.1.2/Luma-0.1.2-Setup-x64.msi)**: recommended graphical per-user installer with an Installed Apps entry. No administrator rights are needed.
- **[Luma-0.1.2-windows-x64.zip](https://github.com/Ken5998/luma/releases/download/v0.1.2/Luma-0.1.2-windows-x64.zip)**: extract all files and run **Install.cmd**. No administrator rights are needed.
- **[SHA256SUMS.txt](https://github.com/Ken5998/luma/releases/download/v0.1.2/SHA256SUMS.txt)**: checksums for these exact packages. Current antivirus reports are linked in the release notes.

The old Inno Setup EXE is withdrawn from public downloads following antivirus detections. The historical findings remain in [the installer investigation](docs/INSTALLER-TRUST.md); they are not a confirmed vendor classification correction.

### MSI installation and updates

Close Luma and Windows Screen Saver Settings, then run the MSI. After installation, open Windows Screen Saver Settings and check selection, wait time and sign-in preference.

The MSI installs in `%LOCALAPPDATA%\Luma\MSI` and preserves appearance preferences. It supports managed default-directory ZIP/Inno migration, repair, upgrades and removal through Windows Installed Apps. Keep using MSI for updates/removal of an MSI installation; ZIP scripts do not manage MSI-owned files.

**Known limitation:** if an MSI uninstall fails and rolls back, a subsequent uninstall can return success while leaving its files. The file is restored, but Windows Installer's registration is not fully recovered. This was reproduced without administrator privileges on two Windows 11 PCs and two Windows Server test environments, including a file-only package without any Luma DLL. Normal install/removal tests pass, but the rollback defect remains unresolved.

In the tested recovery, running the same MSI again to reinstall/repair restores ownership; subsequent removal then succeeds. Keep the MSI if you try it. Do not manually delete Windows Installer registry entries. [Full evidence and upstream report](docs/MSI-RELEASE.md). The release includes this known limitation; promoting it to stable does not mean the rollback defect has been corrected.

### Alternative ZIP installation

Close Luma and Windows Screen Saver Settings. Extract the Windows ZIP, then double-click **Install.cmd**. It installs for the current user in `%LOCALAPPDATA%\Luma\Screensaver`, selects Luma, and opens Windows Screen Saver Settings. Check the wait time and sign-in preference, then click Apply.

Run Install.cmd from a newer extracted package to update an existing ZIP installation. Appearance preferences are kept. If the executable is in use, close the screensaver, preview, and settings window, then retry.

If you installed v0.1.0 with the old graphical EXE, first remove that installation through Windows Installed Apps, then run Install.cmd from the new ZIP. Your appearance preferences at `%LOCALAPPDATA%\Luma\settings.json` are preserved. Close Luma and the Windows preview before switching package types.

To uninstall a ZIP installation, run **Uninstall.cmd** from the package or installation folder. It restores the previous screensaver if that file still exists and Luma is still selected. A newer screensaver choice is left unchanged. The preferences file is preserved.

The scripts change only the current user's screensaver executable selection. They do not change activation, idle timeout, or password requirements. Windows applies the executable selection on its next screensaver launch ([Microsoft documentation](https://learn.microsoft.com/en-us/windows/win32/devnotes/scrnsave-exe)). Organization policies may override the selection.

Previously installed manual copies are not removed. The per-user copy becomes the selected screensaver.

## Build

Requires Windows, a stable Rust toolchain installed with rustup, and Visual Studio Build Tools with the C++ x64 tools and Windows SDK.

Run from the repository root in PowerShell:

```powershell
.\scripts\build-windows.ps1
```

The script produces `target\release\Luma.exe` and `target\release\Luma.scr`, and copies the MIT license alongside them. The first build needs access to crates.io.

### Create a distributable package

```powershell
.\scripts\package-windows.ps1
```

Produces `target\distribution\Luma-windows-x64.zip` and its SHA-256 checksum. The ZIP includes the screensaver, installer, uninstaller, instructions, license, and checksums for its files. It uses the freshly built executable, even if an older development `.scr` is locked by Windows.

The installer is a **per-user MSI**, reusing the native Rust activation and
restoration implementation. It does not require administrator rights and retains
appearance preferences. v0.1.2 is published as stable with the documented
non-elevated uninstall rollback limitation and tested recovery instructions.
See [MSI release preparation](docs/MSI-RELEASE.md) for the evidence and checklist.

For versioned MSI/ZIP assets, use PowerShell 7 and a .NET SDK for
the pinned WiX build tool (neither is an MSI runtime prerequisite):

```powershell
.\scripts\package-release.ps1
```

This creates `Luma-<version>-Setup-x64.msi`, the ZIP and `SHA256SUMS.txt` under
`target\releases\<version>`, then verifies payloads and checksums. Historical
Inno authoring remains available for old-release migration tests. Luma starts its
own release numbering at v0.1.0, independent of the inherited Flux version.

The [VirusTotal workflow](docs/VIRUSTOTAL.md) scans final release assets using the
`VT_API_KEY` repository secret and adds report links to the release notes. It runs
on release publication or manually for an existing release or draft. Reports do
not replace code signing or remove Windows SmartScreen warnings.

The [installer detection investigation](docs/INSTALLER-TRUST.md) records the
vendor-specific findings and component scans. Experimental installer changes
remain on `codex/installer-trust`; they are not a confirmed false-positive fix.

### Deployment tests

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-deployment.ps1
```

Tests installation, replacement, locked files, restoring the original selection, preserving a newer selection, and keeping preferences. They use disposable repository folders and a simulated registry boundary; they do not change the selected Windows screensaver. Registry integration and the Windows settings panel should be checked on an actual installation.

## Run

```powershell
# Windowed desktop application
.\target\release\Luma.exe

# Fullscreen screensaver on all connected displays
.\scripts\run-screensaver.ps1

# Run the .scr executable in a window
.\scripts\run-screensaver.ps1 -Windowed
```

The launcher runs the executable directly because the Windows `.scr` file association can replace command-line arguments.

### Windows screensaver modes

| Argument | Current behavior |
| --- | --- |
| `/s` | Fullscreen screensaver on every display detected at startup |
| `--windowed` | Windowed desktop prototype |
| `/c` | Open the settings window |
| `/p <HWND>` or `/p:<HWND>` | Animated preview embedded in the supplied Windows window; follows its size and exits when the host closes |
| No arguments | Windowed mode for `.exe`; settings window for `.scr` |

## Settings

Open **Settings** in Windows Screen Saver Settings, or run:

```powershell
.\target\release\Luma.exe /c
```

- **Color palette:** Original, Plasma, Poolside, Freedom, or Aurora.
- **Animation speed:** 50–200% of the default speed.
- **Line size:** 50–200%, independent of display DPI.
- **Simulation quality:** Low, Balanced (default), or High. Higher quality uses more GPU resources on each display.
- **Show clock:** Off by default; displays local time in 24-hour format at the top center.
- **Clock display:** Primary display or a specific monitor. If that monitor is unavailable, the clock falls back to the primary display. Windowed mode and the Windows preview show the clock when enabled.

**Save** writes preferences to `%LOCALAPPDATA%\Luma\settings.json`. **Cancel** leaves the file unchanged. **Restore defaults** resets the controls; use Save to keep those values.

Preferences apply when a new desktop, screensaver, or preview instance starts. A running animation is not updated live. Missing settings use defaults; unreadable or invalid files produce a log warning and safe defaults. Saving from the settings window replaces invalid files.

The Windows Forms settings panel is embedded in the executable and uses the Windows PowerShell included with Windows. No companion script needs to be installed. A system policy that blocks PowerShell can prevent the settings window from opening.

Update managed installations by running Install.cmd from the new package. Manual installations still require replacing their `.scr` file. Rebuilding this repository does not update installed copies.

## Tests

```powershell
cargo test --locked --release -p luma -p luma-desktop
```

GPU tests are ignored by default. Run them on a machine with a supported GPU:

```powershell
cargo test --locked --release -p luma -p luma-desktop -- --ignored --test-threads=1
```

The embedded settings form also has an integration test that uses an isolated temporary preferences file:

```powershell
cargo test --locked --release -p luma-desktop --bin Luma embedded_settings_form -- --ignored
```

### Manual acceptance checks

1. Run the windowed application and check animation and resizing.
2. Launch the screensaver with multiple displays connected; each should fill its own screen without borders or a visible cursor.
3. Check mixed resolutions and DPI settings, including displays positioned left of or above the primary display.
4. Let the startup grace period finish, then move the mouse or press a key. All windows should close together.
5. Repeat from PowerShell to check that startup modifier-key events do not close the screensaver.

Automated tests do not replace visual checks on real multi-monitor hardware.

### Preview integration test

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-preview.ps1
```

This opens a temporary host window, launches the `.scr` with `/p`, checks its child window and two sizes, then closes the host and verifies that Luma exits. It does not install or select the screensaver. Preview mode keeps the cursor visible and ignores keyboard/mouse exit gestures. A valid host HWND is required; a missing host exits quietly.

After replacing an installed copy, check its preview and Settings button in Windows Screen Saver Settings.

## Diagnostics

The launcher enables informational logging. Luma writes `Luma.log` next to its executable (`target\release\Luma.log` for a local build), including detected displays, the first rendered frame on each display, and input-triggered exits. The file is overwritten on each launch. If it cannot be created, logging falls back to stderr.

Losing focus does not close the screensaver.

## Roadmap and current limits

- Display hot-plug handling; restart Luma after connecting or disconnecting a monitor.
- Custom application icon.
- Performance tuning for multiple high-resolution displays. Each display currently owns a separate simulation and GPU context; scenes do not span display boundaries.

Both graphical and script-based per-user installers are available.

## Website

The English landing page lives in [`site/`](site/README.md), with interactive palette illustrations and an optional clock preview. The GitHub Actions workflow builds and tests the Windows package, then publishes the site through GitHub Pages. Download buttons open the latest stable GitHub release page, where users can choose MSI or ZIP and read the uninstall rollback note. A documentation update does not replace a released binary. See the [deployment instructions](site/README.md) for the custom domain `luma.ksmvc.ch`.

## Repository structure

| Directory | Purpose |
| --- | --- |
| `luma/` | GPU renderer, shaders, and simulation tests |
| `luma-desktop/` | Windows screensaver, settings, clock, and desktop tests |
| `site/` | Published website and interactive illustration |
| `scripts/` | Build, package, and Windows integration checks |
| `packaging/windows/` | Per-user installer and uninstaller |
| `docs/` | Artwork, release preparation and validation evidence |

The workspace contains only the `luma` and `luma-desktop` packages. The inherited OpenGL/WASM targets, legacy browser demo, and Nix setup were removed; earlier versions remain in Git history. Original Flux credits and license notices are preserved.

## Credits and license

Luma is derived from Flux, copyright © 2021 Sander Melnikov, under the [MIT license](LICENSE). Original rendering work remains credited to Flux and its author. The Luma banner is a new SVG asset created for this fork.
