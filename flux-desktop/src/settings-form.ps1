param([switch]$TestMode)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$settingsPath = $env:FLUX_SETTINGS_PATH
if ([string]::IsNullOrWhiteSpace($settingsPath)) { throw 'The settings path is unavailable.' }
$defaults = @{ palette = 'Original'; speed = 100; size = 100; quality = 'Balanced'; clockEnabled = $false; clockMonitor = 'Primary' }
$values = $defaults.Clone()
$warning = ''
if (Test-Path -LiteralPath $settingsPath) {
    try {
        $loaded = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        foreach ($name in $defaults.Keys) {
            if ($loaded.PSObject.Properties.Name -contains $name) { $values[$name] = $loaded.$name }
        }
        if ($values.palette -notin @('Original','Plasma','Poolside','Freedom','Aurora') -or
            $values.speed -notin @(50,75,100,125,150,200) -or
            $values.size -notin @(50,75,100,125,150,200) -or
            $values.quality -notin @('Low','Balanced','High')) { throw 'Invalid settings values.' }
    } catch {
        $values = $defaults.Clone()
        $warning = 'Saved settings could not be read. Defaults are shown; Save will replace the file.'
    }
}
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Flux settings'
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$form.AutoScaleMode = 'Dpi'
$form.ClientSize = New-Object System.Drawing.Size(460, 462)
$heading = New-Object System.Windows.Forms.Label
$heading.Text = 'Make Flux your own'
$heading.Font = New-Object System.Drawing.Font('Segoe UI', 15)
$heading.SetBounds(24, 18, 410, 35)
$form.Controls.Add($heading)
$controls = @{}
function Add-Choice($name, $labelText, $items, $top) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $labelText
    $label.SetBounds(24, $top + 4, 165, 26)
    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.Name = $name
    $combo.AccessibleName = $labelText
    $combo.DropDownStyle = 'DropDownList'
    $combo.SetBounds(200, $top, 232, 30)
    foreach ($item in $items) { [void]$combo.Items.Add([string]$item) }
    $form.Controls.Add($label)
    $form.Controls.Add($combo)
    $controls[$name] = $combo
}
Add-Choice 'palette' 'Color palette' @('Original','Plasma','Poolside','Freedom','Aurora') 70
Add-Choice 'speed' 'Animation speed (%)' @(50,75,100,125,150,200) 112
Add-Choice 'size' 'Line size (%)' @(50,75,100,125,150,200) 154
Add-Choice 'quality' 'Simulation quality' @('Low','Balanced','High') 196
$clock = New-Object System.Windows.Forms.CheckBox
$clock.Text = 'Show clock (24-hour, top center)'
$clock.AccessibleName = 'Show clock'
$clock.SetBounds(24, 238, 400, 30)
$form.Controls.Add($clock)
$monitorLabels = [ordered]@{ 'Primary display' = 'Primary' }
$index = 0
foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
    $index++
    $label = "Display $index - $($screen.Bounds.Width) x $($screen.Bounds.Height)"
    if ($screen.Primary) { $label += ' (primary)' }
    $monitorLabels[$label] = $screen.DeviceName
}
if ($values.clockMonitor -and $values.clockMonitor -notin @($monitorLabels.Values)) {
    $monitorLabels["Unavailable display: $($values.clockMonitor)"] = $values.clockMonitor
}
Add-Choice 'clockMonitor' 'Clock display' @($monitorLabels.Keys) 280
$clock.Add_CheckedChanged({ $controls.clockMonitor.Enabled = $clock.Checked })
function Set-Choices($prefs) {
    foreach ($name in @('palette','speed','size','quality')) { $controls[$name].SelectedItem = [string]$prefs[$name] }
    $clock.Checked = ($prefs.clockEnabled -eq $true)
    $selected = 'Primary display'
    foreach ($label in $monitorLabels.Keys) { if ($monitorLabels[$label] -eq $prefs.clockMonitor) { $selected = $label } }
    $controls.clockMonitor.SelectedItem = $selected
    $controls.clockMonitor.Enabled = $clock.Checked
}
Set-Choices $values
$note = New-Object System.Windows.Forms.Label
$note.Text = if ($warning) { $warning } else { 'Changes apply the next time Flux or its Windows preview starts. Higher quality uses more GPU resources.' }
$note.SetBounds(24, 328, 410, 60)
$form.Controls.Add($note)
$restore = New-Object System.Windows.Forms.Button
$restore.Text = 'Restore defaults'
$restore.SetBounds(24, 406, 140, 32)
$restore.Add_Click({ Set-Choices $defaults })
$form.Controls.Add($restore)
$cancel = New-Object System.Windows.Forms.Button
$cancel.Text = 'Cancel'
$cancel.SetBounds(236, 406, 90, 32)
$cancel.Add_Click({ $form.Close() })
$form.CancelButton = $cancel
$form.Controls.Add($cancel)
$save = New-Object System.Windows.Forms.Button
$save.Text = 'Save'
$save.SetBounds(338, 406, 94, 32)
$form.AcceptButton = $save
$form.Controls.Add($save)
function Save-Preferences {
    $result = [ordered]@{
        palette = [string]$controls.palette.SelectedItem
        speed = [int]$controls.speed.SelectedItem
        size = [int]$controls.size.SelectedItem
        quality = [string]$controls.quality.SelectedItem
        clockEnabled = [bool]$clock.Checked
        clockMonitor = [string]$monitorLabels[[string]$controls.clockMonitor.SelectedItem]
    }
    $directory = Split-Path $settingsPath -Parent
    [void][System.IO.Directory]::CreateDirectory($directory)
    $temporary = Join-Path $directory ([Guid]::NewGuid().ToString() + '.tmp')
    try {
        [System.IO.File]::WriteAllText($temporary, ($result | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
        if ([System.IO.File]::Exists($settingsPath)) {
            # Windows PowerShell converts $null to an empty string for this overload.
            # NullString passes an actual null backup path to .NET.
            [System.IO.File]::Replace($temporary, $settingsPath, [System.Management.Automation.Language.NullString]::Value)
        } else { [System.IO.File]::Move($temporary, $settingsPath) }
    } finally {
        if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) }
    }
}
$save.Add_Click({
    try { Save-Preferences; $form.Close() }
    catch { [void][System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Unable to save Flux settings', 'OK', 'Error') }
})
try {
    if ($TestMode) {
        # The caller supplies an isolated test path; never point this at real preferences.
        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()
        Set-Choices @{ palette='Plasma'; speed=150; size=125; quality='High'; clockEnabled=$true; clockMonitor='Primary' }
        Save-Preferences
        $saved = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        if ($saved.palette -ne 'Plasma' -or $saved.speed -ne 150 -or $saved.size -ne 125 -or $saved.quality -ne 'High') { throw 'Preference save mismatch.' }
        # Exercise replacement as well as initial creation; the previous bug only
        # affected an existing settings file.
        Set-Choices @{ palette='Aurora'; speed=75; size=200; quality='Low' }
        Save-Preferences
        $replaced = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        if ($replaced.palette -ne 'Aurora' -or $replaced.speed -ne 75 -or $replaced.size -ne 200 -or $replaced.quality -ne 'Low') { throw 'Preference replacement mismatch.' }
        Set-Choices @{ palette='Plasma'; speed=150; size=125; quality='High'; clockEnabled=$true; clockMonitor='Primary' }
        Save-Preferences
        $restore.PerformClick()
        if ($controls.palette.SelectedItem -ne 'Original' -or $controls.speed.SelectedItem -ne '100' -or $controls.size.SelectedItem -ne '100' -or $controls.quality.SelectedItem -ne 'Balanced') { throw 'Restore defaults failed.' }
        if ($clock.Checked -or $controls.clockMonitor.Enabled) { throw 'Clock defaults failed.' }
        $beforeCancel = Get-Content -LiteralPath $settingsPath -Raw
        $cancel.PerformClick()
        if ((Get-Content -LiteralPath $settingsPath -Raw) -ne $beforeCancel) { throw 'Cancel modified settings.' }
        Write-Output 'PASS: settings controls, persistence, defaults, and cancellation.'
    } else { [void]$form.ShowDialog() }
} finally { $form.Dispose() }
