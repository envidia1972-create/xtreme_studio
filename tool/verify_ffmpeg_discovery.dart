/// Prueba del descubrimiento de FFmpeg y del comando de captura.
///
/// Es el punto que mas friccion genera: si la app no encuentra FFmpeg, no se
/// puede emitir, y el DJ no tiene forma de saber por que. Aqui se verifica que
/// lo encuentre en las ubicaciones donde de verdad queda instalado.
///
/// Uso: dart run tool/verify_ffmpeg_discovery.dart
library;

import 'dart:io';

import 'package:xtreme_studio/core/audio/ffmpeg_capture.dart';
import 'package:xtreme_studio/core/profile_store.dart';

int _passed = 0;
final List<String> _failures = [];

void check(bool ok, String description, {String? detail}) {
  if (ok) {
    _passed++;
    stdout.writeln('  [ok]   $description');
  } else {
    _failures.add(description);
    stdout.writeln('  [FALLA] $description${detail != null ? ' -> $detail' : ''}');
  }
}

void section(String title) {
  stdout.writeln('');
  stdout.writeln('== $title ==');
}

Future<void> main() async {
  stdout.writeln('Verificacion del descubrimiento de FFmpeg');

  final toolsDir = Directory('tools');
  final probePath =
      '${toolsDir.path}${Platform.pathSeparator}ffmpeg.exe';
  final probe = File(probePath);
  // Se crea un archivo vacio: a la busqueda solo le importa que exista.
  final existed = probe.existsSync();
  final saved = existed ? probe.readAsBytesSync() : null;
  if (!existed) {
    toolsDir.createSync(recursive: true);
    probe.writeAsStringSync('');
  }

  try {
    section('Ubicaciones buscadas');

    // 1) Ruta preferida por el usuario: prioridad absoluta.
    final preferred = await ProfileStore.findFfmpeg(probePath);
    check(
      preferred == probePath,
      'si el usuario indica una ruta valida, se usa esa',
      detail: preferred,
    );

    // 2) Ruta inexistente indicada por el usuario: no debe romper nada.
    final bogus = await ProfileStore.findFfmpeg(
      '${Directory.systemTemp.path}${Platform.pathSeparator}no-existe-ffmpeg.exe',
    );
    check(
      bogus !=
          '${Directory.systemTemp.path}${Platform.pathSeparator}no-existe-ffmpeg.exe',
      'una ruta invalida se descarta y se sigue buscando',
      detail: bogus.isEmpty ? '(no encontrado, correcto)' : bogus,
    );

    // 3) Autodeteccion: debe encontrarlo junto al proyecto (tools\).
    //    El archivo de prueba sigue en su sitio durante esta comprobacion.
    final auto = await ProfileStore.findFfmpeg('');
    check(
      auto.isNotEmpty,
      'la autodeteccion encuentra FFmpeg en tools\\',
      detail: auto.isEmpty ? 'no lo encontro' : auto,
    );
    check(
      auto.toLowerCase().contains('tools'),
      'la ruta encontrada es la del proyecto',
      detail: auto,
    );
    check(
      File(auto).existsSync(),
      'la ruta devuelta existe de verdad en disco',
      detail: auto,
    );

    // 4) Vacio explicito: debe comportarse igual que la autodeteccion.
    final emptyPreferred = await ProfileStore.findFfmpeg('   ');
    check(
      emptyPreferred.isNotEmpty,
      'una ruta preferida vacia o con espacios no bloquea la busqueda',
      detail: emptyPreferred.isEmpty ? 'devolvio vacio' : emptyPreferred,
    );

    // 5) El caso de la app YA COMPILADA: vive en
    //    build\windows\x64\runner\Release\, cinco niveles dentro del proyecto,
    //    mientras que FFmpeg esta en tools\ en la raiz. Si la busqueda no sube
    //    por los directorios padre, el DJ tendria que copiar ffmpeg.exe a mano.
    section('Ejecucion desde la carpeta compilada');
    final releaseDir = Directory(
      'build${Platform.pathSeparator}windows${Platform.pathSeparator}x64'
      '${Platform.pathSeparator}runner${Platform.pathSeparator}Release',
    );
    releaseDir.createSync(recursive: true);

    final upward = ProfileStore.debugSearchUpwards(releaseDir, 'ffmpeg.exe');
    check(
      upward.isNotEmpty,
      'subiendo desde build\\...\\Release se encuentra tools\\ffmpeg.exe',
      detail: upward.isEmpty ? 'no lo encontro' : upward,
    );
    check(
      upward.isNotEmpty && File(upward).existsSync(),
      'la ruta hallada por la busqueda ascendente existe',
      detail: upward,
    );
    check(
      upward.toLowerCase().contains('tools'),
      'la encontro en la carpeta tools del proyecto',
      detail: upward,
    );

    // Se limpia lo que creo esta comprobacion.
    try {
      Directory('build').deleteSync(recursive: true);
    } catch (_) {}

    section('Comando de captura generado');

    final args = CaptureArgs(
      deviceName: 'Micrófono (Realtek(R) Audio)',
      bitrateKbps: 128,
      sampleRate: 44100,
      channels: 2,
      gainDb: 2.5,
    );
    final preview = args.preview();

    check(preview.startsWith('ffmpeg.exe '), 'el comando empieza con el ejecutable');
    // El nombre del dispositivo va citado junto con el prefijo `audio=`, que es
    // como lo espera el capturador dshow de FFmpeg.
    check(
      preview.contains('"audio=Micrófono (Realtek(R) Audio)"'),
      'cita el argumento del dispositivo (tiene espacios y parentesis)',
      detail: preview.split(' ').take(12).join(' '),
    );
    check(
      preview.contains('-f dshow') && preview.contains('-audio_buffer_size'),
      'indica el capturador de Windows y el tamano de buffer',
    );
    check(
      preview.contains('pipe:1') && preview.contains('pipe:2'),
      'las dos salidas van a las tuberias correctas',
    );
    check(
      !preview.contains('\n'),
      'el comando queda en una sola linea (se puede pegar en la consola)',
    );

    section('Diagnostico de errores de FFmpeg');

    // Estos mensajes son los que ve el DJ cuando algo falla; importan tanto
    // como el codigo, porque sin ellos el fallo es indistinguible de "no suena".
    check(
      explainFfmpegError(
        'Could not find audio only device with name [X] among source devices',
      ).contains('No se encontro el dispositivo'),
      'dispositivo inexistente da un mensaje entendible',
    );
    check(
      explainFfmpegError(
        'dshow: Access is denied.\nCannot open audio device',
      ).contains('Otro programa'),
      'microfono ocupado por otro programa se explica',
    );
    check(
      explainFfmpegError('Unknown encoder libmp3lame').contains('libmp3lame'),
      'falta de codificador MP3 se explica',
    );
    check(
      explainFfmpegError('').isNotEmpty,
      'un error vacio tambien produce un mensaje util',
    );
  } finally {
    // Se restaura el estado original: el archivo de prueba era solo para la
    // comprobacion de autodeteccion.
    if (!existed && probe.existsSync()) {
      probe.deleteSync();
    } else if (existed && saved != null) {
      probe.writeAsBytesSync(saved);
    }
    stdout.writeln('');
    stdout.writeln('(archivo de prueba de FFmpeg eliminado: ${!probe.existsSync()})');
  }

  stdout.writeln('');
  stdout.writeln('===============================');
  if (_failures.isEmpty) {
    stdout.writeln('DETECCION VERIFICADA: $_passed comprobaciones pasaron');
    exit(0);
  }
  stdout.writeln('$_passed OK, ${_failures.length} FALLARON:');
  for (final f in _failures) {
    stdout.writeln('  - $f');
  }
  exit(1);
}
