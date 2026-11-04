# Suspected false-positive review request

SecureAge: submitted on 2026-09-16 with both checksum-verified original samples.
The official form confirmed **Report Submitted** and forwarding to its detection
team. Email notification was requested. No case number was displayed.
DeepInstinct: emailed on 2026-09-16. Zoho confirmed the message in Sent Mail
at 17:01 Europe/Zurich. The message includes the original sample download,
source, checksums and VirusTotal report links. Vendor review is pending.

## SecureAge

Subject: Classification review request — Flux open-source Windows screensaver

Please review the generic `Malicious` classifications for these public files:

- Released installer `Flux-0.1.0-Setup-x64.exe`, SHA-256
  `e0361bffc45347e45bb9721e07adb88c6fbd5556e9e164c7264f3b2a19861fe4`.
- The exact screensaver extracted from the checksum-verified v0.1.0 ZIP,
  `Flux.scr`, SHA-256
  `d85ff71abb7de287da02acdb7d159bb6c7da302d6c8d42b0b6bf56012c458ffc`.

Source: https://github.com/LeonCB/flux

Public release and checksums: https://github.com/LeonCB/flux/releases/tag/v0.1.0

Reports:
https://www.virustotal.com/gui/file/e0361bffc45347e45bb9721e07adb88c6fbd5556e9e164c7264f3b2a19861fe4/detection
https://www.virustotal.com/gui/file/d85ff71abb7de287da02acdb7d159bb6c7da302d6c8d42b0b6bf56012c458ffc/detection

Flux is an MIT-licensed Windows screensaver based on Luma and the original Flux. It renders animated
graphics and offers a settings dialog. The v0.1.0 installer is an unsigned
Inno Setup package that installs for the current user and sets that user's
`Control Panel\Desktop\SCRNSAVE.EXE` selection. It preserves the previous choice
for uninstall. It does not request administrator rights. Its setup custom
actions use PowerShell for local metadata and registry operations, and the
screensaver uses an embedded PowerShell Windows Forms settings dialog.

The unchanged ZIP received zero detections, while the extracted screensaver
received SecureAge's generic detection. That discrepancy motivated component
isolation; we do not consider the ZIP verdict proof that its contents are safe.
A native installer-helper experiment did not eliminate the original setup
detections. Please confirm whether your classifications are correct, identify
the triggering behavior or component if possible, and correct them if your
review establishes a false positive. No antivirus exclusions or protection
changes have been applied.

Official submission route:
https://www.secureage.com/contact-us
(the "Submit false positive" option).

## DeepInstinct

Subject: Classification review request — unsigned Flux Inno Setup installer

Please review `Flux-0.1.0-Setup-x64.exe`, SHA-256
`e0361bffc45347e45bb9721e07adb88c6fbd5556e9e164c7264f3b2a19861fe4`,
classified as `MALICIOUS` in VirusTotal.

Source, release and setup report are linked above. The extracted original
screensaver's separate report returned no DeepInstinct detection, whereas the
original installer and a tested native-helper/standard-compression candidate
were flagged. This suggests an installer-related difference for your engine,
but does not establish the precise cause. Please review the public released
sample, explain the classification if possible, and correct it if appropriate.

Recipient: `vt-fps-requests@deepinstinct.com`, verified in
[VirusTotal's false-positive contacts](https://docs.virustotal.com/docs/false-positive-contacts)
on 2026-09-16.

## Submission notes

Use the maintainer's approved contact email; do not use a GitHub noreply address.
The requests contain only public project information and public sample hashes.
If a vendor requires a sample attachment, use the exact hash-verified released
file, not a rebuilt file under the same name. Keep the original report and source
links attached to the review case. The final classification belongs to the vendor.
