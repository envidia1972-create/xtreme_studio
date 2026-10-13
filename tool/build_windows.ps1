# Compila e instala Xtreme Studio en Windows.
#
# Ejecutar desde la raiz del proyecto:
#     powershell -ExecutionPolicy Bypass -File tool\build_windows.ps1
#
# Por que un script y no solo el comando: hay dos dependencias que conviene
# comprobar ANTES de gastar minutos compilando (FFmpeg y las herramientas de
# C++ de Visual Studio), que son las dos causas habituales de que el primer
# intento falle.

$ErrorActionPreference = 'Stop'

$root = 'C:\Desarrollo\xtreme_studio'
Set-Location $root

Write-Host ''
Write-Host '=== Xtreme Studio - compilacion para Windows ===' -ForegroundColor Cyan
Write-Host ''

# ---------------------------------------------------------------- Flutter SDK
$flutter = 'C:\Users\Usuario\flutter\bin\flutter.bat'
if (-not (Test-Path $flutter)) {
    Write-Host 'ERROR: no se encontro Flutter en ' -ForegroundColor Red -NoNewline
    Write-Host $flutter
    Write-Host 'Ajusta la ruta en este script o instala Flutter.'
    exit 1
}

# ------------------------------------------------------ Visual Studio C++/CMake
# No basta con saber que hay C++: el build de Flutter necesita ademas CMake y el
# Windows SDK. Comprobarlo aqui evita que el proceso falle a mitad, despues de
# varios minutos, con un error de CMake dificil de interpretar.
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
$vsPath = ''
if (Test-Path $vswhere) {
    $installs = & $vswhere -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($installs) { $vsPath = @($installs)[0] }
}

if (-not $vsPath) {
    Write-Host 'ERROR: falta el soporte de C++ de Visual Studio.' -ForegroundColor Red
    Write-Host 'Instala "Visual Studio Build Tools" con la carga de trabajo'
    Write-Host '"Desarrollo para escritorio con C++".'
    exit 1
}
Write-Host "[ok] Visual Studio: $vsPath" -ForegroundColor Green

# CMake incluido en Visual Studio.
$cmake = Get-ChildItem -Path (Join-Path $vsPath 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe') -ErrorAction SilentlyContinue
if (-not $cmake) {
    Write-Host 'ERROR: no se encontro CMake dentro de Visual Studio.' -ForegroundColor Red
    Write-Host 'Revisa la instalacion o instala CMake aparte.'
    exit 1
}
Write-Host "[ok] CMake: $($cmake.VersionInfo.FileVersion)" -ForegroundColor Green

# SDK de Windows: Flutter lo necesita para enlazar (kernel32, ole32, etc.).
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
if ($sdkVersions.Count -eq 0) {
    Write-Host 'ERROR: no se encontro el SDK de Windows 10/11.' -ForegroundColor Red
    Write-Host 'Instala el componente "Windows 10/11 SDK" desde el instalador'
    Write-Host 'de Visual Studio.'
    exit 1
}
Write-Host "[ok] Windows SDK: $($sdkVersions[-1])" -ForegroundColor Green

# Compilador y enlazador.
$vcTools = Get-ChildItem -Path (Join-Path $vsPath 'VC\Tools\MSVC') -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -First 1
if (-not $vcTools) {
    Write-Host 'ERROR: no se encontro el conjunto de herramientas de MSVC.' -ForegroundColor Red
    exit 1
}
$cl = Join-Path $vcTools.FullName 'bin\Hostx64\x64\cl.exe'
if (-not (Test-Path $cl)) {
    Write-Host "ERROR: no se encontro cl.exe en $cl" -ForegroundColor Red
    exit 1
}
Write-Host "[ok] MSVC: $($vcTools.Name)" -ForegroundColor Green

# --------------------------------------------------------------------- FFmpeg
$ffmpegCandidates = @(
    (Join-Path $root 'tools\ffmpeg.exe'),
    (Join-Path $root 'tools\ffmpeg\bin\ffmpeg.exe')
)
$ffmpeg = $ffmpegCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $ffmpeg) {
    $onPath = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($onPath) { $ffmpeg = $onPath.Source }
}

if (-not $ffmpeg) {
    Write-Host '[aviso] No se encontro ffmpeg.exe.' -ForegroundColor Yellow
    Write-Host '        La app compilara igual, pero no podra emitir hasta que'
    Write-Host '        indiques su ruta en Ajustes.'
    Write-Host '        Descarga una build "full"/"gpl" de https://www.gyan.dev/ffmpeg/builds/'
    Write-Host '        y copia ffmpeg.exe a la carpeta tools\ del proyecto.'
}
else {
    Write-Host "[ok] FFmpeg: $ffmpeg" -ForegroundColor Green
}

# ------------------------------------------------------------------ Dependencias
Write-Host ''
Write-Host 'Resolviendo dependencias...'

# La cache de pub por defecto esta en %LOCALAPPDATA%\Pub\Cache. Si esa carpeta
# no se puede escribir (permisos rotos, cuota, antivirus), `pub get` falla con
# un error confuso. Cuando existe una cache dentro del proyecto se usa esa, que
# ademas permite compilar sin conexion.
$cacheCandidates = @(
    (Join-Path $root '.pubcache'),
    (Join-Path $root 'tools\pubcache')
)
$localPubCache = $cacheCandidates |
    Where-Object { Test-Path (Join-Path $_ 'hosted\pub.dev') } |
    Select-Object -First 1

if (-not $localPubCache) {
    # Sin cache local: se comprueba que la de por defecto se pueda escribir.
    $defaultCache = Join-Path $env:LOCALAPPDATA 'Pub\Cache'
    $fallback = Join-Path $root '.pubcache'
    if (Test-Path $defaultCache) {
        $writable = $false
        try {
            $probeFile = Join-Path $defaultCache '__write_test.tmp'
            Set-Content -Path $probeFile -Value 'x' -ErrorAction Stop
            Remove-Item $probeFile -Force -ErrorAction SilentlyContinue
            $writable = $true
        }
        catch {
            $writable = $false
        }
        if (-not $writable) {
            Write-Host '[aviso] La cache de pub por defecto no se puede escribir:' -ForegroundColor Yellow
            Write-Host "        $defaultCache"
            Write-Host "        Se usara $fallback"
            $localPubCache = $fallback
        }
    }
}

if ($localPubCache) {
    $env:PUB_CACHE = $localPubCache
    Write-Host "[info] Cache de pub: $localPubCache"
}

& $flutter pub get
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host 'Fallo la resolucion de dependencias.' -ForegroundColor Red
    Write-Host 'Si el error menciona permisos, revisa la cache de pub indicada arriba.'
    exit $LASTEXITCODE
}

# ------------------------------------------------------------------- Compilacion
Write-Host ''
Write-Host 'Compilando (esto puede tardar unos minutos la primera vez)...'
& $flutter build windows --release
$buildExit = $LASTEXITCODE

$outDir = Join-Path $root 'build\windows\x64\runner\Release'
$exe = Join-Path $outDir 'xtreme_studio.exe'

if ($buildExit -ne 0) {
    # Flutter puede fallar en el paso INSTALL ("cmake -DBUILD_TYPE=Release -P
    # cmake_install.cmake") dejando el binario ya generado pero sin copiar los
    # assets a la carpeta Release. Si el ejecutable existe, se termina el trabajo
    # a mano en lugar de dar la compilacion por perdida.
    if (Test-Path $exe) {
        Write-Host ''
        Write-Host '[aviso] Flutter devolvio un error al final, pero el ejecutable' -ForegroundColor Yellow
        Write-Host '        ya se genero. Se completan los archivos a mano.'
        Write-Host '        (Si el error fue de compilacion, se vera al comprobar el arranque.)'
    }
    else {
        Write-Host ''
        Write-Host 'La compilacion fallo: no se genero el ejecutable.' -ForegroundColor Red
        exit $buildExit
    }
}

# ------------------------------------------- Completar la carpeta de salida
# Se ejecuta siempre (haya fallado INSTALL o no): es idempotente y garantiza que
# la carpeta quede completa incluso si Flutter cambio de comportamiento.
if (Test-Path $outDir) {
    $dataDir = Join-Path $outDir 'data'
    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

    # 1. Los assets de Flutter (fuentes, shaders, manifiestos).
    #
    #    Si no existen, se generan con `flutter build bundle`: es un paso barato
    #    (segundos) que solo arma los assets, sin compilar el binario. Sin ellos
    #    la aplicacion NO ARRANCA, y el sintoma es confuso ("no abre", "no
    #    responde") porque no hay ningun mensaje de error visible.
    $srcAssets = Join-Path $root 'build\flutter_assets'
    $dstAssets = Join-Path $dataDir 'flutter_assets'

    if (-not (Test-Path $srcAssets) -or
        -not (Test-Path (Join-Path $srcAssets 'AssetManifest.bin'))) {
        Write-Host '[info] Faltan los assets: generandolos con flutter build bundle...'
        $env:PUB_CACHE = if ($localPubCache) { $localPubCache } else { $env:PUB_CACHE }
        & $flutter build bundle --release 2>&1 | Out-Null
        if (-not (Test-Path (Join-Path $srcAssets 'AssetManifest.bin'))) {
            # Segunda ubicacion posible segun la version del tool.
            $alt = Join-Path $root 'build\flutter_assets'
            if (Test-Path $alt) { $srcAssets = $alt }
        }
    }

    if (Test-Path $srcAssets) {
        $assetItems = @(Get-ChildItem -Path $srcAssets -Force)
        if ($assetItems.Count -gt 0) {
            New-Item -ItemType Directory -Force -Path $dstAssets | Out-Null
            Copy-Item (Join-Path $srcAssets '*') $dstAssets -Recurse -Force
            Write-Host "[ok] flutter_assets copiado ($($assetItems.Count) elementos)" -ForegroundColor Green
        }
    }
    else {
        Write-Host '[aviso] No se encontraron los assets de Flutter.' -ForegroundColor Yellow
        Write-Host '        La aplicacion no arrancara sin ellos.'
    }

    # 2. El codigo Dart compilado (AOT). El motor lo busca en `data\app.so`, no
    #    dentro de flutter_assets: si se coloca mal, la app abre y se cierra
    #    sola con "Unable to start engine without AOT data".
    $appSo = Get-ChildItem -Path (Join-Path $root '.dart_tool\flutter_build') `
        -Filter 'app.so' -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($appSo) {
        Copy-Item $appSo.FullName (Join-Path $dataDir 'app.so') -Force
        Write-Host ("[ok] app.so copiado ({0:N1} MB)" -f ($appSo.Length / 1MB)) -ForegroundColor Green
    }
    else {
        Write-Host '[aviso] No se encontro app.so (el codigo Dart compilado)' -ForegroundColor Yellow
    }

    # 3. Los datos de internacionalizacion, si Flutter no los copio.
    $icu = Join-Path $dataDir 'icudtl.dat'
    if (-not (Test-Path $icu)) {
        $icuSrc = Get-ChildItem -Path (Join-Path $root '.dart_tool\flutter_build') `
            -Filter 'icudtl.dat' -Recurse -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $icuSrc) {
            $icuSrc = Get-ChildItem -Path 'C:\Users\Usuario\flutter\bin\cache\artifacts\engine' `
                -Filter 'icudtl.dat' -Recurse -File -ErrorAction SilentlyContinue |
                Select-Object -First 1
        }
        if ($icuSrc) {
            Copy-Item $icuSrc.FullName $icu -Force
            Write-Host '[ok] icudtl.dat copiado' -ForegroundColor Green
        }
    }
}

# ----------------------------------------------------------------------- Copiar FFmpeg
if ($ffmpeg -and (Test-Path $outDir)) {
    $dest = Join-Path $outDir 'ffmpeg.exe'
    if ($ffmpeg -ne $dest) {
        Copy-Item $ffmpeg $dest -Force
        Write-Host '[ok] ffmpeg.exe copiado junto al ejecutable' -ForegroundColor Green
    }

    # La licencia de FFmpeg debe acompanar al binario si se redistribuye la app.
    # Se busca junto al ffmpeg de origen (las builds de gyan/BtbN traen LICENSE).
    $ffmpegDir = Split-Path -Parent $ffmpeg
    foreach ($lic in @('LICENSE', 'LICENSE.txt', 'LICENSE.md')) {
        $src = Join-Path $ffmpegDir $lic
        if (Test-Path $src) {
            Copy-Item $src (Join-Path $outDir 'FFMPEG-LICENSE.txt') -Force
            Write-Host '[ok] licencia de FFmpeg copiada' -ForegroundColor Green
            break
        }
    }

    # Aviso util: las builds "full"/"gpl" incluyen componentes GPL.
    if ($ffmpeg -match 'gpl|full') {
        Write-Host '[aviso] Estas usando una build GPL de FFmpeg.' -ForegroundColor Yellow
        Write-Host '        Si vas a distribuir la app, revisa THIRD_PARTY.md'
        Write-Host '        (afecta solo a FFmpeg, no al codigo de Xtreme Studio).'
    }
}

# ------------------------------------------------------------------- Documentacion
if (Test-Path $outDir) {
    $docs = @('README.md', 'THIRD_PARTY.md')
    foreach ($d in $docs) {
        $src = Join-Path $root $d
        if (Test-Path $src) {
            Copy-Item $src (Join-Path $outDir $d) -Force
        }
    }
    Write-Host '[ok] documentacion copiada junto al ejecutable' -ForegroundColor Green
}

# ---------------------------------------------------- Archivos imprescindibles
# Una carpeta Release incompleta produce el peor sintoma posible: la aplicacion
# "no abre" o "no responde", sin ningun mensaje de error. Se comprueba aqui, que
# es el unico momento en que se puede avisar con precision.
$required = [ordered]@{
    'xtreme_studio.exe'                          = 'el ejecutable'
    'flutter_windows.dll'                        = 'el motor de Flutter'
    'ffmpeg.exe'                                 = 'el motor de audio'
    'data\icudtl.dat'                            = 'datos de idioma'
    'data\app.so'                                = 'el codigo de la aplicacion'
    'data\flutter_assets\AssetManifest.bin'      = 'los recursos de la interfaz'
    'data\flutter_assets\fonts\MaterialIcons-Regular.otf' = 'la tipografia de iconos'
}

$missing = @()
foreach ($rel in $required.Keys) {
    if (-not (Test-Path (Join-Path $outDir $rel))) {
        $missing += "  - $rel  ($($required[$rel]))"
    }
}

if ($missing.Count -gt 0) {
    Write-Host ''
    Write-Host '=== LA CARPETA QUEDO INCOMPLETA ===' -ForegroundColor Red
    Write-Host 'Falta lo siguiente:' -ForegroundColor Red
    $missing | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    Write-Host ''
    Write-Host 'Sin estos archivos la aplicacion NO ARRANCA.' -ForegroundColor Yellow
    Write-Host 'Los recursos se generan con:' -ForegroundColor Yellow
    Write-Host '    flutter build bundle --release'
    Write-Host 'y despues volve a correr este script.'
    exit 1
}

# Resultado
Write-Host ''
Write-Host '=== LISTO ===' -ForegroundColor Green
if (Test-Path $exe) {
    Write-Host "Ejecutable: $exe"
    Write-Host ''
    Write-Host 'Podes abrirlo ahora con:'
    Write-Host "    & `"$exe`""
    Write-Host ''

    # Comprobacion final: que la app realmente arranque. Un fallo aqui es lo que
    # convierte "compilo bien" en "no abre", y es dificil de diagnosticar a mano.
    Write-Host 'Comprobando que la aplicacion arranque...'
    try {
        Start-Process -FilePath $exe -WorkingDirectory $outDir -PassThru |
            ForEach-Object {
                Start-Sleep -Seconds 6
                if ($_.HasExited) {
                    Write-Host "[aviso] La aplicacion se cerro sola (codigo $($_.ExitCode))." -ForegroundColor Yellow
                    Write-Host '        Falta algun archivo en la carpeta Release.'
                }
                else {
                    Write-Host '[ok] La aplicacion arranco correctamente' -ForegroundColor Green
                    try { $_.Kill() } catch {}
                }
            }
    }
    catch {
        Write-Host "[aviso] No se pudo comprobar el arranque: $_" -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host 'Antes de distribuir la carpeta Release a otra emisora, revisa'
    Write-Host 'THIRD_PARTY.md para las licencias de FFmpeg.'
}
else {
    Write-Host "Revisa la carpeta: $outDir" -ForegroundColor Yellow
    exit 1
}
