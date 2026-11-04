# VirusTotal release reports

The **Scan release with VirusTotal** GitHub Actions workflow scans the final
`Flux-<version>-Setup-x64.msi` (or the historical EXE) and
`Flux-<version>-windows-x64.zip` attached to a
GitHub release. Configure `VT_API_KEY` as a repository Actions secret. The key is
passed only to the scanning step and is never written to reports.

## Running a scan

- New releases: upload both packages and `SHA256SUMS.txt` before publishing.
  The `release: published` event starts the scan automatically after publication.
  Matching recorded analysis IDs are reused when the filename and SHA-256 still
  match, so scanning a draft first does not upload the same files again.
- Existing releases or drafts: open **Actions → Scan release with VirusTotal →
  Run workflow**, select the reviewed branch (normally `main`), and enter the release tag, for example `v0.1.1`.
  This also allows a maintainer to scan a draft before publishing it.
- If results are still pending, run again with **Refresh recorded analyses
  without uploading the files again** enabled. This looks up the recorded
  analysis IDs only when their filenames and SHA-256 hashes match the assets.
- If an upload failed or no analysis ID is recorded, retry with that option off.

Adding the secret alone does not scan an existing release. The workflow must exist on the default branch before it can be dispatched;
the selected reviewed branch supplies the scanning implementation.
Releases published by another workflow using `GITHUB_TOKEN` do not trigger a
second workflow: that release workflow must explicitly invoke the scanning
script or dispatch this workflow instead.

## Behavior and limitations

Both files are checked against the release's `SHA256SUMS.txt` before any upload.
The workflow downloads existing assets; it does not rebuild, replace, sign,
publish, or delete release assets. Checksums verify consistency, not authorship.

Uploads are public VirusTotal samples. Do not use this workflow for private
builds or packages containing secrets. Files over 32 MiB use VirusTotal's
large-file endpoint; files over 650 MiB are rejected. Requests are spaced by
at least 16 seconds, HTTP 429 responses have bounded retries, and polling is
bounded. Account quotas still apply.

The workflow adds or replaces only its marked VirusTotal section in the release
notes, preserving other text. It includes SHA-256 report links, analysis IDs,
pending states, and actual detection counts only after a completed response.
Completed reports also list detecting engines and their labels; the JSON artifact
records engine versions and methods for comparison between releases.
Reports are also included in the Actions summary and diagnostic artifacts.
API failures are reported without raw responses or credentials; the run fails
after saving available results so that a retry is visible. Detections themselves
do not automatically fail the run: review the reports for possible false positives.

A report is not a safety guarantee, does not replace Authenticode signing,
and does not remove Microsoft Defender SmartScreen warnings. Scanning a ZIP
does not establish that every nested file has a separate completed report.

Run offline integration tests with:

```powershell
pwsh -NoProfile -File scripts/test-virustotal.ps1
```

API references: [file upload](https://docs.virustotal.com/reference/files-scan),
[large-file upload URL](https://docs.virustotal.com/reference/files-upload-url),
[analysis status](https://docs.virustotal.com/reference/analysis).
The multipart format and release-report approach follow
[PaneShift](https://github.com/Ken5998/PaneShift/blob/main/docs/CODE_SIGNING.md).

The **Verify installer remediation** workflow on `codex/installer-trust` builds and tests the graphical
installer against the exact, checksum-verified v0.1.0 screensaver payload. It
scans the candidate and saves reports as Actions artifacts without changing the
published release. See [installer investigation](INSTALLER-TRUST.md).

For this comparison, unchanged files reuse matching recorded analysis IDs;
diagnostic scans include `Flux.scr` and `flux-install-helper.exe` as individual
files, each verified against the candidate checksums. The normal release workflow
still scans its two published packages. Neither workflow treats a detection as
an automatic false positive.

On `main`, **Refresh installer investigation reports** accepts the verification
run ID and refreshes its recorded analysis IDs without executing or uploading
the candidate files. Updated Markdown and JSON reports are saved as Actions
artifacts; the published release is not modified.
