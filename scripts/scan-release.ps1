#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Tag,
    [Parameter(Mandatory)][string] $Repository,
    [switch] $ReportOnly
)
. "$PSScriptRoot/virustotal-common.ps1"
Assert-FluxReleaseTag $Tag
if ($Repository -notmatch '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z') { throw 'Invalid repository name.' }
if ([string]::IsNullOrWhiteSpace($env:VT_API_KEY)) { throw 'Configure the VT_API_KEY repository secret before scanning.' }
$null = Get-Command gh -ErrorAction Stop
$version = $Tag.Substring(1)
$directory = Join-Path (Split-Path $PSScriptRoot -Parent) ('target/virustotal/' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $directory

gh release download $Tag --repo $Repository --dir $directory --pattern "Flux-$version-Setup-x64.*" --pattern "Flux-$version-windows-x64.zip" --pattern SHA256SUMS.txt
if ($LASTEXITCODE -ne 0) { throw 'Could not download all final release assets.' }
$json = gh release view $Tag --repo $Repository --json body
if ($LASTEXITCODE -ne 0) { throw 'Could not read release notes.' }
$body = [string](($json | ConvertFrom-Json).body)
$scan = & "$PSScriptRoot/submit-virustotal.ps1" -Tag $Tag -Directory $directory -ExistingNotes $body -ReportOnly:$ReportOnly -ReuseRecordedAnalyses
$report = Get-Content -LiteralPath $scan.ReportPath -Raw
if ($env:GITHUB_STEP_SUMMARY) { $report | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY }

# Re-read after polling to preserve unrelated note edits made during the scan.
$json = gh release view $Tag --repo $Repository --json body
if ($LASTEXITCODE -ne 0) { throw 'Could not refresh release notes.' }
$body = [string](($json | ConvertFrom-Json).body)
$notesPath = Join-Path $directory 'release-notes.md'
Merge-VirusTotalNotes $body $report | Set-Content -LiteralPath $notesPath -Encoding utf8NoBOM
gh release edit $Tag --repo $Repository --notes-file $notesPath
if ($LASTEXITCODE -ne 0) { throw 'Could not update VirusTotal release notes.' }
if ($scan.HasErrors) { throw 'VirusTotal did not finish all requests. Diagnostics were saved in the release notes; retry or refresh results.' }
