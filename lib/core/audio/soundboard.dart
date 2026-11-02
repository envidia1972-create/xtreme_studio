/// Soundboard: jingles, mezcla en vivo y cue local.
///
/// El motor entrega el PCM del micrófono en `f32le` ya con la ganancia
/// aplicada. Este archivo agrega una etapa de mezcla **en Dart**, antes del
/// vúmetro y del codificador: todo lo que se mide, se envía y se graba es la
/// mezcla final.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'ffmpeg_capture.dart' show CaptureBackend;

/// Configuración de un pad del soundboard.
class SoundboardPad {
  SoundboardPad({
    required this.id,
    this.name = '',
    this.fileName = '',
    this.keyLabel = '',
    this.volume = 1.0,
    this.loop = false,
    this.ducking = true,
  });

  final String id;
  String name;

  /// Nombre del archivo dentro de la carpeta del soundboard.
  String fileName;
  String keyLabel;

  /// Volumen lineal del jingle (0..1).
  double volume;
  bool loop;

  /// Si suena este pad, bajar el micrófono para que la voz no quede tapada.
  bool ducking;

  bool get assigned => fileName.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'file': fileName,
    'key': keyLabel,
    'volume': volume,
    'loop': loop,
    'ducking': ducking,
  };

  factory SoundboardPad.fromJson(Map<String, dynamic> json) => SoundboardPad(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    fileName: json['file'] as String? ?? '',
    keyLabel: json['key'] as String? ?? '',
    volume: ((json['volume'] as num?)?.toDouble() ?? 1.0).clamp(0.0, 1.0),
    loop: json['loop'] as bool? ?? false,
    ducking: json['ducking'] as bool? ?? true,
  );

  SoundboardPad copyWith({
    String? name,
    String? fileName,
    String? keyLabel,
    double? volume,
    bool? loop,
    bool? ducking,
  }) => SoundboardPad(
    id: id,
    name: name ?? this.name,
    fileName: fileName ?? this.fileName,
    keyLabel: keyLabel ?? this.keyLabel,
    volume: volume ?? this.volume,
    loop: loop ?? this.loop,
    ducking: ducking ?? this.ducking,
  );
}

/// Audio decodificado a PCM float32 intercalado, a la frecuencia/canales del
/// stream.
class JingleClip {
  JingleClip({
    required this.samples,
    required this.sampleRate,
    required this.channels,
  });

  final Float32List samples;
  final int sampleRate;
  final int channels;

  int get frames => channels == 0 ? 0 : samples.length ~/ channels;

  Duration get duration => Duration(
    microseconds: sampleRate == 0
        ? 0
        : (frames * Duration.microsecondsPerSecond) ~/ sampleRate,
  );
}

class _Voice {
  _Voice({
    required this.padId,
    required this.clip,
    required this.volume,
    required this.loop,
    required this.ducking,
  });

  final String padId;
  final JingleClip clip;
  final double volume;
  final bool loop;
  final bool ducking;

  int position = 0; // frames
  bool stopping = false;
  int fadeRemaining = 0;
  bool removed = false;
}

/// Mezclador de micrófono + jingles.
class SoundboardMixer {
  SoundboardMixer({this.sampleRate = 44100, this.channels = 2});

  int sampleRate;
  int channels;

  /// Volumen general de los jingles (no afecta al micrófono).
  double masterVolume = 0.8;

  /// Cuánto baja el micrófono cuando hay un jingle con ducking.
  double duckingDb = -12.0;

  final List<_Voice> _voices = [];
  Uint8List _carry = Uint8List(0);
  double _duck = 1.0;
  final _changes = StreamController<void>.broadcast();

  Stream<void> get changes => _changes.stream;

  bool get isActive => _voices.isNotEmpty;
  bool get isDucking => _duck < 0.999;

  Set<String> get activePads => _voices.map((v) => v.padId).toSet();

  void configure(int newSampleRate, int newChannels) {
    if (sampleRate == newSampleRate && channels == newChannels) return;
    stopAll();
    sampleRate = newSampleRate;
    channels = newChannels;
    _carry = Uint8List(0);
    _duck = 1.0;
  }

  void trigger(SoundboardPad pad, JingleClip clip, {double? volume}) {
    if (clip.frames == 0) return;
    // Un mismo pad no se superpone consigo mismo: se reinicia.
    _voices.removeWhere((v) => v.padId == pad.id);
    _voices.add(
      _Voice(
        padId: pad.id,
        clip: clip,
        volume: (volume ?? pad.volume).clamp(0.0, 1.0),
        loop: pad.loop,
        ducking: pad.ducking,
      ),
    );
    _emit();
  }

  void stopPad(String padId, {bool fade = true}) {
    for (final voice in _voices) {
      if (voice.padId != padId) continue;
      if (!fade) {
        voice.removed = true;
      } else {
        voice.stopping = true;
        voice.fadeRemaining = _fadeOutFrames;
      }
    }
    _voices.removeWhere((v) => v.removed);
    _emit();
  }

  void stopAll() {
    _voices.clear();
    _carry = Uint8List(0);
    _duck = 1.0;
    _emit();
  }

  double progressFor(String padId) {
    final voice = _voices.where((v) => v.padId == padId).firstOrNull;
    if (voice == null || voice.clip.frames == 0) return 0;
    return (voice.position / voice.clip.frames).clamp(0.0, 1.0);
  }

  int get _fadeOutFrames => math.max(1, (sampleRate * 0.05).round());
  int get _fadeInFrames => math.max(1, (sampleRate * 0.008).round());

  /// Mezcla los jingles activos con el bloque de micrófono.
  ///
  /// [micPcm] llega en `f32le` intercalado. Si no hay jingles ni ducking
  /// pendiente, devuelve el mismo bloque sin copiarlo.
  Uint8List mix(Uint8List micPcm) {
    if (_voices.isEmpty && !isDucking) {
      _carry = Uint8List(0);
      return micPcm;
    }
    if (micPcm.isEmpty) return micPcm;

    final data = _combineCarry(micPcm);
    final totalSamples = data.length ~/ 4;
    if (totalSamples == 0) {
      _carry = data;
      return Uint8List(0);
    }
    final frameCount = totalSamples ~/ channels;
    final usableSamples = frameCount * channels;
    final usableBytes = usableSamples * 4;
    if (frameCount == 0) {
      _carry = data;
      return Uint8List(0);
    }

    final input = data.buffer.asFloat32List(data.offsetInBytes, usableSamples);

    final hasDuckingVoice = _voices.any((v) => v.ducking && !v.removed);
    final duckTarget = hasDuckingVoice
        ? math.pow(10, duckingDb / 20).toDouble()
        : 1.0;
    _duck += (duckTarget - _duck) * 0.25;
    if ((_duck - 1.0).abs() < 0.001) _duck = 1.0;

    final output = Float32List(usableSamples);
    for (var i = 0; i < usableSamples; i++) {
      output[i] = _clampSample(input[i] * _duck);
    }

    final toRemove = <_Voice>[];
    for (final voice in _voices) {
      if (voice.removed) {
        toRemove.add(voice);
        continue;
      }
      _mixVoice(voice, output, frameCount);
      if (voice.removed) toRemove.add(voice);
    }
    for (final voice in toRemove) {
      _voices.remove(voice);
    }
    if (toRemove.isNotEmpty) _emit();

    _carry = usableBytes == data.length
        ? Uint8List(0)
        : Uint8List.fromList(data.sublist(usableBytes));

    return output.buffer.asUint8List(0, output.lengthInBytes);
  }

  void _mixVoice(_Voice voice, Float32List output, int frameCount) {
    final clip = voice.clip;
    final available = clip.frames - voice.position;
    if (available <= 0) {
      if (voice.loop) {
        voice.position = 0;
      } else {
        voice.removed = true;
        return;
      }
    }

    final frames = math.min(frameCount, clip.frames - voice.position);
    final baseGain = voice.volume * masterVolume;

    for (var f = 0; f < frames; f++) {
      final position = voice.position + f;
      final remaining = clip.frames - position;
      final fadeIn = position < _fadeInFrames ? position / _fadeInFrames : 1.0;
      var gain = baseGain * fadeIn;
      if (voice.stopping) {
        final total = _fadeOutFrames;
        gain *= voice.fadeRemaining / total;
        voice.fadeRemaining--;
        if (voice.fadeRemaining <= 0) {
          voice.removed = true;
          break;
        }
      } else if (!voice.loop && remaining < _fadeOutFrames) {
        gain *= remaining / _fadeOutFrames;
      }
      final outBase = f * channels;
      final clipBase = (voice.position + f) * channels;
      for (var c = 0; c < channels; c++) {
        output[outBase + c] = _clampSample(
          output[outBase + c] + clip.samples[clipBase + c] * gain,
        );
      }
    }

    voice.position += frames;
    if (voice.position >= clip.frames) {
      if (voice.loop && !voice.stopping) {
        voice.position = 0;
      } else {
        voice.removed = true;
      }
    }
  }

  Uint8List _combineCarry(Uint8List chunk) {
    if (_carry.isEmpty) return chunk;
    final data = Uint8List(_carry.length + chunk.length)
      ..setAll(0, _carry)
      ..setAll(_carry.length, chunk);
    _carry = Uint8List(0);
    return data;
  }

  static double _clampSample(double sample) {
    if (!sample.isFinite) return 0;
    if (sample > 1.0) return 1.0;
    if (sample < -1.0) return -1.0;
    return sample;
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> dispose() async {
    _voices.clear();
    await _changes.close();
  }
}

/// Decodifica un jingle a PCM float32 con el FFmpeg de la app.
class JingleDecoder {
  JingleDecoder(this.ffmpegPath);

  final String ffmpegPath;

  Future<JingleClip> decode({
    required String path,
    required int sampleRate,
    required int channels,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (!File(path).existsSync()) {
      throw StateError('No se encontro el archivo del jingle: $path');
    }
    final process = await Process.start(ffmpegPath, [
      '-hide_banner',
      '-loglevel',
      'error',
      '-nostdin',
      '-i',
      path,
      '-vn',
      '-map',
      '0:a:0',
      '-ac',
      '$channels',
      '-ar',
      '$sampleRate',
      '-f',
      'f32le',
      'pipe:1',
    ]);

    final out = <int>[];
    final err = <int>[];
    final outSub = process.stdout.listen((data) {
      // 512 MB es un limite de seguridad: un archivo enorme no debe tumbar la
      // app por quedarse sin memoria.
      if (out.length + data.length > 512 * 1024 * 1024) {
        process.kill(ProcessSignal.sigkill);
        return;
      }
      out.addAll(data);
    });
    final errSub = process.stderr.listen(err.addAll);
    var code = -1;
    try {
      code = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
    await outSub.cancel();
    await errSub.cancel();
    if (code != 0 || out.isEmpty) {
      final message = String.fromCharCodes(err).trim();
      throw StateError(
        message.isEmpty
            ? 'FFmpeg no pudo decodificar el jingle.'
            : 'FFmpeg no pudo decodificar el jingle: $message',
      );
    }

    final usable = out.length - (out.length % 4);
    final bytes = Uint8List.fromList(out.sublist(0, usable));
    final samples = bytes.buffer.asFloat32List(0, usable ~/ 4);
    return JingleClip(
      samples: samples,
      sampleRate: sampleRate,
      channels: channels,
    );
  }
}

/// Reproduce un jingle en el equipo del DJ (cue local), sin enviarlo al stream.
class CuePlayer {
  CuePlayer({required this.ffmpegPath, required this.backend, this.ffplayPath});

  final String ffmpegPath;
  final CaptureBackend backend;
  String? ffplayPath;

  final Map<String, Process> _processes = {};
  final Map<String, StreamSubscription<List<int>>> _errSubs = {};

  bool get isAvailable =>
      (ffplayPath != null && File(ffplayPath!).existsSync()) ||
      (ffmpegPath.isNotEmpty &&
          Platform.isLinux &&
          File(ffmpegPath).existsSync());

  /// Busca `ffplay` junto al FFmpeg de la app. En Windows el build lo copia
  /// al lado del ejecutable; en Linux se usa FFmpeg con salida Pulse/ALSA.
  static String? findFfplay(String ffmpegPath) {
    if (ffmpegPath.isEmpty) return null;
    final dir = File(ffmpegPath).parent;
    for (final name in ['ffplay.exe', 'ffplay']) {
      final candidate = File('${dir.path}${Platform.pathSeparator}$name');
      if (candidate.existsSync()) return candidate.path;
    }
    return null;
  }

  /// Construye los argumentos del reproductor. Se expone para pruebas.
  List<String>? buildArguments({required String path, required double volume}) {
    final clamped = volume.clamp(0.0, 1.0);
    final ffplay = ffplayPath;
    if (ffplay != null && File(ffplay).existsSync()) {
      return [
        '-nodisp',
        '-autoexit',
        '-loglevel',
        'error',
        '-volume',
        '${(clamped * 100).round()}',
        path,
      ];
    }
    if (!Platform.isLinux || ffmpegPath.isEmpty) return null;
    final args = <String>[
      '-hide_banner',
      '-loglevel',
      'error',
      '-nostdin',
      '-re',
      '-i',
      path,
      '-vn',
      '-af',
      'volume=${clamped.toStringAsFixed(2)}',
      '-f',
      backend == CaptureBackend.alsa ? 'alsa' : 'pulse',
    ];
    args.add('default');
    return args;
  }

  Future<bool> play({
    required String padId,
    required String path,
    required double volume,
  }) async {
    if (!File(path).existsSync()) return false;
    final args = buildArguments(path: path, volume: volume);
    if (args == null) return false;
    await stop(padId);
    try {
      final executable = ffplayPath != null && File(ffplayPath!).existsSync()
          ? ffplayPath!
          : ffmpegPath;
      final process = await Process.start(executable, args);
      _processes[padId] = process;
      // El stderr se drena para que el proceso no se bloquee si escribe mucho.
      _errSubs[padId] = process.stderr.listen((_) {});
      unawaited(
        process.exitCode.then((_) {
          _processes.remove(padId);
          unawaited(_errSubs.remove(padId)?.cancel());
        }),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> stop(String padId) async {
    final process = _processes.remove(padId);
    await _errSubs.remove(padId)?.cancel();
    if (process != null) {
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
  }

  Future<void> stopAllCues() async {
    final ids = _processes.keys.toList();
    for (final id in ids) {
      await stop(id);
    }
  }

  bool isPlaying(String padId) => _processes.containsKey(padId);

  Future<void> dispose() async {
    await stopAllCues();
  }
}

/// Teclas asignables a los pads.
const soundboardKeyLabels = [
  '1',
  '2',
  '3',
  '4',
  '5',
  '6',
  '7',
  '8',
  'F1',
  'F2',
  'F3',
  'F4',
  'F5',
  'F6',
  'F7',
  'F8',
];

/// Tonos/formatos aceptados al importar.
const soundboardAudioExtensions = {
  'mp3',
  'wav',
  'ogg',
  'oga',
  'flac',
  'm4a',
  'aac',
  'opus',
};

/// `true` si la extension del archivo es de audio para el soundboard.
bool isSoundboardAudioFile(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot < 0 || dot == fileName.length - 1) return false;
  final ext = fileName.substring(dot + 1).toLowerCase();
  return soundboardAudioExtensions.contains(ext);
}
