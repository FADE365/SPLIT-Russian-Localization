#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$GameDirectory
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Host.UI.RawUI.WindowTitle = 'S.P.L.I.T. — установка русификатора'

$AppId = '3684610'
$Magic = [UInt32]0x43504447
$ExpectedExeSha256 = '2F5E7E3EC06E1E3ECA3623E75DF65DE342DC39E21B886B59BA5D455BC752C9F6'
$BackupSuffix = '.split_ru_backup'
$ManifestPartsPath = Join-Path $PSScriptRoot 'translation_patch.parts'
$GdreReleaseApi = 'https://api.github.com/repos/GDRETools/gdsdecomp/releases/latest'

function Wait-Exit([string]$Message) {
    Write-Host ''
    Write-Host $Message
    if ($Host.Name -notmatch 'ServerRemoteHost') {
        [void](Read-Host 'Нажмите Enter для выхода')
    }
}

function Get-Sha256Text([string]$Text) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-PckFooterInfo([string]$ExePath) {
    $fs = [System.IO.File]::Open($ExePath, 'Open', 'Read', 'ReadWrite')
    try {
        if ($fs.Length -lt 108) { return $null }
        $br = New-Object System.IO.BinaryReader($fs)
        $fs.Seek(-4, [System.IO.SeekOrigin]::End) | Out-Null
        if ($br.ReadUInt32() -ne $Magic) { return $null }
        $fs.Seek(-12, [System.IO.SeekOrigin]::End) | Out-Null
        $pckSize = $br.ReadUInt64()
        if ($pckSize -lt 96 -or $pckSize -gt ($fs.Length - 12)) { return $null }
        $start = $fs.Length - 12 - [Int64]$pckSize
        $fs.Position = $start
        if ($br.ReadUInt32() -ne $Magic) { return $null }
        $version = $br.ReadUInt32()
        $major = $br.ReadUInt32()
        $minor = $br.ReadUInt32()
        $patch = $br.ReadUInt32()
        $flags = $br.ReadUInt32()
        $fileBase = $br.ReadUInt64()
        $fs.Position += 64
        $count = $br.ReadUInt32()
        return [pscustomobject]@{
            Start = $start
            Size = [Int64]$pckSize
            Version = $version
            Major = $major
            Minor = $minor
            Patch = $patch
            Flags = $flags
            FileBase = [Int64]$fileBase
            Count = $count
            ExeLength = $fs.Length
        }
    } finally {
        $fs.Dispose()
    }
}

function Add-UniquePath([System.Collections.Generic.List[string]]$List, [string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return }
    if (-not $List.Contains($full)) { $List.Add($full) }
}

function Get-SteamLibraries {
    $result = New-Object 'System.Collections.Generic.List[string]'
    $steamRoots = New-Object 'System.Collections.Generic.List[string]'
    foreach ($regPath in @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )) {
        try {
            $item = Get-ItemProperty -LiteralPath $regPath -ErrorAction Stop
            Add-UniquePath $steamRoots $item.SteamPath
            Add-UniquePath $steamRoots $item.InstallPath
        } catch {}
    }
    foreach ($root in $steamRoots) {
        Add-UniquePath $result $root
        $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf -PathType Leaf) {
            $text = Get-Content -LiteralPath $vdf -Raw
            foreach ($match in [regex]::Matches($text, '(?m)^\s*"path"\s*"([^"]+)"')) {
                Add-UniquePath $result ($match.Groups[1].Value -replace '\\\\', '\')
            }
        }
    }
    return $result
}

function Get-SplitGameFolders {
    $folders = New-Object 'System.Collections.Generic.List[string]'
    if ($GameDirectory) { Add-UniquePath $folders $GameDirectory }
    Add-UniquePath $folders $PSScriptRoot
    Add-UniquePath $folders (Split-Path -Parent $PSScriptRoot)

    foreach ($lib in Get-SteamLibraries) {
        $manifest = Join-Path $lib ('steamapps\appmanifest_' + $AppId + '.acf')
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { continue }
        $text = Get-Content -LiteralPath $manifest -Raw
        $match = [regex]::Match($text, '"installdir"\s*"([^"]+)"')
        if ($match.Success) {
            Add-UniquePath $folders (Join-Path $lib ('steamapps\common\' + $match.Groups[1].Value))
        }
    }
    return $folders
}

function Find-SplitExe([string]$Folder) {
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { return $null }
    $preferred = Join-Path $Folder 'split.exe'
    if (Test-Path -LiteralPath $preferred -PathType Leaf) {
        $info = Get-PckFooterInfo $preferred
        if ($null -ne $info -and $info.Major -eq 4 -and $info.Minor -eq 4) {
            return [pscustomobject]@{ File = Get-Item -LiteralPath $preferred; Info = $info }
        }
    }
    foreach ($exe in Get-ChildItem -LiteralPath $Folder -Filter '*.exe' -File -ErrorAction SilentlyContinue) {
        if ($exe.Name -match '(?i)(unins|crash|console|vcredist|setup)') { continue }
        $info = Get-PckFooterInfo $exe.FullName
        if ($null -ne $info -and $info.Major -eq 4 -and $info.Minor -eq 4 -and $info.Count -gt 500) {
            return [pscustomobject]@{ File = $exe; Info = $info }
        }
    }
    return $null
}

function Resolve-GameTarget {
    foreach ($folder in Get-SplitGameFolders) {
        $candidate = Find-SplitExe $folder
        if ($null -ne $candidate) { return $candidate }
    }
    while ($true) {
        Write-Host ''
        $manual = Read-Host 'Steam-версия не найдена автоматически. Вставьте путь к папке игры'
        $manual = $manual.Trim().Trim('"')
        $candidate = Find-SplitExe $manual
        if ($null -ne $candidate) { return $candidate }
        Write-Warning 'В указанной папке не найден совместимый split.exe.'
    }
}

function Invoke-Checked([string]$Exe, [string[]]$Arguments, [string]$Stage) {
    Write-Host ('  ' + $Stage + '...')
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Stage завершён с кодом $LASTEXITCODE."
    }
}

function Get-GdreTools {
    $toolRoot = Join-Path $env:LOCALAPPDATA 'SPLIT-Russian-Localization\GDRETools'
    $existing = Get-ChildItem -LiteralPath $toolRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)^gdre.*tools.*\.exe$' } |
        Sort-Object Length -Descending |
        Select-Object -First 1
    if ($null -ne $existing) { return $existing.FullName }

    Write-Host 'Загрузка Godot RE Tools с официального GitHub...'
    New-Item -ItemType Directory -Path $toolRoot -Force | Out-Null
    $headers = @{ 'User-Agent' = 'SPLIT-Russian-Localization-Installer' }
    $release = Invoke-RestMethod -UseBasicParsing -Headers $headers -Uri $GdreReleaseApi
    $asset = $release.assets |
        Where-Object { $_.name -match '(?i)windows.*\.zip$' -and $_.name -notmatch '(?i)(mono|symbols|source)' } |
        Select-Object -First 1
    if ($null -eq $asset) {
        throw 'В последнем выпуске GDRETools не найден Windows ZIP.'
    }

    $zipPath = Join-Path $toolRoot $asset.name
    Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri $asset.browser_download_url -OutFile $zipPath
    Expand-Archive -LiteralPath $zipPath -DestinationPath $toolRoot -Force
    Remove-Item -LiteralPath $zipPath -Force

    $found = Get-ChildItem -LiteralPath $toolRoot -Recurse -File |
        Where-Object { $_.Name -match '(?i)^gdre.*tools.*\.exe$' } |
        Sort-Object Length -Descending |
        Select-Object -First 1
    if ($null -eq $found) { throw 'gdre_tools.exe не найден после распаковки.' }
    return $found.FullName
}

function Normalize-Text([string]$Text) {
    return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
}

function Apply-TranslationPatch([object]$FilePatch, [string]$RecoveredRoot) {
    $relative = [string]$FilePatch.path
    $path = Join-Path $RecoveredRoot ($relative -replace '/', '\')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "После восстановления отсутствует файл: $relative"
    }

    $text = Normalize-Text ([System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8))
    $sourceHash = Get-Sha256Text $text
    if ($sourceHash -ne ([string]$FilePatch.source_sha256).ToLowerInvariant()) {
        throw "Исходный текст $relative не совпал с поддерживаемой версией игры."
    }

    $builder = New-Object System.Text.StringBuilder
    $cursor = 0
    foreach ($operation in @($FilePatch.operations | Sort-Object { [Int64]$_.offset })) {
        $offset = [Int32]$operation.offset
        $old = [string]$operation.old
        $new = [string]$operation.new
        if ($offset -lt $cursor -or ($offset + $old.Length) -gt $text.Length) {
            throw "Некорректное смещение патча в $relative."
        }
        if ($old.Length -gt 0 -and $text.Substring($offset, $old.Length) -cne $old) {
            throw "Не удалось применить фрагмент перевода к $relative."
        }
        [void]$builder.Append($text, $cursor, $offset - $cursor)
        [void]$builder.Append($new)
        $cursor = $offset + $old.Length
    }
    [void]$builder.Append($text, $cursor, $text.Length - $cursor)
    $patched = $builder.ToString()

    $targetHash = Get-Sha256Text $patched
    if ($targetHash -ne ([string]$FilePatch.target_sha256).ToLowerInvariant()) {
        throw "Контрольная сумма переведённого $relative не совпала."
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $patched, $utf8NoBom)
}

function Copy-Bytes([System.IO.Stream]$InputStream, [System.IO.Stream]$OutputStream, [Int64]$Count) {
    $buffer = New-Object byte[] (4MB)
    $remaining = $Count
    while ($remaining -gt 0) {
        $want = [Math]::Min([Int64]$buffer.Length, $remaining)
        $read = $InputStream.Read($buffer, 0, [int]$want)
        if ($read -le 0) { throw 'Неожиданный конец файла при копировании EXE.' }
        $OutputStream.Write($buffer, 0, $read)
        $remaining -= $read
    }
}

function Embed-Pck([string]$OriginalExe, [string]$PckPath, [string]$OutputExe, [object]$OriginalInfo) {
    $input = [System.IO.File]::OpenRead($OriginalExe)
    $output = [System.IO.File]::Open($OutputExe, 'Create', 'ReadWrite', 'None')
    try {
        Copy-Bytes $input $output ([Int64]$OriginalInfo.Start)
        $startPad = [int]((8 - ($output.Position % 8)) % 8)
        if ($startPad -gt 0) { $output.Write((New-Object byte[] $startPad), 0, $startPad) }
        $newPckStart = $output.Position

        $pck = [System.IO.File]::OpenRead($PckPath)
        try { $pck.CopyTo($output, 4MB) } finally { $pck.Dispose() }

        $footerPad = [int]((8 - ((($output.Position - $newPckStart) + 12) % 8)) % 8)
        if ($footerPad -gt 0) { $output.Write((New-Object byte[] $footerPad), 0, $footerPad) }
        $newPckSize = [UInt64]($output.Position - $newPckStart)
        $writer = New-Object System.IO.BinaryWriter($output)
        $writer.Write($newPckSize)
        $writer.Write($Magic)
        $writer.Flush()
        $output.Flush($true)
    } finally {
        $input.Dispose()
        $output.Dispose()
    }
}

$workRoot = $null
$tempExe = $null
try {
    Write-Host 'S.P.L.I.T. — русский перевод для Steam'
    Write-Host 'Версия установщика: 1.0-test'
    Write-Host ''

    if (-not (Test-Path -LiteralPath $ManifestPartsPath -PathType Container)) {
        throw 'Рядом с установщиком отсутствует каталог translation_patch.parts.'
    }
    $manifestParts = @(Get-ChildItem -LiteralPath $ManifestPartsPath -Filter '*.part' -File | Sort-Object Name)
    if ($manifestParts.Count -eq 0) { throw 'Фрагменты манифеста перевода не найдены.' }
    $manifestText = [string]::Concat(($manifestParts | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8) }))
    $manifest = $manifestText | ConvertFrom-Json
    if ([string]$manifest.required_exe_sha256 -ne $ExpectedExeSha256.ToLowerInvariant()) {
        throw 'Внутренний манифест имеет неожиданную версию.'
    }

    $target = Resolve-GameTarget
    $exePath = $target.File.FullName
    $backupPath = $exePath + $BackupSuffix
    $tempExe = $exePath + '.split_ru_installing'

    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
        throw "Резервная копия уже существует:`n$backupPath`nРусификатор, вероятно, уже установлен."
    }

    Write-Host ('Игра: ' + $exePath)
    Write-Host 'Проверка версии Steam EXE...'
    $actualHash = (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash
    if ($actualHash -ne $ExpectedExeSha256) {
        throw "Эта версия split.exe пока не поддерживается.`nОжидалось: $ExpectedExeSha256`nПолучено:  $actualHash"
    }

    $gdre = Get-GdreTools
    Write-Host ('GDRETools: ' + $gdre)

    $workRoot = Join-Path $env:TEMP ('split_ru_' + [Guid]::NewGuid().ToString('N'))
    $recoveredRoot = Join-Path $workRoot 'recovered'
    $patchedPck = Join-Path $workRoot 'split_ru.pck'
    New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

    Write-Host 'Создание резервной копии оригинального EXE...'
    Copy-Item -LiteralPath $exePath -Destination $backupPath -Force

    $recoverArgs = New-Object 'System.Collections.Generic.List[string]'
    $recoverArgs.Add('--headless')
    $recoverArgs.Add("--recover=$backupPath")
    $recoverArgs.Add("--output=$recoveredRoot")
    $recoverArgs.Add('--skip-checksum-check')
    foreach ($file in $manifest.files) {
        $recoverArgs.Add('--include=res://' + [string]$file.source_packed_path)
        $recoverArgs.Add('--include=res://' + [string]$file.path + '.remap')
    }
    Invoke-Checked $gdre $recoverArgs.ToArray() 'Восстановление изменяемых ресурсов'

    $missing = @($manifest.files | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $recoveredRoot (([string]$_.path) -replace '/', '\')) -PathType Leaf)
    })
    if ($missing.Count -gt 0) {
        Write-Warning 'Выборочное восстановление не вернуло все исходники. Выполняется полное восстановление проекта.'
        Remove-Item -LiteralPath $recoveredRoot -Recurse -Force -ErrorAction SilentlyContinue
        Invoke-Checked $gdre @('--headless', "--recover=$backupPath", "--output=$recoveredRoot", '--skip-checksum-check') 'Полное восстановление ресурсов'
    }

    Write-Host 'Применение русского перевода...'
    foreach ($file in $manifest.files) {
        Write-Host ('  ' + [string]$file.path)
        Apply-TranslationPatch $file $recoveredRoot
    }

    $scriptFiles = @($manifest.files | Where-Object { ([string]$_.path).EndsWith('.gd') })
    $compileArgs = New-Object 'System.Collections.Generic.List[string]'
    $compileArgs.Add('--headless')
    $compileArgs.Add('--bytecode=4.4.1')
    foreach ($file in $scriptFiles) {
        $source = Join-Path $recoveredRoot (([string]$file.path) -replace '/', '\')
        $compileArgs.Add("--compile=$source")
    }
    Invoke-Checked $gdre $compileArgs.ToArray() 'Компиляция GDScript'

    $sceneFiles = @($manifest.files | Where-Object { ([string]$_.path).EndsWith('.tscn') })
    $convertArgs = New-Object 'System.Collections.Generic.List[string]'
    $convertArgs.Add('--headless')
    foreach ($file in $sceneFiles) {
        $source = Join-Path $recoveredRoot (([string]$file.path) -replace '/', '\')
        $convertArgs.Add("--txt-to-bin=$source")
    }
    Invoke-Checked $gdre $convertArgs.ToArray() 'Конвертация сцен в бинарный формат'

    $pckArgs = New-Object 'System.Collections.Generic.List[string]'
    $pckArgs.Add('--headless')
    $pckArgs.Add("--pck-patch=$backupPath")
    $pckArgs.Add("--output=$patchedPck")
    foreach ($file in $manifest.files) {
        $relative = [string]$file.path
        $sourceText = Join-Path $recoveredRoot ($relative -replace '/', '\')
        if ($relative.EndsWith('.gd')) {
            $sourceBinary = [System.IO.Path]::ChangeExtension($sourceText, '.gdc')
        } else {
            $sourceBinary = [System.IO.Path]::ChangeExtension($sourceText, '.scn')
        }
        if (-not (Test-Path -LiteralPath $sourceBinary -PathType Leaf)) {
            throw "Не создан бинарный ресурс: $sourceBinary"
        }
        $destination = 'res://' + [string]$file.patch_destination
        $pckArgs.Add("--patch-file=$sourceBinary=$destination")
    }
    Invoke-Checked $gdre $pckArgs.ToArray() 'Сборка локализованного PCK'

    if (-not (Test-Path -LiteralPath $patchedPck -PathType Leaf)) {
        throw 'GDRETools не создал локализованный PCK.'
    }
    $pckStream = [System.IO.File]::OpenRead($patchedPck)
    try {
        $reader = New-Object System.IO.BinaryReader($pckStream)
        if ($reader.ReadUInt32() -ne $Magic) { throw 'Созданный PCK имеет неверный заголовок.' }
    } finally {
        $pckStream.Dispose()
    }

    Write-Host 'Встраивание локализованного PCK в Steam EXE...'
    Embed-Pck $backupPath $patchedPck $tempExe $target.Info
    $newInfo = Get-PckFooterInfo $tempExe
    if ($null -eq $newInfo -or $newInfo.Major -ne 4 -or $newInfo.Minor -ne 4 -or $newInfo.Count -lt 1000) {
        throw 'Итоговый EXE не прошёл структурную проверку.'
    }

    Remove-Item -LiteralPath $exePath -Force
    Move-Item -LiteralPath $tempExe -Destination $exePath -Force
    $tempExe = $null

    Write-Host ''
    Write-Host 'Русификатор установлен.' -ForegroundColor Green
    Write-Host 'Запускайте игру обычной кнопкой «Играть» в Steam.'
    Write-Host ('Резервная копия: ' + $backupPath)
    Wait-Exit 'Готово.'
    exit 0
} catch {
    Write-Host ''
    Write-Host ('ОШИБКА: ' + $_.Exception.Message) -ForegroundColor Red
    try {
        if ($tempExe -and (Test-Path -LiteralPath $tempExe)) {
            Remove-Item -LiteralPath $tempExe -Force
        }
    } catch {}
    Wait-Exit 'Установка не завершена. Оригинальная игра сохранена в резервной копии.'
    exit 1
} finally {
    if ($workRoot -and (Test-Path -LiteralPath $workRoot)) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
