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
import 'package:xtreme_studio/core/audio/ffmpeg_capture.dart';
import 'package:xtreme_studio/core/server_profile.dart';

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
  final List<String> requests = [];
  final List<String> metadataRequests = [];
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
      // El test cierra conexiones a proposito: sin observar `done`, el EPIPE
      // del servidor simulado aparece como error no capturado.
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
              final headers = latin1.decode(buffer, allowInvalid: true);
              requests.add(headers);
              final firstLine = headers.split('\r\n').first;
              headersDone = true;
              try {
                if (firstLine.startsWith('PUT ') ||
                    firstLine.startsWith('SOURCE ')) {
                  request = headers;
                  socket.write('HTTP/1.1 100 Continue\r\n\r\n');
                } else {
                  // Peticion de metadatos (/admin/metadata) o mode=delete.
                  metadataRequests.add(firstLine);
                  socket.write(
                    'HTTP/1.1 200 OK\r\n'
                    'Content-Length: 0\r\n'
                    'Connection: close\r\n\r\n',
                  );
                  socket.close();
                }
              } catch (_) {
                // El test pudo cortar la conexion justo ahora.
              }
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
  await runZonedGuarded(_run, (error, stack) {
    stderr.writeln('ERROR NO CAPTURADO: $error');
    stderr.writeln(stack);
    exit(3);
  });
}

Future<void> _run() async {
  stdout.writeln('Prueba de integracion del motor de emision');
  stdout.writeln('(FFmpeg falso + servidor Icecast simulado)');

  final fakeName = Platform.isWindows ? 'fake_ffmpeg.exe' : 'fake_ffmpeg';
  final fakeFfmpeg = File('tools${Platform.pathSeparator}$fakeName');
  if (!fakeFfmpeg.existsSync()) {
    stdout.writeln('');
    stdout.writeln('FALTA tools/$fakeName.');
    stdout.writeln('Compilalo con:');
    if (Platform.isWindows) {
      stdout.writeln(
        r'  cmd /c ""C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat" && cl /nologo /O2 /Fe:tools\fake_ffmpeg.exe tool\fake_ffmpeg.c"',
      );
    } else {
      stdout.writeln('  cc -O2 -o tools/fake_ffmpeg tool/fake_ffmpeg.c');
    }
    exit(1);
  }

  // Comprobacion previa: si este entorno no permite lanzar procesos, la prueba
  // no puede ejecutarse y conviene decirlo en lugar de fallar en cascada.
  try {
    final probe = await Process.start(fakeFfmpeg.absolute.path, const []);
    probe.kill();
  } catch (e) {
    stdout.writeln('');
    stdout.writeln('No se puede lanzar procesos en este entorno:');
    stdout.writeln('  $e');
    stdout.writeln('');
    stdout.writeln(
      'Esta prueba necesita ejecutar FFmpeg, asi que debe correrse en',
    );
    stdout.writeln(
      'una terminal normal (no dentro de un entorno restringido).',
    );
    exit(2);
  }

  final temp = await Directory.systemTemp.createTemp('xtreme_engine_');
  // El doble escribe un archivo por papel (captura/codificador) para no
  // mezclar los argumentos de los dos procesos.
  final argsBase = '${temp.path}${Platform.pathSeparator}ffmpeg_args.txt';
  File roleArgs(String role) => File('$argsBase.$role');
  final argsFile = File(argsBase);
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

  // El falso FFmpeg escribe sus argumentos en este archivo (ver fake_ffmpeg.c).
  //
  // El capturador se fija de forma explicita: el doble de FFmpeg no implementa
  // `-devices`, asi que la autodeteccion no tendria de donde elegir. En la app
  // real el motor consulta la build de FFmpeg (ver `verify_core`).
  final backend = CaptureBackend.forPlatform();
  final engine = BroadcastEngine(
    profile: profile,
    ffmpegPath: fakeFfmpeg.absolute.path,
    deviceName: 'Microfono Falso',
    captureBackend: backend,
    // La app pasa la grabacion desde Ajustes (no desde el perfil): se prueba
    // exactamente esa ruta.
    recordLocally: true,
    recordDirectory: recordDir.path,
    // El motor no debe inhibir la pantalla durante las pruebas.
    keepScreenAwake: false,
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
      await waitFor(
        () => server.connections >= 1,
        timeout: const Duration(seconds: 5),
        what: 'la conexion del servidor',
      ),
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
    section('Argumentos de la captura y del codificador');
    final gotArgs = await waitFor(
      () =>
          roleArgs('capture').existsSync() && roleArgs('encoder').existsSync(),
      timeout: const Duration(seconds: 5),
      what: 'los archivos de argumentos',
    );
    check(gotArgs, 'se lanzaron la captura y el codificador');
    if (gotArgs) {
      List<String> readArgs(String role) =>
          roleArgs(role).readAsLinesSync().where((l) => l.isNotEmpty).toList();

      final captureArgs = readArgs('capture');
      check(
        captureArgs.contains(backend.ffmpegName),
        'la captura usa el backend de la plataforma (${backend.ffmpegName})',
      );
      if (backend == CaptureBackend.dshow) {
        check(
          captureArgs.any((a) => a.startsWith('audio=')),
          'la captura pasa un dispositivo de entrada (dshow)',
          detail: captureArgs.firstWhere(
            (a) => a.startsWith('audio='),
            orElse: () => '',
          ),
        );
      } else {
        final inputIndex = captureArgs.indexOf('-i');
        check(
          inputIndex >= 0 && captureArgs[inputIndex + 1] == 'Microfono Falso',
          'la captura pasa el nombre de la fuente (${backend.ffmpegName})',
          detail: inputIndex >= 0 ? captureArgs[inputIndex + 1] : 'sin -i',
        );
      }
      check(
        captureArgs.contains('f32le') && captureArgs.contains('pipe:1'),
        'la captura entrega PCM flotante por stdout',
      );
      check(
        !captureArgs.contains('libmp3lame') &&
            !captureArgs.any((a) => a.startsWith('volume=')),
        'la captura no codifica ni aplica ganancia (eso es de Dart)',
      );

      final encoderArgs = readArgs('encoder');
      check(
        encoderArgs.contains('f32le') &&
            encoderArgs.contains('pipe:0') &&
            encoderArgs.contains('pipe:1'),
        'el codificador recibe PCM por stdin y entrega audio por stdout',
      );
      check(
        encoderArgs.contains('-analyzeduration') &&
            encoderArgs.contains('-probesize'),
        'el codificador emite sin analizar el flujo en vivo',
      );
      check(encoderArgs.contains('libmp3lame'), 'el codificador usa MP3/LAME');
      final bitrateIndex = encoderArgs.indexOf('-b:a');
      check(
        bitrateIndex >= 0 && encoderArgs[bitrateIndex + 1] == '128k',
        'se usa el bitrate del perfil',
      );
      check(
        encoderArgs.any((a) => a.contains('alimiter=limit=0.95')),
        'el codificador mantiene el limitador de seguridad',
      );
    }

    // ------------------------------------------------------------ envio real
    section('Envio de audio y vumetros');
    final sentBytes = await waitFor(
      () => server.audio.length > 2000,
      timeout: const Duration(seconds: 10),
      what: 'recibir audio en el servidor',
    );
    check(
      sentBytes,
      'el audio llega al servidor',
      detail: 'recibidos ${server.audio.length} bytes',
    );
    check(
      server.audio.length > 4 &&
          server.audio[0] == 0xFF &&
          server.audio[1] == 0xFB,
      'el flujo empieza con cabecera MP3 valida',
      detail: 'primeros bytes: ${server.audio.take(4).toList()}',
    );

    final meterOk = await waitFor(
      () => engine.snapshot.peakDb > -20,
      timeout: const Duration(seconds: 10),
      what: 'que el vumetro mida nivel',
    );
    check(
      meterOk,
      'el vumetro mide la senal de entrada',
      detail: 'pico ${engine.snapshot.peakDb.toStringAsFixed(1)} dBFS',
    );
    check(
      (engine.snapshot.peakDb - (-6.0)).abs() < 2.0,
      'el nivel medido corresponde a la onda de -6 dBFS (±2)',
      detail: 'pico ${engine.snapshot.peakDb.toStringAsFixed(1)} dBFS',
    );
    check(engine.snapshot.isLive, 'el estado es AL AIRE');

    // ------------------------------------------------- ganancia en vivo
    section('Ganancia en vivo sin cortar la emision');
    final capturePidBefore = engine.capturePid;
    final encoderPidBefore = engine.encoderPid;
    final peakBeforeGain = engine.snapshot.peakDb;
    final bytesBeforeGain = server.audio.length;

    await engine.setGain(-12);
    check(
      await waitFor(
        () => engine.snapshot.peakDb < peakBeforeGain - 8,
        timeout: const Duration(seconds: 4),
        what: 'que el vumetro baje con la ganancia',
      ),
      'mover la ganancia actualiza el vumetro al aire',
      detail:
          'antes ${peakBeforeGain.toStringAsFixed(1)} dBFS, '
          'despues ${engine.snapshot.peakDb.toStringAsFixed(1)} dBFS',
    );
    check(
      engine.capturePid == capturePidBefore,
      'la captura NO se reinicia al mover la ganancia',
      detail: 'pid antes $capturePidBefore, ahora ${engine.capturePid}',
    );
    check(
      engine.encoderPid == encoderPidBefore,
      'el codificador NO se reinicia al mover la ganancia',
      detail: 'pid antes $encoderPidBefore, ahora ${engine.encoderPid}',
    );
    check(
      !logMessages.any((m) => m.contains('La captura de audio se detuvo')),
      'no hay ningun corte de captura durante el ajuste',
    );
    check(
      await waitFor(
        () => server.audio.length > bytesBeforeGain + 1000,
        timeout: const Duration(seconds: 4),
        what: 'que el audio siga llegando al servidor',
      ),
      'la transmision sigue fluyendo despues del ajuste',
      detail:
          'antes $bytesBeforeGain bytes, ahora ${server.audio.length} bytes',
    );
    check(engine.snapshot.isLive, 'el motor sigue AL AIRE durante el ajuste');

    // Y al subirla vuelve a subir el nivel, sin reiniciar nada.
    final peakAfterDrop = engine.snapshot.peakDb;
    await engine.setGain(0);
    check(
      await waitFor(
        () => engine.snapshot.peakDb > peakAfterDrop + 8,
        timeout: const Duration(seconds: 4),
        what: 'que el vumetro vuelva a subir',
      ),
      'subir la ganancia tambien se refleja en el vumetro',
      detail:
          'antes ${peakAfterDrop.toStringAsFixed(1)} dBFS, '
          'despues ${engine.snapshot.peakDb.toStringAsFixed(1)} dBFS',
    );
    check(
      engine.capturePid == capturePidBefore &&
          engine.encoderPid == encoderPidBefore,
      'ningun proceso se reinicio en todo el ajuste',
    );

    // ------------------------------------------------------------- metadatos

    // ------------------------------------------------------------- metadatos
    section('Metadatos (suena ahora)');
    final metaOk = await engine.setTrack('Los Fabulosos - Prueba');
    check(metaOk, 'el servidor acepta el titulo por /admin/metadata');
    final adminOk = await waitFor(
      () => server.metadataRequests.any(
        (r) =>
            r.contains('/admin/metadata') &&
            r.contains('mode=updinfo') &&
            r.contains('Los'),
      ),
      timeout: const Duration(seconds: 10),
      what: 'que llegue la peticion de metadatos',
    );
    check(
      adminOk,
      'el titulo se envia por HTTP aparte (no dentro del audio)',
      detail: server.metadataRequests.join(' | '),
    );
    check(
      !latin1.decode(server.audio, allowInvalid: true).contains('StreamTitle'),
      'el flujo de audio NO contiene bloques de metadatos',
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
        check(
          f.path.endsWith('.mp3'),
          'la grabacion es un MP3',
          detail: f.uri.pathSegments.last,
        );
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
    check(
      reconnecting,
      'el motor detecta que se corto la conexion y pasa a RECONECTANDO',
      detail: 'estado actual: ${engine.snapshot.state.label}',
    );
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
    check(
      recovered,
      'el motor se reconecta solo, sin intervencion del DJ',
      detail: 'estado actual: ${engine.snapshot.state.label}',
    );
    check(
      server.connections >= 2,
      'hubo una segunda conexion al servidor',
      detail: 'conexiones: ${server.connections}',
    );

    // Y debe volver a llegar audio por la conexion nueva.
    final resumed = await waitFor(
      () => server.audio.length > bytesAntes + 1000,
      timeout: const Duration(seconds: 10),
      what: 'que se reanude el envio de audio',
    );
    check(
      resumed,
      'el audio se reanuda tras reconectar',
      detail: 'antes $bytesAntes, ahora ${server.audio.length}',
    );

    // ------------------------------------------- captura sigue viva al reconectar
    check(
      !logMessages.any((m) => m.contains('La captura de audio se detuvo')),
      'la captura de audio NO se reinicio al reconectar',
    );

    // ------------------------------------------------------------------ apagado
    section('Salida del aire');
    await engine.goOffAir();
    check(
      engine.snapshot.state == BroadcastState.idle,
      'el estado vuelve a FUERA DEL AIRE',
    );
    check(
      await waitFor(
        () => logMessages.any((m) => m.contains('Fuera del aire')),
        timeout: const Duration(seconds: 3),
        what: 'el registro de salida',
      ),
      'el registro informa la salida',
    );

    // El codificador se detiene, pero la captura sigue viva: es la misma fuente
    // que mantiene el vumetro fuera del aire.
    check(
      await waitFor(
        () => !engine.isEncoding,
        timeout: const Duration(seconds: 5),
        what: 'que termine el codificador',
      ),
      'el codificador se detiene al salir del aire',
    );
    check(
      engine.isCapturing,
      'la captura sigue viva para el vumetro fuera del aire',
    );
    check(
      engine.snapshot.peakDb > -20,
      'el vumetro sigue midiendo la misma entrada tras salir del aire',
      detail: 'pico ${engine.snapshot.peakDb.toStringAsFixed(1)} dBFS',
    );

    // Al cerrar la app si debe terminar la captura: un FFmpeg huerfano dejaria
    // el microfono ocupado y el proximo arranque fallaria.
    await engine.dispose();
    final captureStopped = await waitFor(
      () => !engine.isCapturing,
      timeout: const Duration(seconds: 5),
      what: 'que termine el proceso de captura',
    );
    check(
      captureStopped,
      'al cerrar, el proceso de captura termina (no queda huerfano)',
      detail: 'codigo de salida: ${engine.captureExitCode}',
    );

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

    final failureLogs = <String>[];
    final failureEngine = BroadcastEngine(
      profile: failureProfile,
      ffmpegPath: fakeFfmpeg.absolute.path,
      deviceName: 'Microfono Falso',
      captureBackend: backend,
      keepScreenAwake: false,
      environment: {
        'FAKEFFMPEG_ARGS_FILE': argsFile.path,
        // La captura normal se detiene sola a los 800 ms...
        'FAKEFFMPEG_DURATION_MS': '800',
        // ...y el diagnostico devuelve el error tipico de dispositivo ausente.
        'FAKEFFMPEG_DIAGNOSE_MESSAGE': mensajeReal,
      },
    );
    failureEngine.logs.listen((e) => failureLogs.add(e.message));

    final wentLive = await failureEngine.goLive();
    check(wentLive, 'el motor entra al aire antes de fallar la captura');

    // La primera muerte no debe cortar la emision: el motor reabre la captura
    // y sigue al aire (el socket y el codificador no se tocan). Solo despues
    // de varias muertes seguidas se rinde y explica el motivo.
    check(
      await waitFor(
        () => failureLogs.any((m) => m.contains('Reabriendo la captura')),
        timeout: const Duration(seconds: 10),
        what: 'que el motor reabra la captura sin salir del aire',
      ),
      'una captura que muere se reabre sin cortar la emision',
    );

    // Esperar a que la captura muera y el motor explique el motivo.
    //
    // Ojo: el motor primero avisa "captura detenida" y despues completa el
    // diagnostico. Hay que esperar el mensaje final, no el primero, o la prueba
    // se adelanta y lee el texto generico (esto ocurria de forma intermitente).
    final explained = await waitFor(
      () =>
          failureEngine.snapshot.state == BroadcastState.stopped &&
          (failureEngine.snapshot.lastError ?? '').contains(
            'No se encontro el dispositivo',
          ),
      timeout: const Duration(seconds: 30),
      what: 'que el motor explique el fallo',
    );
    check(
      explained,
      'el motor detecta la muerte de la captura',
      detail: 'estado: ${failureEngine.snapshot.state.label}',
    );

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
    stdout.writeln(
      'Estados recorridos: ${states.map((s) => s.label).join(' -> ')}',
    );
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
