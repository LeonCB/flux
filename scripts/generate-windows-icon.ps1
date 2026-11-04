# Render the existing site icon into a multi-resolution Windows ICO without external dependencies.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$repo = Split-Path $PSScriptRoot -Parent
$null = New-Item -ItemType Directory -Path (Join-Path $repo 'target') -Force
[xml]$svg = Get-Content -LiteralPath (Join-Path $repo 'site/icon.svg') -Raw
$ns = New-Object Xml.XmlNamespaceManager($svg.NameTable)
$ns.AddNamespace('s', 'http://www.w3.org/2000/svg')
$rect = $svg.SelectSingleNode('/s:svg/s:rect', $ns)
$shape = $svg.SelectSingleNode('/s:svg/s:path', $ns)
$gradient = $svg.SelectSingleNode('//s:linearGradient', $ns)
if ($svg.svg.viewBox -ne '0 0 64 64' -or $gradient.x2 -ne '1' -or $gradient.y2 -ne '1' -or $shape.d -match '[^MC0-9.,\s-]') {
    throw 'The SVG structure changed. Update the Windows icon renderer to match it.'
}
$path = New-Object Drawing.Drawing2D.GraphicsPath
$background = New-Object Drawing.Drawing2D.GraphicsPath
try {
    $tokens = @([regex]::Matches($shape.d, '[MC]|-?\d+(?:\.\d+)?') | ForEach-Object Value)
    $i = 0
    $x = $y = 0
    while ($i -lt $tokens.Count) {
        $command = $tokens[$i++]
        if ($command -eq 'M') {
            $path.StartFigure()
            $x = [float]::Parse($tokens[$i++], [Globalization.CultureInfo]::InvariantCulture)
            $y = [float]::Parse($tokens[$i++], [Globalization.CultureInfo]::InvariantCulture)
        } elseif ($command -eq 'C') {
            $p = @(0..5 | ForEach-Object { [float]::Parse($tokens[$i++], [Globalization.CultureInfo]::InvariantCulture) })
            $path.AddBezier($x, $y, $p[0], $p[1], $p[2], $p[3], $p[4], $p[5])
            $x, $y = $p[4], $p[5]
        } else { throw "Unsupported SVG path command: $command" }
    }
    $diameter = 2 * [float]$rect.rx
    $edge = 64 - $diameter
    $background.AddArc(0, 0, $diameter, $diameter, 180, 90)
    $background.AddArc($edge, 0, $diameter, $diameter, 270, 90)
    $background.AddArc($edge, $edge, $diameter, $diameter, 0, 90)
    $background.AddArc(0, $edge, $diameter, $diameter, 90, 90)
    $background.CloseFigure()
    $images = New-Object 'Collections.Generic.List[byte[]]'
    $sizes = @(16, 20, 24, 32, 48, 64, 128, 256)
    foreach ($size in $sizes) {
        $large = [Drawing.Bitmap]::new($size * 4, $size * 4)
        $bitmap = [Drawing.Bitmap]::new($size, $size)
        $g = [Drawing.Graphics]::FromImage($large)
        $output = [Drawing.Graphics]::FromImage($bitmap)
        $fill = New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml($rect.fill))
        $bounds = $path.GetBounds()
        $brush = New-Object Drawing.Drawing2D.LinearGradientBrush($bounds.Location, ([Drawing.PointF]::new($bounds.Right, $bounds.Bottom)), [Drawing.Color]::White, [Drawing.Color]::White)
        $blend = New-Object Drawing.Drawing2D.ColorBlend
        $blend.Colors = [Drawing.Color[]]@($gradient.stop | ForEach-Object { [Drawing.ColorTranslator]::FromHtml($_.'stop-color') })
        $blend.Positions = [single[]]@(0, .5, 1)
        $brush.InterpolationColors = $blend
        $pen = New-Object Drawing.Pen($brush, [float]$shape.'stroke-width')
        $pen.StartCap = $pen.EndCap = [Drawing.Drawing2D.LineCap]::Round
        $stream = New-Object IO.MemoryStream
        try {
            $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.ScaleTransform($size * 4 / 64, $size * 4 / 64)
            $g.FillPath($fill, $background)
            $g.DrawPath($pen, $path)
            $output.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $output.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $output.DrawImage($large, 0, 0, $size, $size)
            $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
            $images.Add($stream.ToArray())
            if ($size -eq 256) { $bitmap.Save((Join-Path $repo 'target/flux-icon-preview.png'), [Drawing.Imaging.ImageFormat]::Png) }
        } finally {
            $stream.Dispose(); $pen.Dispose(); $brush.Dispose(); $fill.Dispose()
            $g.Dispose(); $output.Dispose(); $large.Dispose(); $bitmap.Dispose()
        }
    }
    $destination = Join-Path $repo 'packaging/windows/Flux.ico'
    $writer = New-Object IO.BinaryWriter([IO.File]::Create($destination))
    try {
        $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
        $offset = 6 + 16 * $sizes.Count
        for ($i = 0; $i -lt $sizes.Count; $i++) {
            $dimension = [byte]$(if ($sizes[$i] -eq 256) { 0 } else { $sizes[$i] })
            $writer.Write($dimension); $writer.Write($dimension)
            $writer.Write([byte]0); $writer.Write([byte]0)
            $writer.Write([uint16]1); $writer.Write([uint16]32)
            $writer.Write([uint32]$images[$i].Length); $writer.Write([uint32]$offset)
            $offset += $images[$i].Length
        }
        foreach ($bytes in $images) { $writer.Write($bytes) }
    } finally { $writer.Dispose() }
    Write-Output "Windows icon: $destination"
} finally { $path.Dispose(); $background.Dispose() }
