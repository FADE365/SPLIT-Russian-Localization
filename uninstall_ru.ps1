#requires -Version 5.1
[CmdletBinding()]
param([string]$GameDirectory)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$Host.UI.RawUI.WindowTitle = 'S.P.L.I.T. — удаление русификатора'

$AppId = '3684610'
$BackupSuffix = '.split_ru_backup'

function Add-UniquePath([System.Collections.Generic.List[string]]$List, [string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return }
    if (-not $List.Contains($full)) { $List.Add($full) }
}

function Get-SteamLibraries {
    $result = New-Object 'System.Collections.Generic.List[string]'
    $roots = New-Object 'System.Collections.Generic.List[string]'
    foreach ($regPath in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        try {
            $item = Get-ItemProperty -LiteralPath $regPath -ErrorAction Stop
            Add-UniquePath $roots $item.SteamPath
            Add-UniquePath $roots $item.InstallPath
        } catch {}
    }
    foreach ($root in $roots) {
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

function Get-Candidates {
    $folders = New-Object 'System.Collections.Generic.List[string]'
    if ($GameDirectory) { Add-UniquePath $folders $GameDirectory }
    Add-UniquePath $folders $PSScriptRoot
    Add-UniquePath $folders (Split-Path -Parent $PSScriptRoot)
    foreach ($lib in Get-SteamLibraries) {
        $acf = Join-Path $lib ('steamapps\appmanifest_' + $AppId + '.acf')
        if (-not (Test-Path -LiteralPath $acf -PathType Leaf)) { continue }
        $text = Get-Content -LiteralPath $acf -Raw
        $match = [regex]::Match($text, '"installdir"\s*"([^"]+)"')
        if ($match.Success) {
            Add-UniquePath $folders (Join-Path $lib ('steamapps\common\' + $match.Groups[1].Value))
        }
    }
    return $folders
}

try {
    $found = $null
    foreach ($folder in Get-Candidates) {
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
        foreach ($backup in Get-ChildItem -LiteralPath $folder -Filter ('*.exe' + $BackupSuffix) -File -ErrorAction SilentlyContinue) {
            $exePath = $backup.FullName.Substring(0, $backup.FullName.Length - $BackupSuffix.Length)
            $found = [pscustomobject]@{ Exe = $exePath; Backup = $backup.FullName }
            break
        }
        if ($found) { break }
    }

    while (-not $found) {
        $manual = (Read-Host 'Резервная копия не найдена автоматически. Вставьте путь к папке игры').Trim().Trim('"')
        if (Test-Path -LiteralPath $manual -PathType Container) {
            $backup = Get-ChildItem -LiteralPath $manual -Filter ('*.exe' + $BackupSuffix) -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($backup) {
                $found = [pscustomobject]@{
                    Exe = $backup.FullName.Substring(0, $backup.FullName.Length - $BackupSuffix.Length)
                    Backup = $backup.FullName
                }
            }
        }
        if (-not $found) { Write-Warning 'В этой папке нет резервной копии русификатора.' }
    }

    if (Test-Path -LiteralPath $found.Exe -PathType Leaf) {
        Remove-Item -LiteralPath $found.Exe -Force
    }
    Move-Item -LiteralPath $found.Backup -Destination $found.Exe -Force
    Write-Host ''
    Write-Host 'Оригинальный Steam EXE восстановлен.' -ForegroundColor Green
    [void](Read-Host 'Нажмите Enter для выхода')
    exit 0
} catch {
    Write-Host ''
    Write-Host ('ОШИБКА: ' + $_.Exception.Message) -ForegroundColor Red
    [void](Read-Host 'Нажмите Enter для выхода')
    exit 1
}
