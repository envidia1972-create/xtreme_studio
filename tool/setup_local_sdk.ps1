# Monta un SDK de Flutter "de trabajo" dentro del workspace.
#
# Por que: el tool de Flutter necesita ESCRIBIR en <sdk>/bin/cache (su archivo
# de bloqueo y sus stamps). El SDK real vive en C:\Users\Usuario\flutter, fuera
# del workspace, y el sandbox lo deja en solo lectura; por eso `flutter` se
# colgaba o moria con "failed to open ... lockfile".
#
# Solucion: un SDK espejo donde
#   - las carpetas grandes y de solo lectura se enlazan con junctions
#     (no se duplican 1.7 GB),
#   - las carpetas que el tool necesita escribir son reales.
#
# Uso: powershell -ExecutionPolicy Bypass -File tool\setup_local_sdk.ps1

$ErrorActionPreference = 'Stop'

$realSdk = 'C:\Users\Usuario\flutter'
$localSdk = 'C:\Desarrollo\xtreme_studio\.flutter_sdk'

if (-not (Test-Path "$realSdk\bin\internal\engine.version")) {
    throw "No parece un SDK de Flutter valido: $realSdk"
}

Write-Output "SDK real : $realSdk"
Write-Output "SDK local: $localSdk"
Write-Output ''

# --- Estructura base -------------------------------------------------------
foreach ($d in @('bin', 'bin\cache', 'bin\internal', 'packages')) {
    $path = Join-Path $localSdk $d
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
    }
}

# --- Enlaces de solo lectura ----------------------------------------------
# Formato: destino_local|origen_real
$links = @(
    'bin\internal|bin\internal',
    'packages|packages',
    'bin\cache\dart-sdk|bin\cache\dart-sdk',
    'bin\cache\artifacts|bin\cache\artifacts',
    'bin\cache\pkg|bin\cache\pkg'
)

foreach ($entry in $links) {
    $parts = $entry.Split('|')
    $target = Join-Path $localSdk $parts[0]
    $source = Join-Path $realSdk $parts[1]

    if (-not (Test-Path -LiteralPath $source)) {
        Write-Output "[aviso] no existe el origen: $source"
        continue
    }
    if (Test-Path -LiteralPath $target) {
        $item = Get-Item -LiteralPath $target -Force
        if ($item.LinkType -eq 'Junction') {
            Write-Output "[ok] junction ya presente: $($parts[0])"
            continue
        }
        # Es un directorio real (creado arriba): se reemplaza por la junction.
        Remove-Item -LiteralPath $target -Recurse -Force
    }
    New-Item -ItemType Junction -Path $target -Target $source | Out-Null
    Write-Output "[ok] junction: $($parts[0]) -> $source"
}

# --- Archivos sueltos de bin\cache ----------------------------------------
$cacheFiles = @(
    'flutter_tools.snapshot',
    'flutter_tools.stamp',
    'flutter.version.json',
    'engine.stamp',
    'engine.realm',
    'engine_stamp.json',
    'engine-dart-sdk.stamp',
    'flutter_sdk.stamp',
    'flutter_version_check.stamp',
    'material_fonts.stamp',
    'windows-sdk.stamp',
    'font-subset.stamp',
    'gradle_wrapper.stamp',
    'android-sdk.stamp',
    'ios-sdk.stamp',
    'linux-sdk.stamp',
    'macos-sdk.stamp',
    'openssl.stamp',
    'libimobiledevice.stamp',
    'libimobiledeviceglue.stamp',
    'libplist.stamp',
    'libusbmuxd.stamp',
    'ios-deploy.stamp',
    'android-internal-build-artifacts.stamp',
    '.dartignore'
)
$copied = 0
foreach ($f in $cacheFiles) {
    $src = Join-Path $realSdk "bin\cache\$f"
    $dst = Join-Path $localSdk "bin\cache\$f"
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination $dst -Force
        $copied++
    }
}
Write-Output "[ok] $copied archivos de cache copiados"

# --- bin\flutter.bat y dart.bat -------------------------------------------
# `bin\internal` es un junction al SDK real, asi que no hay que copiar nada de
# ahi: shared.bat y engine.version ya se ven a traves del enlace.
foreach ($f in @('flutter.bat', 'dart.bat')) {
    $src = Join-Path $realSdk "bin\$f"
    $dst = Join-Path $localSdk "bin\$f"
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }
}

# --- Archivo de version ----------------------------------------------------
# El tool lo consulta para saber que version es el SDK. En un checkout con git
# lo saca de git; aqui se escribe a mano desde flutter.version.json.
$versionJson = Get-Content (Join-Path $realSdk 'bin\cache\flutter.version.json') -Raw | ConvertFrom-Json
$versionText = @"
{
  "frameworkVersion": "$($versionJson.frameworkVersion)",
  "channel": "$($versionJson.channel)",
  "repositoryUrl": "$($versionJson.repositoryUrl)",
  "frameworkRevision": "$($versionJson.frameworkRevision)",
  "frameworkCommitDate": "$($versionJson.frameworkCommitDate)",
  "engineRevision": "$($versionJson.engineRevision)",
  "engineCommitDate": "$($versionJson.engineCommitDate)",
  "dartSdkVersion": "$($versionJson.dartSdkVersion)",
  "devToolsVersion": "$($versionJson.devToolsVersion)",
  "flutterVersion": "$($versionJson.flutterVersion)"
}
"@
Set-Content -Path (Join-Path $localSdk 'version') -Value $versionText -NoNewline -Encoding UTF8
Write-Output "[ok] archivo version creado ($($versionJson.frameworkVersion))"

# --- Verificacion ----------------------------------------------------------
Write-Output ''
Write-Output 'Comprobaciones:'
$checks = @(
    'bin\flutter_tools.snapshot',
    'bin\cache\flutter_tools.snapshot',
    'bin\cache\dart-sdk\bin\dart.exe',
    'bin\cache\artifacts\engine\windows-x64\flutter_windows.dll',
    'packages\flutter_tools\bin\tool_backend.bat',
    'version'
)
foreach ($c in $checks) {
    $p = Join-Path $localSdk $c
    $exists = Test-Path -LiteralPath $p
    Write-Output ("  [{0}] {1}" -f $(if ($exists) { 'ok' } else { 'FALTA' }), $c)
}
