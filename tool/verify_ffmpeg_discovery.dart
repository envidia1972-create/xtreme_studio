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
    stdout.writeln(
      '  [FALLA] $description${detail != null ? ' -> $detail' : ''}',
    );
  }
}

void section(String title) {
  stdout.writeln('');
  stdout.writeln('== $title ==');
}

Future<void> main() async {
  stdout.writeln('Verificacion del descubrimiento de FFmpeg');

  final toolsDir = Directory('tools');
  final exeName = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
  final probePath = '${toolsDir.path}${Platform.pathSeparator}$exeName';
  final probe = File(probePath);
  // Si el proyecto ya trae FFmpeg (el caso normal en Linux, donde se descarga
  // para probar la captura real), NO se toca. Solo se crea un archivo vacio si
  // no existe: a la busqueda le importa que exista, no su contenido.
  final existed = probe.existsSync();
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
      '${Directory.systemTemp.path}${Platform.pathSeparator}no-existe-$exeName',
    );
    check(
      bogus !=
          '${Directory.systemTemp.path}${Platform.pathSeparator}no-existe-$exeName',
      'una ruta invalida se descarta y se sigue buscando',
      detail: bogus.isEmpty ? '(no encontrado, correcto)' : bogus,
    );

    // 3) Autodeteccion: debe encontrarlo junto al proyecto (tools\).
    //    El archivo de prueba sigue en su sitio durante esta comprobacion.
    final auto = await ProfileStore.findFfmpeg('');
    check(
      auto.isNotEmpty,
      'la autodeteccion encuentra FFmpeg en tools/',
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

    // 5) El caso de la app YA COMPILADA: vive dentro de build/, varios niveles
    //    por debajo del proyecto, mientras que FFmpeg esta en tools/ en la
    //    raiz. Si la busqueda no sube por los directorios padre, el DJ tendria
    //    que copiar FFmpeg a mano.
    section('Ejecucion desde la carpeta compilada');
    final buildExisted = Directory('build').existsSync();
    final releaseDir = Platform.isWindows
        ? Directory(
            'build${Platform.pathSeparator}windows${Platform.pathSeparator}x64'
            '${Platform.pathSeparator}runner${Platform.pathSeparator}Release',
          )
        : Directory(
            'build${Platform.pathSeparator}linux${Platform.pathSeparator}x64'
            '${Platform.pathSeparator}release${Platform.pathSeparator}bundle',
          );
    releaseDir.createSync(recursive: true);

    final upward = ProfileStore.debugSearchUpwards(releaseDir, exeName);
    check(
      upward.isNotEmpty,
      'subiendo desde la carpeta compilada se encuentra tools/$exeName',
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

    // Se limpia solo la carpeta build si la creo esta comprobacion: si ya
    // existia (por ejemplo, tras compilar la app) no se toca.
    if (!buildExisted) {
      try {
        Directory('build').deleteSync(recursive: true);
      } catch (_) {}
    }

    section('Comando de captura generado');

    final backend = CaptureBackend.forPlatform();
    final args = CaptureArgs(
      deviceName: 'Micrófono (Realtek(R) Audio)',
      sampleRate: 44100,
      channels: 2,
      backend: backend,
    );
    final preview = args.preview();

    check(
      preview.startsWith(Platform.isWindows ? 'ffmpeg.exe ' : 'ffmpeg '),
      'el comando empieza con el ejecutable de la plataforma',
      detail: preview.split(' ').first,
    );
    check(
      preview.contains('"Micrófono (Realtek(R) Audio)"'),
      'cita el argumento del dispositivo (tiene espacios y parentesis)',
      detail: preview.split(' ').take(12).join(' '),
    );
    if (backend == CaptureBackend.dshow) {
      // En Windows el nombre va junto con el prefijo `audio=`, que es como lo
      // espera el capturador dshow de FFmpeg.
      check(
        preview.contains('"audio=Micrófono (Realtek(R) Audio)"'),
        'dshow recibe el prefijo audio=',
      );
      check(
        preview.contains('-f dshow') && preview.contains('-audio_buffer_size'),
        'indica el capturador de Windows y el tamano de buffer',
      );
    } else {
      check(
        preview.contains('-f ${backend.ffmpegName}') &&
            !preview.contains('dshow'),
        'Linux usa el capturador ${backend.ffmpegName}, sin dshow',
      );
    }
    check(
      preview.contains('f32le') && preview.contains('pipe:1'),
      'la captura entrega PCM flotante por stdout',
    );
    check(
      !preview.contains('\n'),
      'el comando queda en una sola linea (se puede pegar en la consola)',
    );

    final encoderPreview = const EncoderArgs(
      bitrateKbps: 128,
      sampleRate: 44100,
      channels: 2,
    ).preview();
    check(
      encoderPreview.contains('pipe:0') &&
          encoderPreview.contains('libmp3lame') &&
          !encoderPreview.contains('\n'),
      'el codificador recibe PCM por stdin y entrega MP3 por stdout',
      detail: encoderPreview,
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
    check(
      explainFfmpegError(
        "Unknown input format: 'pulse'",
        backend: CaptureBackend.pulse,
      ).contains('no incluye soporte'),
      'una build sin PulseAudio se explica',
    );
    check(
      explainFfmpegError(
        'PulseAudio server connection failure: Connection refused',
        backend: CaptureBackend.pulse,
      ).contains('No se pudo conectar'),
      'un servidor PulseAudio caido se explica',
    );
  } finally {
    // Se restaura el estado original: el archivo de prueba era solo para la
    // comprobacion de autodeteccion.
    if (!existed && probe.existsSync()) {
      probe.deleteSync();
    }
    stdout.writeln('');
    stdout.writeln(
      '(archivo de prueba de FFmpeg eliminado: ${!probe.existsSync()})',
    );
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
