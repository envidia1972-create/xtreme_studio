# Verifica que la compilacion de Windows quedo completa y con codigo fresco.
#
# Se ejecuta DESPUES de tool\build_windows.ps1. Existe porque los fallos de
# empaquetado de este proyecto no son "la compilacion falla", sino que termina
# "bien" dejando algo mal:
#
#   - data\app.so de una version anterior (la app abre sin los ultimos cambios),
#   - o un binario compilado SIN la version inyectada, que se cree 0.1.0 y pida
#     actualizar para siempre.
#
# Ninguno de los dos da un mensaje de error. Comprobarlos aqui es barato.
#
# Uso:
#   powershell -ExecutionPolicy Bypass -File tool\verificar_compilacion.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$outDir = Join-Path $root 'build\windows\x64\runner\Release'

Write-Host ''
Write-Host '=== Verificacion de la compilacion ===' -ForegroundColor Cyan

if (-not (Test-Path $outDir)) {
    Write-Host 'La carpeta Release no existe: no se compilo.' -ForegroundColor Red
    exit 1
}

# ------------------------------------------------ 1. Archivos imprescindibles
$required = [ordered]@{
    'xtreme_studio.exe'                                   = 'el ejecutable'
    'flutter_windows.dll'                                 = 'el motor de Flutter'
    'ffmpeg.exe'                                          = 'el motor de audio'
    'data\icudtl.dat'                                     = 'datos de idioma'
    'data\app.so'                                         = 'el codigo de la aplicacion'
    'data\flutter_assets\AssetManifest.bin'               = 'los recursos de la interfaz'
    'data\flutter_assets\fonts\MaterialIcons-Regular.otf' = 'la tipografia de iconos'
}

$missing = @()
foreach ($rel in $required.Keys) {
    if (-not (Test-Path (Join-Path $outDir $rel))) { $missing += $rel }
}

if ($missing.Count -gt 0) {
    Write-Host ''
    Write-Host '[FALLA] Faltan archivos: la aplicacion no arrancara.' -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "   - $_  ($($required[$_]))" -ForegroundColor Red }
    exit 1
}
Write-Host "[ok] Los $($required.Count) archivos imprescindibles estan presentes" -ForegroundColor Green

# ------------------------------- 2. El codigo compilado es posterior al fuente
$appSo = Join-Path $outDir 'data\app.so'
$newestSource = Get-ChildItem -Path (Join-Path $root 'lib') -Recurse -Filter '*.dart' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $newestSource) { $newestSource = Get-Item (Join-Path $root 'pubspec.yaml') }

$soTime = (Get-Item $appSo).LastWriteTime
Write-Host ''
Write-Host "  app.so             : $soTime"
Write-Host "  ultimo cambio lib/ : $($newestSource.LastWriteTime)  ($($newestSource.Name))"

if ($soTime -lt $newestSource.LastWriteTime) {
    Write-Host ''
    Write-Host '[FALLA] El codigo compilado es MAS VIEJO que el codigo fuente.' -ForegroundColor Red
    Write-Host '        La aplicacion correra con una version anterior.' -ForegroundColor Red
    Write-Host ''
    Write-Host '        Solucion: borra los sellos y vuelve a compilar:' -ForegroundColor Yellow
    Write-Host '          Get-ChildItem .dart_tool\flutter_build -Recurse -Include aot_elf_release.stamp,app.so | Remove-Item -Force'
    Write-Host '          powershell -ExecutionPolicy Bypass -File tool\build_windows.ps1'
    exit 1
}
Write-Host '[ok] El codigo compilado es posterior al ultimo cambio del fuente' -ForegroundColor Green

# -------------------------------- 3. La version de pubspec esta dentro del binario
# Compilar con `flutter build` a secas (sin el script) deja la app creyendose
# 0.1.0: pide actualizar siempre y nunca se pone al dia. Es invisible hasta que
# se mira el binario, asi que se comprueba aqui leyendo data\app.so.
$versionText = Select-String -Path (Join-Path $root 'pubspec.yaml') -Pattern '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)' |
    Select-Object -First 1
if ($versionText -and $versionText.Matches.Count -gt 0) {
    $expected = $versionText.Matches[0].Groups[1].Value
    $ascii = [System.Text.Encoding]::GetEncoding(28591)
    $raw = [System.IO.File]::ReadAllBytes($appSo)
    $text = $ascii.GetString($raw)
    if ($text.Contains($expected)) {
        Write-Host "[ok] La version $expected esta incrustada en el binario" -ForegroundColor Green
    }
    else {
        Write-Host ''
        Write-Host "[FALLA] El binario NO contiene la version $expected de pubspec.yaml." -ForegroundColor Red
        Write-Host '        Se compilo sin inyectar la version: la app se creera 0.1.0 y' -ForegroundColor Red
        Write-Host '        pedira actualizar indefinidamente.' -ForegroundColor Red
        Write-Host ''
        Write-Host '        Compila con el script del proyecto, no con flutter a secas:' -ForegroundColor Yellow
        Write-Host '          powershell -ExecutionPolicy Bypass -File tool\build_windows.ps1'
        exit 1
    }
}

# ------------------------------------------------------ 4. Icono y commit
$exe = Join-Path $outDir 'xtreme_studio.exe'
try {
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exe)
    if ($null -ne $icon -and $icon.Width -ge 16) {
        Write-Host "[ok] Icono del ejecutable: $($icon.Width)x$($icon.Height)" -ForegroundColor Green
    }
    else {
        Write-Host '[aviso] El ejecutable no tiene icono incrustado.' -ForegroundColor Yellow
    }
}
catch {
    Write-Host '[aviso] No se pudo comprobar el icono.' -ForegroundColor Yellow
}

$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) {
    Push-Location $root
    try {
        $sha = (& git rev-parse --short HEAD 2>$null)
        $msg = (& git log -1 --format='%s' 2>$null)
        Write-Host "  commit compilado   : $sha  $msg"
    }
    catch { }
    finally { Pop-Location }
}

# ---------------------------------------------------------------- 5. Resumen
$total = (Get-ChildItem $outDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
Write-Host ''
Write-Host ("TOTAL: {0:N1} MB en {1}" -f ($total / 1MB), $outDir)
Write-Host ''
Write-Host 'COMPILACION VERIFICADA: esta lista para usar o empaquetar.' -ForegroundColor Green
Write-Host ''
Write-Host 'Para compartirla:' -ForegroundColor Cyan
Write-Host '  cd build\windows\x64\runner'
Write-Host '  Compress-Archive -Path Release -DestinationPath XtremeStudio-Windows.zip -Force'
Write-Host ''
exit 0
