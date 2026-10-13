import 'dart:io';

import 'package:xtreme_studio/core/audio/ffmpeg_capture.dart';

/// Diagnostico de la enumeracion de dispositivos de entrada.
///
/// Usa la MISMA funcion que la aplicacion (`FfmpegLocator.listAudioDevices`)
/// para que el resultado sea representativo de lo que ve la app.
Future<void> main(List<String> args) async {
  final ffmpeg = args.isNotEmpty
      ? args.first
      : r'C:\Desarrollo\xtreme_studio\tools\ffmpeg.exe';

  stdout.writeln('=== Diagnostico de dispositivos de entrada ===');
  stdout.writeln('ffmpeg: $ffmpeg');
  stdout.writeln('existe : ${File(ffmpeg).existsSync()}');
  stdout.writeln('');

  final locator = FfmpegLocator(ffmpeg);

  stdout.writeln('--- version() ---');
  final v = await locator.version();
  stdout.writeln('  "$v"');
  stdout.writeln('');

  stdout.writeln('--- listAudioDevices() ---');
  final devices = await locator.listAudioDevices();
  stdout.writeln('  dispositivos encontrados: ${devices.length}');
  for (final d in devices) {
    stdout.writeln('    id   = "${d.id}"');
    stdout.writeln('    name = "${d.name}"');
  }
  stdout.writeln('');

  if (devices.isEmpty) {
    stdout.writeln('  LECTURA VACIA: la app no podria ofrecer ningun dispositivo.');
    stdout.writeln('  Se repite la llamada a FFmpeg mostrando lo que devuelve:');
    final r = await Process.run(ffmpeg, [
      '-hide_banner',
      '-list_devices',
      'true',
      '-f',
      'dshow',
      '-i',
      'dummy',
    ]);
    stdout.writeln('    exitCode: ${r.exitCode}');
    stdout.writeln('    stdout length: ${(r.stdout as String).length}');
    stdout.writeln('    stderr length: ${(r.stderr as String).length}');
    stdout.writeln('    --- stderr ---');
    for (final l in (r.stderr as String).split('\n')) {
      if (l.trim().isNotEmpty) stdout.writeln('      $l');
    }
  }
}
