#requires -Version 7.0
# Offline tests: no uploads, credentials, GitHub writes, or installed application changes.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/virustotal-common.ps1"
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Assert-Rejected([scriptblock] $Action, [string] $Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert $rejected $Message
}
foreach ($name in @('virustotal-common.ps1', 'submit-virustotal.ps1', 'scan-release.ps1', 'test-virustotal.ps1')) {
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $name), [ref] $tokens, [ref] $errors)
    Assert ($errors.Count -eq 0) "Syntax errors in ${name}: $errors"
}
foreach ($tag in @('v0.1.0', 'v1.2.3-rc.1', 'v1.2.3+build.4')) { Assert-FluxReleaseTag $tag }
foreach ($tag in @('0.1.0', 'v01.2.3', 'v1.0', 'v1.2.3/../../file', "v1.2.3`n", 'v1.2.3;exit')) {
    Assert-Rejected { Assert-FluxReleaseTag $tag } "Unsafe tag accepted: $tag"
}
$directory = Join-Path ([IO.Path]::GetTempPath()) ('flux-vt-test-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $directory
$oldKey = $env:VT_API_KEY
$env:VT_API_KEY = 'offline-test-secret'
# Keep fixture reports out of the real GitHub Actions job summary.
$oldSummary = $env:GITHUB_STEP_SUMMARY
$env:GITHUB_STEP_SUMMARY = $null
$global:fluxVtTestScenario = 'completed'
$global:fluxVtTestCalls = [Collections.Generic.List[object]]::new()
$global:fluxVtTestSleeps = [Collections.Generic.List[int]]::new()
$global:fluxVtTestGitHub = @{ Fixture = $directory; Directory = $null; Views = 0; Edited = $null; Calls = [Collections.Generic.List[string]]::new() }
# Replace only the transport and clock; exercise actual upload/validation/report code.
function Invoke-RestMethod {
    [CmdletBinding()]
    param($Uri, $Method, $Headers, $TimeoutSec, $MaximumRedirection, $Body)
    $global:fluxVtTestCalls.Add([pscustomobject]@{ Uri = [string]$Uri; Method = $Method })
    Assert ($Headers['x-apikey'] -eq 'offline-test-secret') 'Unexpected credential source.'
    Assert ($MaximumRedirection -eq 0) 'Credential-bearing redirects must be disabled.'
    if ($global:fluxVtTestScenario -eq '429' -or $global:fluxVtTestScenario -eq '401') {
        $exception = [Exception]::new('DO NOT LEAK offline-test-secret')
        $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = [int]$global:fluxVtTestScenario })
        throw $exception
    }
    if ($Uri -like '*/files/upload_url') {
        if ($global:fluxVtTestScenario -eq 'bad-host') { return @{ data = 'https://example.org/upload' } }
        return @{ data = 'https://www.virustotal.com/upload/test' }
    }
    if ($Method -eq 'Post') {
        Assert ($Body -is [Net.Http.MultipartFormDataContent]) 'Upload did not use multipart.'
        return @{ data = @{ id = 'test-analysis_123=' } }
    }
    if ($global:fluxVtTestScenario -eq 'pending') { return @{ data = @{ attributes = @{ status = 'queued' } } } }
    if ($global:fluxVtTestScenario -eq 'malformed') { return @{ data = @{ attributes = @{ status = 'completed'; stats = @{} } } } }
    return @{ data = @{ attributes = @{ status = 'completed'; stats = @{ malicious = 1; suspicious = 2 }; results = @{
        Fixture = @{ engine_name = 'Fixture AV'; engine_version = '1'; category = 'malicious'; method = 'heuristic'; result = 'Generic.Test' }
    } } } }
}
function Start-Sleep { param([int]$Milliseconds, [int]$Seconds) $global:fluxVtTestSleeps.Add($Milliseconds + 1000 * $Seconds) }
function gh {
    $arguments = @($args)
    $global:LASTEXITCODE = 0
    $verb = $arguments[1]
    $global:fluxVtTestGitHub.Calls.Add($verb)
    switch ($verb) {
        download {
            $destination = $arguments[[array]::IndexOf($arguments, '--dir') + 1]
            $global:fluxVtTestGitHub.Directory = $destination
            foreach ($name in @('Flux-0.1.0-Setup-x64.exe', 'Flux-0.1.0-windows-x64.zip', 'SHA256SUMS.txt')) {
                Copy-Item -LiteralPath (Join-Path $global:fluxVtTestGitHub.Fixture $name) -Destination $destination
            }
        }
        view {
            $global:fluxVtTestGitHub.Views++
            $body = if ($global:fluxVtTestGitHub.Views -eq 1) { 'Original release notes.' } else { 'Original release notes. Maintainer edit during scan.' }
            if ($global:fluxVtTestGitHub.RecordedNotes) { $body += [Environment]::NewLine + $global:fluxVtTestGitHub.RecordedNotes }
            @{ body = $body } | ConvertTo-Json
        }
        edit {
            Assert ($arguments.Count -eq 7 -and $arguments[5] -eq '--notes-file') 'Unexpected release mutation.'
            $global:fluxVtTestGitHub.Edited = Get-Content -LiteralPath $arguments[6] -Raw
        }
        default { throw "Unexpected GitHub operation: $verb" }
    }
}
function Write-TestChecksums {
    Get-ChildItem -LiteralPath $directory -File | Where-Object Extension -in @('.exe', '.zip') | ForEach-Object {
        '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name
    } | Set-Content -LiteralPath (Join-Path $directory 'SHA256SUMS.txt')
}
function Run-Scan([string]$Scenario, [switch]$ReportOnly, [string]$Notes = '', [switch]$ReuseRecordedAnalyses) {
    $global:fluxVtTestScenario = $Scenario
    $global:fluxVtTestCalls.Clear()
    $global:fluxVtTestSleeps.Clear()
    & "$PSScriptRoot/submit-virustotal.ps1" -Tag v0.1.0 -Directory $directory -ReportOnly:$ReportOnly -ExistingNotes $Notes -ReuseRecordedAnalyses:$ReuseRecordedAnalyses -WarningAction SilentlyContinue
}
try {
    foreach ($name in @('Flux-0.1.0-Setup-x64.exe', 'Flux-0.1.0-windows-x64.zip')) {
        [IO.File]::WriteAllBytes((Join-Path $directory $name), [byte[]](0, 1, 13, 10, 127, 128, 255, [byte]$name.Length))
    }
    Write-TestChecksums
    $assets = @(Get-FluxScanAssets $directory v0.1.0)
    # MSI packaging uses the same validation and never accepts ambiguous installers.
    $exe = Join-Path $directory 'Flux-0.1.0-Setup-x64.exe'
    $msi = Join-Path $directory 'Flux-0.1.0-Setup-x64.msi'
    Copy-Item -LiteralPath $exe -Destination $msi
    $msiLine = '{0}  Flux-0.1.0-Setup-x64.msi' -f (Get-FileHash $msi).Hash.ToLowerInvariant()
    Add-Content -LiteralPath (Join-Path $directory 'SHA256SUMS.txt') -Value $msiLine
    Assert-Rejected { Get-FluxScanAssets $directory v0.1.0 } 'Ambiguous EXE/MSI assets were accepted.'
    (Get-Content (Join-Path $directory 'SHA256SUMS.txt') | Where-Object { $_ -notlike '*-Setup-x64.exe' }) | Set-Content (Join-Path $directory 'SHA256SUMS.txt')
    $msiAssets = @(Get-FluxScanAssets $directory v0.1.0)
    Assert ($msiAssets[0].Name.EndsWith('.msi')) 'MSI installer was not selected.'
    Remove-Item -LiteralPath $msi
    Write-TestChecksums
    $multipart = New-VirusTotalMultipart $assets[0].File
    try {
        Assert ($multipart.Headers.ContentType.ToString() -match '^multipart/form-data; boundary=Flux[a-f0-9]+$') 'Invalid multipart boundary.'
        $wire = [Text.Encoding]::Latin1.GetString($multipart.ReadAsByteArrayAsync().GetAwaiter().GetResult())
        Assert ($wire.Contains('name="file"; filename="Flux-0.1.0-Setup-x64.exe"') -and -not $wire.Contains('filename*')) 'Invalid multipart disposition.'
        Assert ($wire.Contains([Text.Encoding]::Latin1.GetString([IO.File]::ReadAllBytes($assets[0].File.FullName)))) 'Binary payload was modified.'
    } finally { $multipart.Dispose() }

    $scan = Run-Scan completed
    Assert (-not $scan.HasErrors -and $global:fluxVtTestCalls.Count -eq 4) "Completed scan failed (calls: $($global:fluxVtTestCalls.Count)): $(Get-Content -LiteralPath $scan.ReportPath -Raw)"
    Assert ($global:fluxVtTestSleeps.Count -eq 3) 'Requests were not rate limited.'
    $report = Get-Content -LiteralPath $scan.ReportPath -Raw
    Assert ($report.Contains('1 malicious, 2 suspicious')) 'Detection counts were not reported accurately.'
    Assert ($report.Contains('Fixture AV: Generic.Test (malicious)')) 'Engine diagnosis was omitted.'
    Assert (-not $report.Contains($env:VT_API_KEY)) 'Credential leaked.'
    $scan = Run-Scan completed -ReportOnly -Notes $report
    Assert (-not $scan.HasErrors -and $global:fluxVtTestCalls.Count -eq 2) 'Report-only refresh failed.'
    Assert (@($global:fluxVtTestCalls | Where-Object Method -eq Post).Count -eq 0) 'Refresh uploaded files.'
    $scan = Run-Scan completed -ReportOnly -Notes ($report.Replace($assets[0].Hash, ('a' * 64)))
    Assert ($scan.HasErrors -and $global:fluxVtTestCalls.Count -eq 1) 'Refresh accepted analysis for a different hash.'
    $scan = Run-Scan completed -ReuseRecordedAnalyses -Notes ($report.Replace($assets[0].Hash, ('a' * 64)))
    Assert (-not $scan.HasErrors -and $global:fluxVtTestCalls.Count -eq 3) 'Matching archive analysis was not reused.'
    Assert (@($global:fluxVtTestCalls | Where-Object Method -eq Post).Count -eq 1) 'Unchanged archive was uploaded again.'
    Assert-Rejected { Get-FluxScanAssets $directory v0.1.0 @('../secret.txt') } 'Unsafe diagnostic artifact was accepted.'

    $scan = Run-Scan pending
    Assert (-not $scan.HasErrors -and $global:fluxVtTestCalls.Count -eq 8) 'Pending polling was not bounded.'
    $pending = Get-Content -LiteralPath $scan.ReportPath -Raw
    Assert ($pending.Contains('Analysis pending') -and -not $pending.Contains('Analysis completed')) 'Queued scan claimed completion.'
    $scan = Run-Scan malformed
    Assert $scan.HasErrors 'Missing detection counts were accepted.'
    Assert (-not (Get-Content -LiteralPath $scan.ReportPath -Raw).Contains('Analysis completed')) 'Malformed scan claimed completion.'
    $scan = Run-Scan 429
    Assert ($scan.HasErrors -and $global:fluxVtTestCalls.Count -eq 6) '429 retries were not bounded to three per file.'
    Assert (@($global:fluxVtTestSleeps | Where-Object { $_ -eq 60000 }).Count -eq 4) '429 retries did not back off.'
    $scan = Run-Scan 401
    Assert ($scan.HasErrors -and $global:fluxVtTestCalls.Count -eq 2) 'Authentication failure was not handled.'
    $failure = Get-Content -LiteralPath $scan.ReportPath -Raw
    Assert ($failure.Contains('HTTP 401') -and -not $failure.Contains('offline-test-secret')) 'Unsafe or missing failure diagnostics.'

    $originalBody = "# Flux`n`nOriginal notes with `$literal and accents: qualità.`n`n## Downloads`nKeep these links."
    $merged = Merge-VirusTotalNotes $originalBody $report
    $updated = Merge-VirusTotalNotes $merged $pending
    Assert ($updated.StartsWith($originalBody)) 'Unrelated release notes were changed.'
    Assert (([regex]::Matches($updated, '<!-- flux-virustotal:start -->')).Count -eq 1) 'Retry duplicated reports.'
    Assert ($updated.Contains('Analysis pending') -and -not $updated.Contains('Analysis completed')) 'Retry did not replace prior report.'
    Assert-Rejected { Merge-VirusTotalNotes '<!-- flux-virustotal:start -->' $report } 'Broken report markers were accepted.'

    $global:fluxVtTestScenario = 'completed'
    $global:fluxVtTestGitHub.RecordedNotes = $report
    $global:fluxVtTestCalls.Clear()
    & "$PSScriptRoot/scan-release.ps1" -Tag v0.1.0 -Repository test/flux
    Assert ($global:fluxVtTestCalls.Count -eq 2) 'Release scan did not reuse both matching analyses.'
    Assert (@($global:fluxVtTestCalls | Where-Object Method -eq Post).Count -eq 0) 'Publication uploaded previously scanned release assets again.'
    Assert ($global:fluxVtTestGitHub.Edited.Contains('Maintainer edit during scan.')) 'End-to-end scan overwrote a concurrent note edit.'
    Assert ($global:fluxVtTestGitHub.Edited.Contains('1 malicious, 2 suspicious')) 'End-to-end scan did not add actual results.'
    Assert (($global:fluxVtTestGitHub.Calls -join ',') -eq 'download,view,view,edit') 'Unexpected GitHub mutation or missing notes refresh.'

    # A 33 MiB file must use the large-file endpoint, with credential-safe host validation.
    $stream = [IO.File]::OpenWrite($assets[0].File.FullName)
    try { $stream.SetLength(33MB) } finally { $stream.Dispose() }
    Write-TestChecksums
    $scan = Run-Scan completed
    Assert (-not $scan.HasErrors -and $global:fluxVtTestCalls[0].Uri.EndsWith('/files/upload_url')) 'Large upload endpoint was not used.'
    $scan = Run-Scan bad-host
    Assert ($scan.HasErrors -and @($global:fluxVtTestCalls | Where-Object Uri -like '*example.org*').Count -eq 0) 'Credentials sent to an untrusted upload host.'

    [IO.File]::WriteAllText($assets[1].File.FullName, 'modified after checksums')
    $global:fluxVtTestCalls.Clear()
    Assert-Rejected { Run-Scan completed } 'Changed artifact was accepted.'
    Assert ($global:fluxVtTestCalls.Count -eq 0) 'A file was uploaded before both checksums were verified.'
    $env:VT_API_KEY = ''
    Assert-Rejected { Run-Scan completed } 'Missing API key was accepted.'
    Write-Output 'PASS: syntax, tags, exact asset hashes, multipart bytes, completed/pending/malformed reports, refresh-only, throttling/retries, safe diagnostics, end-to-end release note updates, large uploads, and missing key.'
} finally {
    $env:VT_API_KEY = $oldKey
    $env:GITHUB_STEP_SUMMARY = $oldSummary
    Remove-Variable -Name fluxVtTestCalls,fluxVtTestSleeps,fluxVtTestScenario -Scope Global
    if ($global:fluxVtTestGitHub.Directory) {
        foreach ($name in @('Flux-0.1.0-Setup-x64.exe', 'Flux-0.1.0-windows-x64.zip', 'SHA256SUMS.txt', 'virustotal.md', 'virustotal-results.json', 'release-notes.md')) {
            $path = Join-Path $global:fluxVtTestGitHub.Directory $name
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
        }
        Remove-Item -LiteralPath $global:fluxVtTestGitHub.Directory
    }
    Remove-Variable -Name fluxVtTestGitHub -Scope Global
    # Delete only the exact files made in this test; no recursive computed-path cleanup.
    foreach ($name in @('Flux-0.1.0-Setup-x64.exe', 'Flux-0.1.0-windows-x64.zip', 'SHA256SUMS.txt', 'virustotal.md', 'virustotal-results.json')) {
        $path = Join-Path $directory $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    Remove-Item -LiteralPath $directory
}
