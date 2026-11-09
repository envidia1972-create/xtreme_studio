/// Instalacion de una actualizacion ya descargada.
///
/// En Windows no se puede sobrescribir el `.exe` mientras la app esta abierta.
/// Por eso se lanza un pequeno script de PowerShell que espera a que el proceso
/// termine, reemplaza la carpeta portable, restaura la copia anterior si algo
/// falla y arranca la app de nuevo.
library;

import 'dart:io';

import 'update_models.dart';

class UpdateInstaller {
  const UpdateInstaller._();

  static bool get supportsCurrentPlatform => Platform.isWindows;

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
      throw UpdateException(
        'No se puede escribir en ${directory.path}. Instala Xtreme Studio en '
        'una carpeta tuya (por ejemplo C:\\XtremeStudio) o ejecuta como '
        'administrador. (${e.message})',
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
