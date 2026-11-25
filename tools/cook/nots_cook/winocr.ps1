param([string]$List, [string]$Out, [string]$Lang = 'ar-SA')
# Reads the PNG files named in $List with Windows' built-in OCR and writes one
# JSON line per file: name, and the words of each line with their boxes.
Add-Type -AssemblyName System.Runtime.WindowsRuntime
[void][Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
[void][Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
[void][Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
[void][Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime]
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($op, $type) {
    $t = $asTaskGeneric.MakeGenericMethod($type).Invoke($null, @($op))
    $t.Wait(-1) | Out-Null
    $t.Result
}
$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage([Windows.Globalization.Language]::new($Lang))
$w = New-Object System.IO.StreamWriter($Out, $false, (New-Object System.Text.UTF8Encoding($false)))
foreach ($path in Get-Content -Encoding UTF8 $List) {
    if (-not $path) { continue }
    try {
        $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
        $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
        $dec = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $bmp = Await ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $res = Await ($engine.RecognizeAsync($bmp)) ([Windows.Media.Ocr.OcrResult])
        $lines = @()
        foreach ($l in $res.Lines) {
            $ws = @()
            foreach ($x in $l.Words) {
                $r = $x.BoundingRect
                $ws += ,@($x.Text, [math]::Round($r.X, 1), [math]::Round($r.Y, 1), [math]::Round($r.X + $r.Width, 1), [math]::Round($r.Y + $r.Height, 1))
            }
            $lines += ,$ws
        }
        $stream.Dispose()
        $o = @{ name = [IO.Path]::GetFileNameWithoutExtension($path); lines = $lines }
        $w.WriteLine(($o | ConvertTo-Json -Depth 6 -Compress))
        $w.Flush()
    } catch {
        # A page that fails here is still read by the other engine.
    }
}
$w.Close()
