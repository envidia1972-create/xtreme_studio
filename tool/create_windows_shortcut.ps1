# Crea un acceso directo de Xtreme Studio en el Escritorio, con su icono.
#
# Uso:
#   powershell -ExecutionPolicy Bypass -File tool\create_windows_shortcut.ps1
#
# El icono esta incrustado en xtreme_studio.exe (Runner.rc -> app_icon.ico).
#
# Si el .exe esta en otra carpeta (por ejemplo, el artifact descargado):
#   powershell -ExecutionPolicy Bypass -File tool\create_windows_shortcut.ps1 -Exe C:\XtremeStudio\xtreme_studio.exe
param(
    [string]$Exe = ''
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$exe = if ($Exe) { $Exe } else { Join-Path $root 'build\windows\x64\runner\Release\xtreme_studio.exe' }
if (-not (Test-Path $exe)) {
    Write-Host "ERROR: no se encontro $exe" -ForegroundColor Red
    Write-Host 'Compila primero con tool\build_windows.ps1' -ForegroundColor Yellow
    exit 1
}

$desktop = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktop 'Xtreme Studio.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $exe
$shortcut.WorkingDirectory = Split-Path -Parent $exe
$shortcut.IconLocation = "$exe,0"
$shortcut.Description = 'Xtreme Studio - consola de emision para radio'
$shortcut.Save()

Write-Host "[ok] Acceso directo creado: $shortcutPath" -ForegroundColor Green
Write-Host '[ok] Usa el icono incrustado en xtreme_studio.exe' -ForegroundColor Green
