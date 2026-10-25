import 'dart:io';

import 'package:xtreme_studio/core/audio/ffmpeg_capture.dart';
import 'package:xtreme_studio/core/profile_store.dart';

/// Diagnostico de la enumeracion de dispositivos de entrada.
///
/// Usa la MISMA funcion que la aplicacion (`FfmpegLocator.listAudioDevices`)
/// para que el resultado sea representativo de lo que ve la app.
///
/// Uso:
///   dart run tool/diagnose_devices.dart [ruta-a-ffmpeg]
///
/// Sin argumento busca FFmpeg igual que la app (junto al ejecutable, en tools/
/// y en el PATH).
Future<void> main(List<String> args) async {
  var ffmpeg = args.isNotEmpty ? args.first : await ProfileStore.findFfmpeg('');

  stdout.writeln('=== Diagnostico de dispositivos de entrada ===');
  stdout.writeln('ffmpeg: ${ffmpeg.isEmpty ? "(no encontrado)" : ffmpeg}');
  if (ffmpeg.isEmpty) {
    stdout.writeln(
      'Indica la ruta: dart run tool/diagnose_devices.dart /ruta/ffmpeg',
    );
    exit(1);
  }
  stdout.writeln('existe : ${File(ffmpeg).existsSync()}');
  stdout.writeln('');

  final locator = FfmpegLocator(ffmpeg);

  stdout.writeln('--- version() ---');
  stdout.writeln('  "${await locator.version()}"');
  stdout.writeln('');

  stdout.writeln('--- resolveBackend() ---');
  final backend = await locator.resolveBackend();
  stdout.writeln('  ${backend.label} (-f ${backend.ffmpegName})');
  stdout.writeln('');

  stdout.writeln('--- listAudioDevices() ---');
  final devices = await locator.listAudioDevices(backend: backend);
  stdout.writeln('  dispositivos encontrados: ${devices.length}');
  for (final d in devices) {
    stdout.writeln('    id   = "${d.id}"');
    stdout.writeln('    name = "${d.name}"');
    if (d.isMonitor) stdout.writeln('    tipo = monitor');
  }
  stdout.writeln('');

  if (devices.isEmpty) {
    stdout.writeln(
      '  LECTURA VACIA: la app no podria ofrecer ningun dispositivo.',
    );
    stdout.writeln(
      '  Se repite la llamada mostrando lo que devuelve el sistema:',
    );
    final List<String> command;
    if (Platform.isWindows) {
      command = [
        '-hide_banner',
        '-list_devices',
        'true',
        '-f',
        'dshow',
        '-i',
        'dummy',
      ];
    } else {
      // En Linux el sistema de audio es la fuente de verdad.
      stdout.writeln('  (backend ${backend.ffmpegName})');
      command = const [];
    }

    if (command.isNotEmpty) {
      final r = await Process.run(ffmpeg, command);
      stdout.writeln('    exitCode: ${r.exitCode}');
      stdout.writeln('    stdout length: ${(r.stdout as String).length}');
      stdout.writeln('    stderr length: ${(r.stderr as String).length}');
      stdout.writeln('    --- stderr ---');
      for (final l in (r.stderr as String).split('\n')) {
        if (l.trim().isNotEmpty) stdout.writeln('      $l');
      }
    } else {
      stdout.writeln('  Comandos utiles:');
      stdout.writeln('    pactl list sources');
      stdout.writeln('    arecord -l  /  arecord -L');
      stdout.writeln('    ffmpeg -hide_banner -devices | grep -E "pulse|alsa"');
    }
  }
}
