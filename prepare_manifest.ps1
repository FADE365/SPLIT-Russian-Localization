#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'translation_patch.json.gz.b64'
$parts = Join-Path $PSScriptRoot 'translation_patch.parts'
$target = Join-Path $parts '001.part'
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw 'Не найден translation_patch.json.gz.b64.'
}
New-Item -ItemType Directory -Path $parts -Force | Out-Null
$compressed = [Convert]::FromBase64String(([IO.File]::ReadAllText($source)).Trim())
$input = New-Object IO.MemoryStream(,$compressed)
$gzip = New-Object IO.Compression.GzipStream($input, [IO.Compression.CompressionMode]::Decompress)
$output = [IO.File]::Open($target, 'Create', 'Write', 'None')
try { $gzip.CopyTo($output) } finally { $output.Dispose(); $gzip.Dispose(); $input.Dispose() }
