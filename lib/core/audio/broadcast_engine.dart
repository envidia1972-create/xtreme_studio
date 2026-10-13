/// Motor de emision: une captura, codificacion, envio y reconexion.
///
/// Decision de diseno clave: **la captura de audio nunca se reinicia**. FFmpeg
/// arranca una sola vez y sigue produciendo MP3; si la red se cae, solo se
/// rehace el socket contra el servidor. Eso significa que un microcorte de
/// internet no obliga al DJ a volver a elegir el microfono, ni corta la
/// grabacion local, ni deja la senal muda mas de lo necesario.
///
/// El flujo es:
///
///   ffmpeg (dshow -> MP3) --stdout--> Dart --> [socket] --> Icecast/Shoutcast
///                                    \--> grabacion local (.mp3)
///   ffmpeg (PCM 8k) --stderr--> vumetros en pantalla
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../net/broadcaster.dart';
import '../net/icecast_client.dart';
import '../server_profile.dart';
import '../diagnostic_log.dart';
import 'ffmpeg_capture.dart';

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
    required this.bytesSent,
    required this.reconnectAttempt,
    this.currentTrack = '',
    this.lastError,
    this.recordingPath,
  });

  final BroadcastState state;
  final double peakDb;
  final double rmsDb;
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
    Map<String, String>? environment,
  }) : environment = environment ?? const {};

  ServerProfile profile;
  String ffmpegPath;
  double gainDb;
  String deviceName;

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

  /// `true` mientras el proceso de captura/codificacion este vivo.
  ///
  /// Tras salir del aire debe ser `false`: si quedara un FFmpeg huerfano, el
  /// microfono seguiria ocupado y el proximo intento de emitir fallaria.
  bool get isCapturing => _capture?.isRunning ?? false;

  /// Codigo de salida de FFmpeg, cuando ya termino.
  int? get captureExitCode =>
      _capture?.exitCodeIfFinished ?? _lastCaptureExitCode;

  final LevelMeter _meter = LevelMeter();

  BroadcastState _state = BroadcastState.idle;
  String? _lastError;

  CaptureProcess? _capture;
  Broadcaster? _broadcaster;
  StreamSubscription<Uint8List>? _audioSub;
  StreamSubscription<Uint8List>? _meterSub;
  StreamSubscription<int>? _exitSub;
  StreamSubscription<void>? _lostSub;
  Timer? _ticker;
  Timer? _reconnectTimer;
  IOSink? _recordingSink;

  bool _stopping = false;
  int _reconnectAttempt = 0;
  int _secondsOnAir = 0;
  int _bytesSent = 0;
  int? _lastCaptureExitCode;
  final List<String> _ffmpegErrors = [];

  /// Bitrate de pico reciente, para mostrar "no llega audio" con fundamento.
  DateTime? _lastAudioAt;

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
    _setState(BroadcastState.starting);

    DiagnosticLog.instance?.write(
      'motor',
      'salir al aire: emisora="${profile.name}" '
          'destino=${profile.host}:${profile.effectivePort} '
          'dispositivo="${deviceName.isEmpty ? "(por defecto)" : deviceName}" '
          'ffmpeg="$ffmpegPath"',
    );

    if (ffmpegPath.isEmpty || !File(ffmpegPath).existsSync()) {
      _setState(
        BroadcastState.stopped,
        error: 'No se encontro FFmpeg. Indica la ruta del ejecutable en Ajustes.',
      );
      _log('error', 'FFmpeg no encontrado en "$ffmpegPath"');
      return false;
    }

    final ok = await _connectAndStart(force: force);
    if (!ok) return false;

    _startTicker();
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
    } on IcecastException catch (e) {
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
          _log('ok', 'Mount liberado: se entra al aire por la fuerza');
        } on IcecastException catch (retryError) {
          _broadcaster = null;
          _setState(
            BroadcastState.stopped,
            error: 'El mount sigue ocupado despues de intentar liberarlo. '
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
      notifyConnectionLost('el servidor cerro la conexion');
    });

    // 2. Arrancar la captura una sola vez.
    if (_capture == null) {
      final started = await _startCapture();
      if (!started) {
        await broadcaster.close();
        _broadcaster = null;
        return false;
      }
    }

    _setState(BroadcastState.live);
    _log('ok', 'AL AIRE');
    return true;
  }

  Future<bool> _startCapture() async {
    final args = CaptureArgs(
      deviceName: deviceName,
      bitrateKbps: profile.audio.bitrateKbps,
      sampleRate: profile.audio.sampleRate,
      channels: profile.audio.channels,
      gainDb: gainDb,
      metering: true,
    );

    try {
      final capture = await CaptureProcess.start(
        ffmpegPath: ffmpegPath,
        args: args,
        environment: environment,
      );
      _capture = capture;

      // La linea de comandos completa permite reproducir el fallo a mano: es el
      // dato que mas veces hace falta y el mas dificil de adivinar.
      DiagnosticLog.instance?.write('ffmpeg', 'proceso iniciado, pid=${capture.pid}');
      DiagnosticLog.instance?.write('ffmpeg', 'comando: ${args.preview()}');
    } on ProcessException catch (e) {
      DiagnosticLog.instance?.write(
        'ffmpeg',
        'no se pudo iniciar el proceso: ${e.message} (ruta: $ffmpegPath)',
      );
      _setState(
        BroadcastState.stopped,
        error: 'No se pudo iniciar FFmpeg: ${e.message}',
      );
      _log('error', 'No se pudo iniciar FFmpeg: ${e.message}');
      return false;
    }

    // Audio -> servidor (+ grabacion local si esta activa).
    _audioSub = _capture!.audio.listen(
      (chunk) {
        _lastAudioAt = DateTime.now();
        _broadcaster?.send(chunk);
        _bytesSent += chunk.length;
        _recordingSink?.add(chunk);
      },
      onError: (Object e) => _log('warn', 'Error leyendo audio: $e'),
    );

    // PCM -> vumetros, y texto -> diagnostico.
    //
    // FFmpeg escribe las dos cosas por la misma salida de error, asi que hay
    // que separarlas: los mensajes de texto no son muestras de audio (harian
    // saltar el vumetro) y son justamente lo que explica un fallo real.
    _meterSub = _capture!.meter.listen(
      (data) {
        if (looksLikeText(data)) {
          _recordFfmpegMessage(data);
          return;
        }
        _meter.feed(data);
        _emit();
      },
      onError: (_) {},
    );

    // Si FFmpeg muere (microfono desconectado, driver que falla) hay que
    // decirlo, no dejar la pantalla diciendo "AL AIRE" en falso.
    _exitSub = _capture!.exitCode.asStream().listen((code) async {
      if (_stopping || code == 0) return;
      await _handleCaptureFailure(code);
    });

    _startRecording();
    return true;
  }

  /// Explica por que se detuvo la captura y deja el motor en un estado claro.
  ///
  /// Primero se usan los mensajes que FFmpeg alcanzo a escribir. Si no dicen
  /// nada util, se lanza un diagnostico de un solo disparo sobre el mismo
  /// dispositivo para obtener el motivo real, porque "termino sin explicar el
  /// motivo" no le sirve de nada al DJ.
  Future<void> _handleCaptureFailure(int code) async {
    final recorded = _ffmpegErrors.join('\n');
    DiagnosticLog.instance?.write(
      'ffmpeg',
      'la captura termino con codigo $code. Mensajes: '
          '${recorded.isEmpty ? "(ninguno)" : recorded.replaceAll("\n", " | ")}',
    );
    var hint = explainFfmpegError(recorded);
    var usedDiagnosis = false;

    final looksUseful = recorded.trim().isNotEmpty &&
        !hint.contains('sin explicar el motivo');

    if (!looksUseful) {
      _log('info', 'Averiguando por que se detuvo la captura...');
      final lines = await diagnoseCaptureFailure(
        ffmpegPath: ffmpegPath,
        args: CaptureArgs(
          deviceName: deviceName,
          bitrateKbps: profile.audio.bitrateKbps,
          sampleRate: profile.audio.sampleRate,
          channels: profile.audio.channels,
          gainDb: gainDb,
          metering: false,
        ),
        environment: environment,
      );
      if (lines.isNotEmpty) {
        final diagnosis = explainFfmpegError(lines.join('\n'));
        if (!diagnosis.contains('sin explicar el motivo')) {
          hint = diagnosis;
          usedDiagnosis = true;
        }
      }
    }

    // Si ya no se esta emitiendo, no se pisa un estado mas avanzado.
    if (_stopping) return;

    _log('error', 'La captura de audio se detuvo (codigo $code). $hint');
    _setState(BroadcastState.stopped, error: hint);

    if (usedDiagnosis) {
      _log('info', 'Diagnostico obtenido al reabrir el dispositivo');
    }

    await _teardownCapture();
  }

  void _startRecording() {
    if (!profile.recordLocally || profile.recordDirectory.isEmpty) return;
    try {
      final dir = Directory(profile.recordDirectory);
      if (!dir.existsSync()) dir.create(recursive: true);
      final now = DateTime.now();
      final name =
          'xtreme_${now.year}${_two(now.month)}${_two(now.day)}_'
          '${_two(now.hour)}${_two(now.minute)}${_two(now.second)}.mp3';
      final file = File('${dir.path}${Platform.pathSeparator}$name');
      _recordingSink = file.openWrite();
      _snapshot = _snapshot.copyWith(recordingPath: file.path);
      _log('info', 'Grabando en ${file.path}');
    } catch (e) {
      _log('warn', 'No se pudo iniciar la grabacion local: $e');
    }
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// Guarda un mensaje de FFmpeg para poder explicar un fallo despues.
  ///
  /// El motivo real ("device already in use", "Unknown encoder") solo aparece
  /// aqui, y es lo unico que permite decirle al DJ que hacer.
  void _recordFfmpegMessage(Uint8List data) {
    try {
      final lines = collectFfmpegLines(data);
      if (lines.isEmpty) return;
      _ffmpegErrors.addAll(lines);
      // Solo interesan las ultimas lineas: no tiene sentido guardar un log
      // entero durante una emision larga.
      while (_ffmpegErrors.length > 40) {
        _ffmpegErrors.removeAt(0);
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
        final last = _lastAudioAt;
        if (last != null &&
            DateTime.now().difference(last) > const Duration(seconds: 5)) {
          _log('warn', 'No llega audio del dispositivo de entrada');
          _lastAudioAt = DateTime.now();
        }
      }
      _emit();
    });
  }

  /// Actualiza la cancion que suena. No bloquea la emision si el servidor
  /// rechaza el cambio.
  Future<void> setTrack(String track) async {
    _snapshot = _snapshot.copyWith(currentTrack: track);
    _emit();
    final b = _broadcaster;
    if (b == null) return;
    final ok = await b.setMetadata(track);
    if (!ok) {
      _log('warn', 'El servidor no acepto el cambio de titulo');
    } else {
      _log('info', "Suena ahora: $track");
    }
  }

  /// Cambia la ganancia en caliente. Se aplica reiniciando solo la cadena de
  /// captura, que es irreversible en FFmpeg sin reiniciar el proceso.
  Future<void> setGain(double db) async {
    gainDb = db;
    if (_state == BroadcastState.live) {
      _log('info', 'Ajustando ganancia a ${db.toStringAsFixed(1)} dB');
      await _restartCapture();
    } else {
      _emit();
    }
  }

  Future<void> _restartCapture() async {
    await _teardownCapture();
    if (_broadcaster == null) return;
    await _startCapture();
  }

  /// Cierra la captura y el socket tras una caida sin reconexion.
  ///
  /// Se hace aparte porque `_teardownCapture` no toca el socket y aqui tambien
  /// hay que soltarlo: si no, quedaria una conexion medio muerta contra el
  /// servidor.
  Future<void> _teardownCaptureFromReconnectFailure() async {
    await _teardownCapture();
    await _lostSub?.cancel();
    _lostSub = null;
    await _broadcaster?.close();
    _broadcaster = null;
  }

  Future<void> _teardownCapture() async {
    await _audioSub?.cancel();
    await _meterSub?.cancel();
    await _exitSub?.cancel();
    _audioSub = null;
    _meterSub = null;
    _exitSub = null;
    final capture = _capture;
    await capture?.stop();
    // Se conserva el codigo de salida para poder comprobar que el proceso
    // realmente termino y no quedo un FFmpeg huerfano ocupando el microfono.
    if (capture != null) {
      _lastCaptureExitCode ??= capture.exitCodeIfFinished;
    }
    _capture = null;
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
        error: 'Conexion perdida. La reconexion automatica esta desactivada '
            'en esta emisora.',
      );
      // Se corta la captura: seguir codificando sin destino solo ocupa el
      // microfono y gasta CPU.
      unawaited(_teardownCaptureFromReconnectFailure());
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
        await _lostSub?.cancel();
        _lostSub = broadcaster.onConnectionLost.listen((_) {
          notifyConnectionLost('el servidor cerro la conexion');
        });
        await _broadcaster?.close();
        _broadcaster = broadcaster;
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

  /// Sale del aire y libera todo.
  ///
  /// [releaseMount] pide al servidor que suelte la fuente: asi el proximo DJ
  /// puede entrar de inmediato en lugar de esperar el timeout.
  ///
  /// El boton debe responder **de inmediato**: por eso el estado cambia a
  /// "fuera del aire" antes de la limpieza, y el cierre de red y de captura se
  /// hace despues, con limites de tiempo. Si algo se cuelga, no puede dejar al
  /// DJ atrapado con una emision que sigue sonando y un boton que no responde.
  Future<void> goOffAir({bool releaseMount = true}) async {
    if (_stopping) return;
    _stopping = true;

    _ticker?.cancel();
    _ticker = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    // Primero lo que ve el usuario.
    _meter.reset();
    _setState(BroadcastState.idle);
    _log('info', 'Saliendo del aire...');

    try {
      await _shutdown(releaseMount: releaseMount)
          .timeout(const Duration(seconds: 12));
    } catch (e) {
      // Aunque la limpieza falle o tarde, el DJ ya esta fuera del aire en la
      // interfaz y puede volver a intentarlo.
      _log('warn', 'La limpieza tardo o fallo: $e');
      DiagnosticLog.instance?.write('motor', 'fallo al salir del aire: $e');
    }

    _log('info', 'Fuera del aire');
  }

  /// Cierre ordenado de red, captura y grabacion.
  Future<void> _shutdown({required bool releaseMount}) async {
    if (releaseMount) {
      // Se limita el tiempo: si el servidor no responde, no se puede quedar
      // esperando para siempre.
      try {
        await _broadcaster
            ?.releaseMount()
            .timeout(const Duration(seconds: 6));
      } catch (_) {
        // El servidor soltara la fuente por timeout igual.
      }
    }

    await _lostSub?.cancel();
    _lostSub = null;

    try {
      await _broadcaster?.close().timeout(const Duration(seconds: 4));
    } catch (_) {}
    _broadcaster = null;

    await _teardownCapture();

    try {
      await _recordingSink?.flush();
      await _recordingSink?.close();
    } catch (_) {}
    _recordingSink = null;
  }

  Future<void> dispose() async {
    await goOffAir();
    await _snapshotController.close();
    await _logController.close();
  }
}
