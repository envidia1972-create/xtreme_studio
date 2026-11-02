/// Estado y operaciones del soundboard.
///
/// La UI no habla directamente con FFmpeg ni con el mezclador: pide disparar
/// un pad, escucharlo por cue o detenerlo, y este controlador decide si va al
/// aire (mezclado con el micrófono) o solo al equipo del DJ.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'audio/ffmpeg_capture.dart' show CaptureBackend;
import 'audio/soundboard.dart';
import 'diagnostic_log.dart';
import 'soundboard_store.dart';

class SoundboardController extends ChangeNotifier {
  SoundboardController({
    required this.store,
    String ffmpegPath = '',
    CaptureBackend backend = CaptureBackend.pulse,
    int sampleRate = 44100,
    int channels = 2,
  }) : _ffmpegPath = ffmpegPath,
       _backend = backend,
       _sampleRate = sampleRate,
       _channels = channels;

  final SoundboardStore store;
  final SoundboardMixer mixer = SoundboardMixer();

  String _ffmpegPath;
  CaptureBackend _backend;
  int _sampleRate;
  int _channels;

  SoundboardData? _data;
  JingleDecoder? _decoder;
  CuePlayer? _cue;
  final Map<String, JingleClip> _clips = {};
  final Map<String, String> _errors = {};
  Timer? _ticker;
  Timer? _saveTimer;
  int _generation = 0;

  bool _loading = true;
  bool _live = false;
  String? _lastError;

  bool get loading => _loading;
  bool get live => _live;
  String? get lastError => _lastError;
  String get directoryPath => store.directory.path;
  String get ffmpegPath => _ffmpegPath;
  CaptureBackend get backend => _backend;
  int get sampleRate => _sampleRate;
  int get channels => _channels;

  List<SoundboardPad> get pads => _data?.pads ?? const [];

  double get masterVolume => _data?.masterVolume ?? mixer.masterVolume;
  double get duckingDb => _data?.duckingDb ?? mixer.duckingDb;
  bool get cueWhileLive => _data?.cueWhileLive ?? false;
  bool get cueAvailable => _cue?.isAvailable ?? false;

  Future<void> init() async {
    _data = await store.load();
    // Claves validas y sin duplicados, incluso si el JSON viene de una version
    // anterior o fue editado a mano.
    final used = <String>{};
    for (final pad in _data!.pads) {
      var key = pad.keyLabel.toUpperCase();
      if (!soundboardKeyLabels.contains(key) || used.contains(key)) {
        key = soundboardKeyLabels.firstWhere((k) => !used.contains(k));
      }
      pad.keyLabel = key;
      used.add(key);
    }
    mixer.masterVolume = _data!.masterVolume;
    mixer.duckingDb = _data!.duckingDb;
    _loading = false;
    notifyListeners();
  }

  /// Ajusta el decodificador al perfil activo. Si cambia la frecuencia o los
  /// canales, los jingles se vuelven a decodificar para que la mezcla siga
  /// alineada con el PCM del micrófono.
  Future<void> configure({
    required String ffmpegPath,
    required CaptureBackend backend,
    required int sampleRate,
    required int channels,
  }) async {
    final changed =
        ffmpegPath != _ffmpegPath ||
        backend != _backend ||
        sampleRate != _sampleRate ||
        channels != _channels;
    if (!changed && _decoder != null) return;

    _ffmpegPath = ffmpegPath;
    _backend = backend;
    _sampleRate = sampleRate;
    _channels = channels;
    _generation++;
    final generation = _generation;

    await _cue?.dispose();
    _cue = CuePlayer(
      ffmpegPath: ffmpegPath,
      backend: backend,
      ffplayPath: CuePlayer.findFfplay(ffmpegPath),
    );
    _decoder = JingleDecoder(ffmpegPath);
    mixer.configure(sampleRate, channels);
    _clips.clear();
    _errors.clear();
    notifyListeners();

    if (ffmpegPath.isEmpty) return;
    // Se precargan los jingles para que el primer disparo no espere a FFmpeg.
    for (final pad in pads) {
      if (!pad.assigned) continue;
      if (generation != _generation) return;
      await _ensureClip(pad, notify: true);
    }
  }

  void setLive(bool value) {
    if (_live == value) return;
    _live = value;
    if (!value) mixer.stopAll();
    notifyListeners();
  }

  bool isPlaying(String padId) => mixer.activePads.contains(padId);
  bool isCueing(String padId) => _cue?.isPlaying(padId) ?? false;
  double progressFor(String padId) => mixer.progressFor(padId);
  String? errorFor(String padId) => _errors[padId];

  /// Dispara un pad: al aire lo mezcla, fuera del aire lo reproduce por cue.
  Future<bool> triggerPad(SoundboardPad pad) async {
    if (!pad.assigned) {
      _lastError = 'El pad no tiene un jingle asignado.';
      notifyListeners();
      return false;
    }
    if (!_live) return cuePad(pad);

    final clip = await _ensureClip(pad, notify: true);
    if (clip == null) return false;
    mixer.trigger(pad, clip);
    DiagnosticLog.instance?.write(
      'soundboard',
      'pad al aire: ${pad.id} (${pad.fileName})',
    );
    _lastError = null;
    notifyListeners();
    _startTicker();
    if (cueWhileLive) await cuePad(pad);
    return true;
  }

  /// Reproduce el jingle solo en el equipo del DJ, sin enviarlo al servidor.
  Future<bool> cuePad(SoundboardPad pad) async {
    final cue = _cue;
    if (cue == null || !pad.assigned) return false;
    if (!cue.isAvailable) {
      _lastError = Platform.isWindows
          ? 'El cue local necesita ffplay.exe junto a ffmpeg.exe.'
          : 'El cue local necesita FFmpeg con salida de audio.';
      notifyListeners();
      return false;
    }
    final ok = await cue.play(
      padId: pad.id,
      path: store.pathFor(pad.fileName),
      volume: pad.volume * mixer.masterVolume,
    );
    DiagnosticLog.instance?.write(
      'soundboard',
      'cue ${pad.id}: ${ok ? 'iniciado' : 'fallo'} '
          '(${pad.fileName}, master=${mixer.masterVolume.toStringAsFixed(2)})',
    );
    if (!ok) {
      _lastError = 'No se pudo reproducir el cue. Revisa la salida de audio.';
    } else {
      _lastError = null;
    }
    notifyListeners();
    if (ok) _startTicker();
    return ok;
  }

  Future<void> stopPad(SoundboardPad pad) async {
    mixer.stopPad(pad.id);
    await _cue?.stop(pad.id);
    notifyListeners();
  }

  Future<void> stopAll() async {
    mixer.stopAll();
    await _cue?.stopAllCues();
    notifyListeners();
  }

  void setMasterVolume(double value) {
    final data = _data;
    if (data == null) return;
    data.masterVolume = value.clamp(0.0, 1.0);
    mixer.masterVolume = data.masterVolume;
    _scheduleSave();
    notifyListeners();
  }

  void setDuckingDb(double value) {
    final data = _data;
    if (data == null) return;
    data.duckingDb = value.clamp(-40.0, 0.0);
    mixer.duckingDb = data.duckingDb;
    _scheduleSave();
    notifyListeners();
  }

  void setCueWhileLive(bool value) {
    final data = _data;
    if (data == null) return;
    data.cueWhileLive = value;
    _scheduleSave();
    notifyListeners();
  }

  Future<void> updatePad(
    SoundboardPad pad, {
    String? name,
    String? keyLabel,
    double? volume,
    bool? loop,
    bool? ducking,
  }) async {
    if (name != null) pad.name = name;
    if (keyLabel != null) pad.keyLabel = keyLabel;
    if (volume != null) pad.volume = volume.clamp(0.0, 1.0);
    if (loop != null) pad.loop = loop;
    if (ducking != null) pad.ducking = ducking;
    await _persist();
    notifyListeners();
  }

  /// Copia el archivo, lo asigna al pad y lo deja decodificado.
  Future<bool> assignFile(
    SoundboardPad pad,
    String sourcePath, {
    String? name,
  }) async {
    try {
      final fileName = await store.importFile(sourcePath);
      pad.fileName = fileName;
      if (name != null && name.trim().isNotEmpty) {
        pad.name = name.trim();
      } else if (pad.name.trim().isEmpty ||
          pad.name.trim().startsWith('Jingle ')) {
        pad.name = _nameFromFile(fileName);
      }
      _clips.remove(pad.id);
      _errors.remove(pad.id);
      await _persist();
      notifyListeners();
      await _ensureClip(pad, notify: true);
      return true;
    } catch (e) {
      _errors[pad.id] = e.toString().replaceFirst('Bad state: ', '');
      _lastError = _errors[pad.id];
      notifyListeners();
      return false;
    }
  }

  Future<void> clearPad(SoundboardPad pad) async {
    final fileName = pad.fileName;
    pad.fileName = '';
    _clips.remove(pad.id);
    _errors.remove(pad.id);
    mixer.stopPad(pad.id, fade: false);
    await _cue?.stop(pad.id);
    await _persist();
    // Solo se borra el archivo si ningun otro pad lo usa.
    if (fileName.isNotEmpty &&
        !pads.any((p) => p.id != pad.id && p.fileName == fileName)) {
      await store.removeFile(fileName);
    }
    notifyListeners();
  }

  /// Incorpora archivos que el DJ copio a mano en la carpeta del soundboard.
  Future<int> refreshFolder() async {
    final files = store.listAudioFiles();
    final used = pads.map((p) => p.fileName).where((f) => f.isNotEmpty).toSet();
    final empty = pads.where((p) => !p.assigned).toList();
    var added = 0;
    for (final file in files) {
      if (used.contains(file)) continue;
      if (added >= empty.length) break;
      final pad = empty[added];
      pad.fileName = file;
      pad.name = _nameFromFile(file);
      added++;
    }
    if (added > 0) {
      await _persist();
      notifyListeners();
      for (final pad in pads) {
        if (pad.assigned) await _ensureClip(pad, notify: false);
      }
      notifyListeners();
    }
    return added;
  }

  Future<void> openFolder() async {
    try {
      await store.openDirectory();
    } catch (e) {
      _lastError = 'No se pudo abrir la carpeta: $e';
      notifyListeners();
    }
  }

  /// Incorpora un archivo nuevo al primer pad libre. Devuelve el pad usado.
  Future<SoundboardPad?> addFile(
    String sourcePath, {
    String? name,
    String? keyLabel,
  }) async {
    SoundboardPad? empty;
    for (final pad in pads) {
      if (!pad.assigned) {
        empty = pad;
        break;
      }
    }
    if (empty == null) {
      _lastError = 'Los ocho pads ya tienen un jingle.';
      notifyListeners();
      return null;
    }
    if (keyLabel != null && keyLabel.isNotEmpty) empty.keyLabel = keyLabel;
    final ok = await assignFile(empty, sourcePath, name: name);
    return ok ? empty : null;
  }

  Future<JingleClip?> _ensureClip(
    SoundboardPad pad, {
    required bool notify,
  }) async {
    if (!pad.assigned) return null;
    final existing = _clips[pad.id];
    if (existing != null) return existing;
    final decoder = _decoder;
    if (decoder == null || _ffmpegPath.isEmpty) {
      _errors[pad.id] = 'FFmpeg no esta configurado.';
      if (notify) notifyListeners();
      return null;
    }
    final generation = _generation;
    try {
      final clip = await decoder.decode(
        path: store.pathFor(pad.fileName),
        sampleRate: _sampleRate,
        channels: _channels,
      );
      if (generation != _generation) return null;
      _clips[pad.id] = clip;
      _errors.remove(pad.id);
      if (notify) notifyListeners();
      return clip;
    } catch (e) {
      _errors[pad.id] = e.toString().replaceFirst('Bad state: ', '');
      if (notify) notifyListeners();
      return null;
    }
  }

  String _nameFromFile(String fileName) {
    final dot = fileName.lastIndexOf('.');
    final base = dot > 0 ? fileName.substring(0, dot) : fileName;
    return base.replaceAll(RegExp(r'[_-]+'), ' ').trim();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(_persist());
    });
  }

  Future<void> _persist() async {
    final data = _data;
    if (data == null) return;
    data.masterVolume = mixer.masterVolume;
    data.duckingDb = mixer.duckingDb;
    try {
      await store.save(data);
    } catch (e) {
      _lastError = 'No se pudo guardar el soundboard: $e';
    }
  }

  void _startTicker() {
    _ticker ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
      final anySound = mixer.isActive || mixer.isDucking || _anyCue;
      if (!anySound) {
        _ticker?.cancel();
        _ticker = null;
      }
      notifyListeners();
    });
  }

  bool get _anyCue => pads.any((p) => _cue?.isPlaying(p.id) ?? false);

  @override
  void dispose() {
    _ticker?.cancel();
    _saveTimer?.cancel();
    unawaited(_cue?.dispose());
    unawaited(mixer.dispose());
    super.dispose();
  }
}
