# Installer detection investigation

## Public download status

The old v0.1.0 Inno Setup EXE is withdrawn from public downloads following the
recorded antivirus detections. Its source, hashes and historical investigation
remain available. This withdrawal does not establish a vendor-confirmed false
positive or claim that the MSI fixes every classification. v0.1.1 is the stable release, promoted on 2026-10-12 with the
known [uninstall rollback limitation and recovery](MSI-RELEASE.md) disclosed.
Its unchanged MSI and ZIP reported zero malicious and zero suspicious results
on 2026-10-10; this is not a safety guarantee or code signing.
Reports for the final v0.1.1 artifacts are published in that release's notes.

## Baseline, 2026-09-16

The released v0.1.0 installer, SHA-256
`e0361bffc45347e45bb9721e07adb88c6fbd5556e9e164c7264f3b2a19861fe4`,
received **2/68** detections: **DeepInstinct — MALICIOUS** and
**SecureAge — Malicious**. Microsoft and the other engines with completed
supported results did not flag it. These are generic labels, not an identified
malware family or a vendor explanation of the triggering feature.

The v0.1.0 ZIP, SHA-256
`ddc3c6a62d59771c9e1cb7dd7e75565302b61a60bbc3be9dd782fa052e3ad1d6`,
returned zero malicious and zero suspicious results. A clean archive report
does not prove every nested executable is clean.

Links: [original setup report](https://www.virustotal.com/gui/file/e0361bffc45347e45bb9721e07adb88c6fbd5556e9e164c7264f3b2a19861fe4/detection),
[original ZIP report](https://www.virustotal.com/gui/file/ddc3c6a62d59771c9e1cb7dd7e75565302b61a60bbc3be9dd782fa052e3ad1d6/detection).

## Tested changes on `codex/installer-trust`

These are experimental builds, not a confirmed antivirus fix. At the time of these experiments, production retained
the original installer implementation pending the classification review. The
2026-10-10 distribution decision above supersedes that temporary policy. The
reporting improvements and registered-uninstaller lookup are integrated on
`main` independently without shipping an unproven replacement.

The old setup extracted PowerShell scripts to a temporary directory and ran
them hidden with `-ExecutionPolicy Bypass` for preparation and uninstall.
Those actions only needed local file checks, JSON metadata and the current
user's screensaver registry value. The new `flux-installer` Rust helper performs
those same limited operations directly, with no shell, interpreter, network,
downloads or elevation. The graphical setup no longer ships those legacy
PowerShell action files. The ZIP install scripts and the application's existing
settings dialog remain separate and unchanged.

The second candidate stores its payload without internal compression to make individual
executables directly inspectable. This increases download size. No encryption,
obfuscation, exclusions, antivirus configuration changes or detection suppression
are used. The investigation compares both packaging approaches below.

Upgrade testing also exposed an unrelated compatibility issue: Inno Setup may
register `unins001.exe` after an update. The graphical setup now creates an
Uninstall shortcut using `{uninstallexe}`. ZIP uninstall handoff and integration
tests resolve the registered uninstaller instead of assuming `unins000.exe`.

This removes an unnecessary interpreter dependency and policy override; it is
not proof that either feature caused the two antivirus detections. The helper
validates existing metadata, checks exclusive access to the installed binary,
preserves the original screensaver across upgrades, accepts old ZIP metadata,
and leaves newer user selections untouched. A missing prior screensaver is
restored to no selection. Invalid metadata fails without registry changes.

## Verification

`Verify installer remediation` downloads the original release and checks both
asset hashes before extracting its exact screensaver payload. It builds/tests
the helper, compiles setup using pinned, hash- and publisher-verified Inno Setup
6.7.3, runs the real install/update/uninstall/migration tests on a disposable
Windows runner, and submits the resulting setup and original ZIP to VirusTotal.
The existing public release is not replaced during this investigation.

### Native helper with compressed setup

[Run 35108620453](https://github.com/LeonCB/flux/actions/runs/35108620453)
passed all six helper unit tests and the graphical install, update, uninstall,
and ZIP migration checks. Candidate SHA-256:
`be6f1319fe648f5522811275e2f7beeddcc00f892364d869c0347b967b7d5936`.
Its [completed report](https://www.virustotal.com/gui/file/be6f1319fe648f5522811275e2f7beeddcc00f892364d869c0347b967b7d5936/detection)
showed **3/70**: DeepInstinct, SecureAge, and Skyhigh (SWG), the last with
`BehavesLike.Win32.ObfuscatedPoly.wc`. Skyhigh failed to return a verdict in the
original 2/68 analysis, so these totals have different engine coverage.
Removing PowerShell alone did **not** resolve the detections.

The run itself failed when re-uploading the unchanged ZIP returned HTTP 409
(AlreadyExistsError). The comparison workflow now reuses recorded analysis IDs
only for exactly matching filenames and SHA-256 hashes. Changed files are
submitted normally; actual API failures remain visible.

### Uncompressed setup and component isolation

[Run 35109485218](https://github.com/LeonCB/flux/actions/runs/35109485218)
passed the helper tests, install/update/uninstall/ZIP migration checks, and an
upgrade from the actual v0.1.0 graphical installer followed by uninstall.
It separately scans the setup, exact original `Flux.scr`, and native helper,
and refreshes the unchanged ZIP's recorded analysis. The workflow succeeded.

Subsequent component reports observed on 2026-09-16:

| Component | SHA-256 | Result |
| --- | --- | --- |
| Original `Flux.scr` | `d85ff71abb7de287da02acdb7d159bb6c7da302d6c8d42b0b6bf56012c458ffc` | 1/70, SecureAge: Malicious |
| Experimental native helper | `d8ec0d787424f453ff6fba381a835a6ff9b40ff02cc4dfb4d4bf922f9832c19d` | 1/68, Bkav Pro: W32.Malware.F72E07D5; DeepInstinct failed, Google timed out |
| Uncompressed experimental setup | `05840dab034bfc719890016f372034e8e3774552160ce6cfc66946479cd2a73c` | Initially pending; completed API results below |

[Report refresh 35111623941](https://github.com/LeonCB/flux/actions/runs/35111623941)
retrieved the recorded analysis IDs at 14:53 UTC. Its downloadable JSON preserves
the hashes, analysis IDs, engine versions, signatures and counts:

- Uncompressed setup: 2 malicious (APEX `Malicious`, Microsoft
  `Trojan:Win32/Wacatac.B!ml`), 62 undetected, 5 timeouts, 1 failure and
  4 unsupported results.
- Original screensaver: 1 malicious (APEX `Malicious`), 69 undetected and
  4 unsupported results.
- Helper: 1 malicious (Bkav `W32.Malware.F72E07D5`), 67 undetected,
  1 timeout, 1 failure and 4 unsupported results.
- Original ZIP: 0 malicious/suspicious, 67 undetected, 1 failure and
  6 unsupported results.

The recorded API analysis and the previously observed live screensaver page
name different detecting engines (APEX versus SecureAge). These are separate
observations, not evidence of a confirmed reclassification. Preserve the
analysis-specific JSON when comparing results. The uncompressed candidate is
also flagged and remains experimental; it is not a verified fix.

[Screensaver report](https://www.virustotal.com/gui/file/d85ff71abb7de287da02acdb7d159bb6c7da302d6c8d42b0b6bf56012c458ffc/detection),
[helper report](https://www.virustotal.com/gui/file/d8ec0d787424f453ff6fba381a835a6ff9b40ff02cc4dfb4d4bf922f9832c19d/detection),
[uncompressed setup report](https://www.virustotal.com/gui/file/05840dab034bfc719890016f372034e8e3774552160ce6cfc66946479cd2a73c/detection).

SecureAge's detection on the standalone original screensaver shows that changing
only the installer cannot resolve every classification. The native helper also
introduces a separately flagged file, so it is not promoted as a remediation.
No confirmed malicious behavior or precise vendor rationale has been established
by these generic results. [Vendor review requests](ANTIVIRUS-REVIEW.md)
ask for that determination. SecureAge received both original samples on
2026-09-16 after maintainer authorization; the DeepInstinct review request was
also emailed that day. Both vendor reviews remain pending.

The integrated reporting and uninstall-handoff changes passed the full
[main build 35111478116](https://github.com/LeonCB/flux/actions/runs/35111478116),
including the dedicated PowerShell regression tests.

Generic classifications cannot establish the exact cause. A new file also has
a different hash and reputation. Even if a new scan improves, it does not by
itself prove causation, certify safety, or remove SmartScreen warnings.
Only the detecting vendors can confirm and correct their classifications:
[VirusTotal guidance](https://docs.virustotal.com/docs/false-positive).
