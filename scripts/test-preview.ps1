# A small preview host for testing /p without installing the screensaver.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class FluxPreviewNative {
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hwnd, uint command);
    [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hwnd, out Rect rect);
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
}
"@
$repo = Split-Path $PSScriptRoot -Parent
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Flux preview test'
$form.ClientSize = New-Object System.Drawing.Size(480, 300)
$process = $null
try {
    $form.Show()
    $info = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $repo 'target\release\Flux.scr'), "/p $($form.Handle.ToInt64())")
    $info.UseShellExecute = $false
    $info.EnvironmentVariables['RUST_LOG'] = 'info'
    $process = [System.Diagnostics.Process]::Start($info)
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    $child = [IntPtr]::Zero
    while ([DateTime]::UtcNow -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        $child = [FluxPreviewNative]::GetWindow($form.Handle, 5)
        if ($child -ne [IntPtr]::Zero) { break }
        if ($process.HasExited) { throw 'Preview exited before creating a child window.' }
        Start-Sleep -Milliseconds 50
    }
    if ($child -eq [IntPtr]::Zero) { throw 'No preview child window was created.' }
    if ([FluxPreviewNative]::GetParent($child) -ne $form.Handle) { throw 'Incorrect preview parent.' }
    foreach ($size in @((New-Object System.Drawing.Size(480,300)), (New-Object System.Drawing.Size(640,360)))) {
        $form.ClientSize = $size
        $matched = $false
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        do {
            [System.Windows.Forms.Application]::DoEvents()
            $rect = New-Object FluxPreviewNative+Rect
            [void][FluxPreviewNative]::GetClientRect($child, [ref]$rect)
            $matched = ($rect.Right -eq $size.Width -and $rect.Bottom -eq $size.Height)
            Start-Sleep -Milliseconds 50
        } while (!$matched -and [DateTime]::UtcNow -lt $deadline)
        if (!$matched) { throw "Preview failed to resize to $size." }
        Write-Output "Preview child size verified: $size"
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(2)
    while ([DateTime]::UtcNow -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }
    $form.Close()
    if (!$process.WaitForExit(5000)) { throw 'Preview did not exit after host closed.' }
    if ($process.ExitCode -ne 0) { throw "Preview failed with exit code $($process.ExitCode)." }
    Write-Output 'PASS: preview parent, resizing, and shutdown.'
} finally {
    if ($process -and !$process.HasExited) { $process.Kill() }
    $form.Dispose()
}
