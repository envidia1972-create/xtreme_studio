/// Verificacion del **lanzamiento real** del actualizador de Windows.
///
/// Llama a `UpdateInstaller.launchWindowsUpdater` —el mismo codigo que ejecuta
/// la app al actualizar— y comprueba el circuito completo:
///
///   1. el metodo vuelve solo cuando el script confirmo que arranco (marcador),
///   2. el script reemplaza los archivos del destino,
///   3. queda registro en `%TEMP%\xtreme-update.log`.
///
/// Existe por un fallo real: la app cerraba antes de que el script arrancara, la
/// actualizacion no se aplicaba nunca y no habia ningun mensaje que lo dijera.
/// Una comprobacion estatica no lo detectaba; solo lanzarlo de verdad.
///
/// Uso:
///   dart run tool/verify_updater_launch.dart
///
/// Solo corre en Windows: en otras plataformas termina sin fallar.
library;

import 'dart:convert';
import 'dart:io';

import 'package:xtreme_studio/core/update/update_installer.dart';
import 'package:xtreme_studio/core/update/update_models.dart';

int _passed = 0;
final List<String> _failures = [];

void check(bool ok, String description, {String? detail}) {
  if (ok) {
    _passed++;
    stdout.writeln('  [ok]   $description');
  } else {
    _failures.add(description);
    stdout.writeln(
      '  [FALLA] $description${detail == null ? '' : ' -> $detail'}',
    );
  }
}

void section(String title) {
  stdout.writeln('');
  stdout.writeln('== $title ==');
}

Future<void> main() async {
  stdout.writeln('Verificacion del lanzamiento del actualizador');

  if (!Platform.isWindows) {
    stdout.writeln('');
    stdout.writeln('  (omitido: solo aplica a Windows)');
    stdout.writeln('');
    stdout.writeln('LIBERACION VERIFICADA: 0 comprobaciones (otra plataforma)');
    exit(0);
  }

  final base = await Directory.systemTemp.createTemp('xtreme-upd-verify-');
  final dest = Directory('${base.path}${Platform.pathSeparator}Xtreme Studio');
  final pkg = Directory('${base.path}${Platform.pathSeparator}pkg');
  final sep = Platform.pathSeparator;

  try {
    await Directory('${dest.path}${sep}data').create(recursive: true);
    await Directory('${pkg.path}${sep}data').create(recursive: true);

    // Un ejecutable real que termina solo: el script lo relanza al final y un
    // archivo que no sea ejecutable haria fallar ese paso.
    final whoami = File('C:\\Windows\\System32\\whoami.exe');
    await whoami.copy('${dest.path}${sep}xtreme_studio.exe');
    await whoami.copy('${pkg.path}${sep}xtreme_studio.exe');

    final destSo = File('${dest.path}${sep}data${sep}app.so');
    await destSo.writeAsString('VIEJO-0.1.1');
    await File(
      '${pkg.path}${sep}data${sep}app.so',
    ).writeAsString('NUEVO-0.1.3');

    final zip = File('${base.path}${sep}nuevo.zip');
    final compress = await Process.run('powershell.exe', [
      '-NoProfile',
      '-Command',
      'Compress-Archive -Path "${pkg.path}$sep*" '
          '-DestinationPath "${zip.path}" -Force',
    ]);
    check(
      compress.exitCode == 0 && zip.existsSync(),
      'se preparo el paquete de actualizacion',
      detail: '${compress.stderr}',
    );
    if (!zip.existsSync()) {
      throw StateError('no se pudo crear el zip de prueba');
    }

    final info = UpdateInfo(
      latestVersion: '0.1.3',
      currentVersion: '0.1.1',
      notes: 'prueba',
      pageUrl: Uri.parse('https://example.invalid/'),
      assets: [
        UpdateAsset(
          name: 'XtremeStudio-0.1.3-windows-x64.zip',
          url: zip.uri,
          size: zip.lengthSync(),
        ),
      ],
    );

    // ------------------------------------------------------------------ lanzar
    section('Lanzamiento');

    // Se borra el registro antes de lanzar: si quedara el de una corrida
    // anterior, las comprobaciones de "registro" darian falso positivo.
    final log = File('${Directory.systemTemp.path}${sep}xtreme-update.log');
    try {
      if (log.existsSync()) await log.delete();
    } catch (_) {}

    final sw = Stopwatch()..start();
    Object? error;
    try {
      // Un PID inexistente hace que el script siga de inmediato, sin esperar a
      // que muera un proceso real.
      await UpdateInstaller.launchWindowsUpdater(
        archive: zip,
        info: info,
        processId: 999999,
        destination: dest,
      );
    } catch (e) {
      error = e;
    }
    sw.stop();

    check(
      error == null,
      'el actualizador arranco y confirmo (marcador recibido)',
      detail: error?.toString(),
    );
    check(
      sw.elapsed < const Duration(seconds: 8),
      'la confirmacion llego dentro del limite',
      detail: '${sw.elapsedMilliseconds} ms',
    );

    if (error != null) {
      throw StateError('sin confirmacion no se puede seguir');
    }

    // -------------------------------------------------------------- reemplazo
    section('Reemplazo de archivos');

    var replaced = false;
    final waitUntil = DateTime.now().add(const Duration(seconds: 90));
    while (DateTime.now().isBefore(waitUntil)) {
      if (destSo.readAsStringSync().trim() == 'NUEVO-0.1.3') {
        replaced = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    check(
      replaced,
      'el codigo nuevo reemplazo al anterior en el destino',
      detail: destSo.readAsStringSync().trim(),
    );
    if (!replaced) {
      stdout.writeln('  [diagnostico] systemTemp=${Directory.systemTemp.path}');
      stdout.writeln(
        '  [diagnostico] log=${log.path} exists=${log.existsSync()}',
      );
      if (log.existsSync()) {
        stdout.writeln(log.readAsStringSync());
      }
    }
    check(
      File('${dest.path}${sep}xtreme_studio.exe').existsSync(),
      'el ejecutable sigue en su lugar',
    );

    // ------------------------------------------------------------------ rastro
    section('Registro');

    check(log.existsSync(), 'se escribio el registro de la actualizacion');
    if (log.existsSync()) {
      // PowerShell escribe en la codificacion del sistema, asi que un mensaje
      // con acentos no es UTF-8 valido: se decodifica tolerando esos bytes.
      final text = const Utf8Decoder(
        allowMalformed: true,
      ).convert(log.readAsBytesSync());
      check(text.contains('Extrayendo'), 'registro: extraccion');
      check(text.contains('Copiando archivos nuevos'), 'registro: copia');
    }
  } finally {
    try {
      await base.delete(recursive: true);
    } catch (_) {}
  }

  stdout.writeln('');
  stdout.writeln('===============================');
  if (_failures.isEmpty) {
    stdout.writeln('ACTUALIZADOR VERIFICADO: $_passed comprobaciones pasaron');
    exit(0);
  }
  stdout.writeln('$_passed OK, ${_failures.length} FALLARON:');
  for (final f in _failures) {
    stdout.writeln('  - $f');
  }
  exit(1);
}
