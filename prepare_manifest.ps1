#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$sourceDir = Join-Path $PSScriptRoot 'translation_patch.b64.parts'
$partsDir = Join-Path $PSScriptRoot 'translation_patch.parts'
$target = Join-Path $partsDir '001.part'
if (-not (Test-Path -LiteralPath $sourceDir -PathType Container)) {
    throw 'Не найден каталог translation_patch.b64.parts.'
}
$sourceParts = @(Get-ChildItem -LiteralPath $sourceDir -Filter '*.part' -File | Sort-Object Name)
if ($sourceParts.Count -eq 0) { throw 'Не найдены части манифеста перевода.' }
$base64 = [string]::Concat(($sourceParts | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }))
New-Item -ItemType Directory -Path $partsDir -Force | Out-Null
$compressed = [Convert]::FromBase64String($base64)
$input = New-Object IO.MemoryStream(,$compressed)
$gzip = New-Object IO.Compression.GzipStream($input, [IO.Compression.CompressionMode]::Decompress)
$output = [IO.File]::Open($target, 'Create', 'Write', 'None')
try { $gzip.CopyTo($output) } finally { $output.Dispose(); $gzip.Dispose(); $input.Dispose() }
