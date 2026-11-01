/// Prueba REAL de captura de audio en Linux (sin FFmpeg simulado).
///
/// Verifica lo que las demas suites no pueden: que FFmpeg abra una fuente de
/// PulseAudio/PipeWire, codifique MP3, y que el motor lo envie a un servidor
/// con vumetros y grabacion funcionando.
///
/// Para no depender de que haya un microfono ni de molestar al usuario, crea un
/// sink virtual de PulseAudio (`module-null-sink`), reproduce un tono de 1 kHz
/// dentro de ese sink y captura su monitor. Al terminar lo desmonta todo.
///
/// Uso:
///   dart run tool/verify_linux_audio.dart
///
/// Requiere Linux, FFmpeg real con soporte PulseAudio (`tools/ffmpeg` o el del
/// sistema) y un servidor PulseAudio/PipeWire activo. Si falta algo, la prueba
/// se omite con un mensaje claro (no falla por el entorno).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xtreme_studio/core/audio/broadcast_engine.dart';
import 'package:xtreme_studio/core/audio/ffmpeg_capture.dart';
import 'package:xtreme_studio/core/profile_store.dart';
import 'package:xtreme_studio/core/server_profile.dart';

int _passed = 0;
final List<String> _failures = [];
final List<String> _skips = [];

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

void skip(String description) {
  _skips.add(description);
  stdout.writeln('  [OMITIDA] $description');
}

void section(String title) {
  stdout.writeln('');
  stdout.writeln('== $title ==');
}

Future<bool> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  String what = 'la condicion',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  stdout.writeln('    (se agoto el tiempo esperando $what)');
  return false;
}

/// Servidor minimo que imita a Icecast: acepta el PUT y acumula el audio.
class FakeIcecastServer {
  ServerSocket? _server;
  final List<Socket> _sockets = [];
  final List<int> audio = [];
  String request = '';
  int connections = 0;

  int get port => _server!.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((socket) {
      connections++;
      _sockets.add(socket);
      unawaited(socket.done.catchError((Object _) {}));
      final buffer = <int>[];
      var headersDone = false;
      socket.listen(
        (data) {
          if (!headersDone) {
            buffer.addAll(data);
            if (latin1
                .decode(buffer, allowInvalid: true)
                .contains('\r\n\r\n')) {
              request = latin1.decode(buffer, allowInvalid: true);
              headersDone = true;
              try {
                socket.write('HTTP/1.1 100 Continue\r\n\r\n');
              } catch (_) {}
            }
          } else {
            audio.addAll(data);
          }
        },
        onError: (_) {},
        onDone: () {},
      );
    });
  }

  Future<void> stop() async {
    for (final s in _sockets) {
      try {
        s.destroy();
      } catch (_) {}
    }
    _sockets.clear();
    await _server?.close();
    _server = null;
  }
}

Future<void> main() async {
  await runZonedGuarded(_run, (error, stack) {
    stderr.writeln('ERROR NO CAPTURADO: $error');
    stderr.writeln(stack);
    exit(3);
  });
}

Future<void> _run() async {
  stdout.writeln('Prueba REAL de captura de audio en Linux');
  stdout.writeln(
    '(FFmpeg real + PulseAudio/PipeWire + servidor Icecast simulado)',
  );

  if (!Platform.isLinux) {
    skip('solo aplica a Linux');
    _summary();
    return;
  }

  final ffmpegPath = await ProfileStore.findFfmpeg('');
  if (ffmpegPath.isEmpty) {
    skip('no se encontro FFmpeg (ni en tools/ ni en el PATH)');
    _summary();
    return;
  }

  final locator = FfmpegLocator(ffmpegPath);
  final backend = await locator.resolveBackend();
  stdout.writeln('FFmpeg: $ffmpegPath');
  stdout.writeln('Capturador: ${backend.label}');

  if (backend != CaptureBackend.pulse) {
    skip(
      'la captura real de esta prueba usa PulseAudio; '
      'la build de FFmpeg o el servidor solo ofrecen ${backend.label}',
    );
    _summary();
    return;
  }

  const cLocale = {'LANG': 'C', 'LC_ALL': 'C'};
  final pactl = await Process.run('pactl', ['info'], environment: cLocale);
  if (pactl.exitCode != 0) {
    skip('no hay servidor PulseAudio/PipeWire activo');
    _summary();
    return;
  }

  final sinkName = 'xtreme_verify_$pid';
  String? moduleId;
  Process? tone;
  final server = FakeIcecastServer();
  final temp = await Directory.systemTemp.createTemp('xtreme_linux_audio_');
  final recordDir = Directory('${temp.path}${Platform.pathSeparator}rec')
    ..createSync(recursive: true);
  BroadcastEngine? engine;

  try {
    section('Sink virtual y fuente de prueba');
    final loaded = await Process.run('pactl', [
      'load-module',
      'module-null-sink',
      'sink_name=$sinkName',
      'sink_properties=device.description=XtremeVerify',
    ], environment: cLocale);
    if (loaded.exitCode != 0) {
      skip('no se pudo crear el sink virtual: ${loaded.stderr}');
      _summary();
      return;
    }
    moduleId = (loaded.stdout as String).trim();
    check(
      moduleId.isNotEmpty,
      'se creo el sink virtual de prueba',
      detail: 'modulo $moduleId',
    );

    final devices = await locator.listAudioDevices(backend: backend);
    check(
      devices.isNotEmpty,
      'se enumeran dispositivos de entrada',
      detail: '${devices.length}',
    );

    final monitorId = '$sinkName.monitor';
    final monitor = devices.where((d) => d.id == monitorId).firstOrNull;
    check(
      monitor != null,
      'se encontro el monitor del sink virtual',
      detail: monitorId,
    );
    if (monitor == null) {
      _summary();
      return;
    }
    check(monitor.isMonitor, 'el monitor se marca como monitor');

    // Tono de 1 kHz a -6 dBFS aproximadamente (la onda seno de FFmpeg tiene
    // amplitud 0.125; volumen 4 la lleva a 0.5 = -6 dBFS).
    tone = await Process.start(ffmpegPath, [
      '-hide_banner',
      '-loglevel',
      'error',
      '-re',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=1000:sample_rate=48000:duration=20',
      '-af',
      'volume=4.0',
      '-f',
      'pulse',
      '-device',
      sinkName,
      'xtreme_verify_tone',
    ], environment: cLocale);
    // Si el generador de tono falla, se vera en su salida de error.
    final toneErrors = <int>[];
    tone.stderr.listen(toneErrors.addAll);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    check(
      toneErrors.isEmpty,
      'el generador de tono arranco sin errores',
      detail: utf8.decode(toneErrors, allowMalformed: true).trim(),
    );
    check(tone.pid > 0, 'el tono de prueba esta sonando');

    section('Vumetro fuera del aire (misma captura que la emision)');
    await server.start();
    final profile = ServerProfile(
      id: 'linux-real',
      name: 'Radio Linux de prueba',
      host: '127.0.0.1',
      port: server.port,
      mount: '/prueba',
      username: 'source',
      password: 'clave-secreta',
      stationName: 'Xtreme Linux Test',
      audio: const AudioSettings(
        bitrateKbps: 128,
        sampleRate: 44100,
        channels: 2,
      ),
    );

    engine = BroadcastEngine(
      profile: profile,
      ffmpegPath: ffmpegPath,
      deviceName: monitor.id,
      captureBackend: backend,
      recordLocally: true,
      recordDirectory: recordDir.path,
      keepScreenAwake: false,
    );
    final logs = <String>[];
    engine.logs.listen((e) => logs.add('[${e.level}] ${e.message}'));

    check(
      await engine.startPreview(),
      'la captura arranca fuera del aire, sin abrir un segundo proceso',
      detail: engine.snapshot.lastError ?? '',
    );
    check(
      await waitFor(
        () => engine!.snapshot.peakDb > -30,
        timeout: const Duration(seconds: 10),
        what: 'niveles reales fuera del aire',
      ),
      'el vumetro recibe niveles reales antes de salir al aire',
      detail: 'pico ${engine.snapshot.peakDb.toStringAsFixed(1)} dBFS',
    );

    final previewPid = engine.capturePid;
    final peakBeforeGain = engine.snapshot.peakDb;
    await engine.setGain(-12);
    check(
      await waitFor(
        () => engine!.snapshot.peakDb < peakBeforeGain - 8,
        timeout: const Duration(seconds: 5),
        what: 'que la ganancia baje el nivel fuera del aire',
      ),
      'mover la ganancia actualiza el vumetro sin reiniciar la captura',
      detail:
          'antes ${peakBeforeGain.toStringAsFixed(1)} dBFS, '
          'despues ${engine.snapshot.peakDb.toStringAsFixed(1)} dBFS',
    );
    check(
      engine.capturePid == previewPid,
      'la captura conserva el mismo proceso al cambiar la ganancia',
      detail: 'pid antes $previewPid, ahora ${engine.capturePid}',
    );
    await engine.setGain(0);
    check(
      await waitFor(
        () => engine!.snapshot.peakDb > peakBeforeGain - 3,
        timeout: const Duration(seconds: 5),
        what: 'que la ganancia vuelva al nivel original',
      ),
      'volver a 0 dB restaura el nivel medido',
      detail: 'pico ${engine.snapshot.peakDb.toStringAsFixed(1)} dBFS',
    );

    section('Emision con captura real');
    final live = await engine.goLive();
    check(
      live,
      'el motor entra al aire reutilizando la captura del vumetro',
      detail: engine.snapshot.lastError ?? '',
    );
    if (!live) {
      _summary();
      return;
    }

    final gotAudio = await waitFor(
      () => server.audio.length > 4000,
      timeout: const Duration(seconds: 20),
      what: 'recibir audio real en el servidor',
    );
    check(
      gotAudio,
      'el audio real de PulseAudio llega al servidor',
      detail: '${server.audio.length} bytes',
    );
    check(
      _hasMp3Frame(server.audio),
      'el flujo capturado contiene tramas MP3 validas',
      detail: '${server.audio.take(8).toList()}',
    );
    check(
      server.request.startsWith('PUT /prueba HTTP/1.1'),
      'el handshake con el servidor es correcto',
    );

    final meter = await waitFor(
      () => engine!.snapshot.peakDb > -30,
      timeout: const Duration(seconds: 15),
      what: 'que el vumetro mida el tono real',
    );
    check(
      meter,
      'el vumetro mide la senal capturada de verdad',
      detail: 'pico ${engine.snapshot.peakDb.toStringAsFixed(1)} dBFS',
    );
    check(
      engine.snapshot.peakDb > -18,
      'el nivel corresponde al tono de -6 dBFS (con margen)',
      detail: 'pico ${engine.snapshot.peakDb.toStringAsFixed(1)} dBFS',
    );

    // Ganancia en caliente: la captura y el codificador deben seguir siendo los
    // mismos procesos. Se captura en un `final` para que la promocion a no-nulo
    // se conserve dentro del closure de `waitFor`.
    final liveEngine = engine;
    final livePeakBefore = liveEngine.snapshot.peakDb;
    final liveCapturePid = liveEngine.capturePid;
    final liveEncoderPid = liveEngine.encoderPid;
    final liveBytesBefore = server.audio.length;
    await liveEngine.setGain(-12);
    check(
      await waitFor(
        () =>
            liveEngine.snapshot.peakDb < livePeakBefore - 8 &&
            liveEngine.snapshot.isLive,
        timeout: const Duration(seconds: 5),
        what: 'que la ganancia en vivo baje el nivel',
      ),
      'la ganancia en vivo tambien baja el nivel del stream',
      detail:
          'antes ${livePeakBefore.toStringAsFixed(1)} dBFS, '
          'despues ${liveEngine.snapshot.peakDb.toStringAsFixed(1)} dBFS',
    );
    check(
      liveEngine.capturePid == liveCapturePid &&
          liveEngine.encoderPid == liveEncoderPid,
      'ningun proceso de audio se reinicio al mover la ganancia',
      detail:
          'captura $liveCapturePid->${liveEngine.capturePid}, '
          'codificador $liveEncoderPid->${liveEngine.encoderPid}',
    );
    check(
      await waitFor(
        () => server.audio.length > liveBytesBefore + 1000,
        timeout: const Duration(seconds: 5),
        what: 'que el audio siga llegando tras el ajuste',
      ),
      'el audio real sigue fluyendo tras el ajuste de ganancia',
    );
    check(
      !logs.any((l) => l.contains('La captura de audio se detuvo')),
      'el ajuste no provoca ningun corte de captura',
    );
    // Se deja en 0 dB para el resto de la prueba.
    await liveEngine.setGain(0);

    final recOk = await waitFor(
      () {
        final files = recordDir.listSync().whereType<File>().toList();
        return files.isNotEmpty && files.first.lengthSync() > 1000;
      },
      timeout: const Duration(seconds: 10),
      what: 'que se escriba la grabacion local',
    );
    check(recOk, 'la grabacion local se escribe con audio real');

    section('Salida del aire y limpieza');
    await engine.goOffAir();
    check(
      engine.snapshot.state == BroadcastState.idle,
      'el motor vuelve a FUERA DEL AIRE',
    );
    check(
      await waitFor(
        () => !engine!.isEncoding,
        timeout: const Duration(seconds: 5),
        what: 'que termine el codificador',
      ),
      'el codificador se detiene al salir del aire',
    );
    check(
      engine.isCapturing,
      'la captura sigue viva para el vumetro fuera del aire',
    );
    await engine.dispose();
    check(
      await waitFor(
        () => !engine!.isCapturing,
        timeout: const Duration(seconds: 5),
        what: 'que termine el proceso de captura',
      ),
      'al cerrar no queda FFmpeg huerfano',
    );
    check(
      engine.captureExitCode != null,
      'FFmpeg termino con un codigo conocido',
      detail: '${engine.captureExitCode}',
    );
    check(
      logs.any((l) => l.contains('Fuera del aire')),
      'el registro informa la salida',
    );

    // El mismo motor con AAC-LC nativo: ademas del MP3, el flujo debe salir en
    // ADTS y anunciar audio/aac al servidor.
    section('Emision AAC-LC');
    final bytesBeforeAac = server.audio.length;
    profile.audio = const AudioSettings(
      codec: AudioCodec.aac,
      bitrateKbps: 96,
      sampleRate: 44100,
      channels: 2,
    );
    final aacEngine = BroadcastEngine(
      profile: profile,
      ffmpegPath: ffmpegPath,
      deviceName: monitor.id,
      captureBackend: backend,
      keepScreenAwake: false,
    );
    aacEngine.logs.listen((e) {});
    check(
      await aacEngine.goLive(),
      'el motor entra al aire codificando AAC-LC',
      detail: aacEngine.snapshot.lastError ?? '',
    );
    check(
      await waitFor(
        () => server.audio.length > bytesBeforeAac + 2000,
        timeout: const Duration(seconds: 15),
        what: 'recibir audio AAC',
      ),
      'el audio AAC llega al servidor',
      detail: '${server.audio.length - bytesBeforeAac} bytes',
    );
    final aacBytes = server.audio.sublist(bytesBeforeAac);
    check(
      aacBytes.length > 2 &&
          aacBytes[0] == 0xFF &&
          (aacBytes[1] & 0xF0) == 0xF0,
      'el flujo AAC empieza con cabecera ADTS valida',
      detail: '${aacBytes.take(4).toList()}',
    );
    check(
      server.request.toLowerCase().contains('content-type: audio/aac'),
      'el PUT anuncia Content-Type: audio/aac',
    );
    await aacEngine.goOffAir();
    check(
      await waitFor(
        () => !aacEngine.isEncoding,
        timeout: const Duration(seconds: 5),
        what: 'que termine el codificador AAC',
      ),
      'el codificador AAC se detiene al salir del aire',
    );
    await aacEngine.dispose();
    check(
      await waitFor(
        () => !aacEngine.isCapturing,
        timeout: const Duration(seconds: 5),
        what: 'que termine la captura AAC',
      ),
      'no queda FFmpeg huerfano tras la emision AAC',
    );
  } finally {
    try {
      await engine?.dispose();
    } catch (_) {}
    try {
      tone?.kill(ProcessSignal.sigkill);
      await tone?.exitCode.timeout(const Duration(seconds: 3));
    } catch (_) {}
    await server.stop();
    if (moduleId != null && moduleId.isNotEmpty) {
      try {
        await Process.run('pactl', [
          'unload-module',
          moduleId,
        ], environment: cLocale);
      } catch (_) {}
    }
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  }

  // Segundo camino real: ALSA. Se prueba con el PCM `null` (silencio), porque
  // este equipo no tiene hardware ALSA libre ni el plugin de PipeWire. Valida
  // que FFmpeg puede abrir un dispositivo ALSA y que el motor lo usa igual.
  await _testAlsaSilence();

  _summary();
}

/// Prueba el camino ALSA con un PCM que existe en cualquier Linux: `null`.
///
/// No mide nivel (el PCM `null` genera silencio), pero comprueba que FFmpeg
/// abre ALSA, codifica y el motor envia el flujo. El binario se busca en
/// `ALSA_FFMPEG`, `.tooling/ffmpeg-alsa/ffmpeg` o `tools/ffmpeg`; si ninguno
/// trae ALSA, se informa y no se cuentan comprobaciones.
Future<void> _testAlsaSilence() async {
  final candidates = <String?>[
    Platform.environment['ALSA_FFMPEG'],
    '.tooling/ffmpeg-alsa/ffmpeg',
    'tools/ffmpeg',
  ];
  String? ffmpegPath;
  for (final candidate in candidates) {
    if (candidate == null || candidate.isEmpty) continue;
    if (File(candidate).existsSync()) {
      ffmpegPath = candidate;
      break;
    }
  }
  if (ffmpegPath == null) {
    stdout.writeln(
      '  [nota] no hay un FFmpeg con ALSA para la prueba opcional',
    );
    return;
  }

  final locator = FfmpegLocator(ffmpegPath);
  final backend = await locator.resolveBackend();
  if (backend != CaptureBackend.alsa) {
    stdout.writeln(
      '  [nota] $ffmpegPath no usa ALSA (capturador: ${backend.ffmpegName}); '
      'se omite la prueba ALSA',
    );
    return;
  }

  section('ALSA real (PCM null)');
  final server = FakeIcecastServer();
  final temp = await Directory.systemTemp.createTemp('xtreme_alsa_audio_');
  BroadcastEngine? engine;
  try {
    await server.start();
    final profile = ServerProfile(
      id: 'linux-alsa',
      name: 'Radio ALSA de prueba',
      host: '127.0.0.1',
      port: server.port,
      mount: '/alsa',
      username: 'source',
      password: 'clave',
      audio: const AudioSettings(
        bitrateKbps: 128,
        sampleRate: 44100,
        channels: 2,
      ),
    );
    engine = BroadcastEngine(
      profile: profile,
      ffmpegPath: ffmpegPath,
      deviceName: 'null',
      captureBackend: CaptureBackend.alsa,
      recordDirectory: temp.path,
      keepScreenAwake: false,
    );
    engine.logs.listen((e) {});

    check(
      await engine.goLive(),
      'el motor entra al aire capturando por ALSA',
      detail: engine.snapshot.lastError ?? '',
    );
    check(
      await waitFor(
        () => server.audio.length > 2000,
        timeout: const Duration(seconds: 15),
        what: 'recibir audio por ALSA',
      ),
      'el flujo ALSA llega al servidor',
      detail: '${server.audio.length} bytes',
    );
    check(
      _hasMp3Frame(server.audio),
      'el flujo ALSA contiene tramas MP3 validas',
      detail: '${server.audio.take(8).toList()}',
    );
    // El PCM `null` de ALSA no garantiza silencio (en este equipo entrega
    // datos); lo que se comprueba es que el vumetro procesa el flujo sin
    // valores fuera de rango.
    await Future<void>.delayed(const Duration(seconds: 2));
    check(
      engine.snapshot.peakDb >= -60 && engine.snapshot.peakDb <= 0,
      'el vumetro procesa el flujo ALSA dentro de rango',
      detail: 'pico ${engine.snapshot.peakDb.toStringAsFixed(1)} dBFS',
    );
    await engine.goOffAir();
    check(
      await waitFor(
        () => !engine!.isEncoding,
        timeout: const Duration(seconds: 5),
        what: 'que termine el codificador de ALSA',
      ),
      'el codificador ALSA se detiene al salir del aire',
    );
    await engine.dispose();
    check(
      await waitFor(
        () => !engine!.isCapturing,
        timeout: const Duration(seconds: 5),
        what: 'que termine el FFmpeg de ALSA',
      ),
      'no queda FFmpeg huerfano al cerrar (ALSA)',
    );
  } finally {
    try {
      await engine?.dispose();
    } catch (_) {}
    await server.stop();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// `true` si el flujo contiene una trama MP3 valida.
///
/// FFmpeg 7 antepone una etiqueta ID3v2 al MP3 (`ID3` + tamano synchsafe);
/// versiones anteriores y el doble de pruebas empiezan directamente por la
/// sincronizacion `0xFF 0xEx`. Ambas formas son validas para los reproductores.
bool _hasMp3Frame(List<int> data) {
  if (data.length < 4) return false;

  bool syncAt(int offset) {
    if (offset + 1 >= data.length) return false;
    return data[offset] == 0xFF && (data[offset + 1] & 0xE0) == 0xE0;
  }

  if (syncAt(0)) return true;

  // Etiqueta ID3v2: bytes 6..9 son el tamano sin contar la cabecera de 10.
  if (data.length >= 10 &&
      data[0] == 0x49 && // I
      data[1] == 0x44 && // D
      data[2] == 0x33) {
    // I
    final size =
        ((data[6] & 0x7F) << 21) |
        ((data[7] & 0x7F) << 14) |
        ((data[8] & 0x7F) << 7) |
        (data[9] & 0x7F);
    if (syncAt(10 + size)) return true;
  }

  // Ultimo recurso: buscar una sincronizacion en la cabecera inicial. Cubre
  // etiquetas ID3v1 u otros metadatos previos al primer fotograma.
  final limit = data.length < 8192 ? data.length : 8192;
  for (var i = 0; i < limit - 1; i++) {
    if (syncAt(i)) return true;
  }
  return false;
}

void _summary() {
  stdout.writeln('');
  stdout.writeln('===============================');
  if (_failures.isEmpty && _skips.isEmpty) {
    stdout.writeln('AUDIO LINUX VERIFICADO: $_passed comprobaciones pasaron');
    exit(0);
  }
  if (_failures.isEmpty) {
    stdout.writeln('OMITIDA: ${_skips.join(' / ')}');
    stdout.writeln('(no se puede probar la captura real en este entorno)');
    exit(0);
  }
  stdout.writeln('$_passed OK, ${_failures.length} FALLARON:');
  for (final f in _failures) {
    stdout.writeln('  - $f');
  }
  exit(1);
}
