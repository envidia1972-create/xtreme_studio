/// Motor de emision: une captura, ganancia, codificacion, envio y reconexion.
///
/// Decision de diseno clave: **hay una sola captura**. Un solo proceso FFmpeg
/// lee el microfono y entrega PCM en crudo; Dart aplica la ganancia, mide el
/// nivel y alimenta a un segundo proceso que codifica. La captura no se reinicia
/// al entrar o salir del aire ni al mover la ganancia: solo se reabre si deja de
/// entregar audio o si el proceso muere (ver `_recoverCapture`).
///
/// Eso resuelve dos problemas de una vez:
///
/// 1. El vumetro es uno solo: mide el mismo PCM con la misma ganancia antes y
///    despues de entrar al aire.
/// 2. Mover la ganancia no corta la emision: es una multiplicacion en Dart, no
///    un reinicio de FFmpeg.
///
/// El flujo es:
///
///   ffmpeg (captura -> PCM f32le) --stdout--> Dart
///                                              |-- ganancia + vumetro
///                                              `--> ffmpeg (encoder) --stdout--> socket
///                                                                       `--> grabacion
///
/// Si la red se cae, solo se rehace el socket: ni el microfono ni el
/// codificador se tocan.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../net/broadcaster.dart';
import '../net/icecast_client.dart';
import '../server_profile.dart';
import '../diagnostic_log.dart';
import '../screen_guard.dart';
import 'ffmpeg_capture.dart';
import 'gain_stage.dart';
import 'soundboard.dart';

/// Estado del motor, tal como se muestra en pantalla.
enum BroadcastState {
  /// Sin emitir.
  idle,

  /// Arrancando captura de audio y conectando al servidor.
  starting,

  /// Al aire.
  live,

  /// Se perdio la conexion, se esta reintentando.
  reconnecting,

  /// Se detuvo. [BroadcastEngine.lastError] explica el motivo.
  stopped,
}

extension BroadcastStateInfo on BroadcastState {
  String get label => switch (this) {
    BroadcastState.idle => 'FUERA DEL AIRE',
    BroadcastState.starting => 'PREPARANDO...',
    BroadcastState.live => 'AL AIRE',
    BroadcastState.reconnecting => 'RECONECTANDO',
    BroadcastState.stopped => 'DETENIDO',
  };
}

/// Instantanea del motor para pintar la interfaz.
class BroadcastSnapshot {
  const BroadcastSnapshot({
    required this.state,
    required this.peakDb,
    required this.rmsDb,
    required this.secondsOnAir,
    this.peakHoldDb = -60,
    required this.bytesSent,
    required this.reconnectAttempt,
    this.currentTrack = '',
    this.lastError,
    this.recordingPath,
  });

  final BroadcastState state;
  final double peakDb;
  final double rmsDb;

  /// Pico retenido para la lectura numerica (estable, sin parpadeo).
  final double peakHoldDb;

  final int secondsOnAir;
  final int bytesSent;
  final int reconnectAttempt;
  final String currentTrack;
  final String? lastError;
  final String? recordingPath;

  bool get isLive => state == BroadcastState.live;

  /// Bitrate real medido, en kbps. Sirve para detectar que el encoder no
  /// arranco bien aunque la conexion este "viva".
  double get measuredKbps {
    if (secondsOnAir <= 0) return 0;
    return (bytesSent * 8) / secondsOnAir / 1000;
  }

  BroadcastSnapshot copyWith({
    BroadcastState? state,
    double? peakDb,
    double? rmsDb,
    double? peakHoldDb,
    int? secondsOnAir,
    int? bytesSent,
    int? reconnectAttempt,
    String? currentTrack,
    String? lastError,
    String? recordingPath,
    bool clearError = false,
  }) => BroadcastSnapshot(
    state: state ?? this.state,
    peakDb: peakDb ?? this.peakDb,
    rmsDb: rmsDb ?? this.rmsDb,
    peakHoldDb: peakHoldDb ?? this.peakHoldDb,
    secondsOnAir: secondsOnAir ?? this.secondsOnAir,
    bytesSent: bytesSent ?? this.bytesSent,
    reconnectAttempt: reconnectAttempt ?? this.reconnectAttempt,
    currentTrack: currentTrack ?? this.currentTrack,
    lastError: clearError ? null : (lastError ?? this.lastError),
    recordingPath: recordingPath ?? this.recordingPath,
  );
}

/// Una linea del registro de actividad que ve el DJ.
class LogEntry {
  LogEntry(this.level, this.message) : at = DateTime.now();

  final String level; // info | ok | warn | error
  final String message;
  final DateTime at;

  String get stamp {
    final h = at.hour.toString().padLeft(2, '0');
    final m = at.minute.toString().padLeft(2, '0');
    final s = at.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

/// Motor de emision para un perfil.
class BroadcastEngine {
  BroadcastEngine({
    required this.profile,
    required this.ffmpegPath,
    this.gainDb = 0.0,
    this.deviceName = '',
    this.recordLocally,
    this.recordDirectory,
    this.captureBackend,
    this.soundboard,
    bool keepScreenAwake = true,
    Map<String, String>? environment,
  }) : environment = environment ?? const {} {
    _gainStage.gainDb = gainDb;
    _screenGuard = ScreenGuard(enabled: keepScreenAwake);
  }

  ServerProfile profile;
  String ffmpegPath;
  double gainDb;
  String deviceName;

  /// Capturador de audio elegido por la interfaz (`dshow`, `pulse` o `alsa`).
  ///
  /// Si es `null`, el motor consulta la build de FFmpeg y el servidor de audio
  /// disponible antes de capturar. La interfaz lo pasa para que la lista de
  /// dispositivos y el comando que se muestra en Ajustes coincidan con lo que
  /// realmente se va a ejecutar.
  CaptureBackend? captureBackend;
  CaptureBackend? _effectiveBackend;

  /// Mezclador de jingles. Es el mismo objeto que usa la pantalla Soundboard:
  /// asi el vumetro, el stream y la grabacion ven exactamente la misma mezcla.
  final SoundboardMixer? soundboard;

  /// Evita que la pantalla se bloquee y que el equipo se suspenda al aire.
  ///
  /// Es un ajuste global de la app (Ajustes). Si se apaga con la emision en
  /// curso, la inhibicion se suelta de inmediato.
  bool get keepScreenAwake => _screenGuard.enabled;

  set keepScreenAwake(bool value) {
    if (_screenGuard.enabled == value) return;
    _screenGuard.enabled = value;
    if (!value && _screenGuard.isRunning) unawaited(_screenGuard.stop());
  }

  /// Inhibe el bloqueo de pantalla y la suspension mientras se emite.
  late final ScreenGuard _screenGuard;

  /// Grabacion local. Si se deja en `null` se usa la del perfil (compatibilidad
  /// con versiones anteriores); la app pasa aqui los ajustes globales, que son
  /// los que el DJ edita en Ajustes.
  bool? recordLocally;
  String? recordDirectory;

  bool get _shouldRecord =>
      (recordLocally ?? profile.recordLocally) &&
      (recordDirectory ?? profile.recordDirectory).isNotEmpty;

  /// Variables de entorno extra para el proceso de captura.
  ///
  /// Se usa en las pruebas, para sustituir FFmpeg por un doble que emite MP3 y
  /// PCM igual que el real y asi poder verificar toda la cadena sin microfono.
  final Map<String, String> environment;

  final _snapshotController = StreamController<BroadcastSnapshot>.broadcast();
  final _logController = StreamController<LogEntry>.broadcast();

  Stream<BroadcastSnapshot> get snapshots => _snapshotController.stream;
  Stream<LogEntry> get logs => _logController.stream;

  BroadcastSnapshot _snapshot = const BroadcastSnapshot(
    state: BroadcastState.idle,
    peakDb: -60,
    rmsDb: -60,
    secondsOnAir: 0,
    bytesSent: 0,
    reconnectAttempt: 0,
  );

  BroadcastSnapshot get snapshot => _snapshot;

  /// `true` mientras el proceso de captura este vivo.
  ///
  /// La captura se mantiene fuera del aire para que el vumetro siga midiendo
  /// con la misma fuente. Solo se detiene al cerrar la app o al cambiar de
  /// dispositivo.
  bool get isCapturing => _capture?.isRunning ?? false;

  /// `true` mientras haya un codificador produciendo audio para el servidor.
  bool get isEncoding => _encoder?.isRunning ?? false;

  /// Codigo de salida de la captura, cuando ya termino.
  int? get captureExitCode =>
      _capture?.exitCodeIfFinished ?? _lastCaptureExitCode;

  /// Codigo de salida del codificador, cuando ya termino.
  int? get encoderExitCode => _encoder?.exitCodeIfFinished;

  /// PID de cada proceso, para diagnostico y pruebas.
  int? get capturePid => _capture?.pid;
  int? get encoderPid => _encoder?.pid;

  final LevelMeter _meter = LevelMeter();
  final GainStage _gainStage = GainStage();

  BroadcastState _state = BroadcastState.idle;
  String? _lastError;

  FfmpegProcess? _capture;
  FfmpegProcess? _encoder;
  Broadcaster? _broadcaster;
  StreamSubscription<Uint8List>? _pcmSub;
  StreamSubscription<Uint8List>? _audioSub;
  StreamSubscription<Uint8List>? _captureErrSub;
  StreamSubscription<Uint8List>? _encoderErrSub;
  StreamSubscription<int>? _exitSub;
  StreamSubscription<int>? _encoderExitSub;
  StreamSubscription<void>? _lostSub;
  Timer? _ticker;
  Timer? _reconnectTimer;
  IOSink? _recordingSink;

  bool _stopping = false;
  int _reconnectAttempt = 0;
  int _secondsOnAir = 0;
  int _bytesSent = 0;
  int _ticksSinceFlush = 0;
  bool _flushInFlight = false;
  int? _lastCaptureExitCode;
  final List<String> _ffmpegErrors = [];
  final List<String> _encoderErrors = [];

  /// Ultima vez que se publico una lectura de nivel (se limita a ~20 por
  /// segundo para no reconstruir la interfaz en cada bloque de PCM).
  DateTime? _lastMeterEmit;

  /// Bitrate de pico reciente, para mostrar "no llega audio" con fundamento.
  DateTime? _lastAudioAt;

  /// Ultimo bloque de PCM que entrego la captura.
  ///
  /// Es distinto de [_lastAudioAt], que mide la salida del codificador: si la
  /// captura se queda muda pero el codificador sigue vivo, la emision se oye
  /// en silencio aunque el estado diga "AL AIRE". Con esta marca se detecta y
  /// se reabre la captura.
  DateTime? _lastPcmAt;

  /// Cuando se abrio la captura actual, para vigilar el arranque.
  DateTime? _captureStartedAt;

  bool _restartingCapture = false;
  DateTime? _lastCaptureRestartAt;
  int _captureRestartCount = 0;

  /// Momentos en que murio el proceso de captura, para no reintentar sin fin.
  final List<DateTime> _captureDeaths = [];

  void _log(String level, String message) {
    // El registro en archivo es lo que permite diagnosticar un fallo que solo
    // ocurre en la maquina del DJ. Se escribe en todos los niveles.
    DiagnosticLog.instance?.write('motor', '[$level] $message');
    if (_logController.isClosed) return;
    _logController.add(LogEntry(level, message));
  }

  void _emit() {
    _snapshot = BroadcastSnapshot(
      state: _state,
      peakDb: _meter.peakDb,
      rmsDb: _meter.rmsDb,
      peakHoldDb: _meter.peakHoldDb,
      secondsOnAir: _secondsOnAir,
      bytesSent: _bytesSent,
      reconnectAttempt: _reconnectAttempt,
      currentTrack: _snapshot.currentTrack,
      lastError: _lastError,
      recordingPath: _snapshot.recordingPath,
    );
    if (!_snapshotController.isClosed) _snapshotController.add(_snapshot);
  }

  void _setState(BroadcastState state, {String? error}) {
    _state = state;
    _lastError = error;
    _emit();
  }

  /// Arranca solo la captura, sin conectarse a ningun servidor.
  ///
  /// Es lo que mantiene vivo el vumetro fuera del aire. La misma captura se
  /// reutiliza al salir al aire: no se abre el microfono dos veces ni se cambia
  /// de medidor.
  Future<bool> startPreview() async {
    if (_capture?.isRunning == true) return true;
    if (ffmpegPath.isEmpty || !File(ffmpegPath).existsSync()) return false;
    _stopping = false;
    _lastCaptureExitCode = null;
    _effectiveBackend =
        captureBackend ?? await FfmpegLocator(ffmpegPath).resolveBackend();
    final started = await _startCapture();
    if (started &&
        _state != BroadcastState.live &&
        _state != BroadcastState.starting &&
        _state != BroadcastState.reconnecting) {
      _setState(BroadcastState.idle);
    }
    return started;
  }

  /// Entra al aire.
  ///
  /// [confirmOverwrite] es la salvaguarda contra pisar a otro DJ: si el mount
  /// ya tiene una fuente activa, el servidor responde 403/409 y aqui se avisa
  /// en lugar de dejar al DJ creyendo que esta al aire.
  Future<bool> goLive({bool force = false}) async {
    if (_state == BroadcastState.live || _state == BroadcastState.starting) {
      return true;
    }
    _stopping = false;
    _reconnectAttempt = 0;
    _secondsOnAir = 0;
    _bytesSent = 0;
    _ffmpegErrors.clear();
    _captureRestartCount = 0;
    _lastCaptureRestartAt = null;
    _captureDeaths.clear();
    _setState(BroadcastState.starting);

    DiagnosticLog.instance?.write(
      'motor',
      'salir al aire: emisora="${profile.name}" '
          'destino=${profile.host}:${profile.effectivePort} '
          'dispositivo="${deviceName.isEmpty ? "(por defecto)" : deviceName}" '
          'ffmpeg="$ffmpegPath" '
          'capturador=${captureBackend?.ffmpegName ?? "auto"}',
    );

    if (ffmpegPath.isEmpty || !File(ffmpegPath).existsSync()) {
      _setState(
        BroadcastState.stopped,
        error:
            'No se encontro FFmpeg. Indica la ruta del ejecutable en Ajustes.',
      );
      _log('error', 'FFmpeg no encontrado en "$ffmpegPath"');
      return false;
    }

    // Se decide el capturador ANTES de conectar: si FFmpeg no trae ni pulse ni
    // alsa, conviene saberlo ya, con un mensaje claro, y no despues de haber
    // ocupado el mount de la radio.
    _effectiveBackend =
        captureBackend ?? await FfmpegLocator(ffmpegPath).resolveBackend();
    DiagnosticLog.instance?.write(
      'audio',
      'capturador elegido: ${_effectiveBackend!.label}',
    );

    final ok = await _connectAndStart(force: force);
    if (!ok) return false;

    // El DJ pudo pulsar "salir" mientras se conectaba. En ese caso no se puede
    // arrancar el reloj ni dejar el estado en "AL AIRE": ya no hay socket.
    if (_stopping) return false;

    _startTicker();
    // Con la emision en curso se pide al escritorio que no bloquee la pantalla
    // ni suspenda el equipo: el bloqueo reconfigura el audio del sistema y la
    // captura se queda muda.
    await _screenGuard.start();
    return true;
  }

  /// `true` si el codigo HTTP indica que el mount ya tiene una fuente activa.
  ///
  /// Icecast responde `403` y SHOUTcast `409` cuando otro emisor ocupa el
  /// punto de montaje. Es la unica senal fiable que da el servidor: algunos
  /// hosting **no** avisan y simplemente desplazan al anterior, en cuyo caso no
  /// hay nada que detectar y la app no puede proteger de eso.
  static bool isMountOccupiedError(int? statusCode) =>
      statusCode == 403 || statusCode == 409;

  /// Ultimo error de conexion, para que la interfaz pueda reaccionar.
  int? get lastConnectStatusCode => _lastConnectStatusCode;
  int? _lastConnectStatusCode;

  Future<bool> _connectAndStart({bool force = false}) async {
    // 1. Conectar ANTES de capturar: si las credenciales estan mal, no tiene
    //    sentido abrir el microfono ni molestar al DJ con un dispositivo
    //    ocupado.
    var broadcaster = Broadcaster(profile);
    try {
      DiagnosticLog.instance?.write(
        'red',
        'conectando a ${profile.host}:${profile.effectivePort}'
            '${profile.normalizedMount} (${profile.protocol.shortLabel})',
      );
      await broadcaster.connect();
      DiagnosticLog.instance?.write('red', 'conexion aceptada por el servidor');
      // Si el DJ cancelo mientras se negociaba la conexion, se suelta el socket
      // ya mismo. Sin esto la emision podia empezar despues de pulsar "salir".
      if (_stopping) {
        await broadcaster.dispose();
        return false;
      }
    } on IcecastException catch (e) {
      if (_stopping) {
        await broadcaster.dispose();
        return false;
      }
      _lastConnectStatusCode = e.statusCode;
      DiagnosticLog.instance?.write(
        'red',
        'conexion rechazada: ${e.message}'
            '${e.statusCode != null ? " (HTTP ${e.statusCode})" : ""}',
      );

      // Mount ocupado y el DJ pidio forzar: se intenta liberar la fuente
      // anterior antes de reintentar. Icecast admite `?mode=delete` para que el
      // servidor suelte el mount sin esperar a que expire por timeout.
      if (force && isMountOccupiedError(e.statusCode)) {
        _log('warn', 'El mount estaba ocupado: se pide al servidor liberarlo');
        await broadcaster.releaseMount();
        await broadcaster.close();

        broadcaster = Broadcaster(profile);
        try {
          await broadcaster.connect();
          if (_stopping) {
            await broadcaster.dispose();
            return false;
          }
          _log('ok', 'Mount liberado: se entra al aire por la fuerza');
        } on IcecastException catch (retryError) {
          _broadcaster = null;
          _setState(
            BroadcastState.stopped,
            error:
                'El mount sigue ocupado despues de intentar liberarlo. '
                'Puede que otro DJ lo este usando ahora mismo. '
                '(${retryError.message})',
          );
          _log('error', 'No se pudo liberar el mount: ${retryError.message}');
          await broadcaster.close();
          return false;
        }
      } else {
        _broadcaster = null;
        final hint = switch (e.statusCode) {
          401 => 'Usuario o contrasena incorrectos.',
          403 || 409 =>
            'Ya hay otro DJ transmitiendo en este mount. Si sos vos, espera a '
                'que el servidor suelte la fuente, o confirma para desplazarlo.',
          _ => e.message,
        };
        _setState(BroadcastState.stopped, error: hint);
        _log('error', 'No se pudo conectar: $hint');
        await broadcaster.close();
        return false;
      }
    } catch (e) {
      if (_stopping) {
        await broadcaster.dispose();
        return false;
      }
      _lastConnectStatusCode = null;
      _setState(BroadcastState.stopped, error: 'Error al conectar: $e');
      _log('error', 'Error al conectar: $e');
      await broadcaster.close();
      return false;
    }

    _lastConnectStatusCode = null;
    _broadcaster = broadcaster;
    _log('ok', 'Conectado a ${profile.summary}');

    // Si el servidor corta la conexion durante la emision, hay que enterarse:
    // Dart no lanza error al escribir en un socket ya cerrado.
    await _lostSub?.cancel();
    _lostSub = broadcaster.onConnectionLost.listen((_) {
      notifyConnectionLost('el servidor dejo de responder o cerro la conexion');
    });

    // 2. La captura puede estar viva desde el modo monitor. Si no, se abre
    //    ahora; en ningun caso se reinicia al entrar al aire.
    if (!await _ensureCapture()) {
      await _teardownBroadcaster();
      return false;
    }

    if (_stopping) {
      await _teardownBroadcaster();
      return false;
    }

    // 3. Codificador: existe solo mientras se esta al aire.
    if (!await _startEncoder()) {
      await _teardownBroadcaster();
      return false;
    }

    _setState(BroadcastState.live);
    _log('ok', 'AL AIRE');
    return true;
  }

  /// Abre la captura si todavia no esta corriendo.
  Future<bool> _ensureCapture() async {
    if (_capture?.isRunning == true) return true;
    return _startCapture();
  }

  /// Arranca la captura de entrada (PCM crudo).
  Future<bool> _startCapture() async {
    final args = CaptureArgs(
      deviceName: deviceName,
      sampleRate: profile.audio.sampleRate,
      channels: profile.audio.channels,
      backend: _effectiveBackend ?? captureBackend,
    );

    FfmpegProcess capture;
    try {
      capture = await FfmpegProcess.start(
        ffmpegPath: ffmpegPath,
        args: args.build(ffmpegPath),
        role: 'capture',
        environment: environment,
      );
    } on ProcessException catch (e) {
      if (_stopping) return false;
      DiagnosticLog.instance?.write(
        'ffmpeg',
        'no se pudo iniciar la captura: ${e.message} (ruta: $ffmpegPath)',
      );
      _setState(
        BroadcastState.stopped,
        error: 'No se pudo iniciar FFmpeg: ${e.message}',
      );
      _log('error', 'No se pudo iniciar FFmpeg: ${e.message}');
      return false;
    }

    _capture = capture;
    _captureStartedAt = DateTime.now();
    _lastPcmAt = null;
    _gainStage.reset();
    _meter.reset();
    _lastMeterEmit = null;

    DiagnosticLog.instance?.write(
      'ffmpeg',
      'captura iniciada, pid=${capture.pid}',
    );
    DiagnosticLog.instance?.write(
      'ffmpeg',
      'comando captura: ${args.preview()}',
    );

    // PCM -> ganancia -> vumetro + codificador.
    _pcmSub = capture.stdout.listen(
      _onPcm,
      onError: (Object e) => _log('warn', 'Error leyendo audio: $e'),
    );
    _captureErrSub = capture.stderr.listen(
      (data) =>
          _recordFfmpegMessage(data, target: _ffmpegErrors, source: 'captura'),
      onError: (_) {},
    );

    _exitSub = capture.exitCode.asStream().listen((code) {
      if (_stopping || code == 0) return;
      // Si se estaba reabriendo la captura, esta salida es la del proceso que
      // se acaba de cerrar a proposito.
      if (_restartingCapture) return;
      // Fuera del manejador: reabrir cancela esta misma suscripcion y no
      // conviene esperar ese cierre desde dentro del evento.
      if (_state == BroadcastState.live) {
        unawaited(
          Future.microtask(
            () => _recoverCapture(
              'la captura termino con codigo $code',
              afterExit: true,
              exitCode: code,
            ),
          ),
        );
        return;
      }
      unawaited(_handleCaptureFailure(code));
    });

    return true;
  }

  /// Aplica la ganancia, mide y entrega el mismo PCM al codificador.
  ///
  /// Todo lo que se mide es exactamente lo que se codifica: no hay una segunda
  /// ruta de audio que pueda desincronizarse.
  void _onPcm(Uint8List chunk) {
    final amplified = _gainStage.process(chunk);
    if (amplified.isEmpty) return;

    final mixed = soundboard?.mix(amplified) ?? amplified;
    if (mixed.isEmpty) return;

    _lastPcmAt = DateTime.now();
    _captureRestartCount = 0;
    _meter.feedFloat(mixed);

    final encoder = _encoder;
    if (encoder != null) {
      try {
        encoder.stdin.add(mixed);
      } catch (e) {
        _log('warn', 'No se pudo entregar audio al codificador: $e');
      }
    }

    final now = DateTime.now();
    final last = _lastMeterEmit;
    if (last == null ||
        now.difference(last) >= const Duration(milliseconds: 50)) {
      _lastMeterEmit = now;
      _emit();
    }
  }

  /// Arranca el codificador que alimenta al servidor.
  Future<bool> _startEncoder() async {
    if (_encoder?.isRunning == true) return true;

    final args = EncoderArgs(
      bitrateKbps: profile.audio.bitrateKbps,
      sampleRate: profile.audio.sampleRate,
      channels: profile.audio.channels,
      codec: profile.audio.codec,
    );

    FfmpegProcess encoder;
    try {
      encoder = await FfmpegProcess.start(
        ffmpegPath: ffmpegPath,
        args: args.build(ffmpegPath),
        role: 'encoder',
        environment: environment,
      );
    } on ProcessException catch (e) {
      DiagnosticLog.instance?.write(
        'ffmpeg',
        'no se pudo iniciar el codificador: ${e.message}',
      );
      _setState(
        BroadcastState.stopped,
        error: 'No se pudo iniciar el codificador: ${e.message}',
      );
      _log('error', 'No se pudo iniciar el codificador: ${e.message}');
      return false;
    }

    _encoder = encoder;
    _encoderErrors.clear();
    // Si el codificador muere, escribir en su entrada no debe tumbar la app.
    unawaited(encoder.stdin.done.catchError((Object _) {}));

    DiagnosticLog.instance?.write(
      'ffmpeg',
      'codificador iniciado, pid=${encoder.pid}',
    );
    DiagnosticLog.instance?.write(
      'ffmpeg',
      'comando codificador: ${args.preview()}',
    );

    // Audio codificado -> servidor (+ grabacion local si esta activa).
    _audioSub = encoder.stdout.listen((chunk) {
      _lastAudioAt = DateTime.now();
      try {
        _broadcaster?.send(chunk);
        _bytesSent += chunk.length;
        _recordingSink?.add(chunk);
      } catch (e) {
        _log('warn', 'Error enviando audio: $e');
      }
    }, onError: (Object e) => _log('warn', 'Error leyendo audio: $e'));

    _encoderErrSub = encoder.stderr.listen(
      (data) => _recordFfmpegMessage(
        data,
        target: _encoderErrors,
        source: 'codificador',
      ),
      onError: (_) {},
    );

    _encoderExitSub = encoder.exitCode.asStream().listen((code) async {
      if (_stopping || code == 0) return;
      await _handleEncoderFailure(code);
    });

    _startRecording();
    return true;
  }

  /// Reabre la captura sin cortar la emision.
  ///
  /// Se usa cuando el proceso de captura muere o deja de entregar PCM. El
  /// codificador y el socket **no** se tocan: los oyentes no pierden el mount y
  /// el audio vuelve en cuanto la entrada responde otra vez.
  ///
  /// [afterExit] distingue las dos causas:
  ///  - la captura **murio** (el proceso termino): se reintenta enseguida,
  ///    porque el proceso ya no existe y esperar solo alarga el silencio;
  ///  - la captura **se quedo muda** (sigue viva pero no entrega PCM): se
  ///    espera un poco antes de reabrirla, para no cerrar y abrir el
  ///    dispositivo en bucle.
  Future<void> _recoverCapture(
    String reason, {
    bool afterExit = false,
    int? exitCode,
  }) async {
    if (_stopping || _restartingCapture) return;
    if (_state != BroadcastState.live) return;

    final now = DateTime.now();

    if (afterExit) {
      // Tres muertes en un minuto ya no son un tropiezo del sistema: algo
      // impide capturar de verdad. Se sale del aire con el diagnostico real.
      _captureDeaths.removeWhere(
        (t) => now.difference(t) > const Duration(minutes: 1),
      );
      _captureDeaths.add(now);
      if (_captureDeaths.length > 3) {
        await _handleCaptureFailure(
          exitCode ?? -1,
          reason: 'la captura se cerro ${_captureDeaths.length} veces seguidas',
        );
        return;
      }
    } else {
      // Enfriamiento: si el dispositivo no responde, no se reinicia en bucle.
      final lastRestart = _lastCaptureRestartAt;
      if (lastRestart != null &&
          now.difference(lastRestart) < const Duration(seconds: 5)) {
        return;
      }

      // Se cuentan los reinicios sin audio nuevo. Cuando se agotan, la emision
      // no tiene sentido: se sale del aire con un mensaje claro.
      if (_captureRestartCount >= 6) {
        await _handleCaptureFailure(
          -1,
          reason: 'la captura no se recupero tras varios intentos',
        );
        return;
      }
      _captureRestartCount++;
    }

    _lastCaptureRestartAt = now;
    _restartingCapture = true;
    try {
      _log('warn', 'Reabriendo la captura de audio ($reason)');
      DiagnosticLog.instance?.write(
        'ffmpeg',
        'reinicio de captura #$_captureRestartCount: $reason',
      );
      await _teardownCapture();
      if (_stopping || _state != BroadcastState.live) return;

      final wasLive = _state == BroadcastState.live;
      final started = await _startCapture();
      // El socket y el codificador siguen vivos: si la reapertura falla, se
      // mantiene el estado al aire y el proximo intento vuelve a probar.
      if (!started && wasLive && !_stopping) {
        _setState(BroadcastState.live);
      }
    } finally {
      _restartingCapture = false;
    }
  }

  /// Explica por que se detuvo la captura y deja el motor en un estado claro.
  ///
  /// Primero se usan los mensajes que FFmpeg alcanzo a escribir. Si no dicen
  /// nada util, se lanza un diagnostico de un solo disparo sobre el mismo
  /// dispositivo para obtener el motivo real, porque "termino sin explicar el
  /// motivo" no le sirve de nada al DJ.
  Future<void> _handleCaptureFailure(int code, {String? reason}) async {
    final recorded = _ffmpegErrors.join('\n');
    DiagnosticLog.instance?.write(
      'ffmpeg',
      'la captura termino con codigo $code. Mensajes: '
          '${recorded.isEmpty ? "(ninguno)" : recorded.replaceAll("\n", " | ")}',
    );
    var hint = explainFfmpegError(recorded, backend: _effectiveBackend);
    var usedDiagnosis = false;

    // Solo se salta el diagnostico si el mensaje de FFmpeg se pudo traducir a
    // una causa concreta. Un volcado sin interpretar ("FFmpeg reporto: ...")
    // no le dice al DJ que hacer, asi que vale la pena reintentar la apertura.
    final looksUseful =
        recorded.trim().isNotEmpty &&
        !hint.contains('sin explicar el motivo') &&
        !hint.startsWith('FFmpeg reporto:');

    if (!looksUseful) {
      _log('info', 'Averiguando por que se detuvo la captura...');
      final lines = await diagnoseCaptureFailure(
        ffmpegPath: ffmpegPath,
        args: CaptureArgs(
          deviceName: deviceName,
          sampleRate: profile.audio.sampleRate,
          channels: profile.audio.channels,
          backend: _effectiveBackend,
        ),
        environment: environment,
      );
      if (lines.isNotEmpty) {
        final diagnosis = explainFfmpegError(
          lines.join('\n'),
          backend: _effectiveBackend,
        );
        if (!diagnosis.contains('sin explicar el motivo')) {
          hint = diagnosis;
          usedDiagnosis = true;
        }
      }
    }

    // Si ya no se esta emitiendo, no se pisa un estado mas avanzado.
    if (_stopping) return;

    _log(
      'error',
      'La captura de audio se detuvo (${reason ?? 'codigo $code'}). $hint',
    );
    _setState(BroadcastState.stopped, error: hint);

    if (usedDiagnosis) {
      _log('info', 'Diagnostico obtenido al reabrir el dispositivo');
    }

    // No queda audio que enviar: se corta el reloj, se cierra el codificador y
    // se suelta el socket. Si se dejara abierto, el servidor seguiria mostrando
    // el mount ocupado y el proximo intento de salir al aire recibiria un 403.
    _ticker?.cancel();
    _ticker = null;
    await _stopEncoder();
    await _teardownCapture();
    await _teardownBroadcaster();
    await _screenGuard.stop();
  }

  /// El codificador murio mientras la captura sigue viva.
  ///
  /// Se sale del aire porque no hay audio que enviar, pero se conserva la
  /// captura: el DJ sigue viendo el nivel del microfono y puede volver a
  /// intentarlo sin reconectar el dispositivo.
  Future<void> _handleEncoderFailure(int code) async {
    if (_stopping) return;
    final recorded = _encoderErrors.join('\n');
    DiagnosticLog.instance?.write(
      'ffmpeg',
      'el codificador termino con codigo $code. Mensajes: '
          '${recorded.isEmpty ? "(ninguno)" : recorded.replaceAll("\n", " | ")}',
    );
    final hint = recorded.trim().isEmpty
        ? 'El codificador de audio se detuvo (codigo $code).'
        : explainFfmpegError(recorded);

    _log('error', 'La codificacion se detuvo (codigo $code). $hint');
    _ticker?.cancel();
    _ticker = null;
    await _stopEncoder();
    await _teardownBroadcaster();
    _setState(BroadcastState.stopped, error: hint);
    await _screenGuard.stop();
  }

  void _startRecording() {
    if (!_shouldRecord) return;
    // Si ya hay una grabacion abierta (por ejemplo tras reiniciar la captura
    // para cambiar la ganancia) se sigue escribiendo en el mismo archivo: un
    // ajuste de volumen no debe partir la grabacion en trozos.
    if (_recordingSink != null) return;
    final dirPath = recordDirectory ?? profile.recordDirectory;
    try {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) dir.create(recursive: true);
      final now = DateTime.now();
      final name =
          'xtreme_${now.year}${_two(now.month)}${_two(now.day)}_'
          '${_two(now.hour)}${_two(now.minute)}${_two(now.second)}.'
          '${profile.audio.codec.fileExtension}';
      final file = File('${dir.path}${Platform.pathSeparator}$name');
      _recordingSink = file.openWrite();
      _snapshot = _snapshot.copyWith(recordingPath: file.path);
      _log('info', 'Grabando en ${file.path}');
    } catch (e) {
      _log('warn', 'No se pudo iniciar la grabacion local: $e');
    }
  }

  /// Cierra el archivo de grabacion (si habia uno).
  Future<void> _closeRecording() async {
    final sink = _recordingSink;
    _recordingSink = null;
    _snapshot = _snapshot.copyWith(recordingPath: '');
    if (sink == null) return;
    try {
      await sink.flush();
      await sink.close();
    } catch (_) {
      // Un fallo al cerrar no debe impedir salir del aire.
    }
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// Guarda un mensaje de FFmpeg para poder explicar un fallo despues.
  ///
  /// El motivo real ("device already in use", "Unknown encoder") solo aparece
  /// aqui, y es lo unico que permite decirle al DJ que hacer. La captura y el
  /// codificador tienen listas separadas para no confundir sus diagnosticos.
  void _recordFfmpegMessage(
    Uint8List data, {
    required List<String> target,
    required String source,
  }) {
    try {
      // La salida de error de FFmpeg es texto UTF-8. Se decodifica el bloque
      // completo con tolerancia: un acento puede quedar partido entre bloques.
      final text = utf8.decode(data, allowMalformed: true);
      final lines = text
          .split(RegExp(r'\r?\n'))
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      if (lines.isEmpty) return;
      target.addAll(lines);
      // Solo interesan las ultimas lineas: no tiene sentido guardar un log
      // entero durante una emision larga.
      while (target.length > 40) {
        target.removeAt(0);
      }
      for (final line in lines) {
        DiagnosticLog.instance?.write('ffmpeg', '$source: $line');
      }
    } catch (_) {
      // Un mensaje ilegible no debe afectar a la emision.
    }
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_state == BroadcastState.live) {
        _secondsOnAir++;
        // Vigilancia: si el servidor acepto la conexion pero no fluye audio,
        // el DJ tiene que enterarse.
        // Vigilancia de la captura: si deja de entregar PCM (por ejemplo,
        // cuando el sistema bloquea la pantalla y PipeWire rearma los nodos),
        // se reabre sin tocar el codificador ni el socket.
        final now = DateTime.now();
        final pcm = _lastPcmAt ?? _captureStartedAt;
        if (pcm != null && now.difference(pcm) > const Duration(seconds: 4)) {
          unawaited(_recoverCapture('dejo de llegar audio de la entrada'));
        }

        final last = _lastAudioAt;
        if (last != null && now.difference(last) > const Duration(seconds: 5)) {
          _log('warn', 'No llega audio del dispositivo de entrada');
          _lastAudioAt = now;
        }

        // Cada 5 s se comprueba que el socket siga drenando. Un servidor que
        // deja de leer, o una red caida sin FIN/RST, mantiene el socket
        // "abierto" y al DJ en AL AIRE aunque nadie reciba audio. El flush
        // tiene su propio timeout y avisa de la caida (ver Broadcaster.flush).
        _ticksSinceFlush++;
        if (_ticksSinceFlush >= 5) {
          _ticksSinceFlush = 0;
          unawaited(_watchConnectionHealth());
        }
      } else {
        _ticksSinceFlush = 0;
      }
      _emit();
    });
  }

  /// Comprueba que lo enviado llega al sistema operativo.
  ///
  /// Se evita solapar comprobaciones: si un flush tarda mas de lo normal, el
  /// ticker no debe encadenar otro cada segundo.
  Future<void> _watchConnectionHealth() async {
    if (_flushInFlight) return;
    _flushInFlight = true;
    try {
      await _broadcaster?.flush();
    } catch (e) {
      _log('warn', 'No se pudo comprobar la conexion: $e');
    } finally {
      _flushInFlight = false;
    }
  }

  /// Actualiza la cancion que suena. No bloquea la emision si el servidor
  /// rechaza el cambio.
  Future<bool> setTrack(String track) async {
    _snapshot = _snapshot.copyWith(currentTrack: track);
    _emit();
    final b = _broadcaster;
    if (b == null) return false;
    final ok = await b.setMetadata(track);
    if (!ok) {
      _log(
        'warn',
        'El servidor no acepto el cambio de titulo. Revisa que el hosting '
            'permita /admin/metadata con estas credenciales.',
      );
    } else {
      _log('info', 'Suena ahora: $track');
    }
    return ok;
  }

  /// Cambia la ganancia en caliente.
  ///
  /// No reinicia nada: solo cambia el factor que [GainStage] aplica al siguiente
  /// bloque de PCM. El microfono, el codificador y el socket siguen intactos,
  /// asi que la emision no se corta y el vumetro refleja el cambio de inmediato.
  Future<void> setGain(double db) async {
    gainDb = db;
    _gainStage.gainDb = db;
    // El pico retenido mostraria durante dos segundos el nivel anterior y
    // pareceria que el control no responde.
    _meter.clearHold();
    _emit();
    if (_state == BroadcastState.live) {
      _log(
        'info',
        'Ganancia ajustada a ${db >= 0 ? '+' : ''}'
            '${db.toStringAsFixed(1)} dB (sin cortar la emision)',
      );
    }
  }

  /// Suelta el socket y el aviso de caida, sin tocar la captura ni el encoder.
  Future<void> _teardownBroadcaster({bool releaseMount = false}) async {
    await _lostSub?.cancel();
    _lostSub = null;
    final broadcaster = _broadcaster;
    _broadcaster = null;
    if (broadcaster == null) return;
    if (releaseMount) {
      try {
        await broadcaster.releaseMount().timeout(const Duration(seconds: 6));
      } catch (_) {
        // El servidor soltara la fuente por timeout igual.
      }
    }
    try {
      await broadcaster.dispose().timeout(const Duration(seconds: 4));
    } catch (_) {
      // El socket ya podia estar muerto.
    }
  }

  /// Detiene el codificador y cierra la grabacion local.
  ///
  /// La captura no se toca: sigue alimentando el vumetro fuera del aire.
  Future<void> _stopEncoder() async {
    await _audioSub?.cancel();
    await _encoderErrSub?.cancel();
    await _encoderExitSub?.cancel();
    _audioSub = null;
    _encoderErrSub = null;
    _encoderExitSub = null;

    final encoder = _encoder;
    _encoder = null;
    if (encoder != null) {
      await encoder.stop();
      DiagnosticLog.instance?.write(
        'ffmpeg',
        'codificador detenido'
            '${encoder.lastStopDetail == null ? "" : ": ${encoder.lastStopDetail}"}',
      );
    }
    await _closeRecording();
  }

  /// Detiene la captura de entrada.
  Future<void> _teardownCapture() async {
    await _pcmSub?.cancel();
    await _captureErrSub?.cancel();
    await _exitSub?.cancel();
    _pcmSub = null;
    _captureErrSub = null;
    _exitSub = null;

    final capture = _capture;
    _capture = null;
    if (capture != null) {
      await capture.stop();
      // Se conserva el codigo de salida para poder comprobar que el proceso
      // realmente termino y no quedo un FFmpeg huerfano ocupando el microfono.
      _lastCaptureExitCode ??= capture.exitCodeIfFinished;
      DiagnosticLog.instance?.write(
        'ffmpeg',
        'captura detenida'
            '${capture.lastStopDetail == null ? "" : ": ${capture.lastStopDetail}"}',
      );
    }
    _gainStage.reset();
  }

  /// Cierra el codificador y el socket, conservando la captura.
  Future<void> _stopEncoderAndBroadcaster({bool releaseMount = false}) async {
    await _stopEncoder();
    await _teardownBroadcaster(releaseMount: releaseMount);
  }

  /// Se perdio el socket: reintenta con espera creciente, sin tocar el audio.
  void _scheduleReconnect() {
    if (_stopping) return;

    // El DJ puede desactivar la reconexion desde el perfil: hay emisoras donde
    // un reinicio automatico es peor que quedarse fuera (por ejemplo si el
    // servidor cobra por sesion, o si hay que avisar antes de volver). En ese
    // caso se sale del aire de forma limpia y se explica por que.
    if (!profile.autoReconnect) {
      _log(
        'warn',
        'Se perdio la conexion y la reconexion automatica esta desactivada '
            'para esta emisora. Volve a salir al aire cuando quieras.',
      );
      _setState(
        BroadcastState.stopped,
        error:
            'Conexion perdida. La reconexion automatica esta desactivada '
            'en esta emisora.',
      );
      // Se cierra el codificador y el socket, pero no la captura: el DJ sigue
      // viendo el nivel del microfono y puede volver a intentarlo.
      unawaited(_stopEncoderAndBroadcaster());
      return;
    }

    _reconnectAttempt++;
    _setState(BroadcastState.reconnecting);

    // 1s, 2s, 4s, 8s, 15s, 15s... suficiente para un cambio de red sin
    // castigar al servidor.
    final wait = switch (_reconnectAttempt) {
      1 => 1,
      2 => 2,
      3 => 4,
      4 => 8,
      _ => 15,
    };
    _log('warn', 'Conexion perdida. Reintento $_reconnectAttempt en ${wait}s');

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: wait), () async {
      if (_stopping) return;
      final broadcaster = Broadcaster(profile);
      try {
        await broadcaster.connect();
        if (_stopping) {
          await broadcaster.dispose();
          return;
        }
        await _lostSub?.cancel();
        _lostSub = broadcaster.onConnectionLost.listen((_) {
          notifyConnectionLost(
            'el servidor dejo de responder o cerro la conexion',
          );
        });
        final previous = _broadcaster;
        _broadcaster = broadcaster;
        // Cerrar el socket viejo no puede bloquear la reconexion: si el sistema
        // deja el cierre colgado, el motor quedaria en RECONECTANDO para
        // siempre aunque el audio ya este saliendo por la conexion nueva.
        try {
          await previous?.dispose().timeout(const Duration(seconds: 2));
        } catch (_) {}
        _reconnectAttempt = 0;
        _setState(BroadcastState.live);
        _log('ok', 'Reconectado: seguimos al aire');
        // El servidor arranca una sesion nueva: hay que reinstalar los
        // metadatos o el "suena ahora" quedaria en blanco para los oyentes.
        final track = _snapshot.currentTrack;
        if (track.isNotEmpty) {
          await broadcaster.setMetadata(track);
        }
      } catch (e) {
        await broadcaster.close();
        _scheduleReconnect();
      }
    });
  }

  /// Notifica una caida detectada desde afuera (por ejemplo, error de socket
  /// al escribir). Idempotente: si ya se esta reconectando, no hace nada.
  void notifyConnectionLost(String reason) {
    if (_stopping) return;
    if (_state == BroadcastState.reconnecting) return;
    if (_state != BroadcastState.live) return;
    _log('warn', 'Se perdio la conexion: $reason');
    _scheduleReconnect();
  }

  /// Sale del aire y libera el socket, sin apagar el vumetro.
  ///
  /// [releaseMount] pide al servidor que suelte la fuente: asi el proximo DJ
  /// puede entrar de inmediato en lugar de esperar el timeout.
  ///
  /// El boton debe responder **de inmediato**: por eso el estado cambia a
  /// "fuera del aire" antes de la limpieza, y el cierre de red y del encoder se
  /// hace despues, con limites de tiempo. Si algo se cuelga, no puede dejar al
  /// DJ atrapado con una emision que sigue sonando y un boton que no responde.
  Future<void> goOffAir({bool releaseMount = true}) async {
    soundboard?.stopAll();
    if (_state == BroadcastState.idle && _encoder == null) return;
    _stopping = true;

    _ticker?.cancel();
    _ticker = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    // Primero lo que ve el usuario. El vumetro NO se reinicia: la captura sigue
    // midiendo el microfono igual que antes de entrar al aire.
    _setState(BroadcastState.idle);
    _log('info', 'Saliendo del aire...');
    await _screenGuard.stop();

    try {
      await _stopEncoderAndBroadcaster(
        releaseMount: releaseMount,
      ).timeout(const Duration(seconds: 12));
    } catch (e) {
      // Aunque la limpieza falle o tarde, el DJ ya esta fuera del aire en la
      // interfaz y puede volver a intentarlo.
      _log('warn', 'La limpieza tardo o fallo: $e');
      DiagnosticLog.instance?.write('motor', 'fallo al salir del aire: $e');
    }

    _secondsOnAir = 0;
    _bytesSent = 0;
    _emit();
    _stopping = false;
    _log('info', 'Fuera del aire');
  }

  /// Cierra todo: encoder, socket y captura.
  Future<void> dispose() async {
    soundboard?.stopAll();
    _stopping = true;
    _ticker?.cancel();
    _ticker = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _stopEncoderAndBroadcaster(releaseMount: true);
    await _teardownCapture();
    await _screenGuard.stop();
    await _snapshotController.close();
    await _logController.close();
  }
}
