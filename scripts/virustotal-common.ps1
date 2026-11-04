# Shared helpers for scanning public, final release assets. Requires PowerShell 7.
$ErrorActionPreference = 'Stop'

function Assert-FluxReleaseTag([string] $Tag) {
    if ($Tag -cnotmatch '\Av(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?\z') {
        throw 'Expected a release tag such as v0.1.0.'
    }
}

function Get-FluxScanAssets([string] $Directory, [string] $Tag, [string[]] $AdditionalFiles = @()) {
    Assert-FluxReleaseTag $Tag
    $version = $Tag.Substring(1)
    $checksums = @(Get-Content -LiteralPath (Join-Path $Directory 'SHA256SUMS.txt'))
    # Validate BOTH files before uploading either one.
    foreach ($name in $AdditionalFiles) {
        if ($name -cnotin @('Flux.scr', 'flux-install-helper.exe')) { throw 'Unexpected diagnostic artifact name.' }
    }
    $installerNames = @("Flux-$version-Setup-x64.exe", "Flux-$version-Setup-x64.msi")
    $installerEntries = @($installerNames | Where-Object { $candidate = $_; @($checksums | Where-Object { $_ -cmatch ('\A[0-9a-fA-F]{64}  ' + [regex]::Escape($candidate) + '\z') }).Count -gt 0 })
    if ($installerEntries.Count -ne 1) { throw 'Checksums must identify exactly one installer (EXE or MSI).' }
    $assets = foreach ($name in (@($installerEntries[0], "Flux-$version-windows-x64.zip") + $AdditionalFiles)) {
        $file = Get-Item -LiteralPath (Join-Path $Directory $name)
        if ($file.PSIsContainer -or $file.Length -eq 0 -or $file.Length -gt 650MB) {
            throw "Invalid release artifact size: $name."
        }
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $matchesForFile = @($checksums | Where-Object { $_ -cmatch ('\A[0-9a-fA-F]{64}  ' + [regex]::Escape($name) + '\z') })
        if ($matchesForFile.Count -ne 1 -or $matchesForFile[0].Substring(0, 64).ToLowerInvariant() -cne $hash) {
            throw "Final artifact checksum mismatch or duplicate/missing entry: $name."
        }
        [pscustomobject]@{ File = $file; Name = $name; Hash = $hash; Url = "https://www.virustotal.com/gui/file/$hash/detection" }
    }
    return $assets
}

function New-VirusTotalMultipart([IO.FileInfo] $File) {
    # Explicit headers match the large-file parser; stream the original bytes.
    $boundary = 'Flux' + [Guid]::NewGuid().ToString('N')
    $multipart = [Net.Http.MultipartFormDataContent]::new($boundary)
    try {
        $content = [Net.Http.StreamContent]::new($File.OpenRead())
        $multipart.Add($content)
        $content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('application/octet-stream')
        $disposition = [Net.Http.Headers.ContentDispositionHeaderValue]::new('form-data')
        $disposition.Name = '"file"'
        $disposition.FileName = '"' + $File.Name.Replace('"', '') + '"'
        $content.Headers.ContentDisposition = $disposition
        $multipart.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::Parse("multipart/form-data; boundary=$boundary")
        return ,$multipart
    } catch { $multipart.Dispose(); throw }
}

function Invoke-VirusTotal([string] $Uri, [string] $Method = 'Get', [IO.FileInfo] $File) {
    $uriObject = [Uri] $Uri
    if ($uriObject.Scheme -ne 'https' -or $uriObject.UserInfo -or $uriObject.Port -ne 443 -or
        ($uriObject.Host -ne 'virustotal.com' -and -not $uriObject.Host.EndsWith('.virustotal.com'))) {
        throw 'Unexpected VirusTotal upload host.'
    }
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $delay = 16 - ([DateTime]::UtcNow - $script:vtLastRequest).TotalSeconds
        if ($delay -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Ceiling($delay * 1000)) }
        $script:vtLastRequest = [DateTime]::UtcNow
        $multipart = $null
        try {
            $parameters = @{
                Uri = $Uri; Method = $Method; Headers = @{ 'x-apikey' = $env:VT_API_KEY }
                TimeoutSec = 180; MaximumRedirection = 0; Verbose = $false; Debug = $false
            }
            if ($File) { $multipart = New-VirusTotalMultipart $File; $parameters.Body = $multipart }
            return Invoke-RestMethod @parameters
        } catch {
            $responseProperty = $_.Exception.PSObject.Properties['Response']
            $status = if ($responseProperty -and $responseProperty.Value) { [int] $responseProperty.Value.StatusCode } else { 0 }
            if ($status -eq 429 -and $attempt -lt 2) { Start-Sleep -Seconds 60; continue }
            # Never print headers, upload URLs, raw API responses or exception details.
            throw "VirusTotal request unavailable (HTTP $status)."
        } finally { if ($multipart) { $multipart.Dispose() } }
    }
}

function Get-VirusTotalAnalysisId([string] $Notes, $Asset) {
    $prefix = "- [$($Asset.Name)]($($Asset.Url))"
    $lines = @($Notes -split '\r?\n' | Where-Object { $_.StartsWith($prefix, [StringComparison]::Ordinal) })
    if ($lines.Count -ne 1 -or $lines[0] -notmatch 'analysis ID: `([A-Za-z0-9=_-]+)`') {
        throw 'No matching existing analysis ID for this filename and hash.'
    }
    return $Matches[1]
}

function Merge-VirusTotalNotes([string] $Body, [string] $Report) {
    $start = '<!-- flux-virustotal:start -->'
    $end = '<!-- flux-virustotal:end -->'
    $hasStart = $Body.Contains($start)
    $hasEnd = $Body.Contains($end)
    if ($hasStart -or $hasEnd) {
        $pattern = '(?s)' + [regex]::Escape($start) + '.*?' + [regex]::Escape($end)
        if (([regex]::Matches($Body, [regex]::Escape($start))).Count -ne 1 -or
            ([regex]::Matches($Body, [regex]::Escape($end))).Count -ne 1 -or
            ([regex]::Matches($Body, $pattern)).Count -ne 1) { throw 'Ambiguous VirusTotal section markers.' }
        return [regex]::Replace($Body, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($m) $Report.Trim() })
    }
    return $Body.TrimEnd() + "`n`n" + $Report.Trim() + "`n"
}
