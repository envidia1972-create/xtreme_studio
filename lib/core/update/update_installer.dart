/// Instalacion de una actualizacion ya descargada.
///
/// En Windows no se puede sobrescribir el `.exe` mientras la app esta abierta;
/// en Linux pasa lo mismo con el ejecutable y las bibliotecas del bundle. En
/// ambas plataformas se lanza un pequeno script que espera a que el proceso
/// termine, reemplaza la carpeta portable, restaura la copia anterior si algo
/// falla y arranca la app de nuevo.
library;

import 'dart:io';

import 'update_models.dart';

class UpdateInstaller {
  const UpdateInstaller._();

  static bool get supportsCurrentPlatform =>
      Platform.isWindows || Platform.isLinux;

  static Directory get installDirectory =>
      File(Platform.resolvedExecutable).parent;

  /// Comprueba que la carpeta de instalacion se pueda escribir. Evita cerrar la
  /// app para descubrir despues que estaba en una ruta de solo lectura.
  static Future<void> ensureWritable(Directory directory) async {
    if (!directory.existsSync()) {
      throw UpdateException('No se encontro la carpeta de instalacion.');
    }
    final probe = File(
      '${directory.path}${Platform.pathSeparator}.xtreme-write-test-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
    } on FileSystemException catch (e) {
      final hint = Platform.isWindows
          ? 'Instala Xtreme Studio en una carpeta tuya (por ejemplo '
                'C:\\XtremeStudio) o ejecuta como administrador.'
          : 'Instala Xtreme Studio en una carpeta tuya, por ejemplo '
                '~/.local/opt/xtreme-studio. No se actualiza una instalacion '
                'del sistema ni una carpeta de solo lectura.';
      throw UpdateException(
        'No se puede escribir en ${directory.path}. $hint (${e.message})',
      );
    }
  }

  /// Lanza el actualizador de Windows y devuelve cuando el proceso fue creado.
  ///
  /// El llamador debe cerrar la app inmediatamente despues. El script espera el
  /// PID, reemplaza los archivos y vuelve a abrir el ejecutable.
  static Future<void> launchWindowsUpdater({
    required File archive,
    required UpdateInfo info,
    required int processId,
    Directory? destination,
  }) async {
    if (!Platform.isWindows) {
      throw UpdateException(
        'La actualizacion automatica todavia no esta disponible para esta '
        'plataforma. Abri la pagina de descarga.',
      );
    }
    if (!archive.existsSync()) {
      throw UpdateException('No se encontro el archivo descargado.');
    }
    final dest = destination ?? installDirectory;
    await ensureWritable(dest);

    final script = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'xtreme-update-${DateTime.now().microsecondsSinceEpoch}.ps1',
    );
    await script.writeAsString(buildWindowsUpdaterScript(), flush: true);
    await Process.start('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-File',
      script.path,
      '$processId',
      archive.path,
      dest.path,
    ], mode: ProcessStartMode.detached);
  }

  /// Lanza el actualizador de Linux y devuelve cuando el proceso fue creado.
  ///
  /// El script espera a que cierre la app, extrae el `.tar.gz`, reemplaza la
  /// carpeta portable y vuelve a abrir el ejecutable. La copia anterior queda
  /// en `<carpeta>.update-backup` por si hace falta recuperarla.
  static Future<void> launchLinuxUpdater({
    required File archive,
    required UpdateInfo info,
    required int processId,
    Directory? destination,
  }) async {
    if (!Platform.isLinux) {
      throw UpdateException(
        'La actualizacion automatica no esta disponible para esta plataforma.',
      );
    }
    if (!archive.existsSync()) {
      throw UpdateException('No se encontro el archivo descargado.');
    }
    final dest = destination ?? installDirectory;
    await ensureWritable(dest);

    final script = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'xtreme-update-${DateTime.now().microsecondsSinceEpoch}.sh',
    );
    await script.writeAsString(buildLinuxUpdaterScript(), flush: true);
    await Process.run('chmod', ['700', script.path]);
    await Process.start('/bin/sh', [
      script.path,
      '$processId',
      archive.path,
      dest.path,
    ], mode: ProcessStartMode.detached);
  }

  /// Script que se ejecuta fuera de la app en Linux. Se expone para poder
  /// verificarlo sin reemplazar archivos reales.
  static String buildLinuxUpdaterScript() {
    return r'''
#!/bin/sh
# Actualizador portable de Xtreme Studio para Linux.
# Uso: xtreme-update.sh <pid> <tar.gz> <carpeta-bundle>
set -u
pid="$1"
archive="$2"
dest="$3"
backup=""

log="$HOME/.xtreme_studio/update.log"
mkdir -p "$HOME/.xtreme_studio" 2>/dev/null || log="${TMPDIR:-/tmp}/xtreme-update.log"

say() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$log" 2>/dev/null
}

restore() {
  if [ -d "$backup" ]; then
    rm -rf "$dest"
    mv "$backup" "$dest"
  fi
  if [ -x "$dest/xtreme_studio" ]; then
    (cd "$dest" && nohup ./xtreme_studio >>"$log" 2>&1 &)
  fi
}

fail() {
  say "ERROR: $*"
  restore
  exit 1
}

if [ ! -f "$archive" ]; then
  fail "No existe el archivo $archive"
fi
if [ ! -d "$dest" ] || [ ! -x "$dest/xtreme_studio" ]; then
  fail "No se encontro la app en $dest"
fi
command -v tar >/dev/null 2>&1 || fail "No esta instalado tar"

say "Esperando a que cierre la app PID $pid"
i=0
while kill -0 "$pid" 2>/dev/null; do
  i=$((i + 1))
  if [ "$i" -ge 120 ]; then
    fail "La app no cerro en 120 segundos"
  fi
  sleep 1
done

tmp="$(mktemp -d "${TMPDIR:-/tmp}/xtreme-update-XXXXXX")" || fail "No se pudo crear el directorio temporal"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
say "Extrayendo $archive"
tar -xzf "$archive" -C "$tmp" || fail "No se pudo extraer el paquete"

src=""
if [ -x "$tmp/xtreme_studio" ]; then
  src="$tmp"
else
  found="$(find "$tmp" -maxdepth 2 -type f -name xtreme_studio -print -quit 2>/dev/null)"
  if [ -n "$found" ]; then
    src="$(dirname "$found")"
  fi
fi
if [ -z "$src" ] || [ ! -x "$src/xtreme_studio" ] || [ ! -d "$src/data" ]; then
  fail "El paquete no contiene un bundle valido de Xtreme Studio"
fi

backup="${dest}.update-backup"
if [ -e "$backup" ]; then
  rm -rf "$backup"
fi
say "Moviendo la version actual a $backup"
mv "$dest" "$backup" || fail "No se pudo preparar la copia de seguridad"
mkdir -p "$dest" || { restore; fail "No se pudo crear $dest"; }

say "Copiando la version nueva"
if ! cp -a "$src/." "$dest/"; then
  restore
  fail "No se pudo copiar la version nueva"
fi
chmod +x "$dest/xtreme_studio" 2>/dev/null || true

say "Actualizacion copiada; iniciando la app"
(cd "$dest" && nohup ./xtreme_studio >>"$log" 2>&1 &)
sleep 2
rm -rf "$tmp" "$archive"
say "Actualizacion completada. Copia anterior: $backup"
exit 0
''';
  }

  /// Script que se ejecuta fuera de la app. Se expone para poder verificarlo
  /// sin reemplazar archivos reales.
  static String buildWindowsUpdaterScript() {
    return r'''
param(
    [Parameter(Mandatory=$true)][int]$AppPid,
    [Parameter(Mandatory=$true)][string]$Zip,
    [Parameter(Mandatory=$true)][string]$Dest
)
$ErrorActionPreference = 'Stop'
$log = Join-Path $env:TEMP 'xtreme-update.log'
function Write-Log([string]$Message) {
    try {
        Add-Content -LiteralPath $log -Value ("[{0}] {1}" -f (Get-Date -Format o), $Message)
    } catch { }
}
function Start-App {
    $exe = Join-Path $Dest 'xtreme_studio.exe'
    if (Test-Path -LiteralPath $exe) {
        Start-Process -FilePath $exe -WorkingDirectory $Dest
    }
}
$tmp = Join-Path $env:TEMP ("xtreme-update-" + [guid]::NewGuid().ToString('N'))
$backup = $Dest + '.update-backup'
try {
    Write-Log "Esperando a que cierre la app PID $AppPid"
    Wait-Process -Id $AppPid -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 700
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    Write-Log "Extrayendo $Zip"
    Expand-Archive -LiteralPath $Zip -DestinationPath $tmp -Force
    $src = $tmp
    if (-not (Test-Path -LiteralPath (Join-Path $src 'xtreme_studio.exe'))) {
        $child = Get-ChildItem -LiteralPath $tmp -Directory |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'xtreme_studio.exe') } |
            Select-Object -First 1
        if ($null -ne $child) { $src = $child.FullName }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $src 'xtreme_studio.exe'))) {
        throw 'El ZIP no contiene xtreme_studio.exe.'
    }
    if (Test-Path -LiteralPath $backup) {
        Remove-Item -LiteralPath $backup -Recurse -Force
    }
    Write-Log "Creando copia de seguridad en $backup"
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
    Copy-Item -Path (Join-Path $Dest '*') -Destination $backup -Recurse -Force
    try {
        Write-Log "Copiando archivos nuevos"
        Copy-Item -Path (Join-Path $src '*') -Destination $Dest -Recurse -Force
        Write-Log 'Actualizacion copiada; iniciando la app'
        Start-App
        Start-Sleep -Seconds 3
        Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $Zip -Force -ErrorAction SilentlyContinue
        Write-Log 'Actualizacion completada'
        exit 0
    }
    catch {
        Write-Log ("Fallo al copiar: " + $_.Exception.Message)
        if (Test-Path -LiteralPath $backup) {
            Copy-Item -Path (Join-Path $backup '*') -Destination $Dest -Recurse -Force -ErrorAction SilentlyContinue
        }
        Start-App
        exit 1
    }
}
catch {
    Write-Log ("Error: " + $_.Exception.Message)
    Start-App
    exit 1
}
''';
  }
}
