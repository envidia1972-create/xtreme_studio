/// Monitor de entrada permanente (vumetro fuera del aire).
///
/// El motor de emision solo captura cuando se sale al aire. Para que el DJ vea
/// el nivel del microfono en todo momento se usa este proceso liviano: FFmpeg
/// captura el dispositivo y emite **solo PCM** de niveles por stderr, sin
/// codificar MP3/AAC. Cuando se sale al aire, el motor detiene este monitor y
/// arranca su propia captura.
///
/// Tambien es el que hace visible el efecto de la ganancia cuando no se esta
/// transmitiendo.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../server_profile.dart';
import 'ffmpeg_capture.dart';

/// Lectura de niveles para la interfaz.
class InputLevels {
  const InputLevels({
    required this.peakDb,
    required this.peakHoldDb,
    required this.rmsDb,
  });

  final double peakDb;
  final double peakHoldDb;
  final double rmsDb;
}

/// Captura continua solo para medir niveles.
class InputMonitor {
  InputMonitor({
    required this.ffmpegPath,
    required this.deviceName,
    required this.backend,
    this.gainDb = 0.0,
  });

  String ffmpegPath;
  String deviceName;
  CaptureBackend backend;
  double gainDb;

  CaptureProcess? _capture;
  StreamSubscription<Uint8List>? _meterSub;
  StreamSubscription<int>? _exitSub;
  final LevelMeter _meter = LevelMeter();
  final _levels = StreamController<InputLevels>.broadcast();
  final _errors = StreamController<String>.broadcast();
  final List<String> _ffmpegErrors = [];

  bool _running = false;
  DateTime _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastError;

  Stream<InputLevels> get levels => _levels.stream;
  Stream<String> get errors => _errors.stream;
  String? get lastError => _lastError;
  bool get isRunning => _running;
  double get peakDb => _meter.peakDb;
  double get peakHoldDb => _meter.peakHoldDb;
  double get rmsDb => _meter.rmsDb;

  /// Arranca la captura de niveles. Si ya habia una, la reemplaza.
  Future<bool> start() async {
    await stop();
    if (!File(ffmpegPath).existsSync()) {
      _fail('No se encontro FFmpeg para monitorear la entrada.');
      return false;
    }

    try {
      final capture = await CaptureProcess.start(
        ffmpegPath: ffmpegPath,
        args: CaptureArgs(
          deviceName: deviceName,
          // Valores irrelevantes en modo meterOnly; se pasan completos porque
          // CaptureArgs los exige.
          bitrateKbps: 128,
          sampleRate: 44100,
          channels: 2,
          gainDb: gainDb,
          metering: true,
          meterOnly: true,
          codec: AudioCodec.mp3,
          backend: backend,
        ),
      );
      _capture = capture;
      _running = true;
      _lastError = null;
      _ffmpegErrors.clear();
      _meter.reset();

      _meterSub = capture.meter.listen(
        (data) {
          if (looksLikeText(data)) {
            final lines = collectFfmpegLines(data);
            _ffmpegErrors.addAll(lines);
            while (_ffmpegErrors.length > 20) {
              _ffmpegErrors.removeAt(0);
            }
            return;
          }
          _meter.feed(data);
          final now = DateTime.now();
          if (now.difference(_lastEmit) < const Duration(milliseconds: 80)) {
            return;
          }
          _lastEmit = now;
          if (_levels.isClosed) return;
          _levels.add(
            InputLevels(
              peakDb: _meter.peakDb,
              peakHoldDb: _meter.peakHoldDb,
              rmsDb: _meter.rmsDb,
            ),
          );
        },
        onError: (Object e) {
          _ffmpegErrors.add('Error leyendo niveles: $e');
        },
      );

      _exitSub = capture.exitCode.asStream().listen((code) {
        if (!_running) return;
        _running = false;
        final detail = _ffmpegErrors.isEmpty
            ? ''
            : explainFfmpegError(_ffmpegErrors.join('\n'), backend: backend);
        _fail(
          detail.isEmpty
              ? 'El monitor de entrada se detuvo (codigo $code).'
              : 'El monitor de entrada se detuvo: $detail',
        );
      });

      return true;
    } on ProcessException catch (e) {
      _fail('No se pudo iniciar el monitor de entrada: ${e.message}');
      return false;
    }
  }

  /// Reinicia con otra ganancia y/o dispositivo, conservando la misma instancia.
  Future<bool> restart({double? gainDb, String? deviceName}) async {
    if (gainDb != null) this.gainDb = gainDb;
    if (deviceName != null) this.deviceName = deviceName;
    return start();
  }

  Future<void> stop() async {
    _running = false;
    await _meterSub?.cancel();
    _meterSub = null;
    await _exitSub?.cancel();
    _exitSub = null;
    final capture = _capture;
    _capture = null;
    await capture?.stop();
    _meter.reset();
  }

  void _fail(String message) {
    _lastError = message;
    if (!_errors.isClosed) _errors.add(message);
  }

  Future<void> dispose() async {
    await stop();
    await _levels.close();
    await _errors.close();
  }
}
