# Compila tools\fake_ffmpeg.exe, el doble de FFmpeg para verify_engine.
#
# Uso:
#   powershell -ExecutionPolicy Bypass -File tool\build_fake_ffmpeg.ps1
#
# No hace falta para usar la app: solo para la prueba de integracion del motor
# en Windows.
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) {
    Write-Host 'ERROR: no se encontro vswhere.exe (Visual Studio).' -ForegroundColor Red
    exit 1
}
$vsPath = @(& $vswhere -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)[0]
if (-not $vsPath) {
    Write-Host 'ERROR: falta la carga de trabajo C++ de Visual Studio.' -ForegroundColor Red
    exit 1
}

$vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $vcvars)) {
    Write-Host "ERROR: no se encontro $vcvars" -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Force -Path tools | Out-Null
Write-Host 'Compilando tools\fake_ffmpeg.exe...'
cmd /c "`"$vcvars`" >nul && cl /nologo /O2 /Fe:tools\fake_ffmpeg.exe tool\fake_ffmpeg.c"
if ($LASTEXITCODE -ne 0 -or -not (Test-Path 'tools\fake_ffmpeg.exe')) {
    Write-Host 'Fallo la compilacion del FFmpeg falso.' -ForegroundColor Red
    exit 1
}
Write-Host '[ok] tools\fake_ffmpeg.exe listo' -ForegroundColor Green
Write-Host 'Ahora: dart run tool\verify_engine.dart'
