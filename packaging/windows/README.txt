Flux for Windows
================

Install or update
-----------------
1. Extract this ZIP to a folder (do not run Install from inside the ZIP).
2. Close Flux and Windows Screen Saver Settings.
3. Double-click Install.cmd. No administrator rights are needed.
4. Windows Screen Saver Settings opens. Check that Flux is selected,
   choose your wait time and sign-in preference, then click Apply.

The package installs to %LOCALAPPDATA%\Flux\Screensaver.
Run Install.cmd again from a newer extracted package to update.
Your palette, speed, size, and quality preferences are preserved.
The installer selects Flux but does not alter the activation setting,
wait time, or password requirement. Review these in the Windows panel.

Switching from an installer
--------------------------
If you installed with the old graphical EXE, remove that copy through Windows
Installed Apps before running Install.cmd from this ZIP. Appearance preferences
are kept. MSI-owned files are managed by MSI, not by these ZIP scripts; remove
an MSI through Windows Installed Apps before switching to ZIP.

Configure
---------
Click Settings in Windows Screen Saver Settings to change Flux's appearance.
Changes apply when the next screensaver or preview instance starts.

Uninstall
---------
Double-click Uninstall.cmd, either in this package or in the installation
folder. Close Flux and Windows Screen Saver Settings first.
The previous screensaver is restored if still available and Flux is still
selected. If you selected a different saver, that choice is left alone.
Preferences in %LOCALAPPDATA%\Flux\settings.json are kept.

Existing manual installation
----------------------------
A manually copied Flux.scr is not removed by this installer. The new
per-user copy is selected instead. You may remove the old copy separately.

Notes
-----
Windows PowerShell is required. These scripts and the binary are unsigned;
Windows or organization policies may require approval before running them.
This package does not bypass organization screen saver policies.
The SHA256SUMS.txt file can detect accidental package corruption; it is
not a digital signature and does not establish the publisher's identity.

Source: https://github.com/LeonCB/flux
Based on Luma by Kenan Kasumović and Flux by Sander Melnikov. See LICENSE for the MIT license.
