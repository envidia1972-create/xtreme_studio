/// Prueba real del actualizador portable de Linux.
///
/// Crea un bundle falso, un tar.gz nuevo, ejecuta el script con un PID que ya
/// no existe y comprueba que reemplaza la carpeta, deja la copia anterior y
/// vuelve a lanzar el ejecutable.
///
/// Uso: dart run tool/verify_linux_updater.dart
library;

import 'dart:io';

import 'package:xtreme_studio/core/update/update_installer.dart';

Future<void> main() async {
  if (!Platform.isLinux) {
    stdout.writeln('Se omite: solo aplica a Linux.');
    return;
  }

  final root = await Directory.systemTemp.createTemp(
    'xtreme linux updater test ',
  );
  final failures = <String>[];
  void check(bool ok, String text) {
    stdout.writeln('  [${ok ? 'ok' : 'FALLA'}] $text');
    if (!ok) failures.add(text);
  }

  try {
    final home = Directory('${root.path}/home')..createSync();
    final dest = Directory('${root.path}/app bundle')..createSync();
    File('${dest.path}/old.txt').writeAsStringSync('version vieja');
    final oldApp = File('${dest.path}/xtreme_studio');
    oldApp.writeAsStringSync('#!/bin/sh\nexit 0\n');
    Process.runSync('chmod', ['755', oldApp.path]);
    Directory('${dest.path}/data').createSync();

    final newRoot = Directory('${root.path}/nuevo')..createSync();
    final newBundle = Directory('${newRoot.path}/bundle')..createSync();
    final newApp = File('${newBundle.path}/xtreme_studio');
    newApp.writeAsStringSync(
      '#!/bin/sh\n'
      r'echo started > "$(dirname "$0")/started.txt"'
      '\n',
    );
    Process.runSync('chmod', ['755', newApp.path]);
    Directory('${newBundle.path}/data').createSync();
    File('${newBundle.path}/new.txt').writeAsStringSync('version nueva');

    final archive = File('${root.path}/update.tar.gz');
    final tar = await Process.run('tar', [
      '-czf',
      archive.path,
      '-C',
      newRoot.path,
      'bundle',
    ]);
    check(tar.exitCode == 0, 'crea el tar.gz de prueba');
    if (tar.exitCode != 0) {
      stderr.write(tar.stderr);
      return;
    }

    final script = File('${root.path}/update.sh');
    script.writeAsStringSync(UpdateInstaller.buildLinuxUpdaterScript());
    Process.runSync('chmod', ['700', script.path]);

    final result = await Process.run(
      '/bin/sh',
      [script.path, '999999', archive.path, dest.path],
      environment: {'HOME': home.path},
    );
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    check(result.exitCode == 0, 'el actualizador termina sin errores');

    final marker = File('${dest.path}/started.txt');
    for (var i = 0; i < 30 && !marker.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    check(File('${dest.path}/new.txt').existsSync(), 'copia la version nueva');
    check(!File('${dest.path}/old.txt').existsSync(), 'quita la version vieja');
    check(marker.existsSync(), 'vuelve a lanzar la app');
    final backup = Directory('${dest.path}.update-backup');
    check(backup.existsSync(), 'deja la copia de seguridad');
    check(
      File('${backup.path}/old.txt').existsSync(),
      'la copia de seguridad conserva la version anterior',
    );
    check(!archive.existsSync(), 'borra el tar.gz descargado');
    check(
      File('${home.path}/.xtreme_studio/update.log').existsSync(),
      'escribe el registro de actualizacion',
    );
  } finally {
    if (root.existsSync()) root.deleteSync(recursive: true);
  }

  stdout.writeln('');
  if (failures.isEmpty) {
    stdout.writeln('ACTUALIZADOR LINUX VERIFICADO');
    exit(0);
  }
  stdout.writeln('${failures.length} fallas:');
  for (final failure in failures) {
    stdout.writeln('  - $failure');
  }
  exit(1);
}
