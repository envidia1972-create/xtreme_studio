# Comprueba que este equipo puede compilar Xtreme Studio para Windows.
#
# Son las mismas comprobaciones que hace tool\build_windows.ps1 antes de
# empezar, pero sin compilar nada: sirve para saber en segundos si falta algo.
#
# Uso: powershell -ExecutionPolicy Bypass -File tool\check_toolchain.ps1

$ErrorActionPreference = 'Continue'

$ok = 0
$fail = 0
$warn = 0

function Check($condition, $okText, $failText) {
    if ($condition) {
        Write-Host "[ok]    $okText" -ForegroundColor Green
        $script:ok++
    }
    else {
        Write-Host "[FALTA] $failText" -ForegroundColor Red
        $script:fail++
    }
}

function Warn($condition, $okText, $warnText, $fix) {
    if ($condition) {
        Write-Host "[ok]    $okText" -ForegroundColor Green
        $script:ok++
    }
    else {
        Write-Host "[aviso] $warnText" -ForegroundColor Yellow
        Write-Host "        $fix"
        $script:warn++
    }
}

Write-Host ''
Write-Host '=== Comprobacion del entorno de compilacion ===' -ForegroundColor Cyan
Write-Host ''

# ---------------------------------------------------------------- Flutter
$flutter = 'C:\Users\Usuario\flutter\bin\flutter.bat'
Check (Test-Path $flutter) `
    "Flutter en $flutter" `
    "No se encontro Flutter en $flutter"

if (Test-Path $flutter) {
    $snapshot = 'C:\Users\Usuario\flutter\bin\cache\flutter_tools.snapshot'
    Check (Test-Path $snapshot) `
        'El tool de Flutter esta construido (snapshot presente)' `
        "Falta $snapshot - ejecuta 'flutter doctor' una vez"

    $versionFile = 'C:\Users\Usuario\flutter\bin\cache\flutter.version.json'
    if (Test-Path $versionFile) {
        $v = Get-Content $versionFile -Raw | ConvertFrom-Json
        Write-Host "[info]  Flutter $($v.frameworkVersion) / Dart $($v.dartSdkVersion)"
    }
}

# ------------------------------------------------------------ Visual Studio
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
$vsPath = ''
if (Test-Path $vswhere) {
    $installs = & $vswhere -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($installs) { $vsPath = @($installs)[0] }
}
Check ($vsPath -ne '') `
    "Visual Studio con C++: $vsPath" `
    'Falta Visual Studio Build Tools con la carga de trabajo de C++'

if ($vsPath) {
    $cmakeExe = Join-Path $vsPath 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
    Check (Test-Path $cmakeExe) `
        'CMake incluido en Visual Studio' `
        "Falta CMake en $cmakeExe"

    $vcTools = Get-ChildItem -Path (Join-Path $vsPath 'VC\Tools\MSVC') -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    Check ($null -ne $vcTools) 'Conjunto de herramientas de MSVC' 'Falta MSVC'

    if ($vcTools) {
        $cl = Join-Path $vcTools.FullName 'bin\Hostx64\x64\cl.exe'
        Check (Test-Path $cl) "Compilador cl.exe ($($vcTools.Name))" "Falta cl.exe en $cl"
    }
}

# -------------------------------------------------------------- Windows SDK
$sdkRoots = @(
    'C:\Program Files (x86)\Windows Kits\10\Include',
    'C:\Program Files\Windows Kits\10\Include'
)
$sdkVersions = @()
foreach ($r in $sdkRoots) {
    if (Test-Path $r) {
        $sdkVersions += @(Get-ChildItem $r -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    }
}
Check ($sdkVersions.Count -gt 0) `
    "Windows SDK ($($sdkVersions -join ', '))" `
    'Falta el SDK de Windows 10/11 (componente de Visual Studio)'

# -------------------------------------------------------------------- FFmpeg
$ffmpeg = @(
    'C:\Desarrollo\xtreme_studio\tools\ffmpeg.exe',
    'C:\Desarrollo\xtreme_studio\tools\ffmpeg\bin\ffmpeg.exe'
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $ffmpeg) {
    $onPath = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($onPath) { $ffmpeg = $onPath.Source }
}
Warn ($null -ne $ffmpeg) `
    "FFmpeg: $ffmpeg" `
    'FFmpeg no encontrado' `
    'La app compila igual, pero sin FFmpeg no puede emitir. Descarga una build full/gpl de https://www.gyan.dev/ffmpeg/builds/ y copia ffmpeg.exe a tools\'

# ---------------------------------------------------------- Proyecto Dart
$root = 'C:\Desarrollo\xtreme_studio'
Check (Test-Path (Join-Path $root 'pubspec.yaml')) 'pubspec.yaml presente' 'Falta pubspec.yaml'
Check (Test-Path (Join-Path $root 'windows\CMakeLists.txt')) `
    'Andamiaje de Windows presente' `
    'Falta el andamiaje de Windows (carpeta windows\)'
Check (Test-Path (Join-Path $root '.dart_tool\package_config.json')) `
    'Dependencias resueltas' `
    'Faltan las dependencias: ejecuta flutter pub get'

# ------------------------------------------------------------------ Resumen
Write-Host ''
Write-Host '========================================='
Write-Host "Resultado: $ok correctas, $fail faltantes, $warn avisos"

if ($fail -eq 0) {
    Write-Host ''
    Write-Host 'TODO LISTO PARA COMPILAR:' -ForegroundColor Green
    Write-Host '    powershell -ExecutionPolicy Bypass -File tool\build_windows.ps1'
    exit 0
}
else {
    Write-Host ''
    Write-Host 'Faltan componentes: instala lo indicado arriba antes de compilar.' -ForegroundColor Red
    exit 1
}
