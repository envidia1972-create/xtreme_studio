/// Prueba de integracion del motor de emision, sin Flutter y sin microfono.
///
/// Se reemplaza FFmpeg por `tools/fake_ffmpeg.exe`, que emite MP3 por stdout y
/// PCM por stderr igual que el real, y se levanta un servidor que imita a
/// Icecast. Con eso se verifica la cadena completa:
///
///   arranque -> captura -> envio de audio -> vumetros -> metadatos ->
///   caida de red -> reconexion -> apagado
///
/// Uso:
///   dart run tool/verify_engine.dart
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xtreme_studio/core/audio/broadcast_engine.dart';
import 'package:xtreme_studio/core/server_profile.dart';

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

/// Espera a que se cumpla una condicion, revisando cada 100 ms.
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

/// Servidor que imita a Icecast: acepta el PUT y acumula los bytes de audio.
class FakeIcecastServer {
  ServerSocket? _server;
  final List<Socket> _sockets = [];
  final List<int> audio = [];
  String request = '';
  int connections = 0;

  int get port => _server!.port;

  /// Longitud del audio recibido en la conexion actual.
  int get currentStreamBytes => audio.length;

  Future<void> start({int? fixedPort}) async {
    _server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      fixedPort ?? 0,
    );
    _server!.listen((socket) {
      connections++;
      _sockets.add(socket);
      final buffer = <int>[];
      var headersDone = false;

      socket.listen(
        (data) {
          if (!headersDone) {
            buffer.addAll(data);
            if (latin1.decode(buffer, allowInvalid: true).contains('\r\n\r\n')) {
              request = latin1.decode(buffer, allowInvalid: true);
              headersDone = true;
              socket.write('HTTP/1.1 100 Continue\r\n\r\n');
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

  /// Corta todas las conexiones, como si se cayera la red.
  Future<void> killConnections() async {
    for (final s in _sockets) {
      try {
        s.destroy();
      } catch (_) {}
    }
    _sockets.clear();
  }

  Future<void> stop() async {
    await killConnections();
    await _server?.close();
    _server = null;
  }
}

Future<void> main() async {
  stdout.writeln('Prueba de integracion del motor de emision');
  stdout.writeln('(FFmpeg falso + servidor Icecast simulado)');

  final fakeFfmpeg = File('tools${Platform.pathSeparator}fake_ffmpeg.exe');
  if (!fakeFfmpeg.existsSync()) {
    stdout.writeln('');
    stdout.writeln('FALTA tools/fake_ffmpeg.exe.');
    stdout.writeln('Compilalo con:');
    stdout.writeln(r'  cmd /c ""C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat" && cl /nologo /O2 /Fe:tools\fake_ffmpeg.exe tool\fake_ffmpeg.c"');
    exit(1);
  }

  // Comprobacion previa: si este entorno no permite lanzar procesos, la prueba
  // no puede ejecutarse y conviene decirlo en lugar de fallar en cascada.
  try {
    final probe = await Process.start(fakeFfmpeg.absolute.path, const []);
    await probe.kill();
  } catch (e) {
    stdout.writeln('');
    stdout.writeln('No se puede lanzar procesos en este entorno:');
    stdout.writeln('  $e');
    stdout.writeln('');
    stdout.writeln('Esta prueba necesita ejecutar FFmpeg, asi que debe correrse en');
    stdout.writeln('una terminal normal (no dentro de un entorno restringido).');
    exit(2);
  }

  final temp = await Directory.systemTemp.createTemp('xtreme_engine_');
  final argsFile = File('${temp.path}${Platform.pathSeparator}ffmpeg_args.txt');
  final recordDir = Directory('${temp.path}${Platform.pathSeparator}rec')
    ..createSync(recursive: true);

  final server = FakeIcecastServer();
  await server.start();

  final profile = ServerProfile(
    id: 'test',
    name: 'Radio de prueba',
    host: '127.0.0.1',
    port: server.port,
    mount: '/prueba',
    username: 'source',
    password: 'clave-secreta',
    stationName: 'Xtreme Test',
    audio: const AudioSettings(
      bitrateKbps: 128,
      sampleRate: 44100,
      channels: 2,
    ),
  );
  profile.inputDeviceId = 'Microfono Falso';
  profile.recordLocally = true;
  profile.recordDirectory = recordDir.path;

  // El falso FFmpeg escribe sus argumentos en este archivo (ver fake_ffmpeg.c).
  final engine = BroadcastEngine(
    profile: profile,
    ffmpegPath: fakeFfmpeg.absolute.path,
    deviceName: 'Microfono Falso',
    environment: {'FAKEFFMPEG_ARGS_FILE': argsFile.path},
  );

  final states = <BroadcastState>[];
  final logMessages = <String>[];
  engine.snapshots.listen((s) {
    if (states.isEmpty || states.last != s.state) states.add(s.state);
  });
  engine.logs.listen((e) => logMessages.add('[${e.level}] ${e.message}'));

  try {
    // ---------------------------------------------------------------- arranque
    section('Arranque y salida al aire');
    final live = await engine.goLive();
    check(live, 'el motor entra al aire');
    check(
      await waitFor(() => server.connections >= 1,
          timeout: const Duration(seconds: 5), what: 'la conexion del servidor'),
      'el servidor recibio la conexion',
    );
    check(
      server.request.startsWith('PUT /prueba HTTP/1.1'),
      'llega un PUT al mount configurado',
      detail: server.request.split('\r\n').first,
    );
    check(
      !server.request.contains('clave-secreta'),
      'la contrasena no viaja en texto plano',
    );

    // ------------------------------------------------------- argumentos ffmpeg
    section('Argumentos con los que se invoco a FFmpeg');
    final gotArgs = await waitFor(() => argsFile.existsSync(),
        timeout: const Duration(seconds: 5), what: 'el archivo de argumentos');
    check(gotArgs, 'FFmpeg fue invocado');
    if (argsFile.existsSync()) {
      final args = argsFile
          .readAsLinesSync()
          .where((l) => l.isNotEmpty)
          .toList();
      check(args.contains('dshow'), 'se captura por dshow');
      check(
        args.any((a) => a.startsWith('audio=')),
        'se pasa un dispositivo de entrada',
        detail: args.firstWhere((a) => a.startsWith('audio='), orElse: () => ''),
      );
      check(args.contains('libmp3lame'), 'se codifica en MP3');
      final bitrateIndex = args.indexOf('-b:a');
      check(
        bitrateIndex >= 0 && args[bitrateIndex + 1] == '128k',
        'se usa el bitrate del perfil',
      );
      check(args.contains('pipe:1'), 'el MP3 se entrega por stdout');
      check(args.contains('pipe:2'), 'los niveles se entregan por stderr');
      final mapCount = args.where((a) => a == '-map').length;
      check(mapCount == 2, 'las dos salidas mapean el audio explicitamente',
          detail: 'mapeos: $mapCount');
    }

    // ------------------------------------------------------------ envio real
    section('Envio de audio y vumetros');
    final sentBytes = await waitFor(
      () => server.audio.length > 2000,
      timeout: const Duration(seconds: 10),
      what: 'recibir audio en el servidor',
    );
    check(sentBytes, 'el audio llega al servidor',
        detail: 'recibidos ${server.audio.length} bytes');
    check(
      server.audio.length > 4 && server.audio[0] == 0xFF && server.audio[1] == 0xFB,
      'el flujo empieza con cabecera MP3 valida',
      detail: 'primeros bytes: ${server.audio.take(4).toList()}',
    );

    final meterOk = await waitFor(
      () => engine.snapshot.peakDb > -20,
      timeout: const Duration(seconds: 10),
      what: 'que el vumetro mida nivel',
    );
    check(meterOk, 'el vumetro mide la senal de entrada',
        detail: 'pico ${engine.snapshot.peakDb.toStringAsFixed(1)} dBFS');
    check(
      (engine.snapshot.peakDb - (-6.0)).abs() < 2.0,
      'el nivel medido corresponde a la onda de -6 dBFS (±2)',
      detail: 'pico ${engine.snapshot.peakDb.toStringAsFixed(1)} dBFS',
    );
    check(engine.snapshot.isLive, 'el estado es AL AIRE');

    // ------------------------------------------------------------- metadatos
    section('Metadatos (suena ahora)');
    await engine.setTrack('Los Fabulosos - Prueba');
    final metaOk = await waitFor(
      () => latin1
          .decode(server.audio, allowInvalid: true)
          .contains('StreamTitle='),
      timeout: const Duration(seconds: 10),
      what: 'que el titulo llegue al servidor',
    );
    check(metaOk, 'el titulo viaja en el flujo de metadatos');
    check(
      latin1
          .decode(server.audio, allowInvalid: true)
          .contains('Los Fabulosos - Prueba'),
      'el titulo llega integro',
    );

    // ---------------------------------------------------------- grabacion local
    section('Grabacion local');
    final recOk = await waitFor(
      () {
        final files = recordDir.listSync().whereType<File>().toList();
        return files.isNotEmpty && files.first.lengthSync() > 500;
      },
      timeout: const Duration(seconds: 10),
      what: 'que se escriba la grabacion',
    );
    check(recOk, 'se esta grabando la emision en disco');
    {
      final files = recordDir.listSync().whereType<File>().toList();
      if (files.isNotEmpty) {
        final f = files.first;
        check(f.path.endsWith('.mp3'), 'la grabacion es un MP3',
            detail: f.uri.pathSegments.last);
        // La grabacion debe ser identica al audio que reciben los oyentes.
        check(
          f.lengthSync() > 0 &&
              (f.lengthSync() - server.audio.length).abs() <= 8192,
          'lo grabado coincide con lo que reciben los oyentes',
          detail: 'grabado ${f.lengthSync()} vs enviado ${server.audio.length}',
        );
      }
    }

    // ------------------------------------------------------ caida y reconexion
    section('Caida de red y reconexion automatica');
    final bytesAntes = server.audio.length;
    await server.killConnections();

    final reconnecting = await waitFor(
      () => engine.snapshot.state == BroadcastState.reconnecting,
      timeout: const Duration(seconds: 8),
      what: 'que el motor detecte la caida',
    );
    check(reconnecting,
        'el motor detecta que se corto la conexion y pasa a RECONECTANDO',
        detail: 'estado actual: ${engine.snapshot.state.label}');
    check(
      states.contains(BroadcastState.reconnecting),
      'el cambio de estado se notifica a la interfaz',
      detail: states.map((s) => s.label).join(' -> '),
    );

    // El servidor sigue vivo: el reintento debe reconectar.
    final recovered = await waitFor(
      () => engine.snapshot.state == BroadcastState.live,
      timeout: const Duration(seconds: 25),
      what: 'que se reconecte solo',
    );
    check(recovered, 'el motor se reconecta solo, sin intervencion del DJ',
        detail: 'estado actual: ${engine.snapshot.state.label}');
    check(server.connections >= 2,
        'hubo una segunda conexion al servidor',
        detail: 'conexiones: ${server.connections}');

    // Y debe volver a llegar audio por la conexion nueva.
    final resumed = await waitFor(
      () => server.audio.length > bytesAntes + 1000,
      timeout: const Duration(seconds: 10),
      what: 'que se reanude el envio de audio',
    );
    check(resumed, 'el audio se reanuda tras reconectar',
        detail: 'antes $bytesAntes, ahora ${server.audio.length}');

    // ------------------------------------------- captura sigue viva al reconectar
    check(
      !logMessages.any((m) => m.contains('La captura de audio se detuvo')),
      'la captura de audio NO se reinicio al reconectar',
    );

    // ------------------------------------------------------------------ apagado
    section('Salida del aire');
    await engine.goOffAir();
    check(engine.snapshot.state == BroadcastState.idle,
        'el estado vuelve a FUERA DEL AIRE');
    check(
      await waitFor(
        () => logMessages.any((m) => m.contains('Fuera del aire')),
        timeout: const Duration(seconds: 3),
        what: 'el registro de salida',
      ),
      'el registro informa la salida',
    );

    // El proceso de captura debe haber terminado de verdad: un FFmpeg huerfano
    // dejaria el microfono ocupado y el proximo intento de emitir fallaria.
    final captureStopped = await waitFor(
      () => !engine.isCapturing,
      timeout: const Duration(seconds: 5),
      what: 'que termine el proceso de captura',
    );
    check(captureStopped, 'el proceso de captura termino (no queda huerfano)',
        detail: 'codigo de salida: ${engine.captureExitCode}');

    // -------------------------------------- fallo de captura con diagnostico
    // Caso central para el DJ: FFmpeg muere y hay que decirle POR QUE. El
    // doble de FFmpeg, cuando se lo relanza pidiendo un instante de audio
    // (el diagnostico), responde con el mensaje real de un dispositivo
    // inexistente.
    section('Fallo de captura explicado al DJ');

    const mensajeReal =
        '[dshow @ 0000] Could not find audio only device with name [Mic] '
        'among source devices.';

    final failureServer = FakeIcecastServer();
    await failureServer.start();

    // Perfil propio para no tocar el que usa el motor anterior.
    final failureProfile = ServerProfile(
      id: 'test-fallo',
      name: 'Radio con fallo de captura',
      host: '127.0.0.1',
      port: failureServer.port,
      mount: '/fallo',
      username: 'source',
      password: 'clave',
      audio: const AudioSettings(
        bitrateKbps: 128,
        sampleRate: 44100,
        channels: 2,
      ),
    );

    final failureEngine = BroadcastEngine(
      profile: failureProfile,
      ffmpegPath: fakeFfmpeg.absolute.path,
      deviceName: 'Microfono Falso',
      environment: {
        'FAKEFFMPEG_ARGS_FILE': argsFile.path,
        // La captura normal se detiene sola a los 800 ms...
        'FAKEFFMPEG_DURATION_MS': '800',
        // ...y el diagnostico devuelve el error tipico de dispositivo ausente.
        'FAKEFFMPEG_DIAGNOSE_MESSAGE': mensajeReal,
      },
    );
    failureEngine.logs.listen((e) {});

    final wentLive = await failureEngine.goLive();
    check(wentLive, 'el motor entra al aire antes de fallar la captura');

    // Esperar a que la captura muera y el motor explique el motivo.
    final explained = await waitFor(
      () => failureEngine.snapshot.state == BroadcastState.stopped &&
          (failureEngine.snapshot.lastError ?? '').isNotEmpty,
      timeout: const Duration(seconds: 30),
      what: 'que el motor explique el fallo',
    );
    check(explained, 'el motor detecta la muerte de la captura',
        detail: 'estado: ${failureEngine.snapshot.state.label}');

    final error = failureEngine.snapshot.lastError ?? '';
    check(
      error.contains('No se encontro el dispositivo'),
      'el mensaje al DJ explica que el dispositivo no existe',
      detail: error,
    );
    check(
      !error.contains('sin explicar el motivo'),
      'y NO se queda en el mensaje generico',
      detail: error,
    );
    check(
      await waitFor(
        () => !failureEngine.isCapturing,
        timeout: const Duration(seconds: 5),
        what: 'que no quede captura huerfana tras el fallo',
      ),
      'tras el fallo no queda un proceso de captura huerfano',
    );

    await failureEngine.dispose();
    await failureServer.stop();

    stdout.writeln('');
    stdout.writeln('Estados recorridos: ${states.map((s) => s.label).join(' -> ')}');
  } finally {
    await engine.dispose();
    await server.stop();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  }

  stdout.writeln('');
  stdout.writeln('===============================');
  if (_failures.isEmpty) {
    stdout.writeln('MOTOR VERIFICADO: $_passed comprobaciones pasaron');
    exit(0);
  }
  stdout.writeln('$_passed OK, ${_failures.length} FALLARON:');
  for (final f in _failures) {
    stdout.writeln('  - $f');
  }
  exit(1);
}
