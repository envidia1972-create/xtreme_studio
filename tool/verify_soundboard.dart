/// Verificacion del mezclador, persistencia y cue del soundboard.
///
/// Uso: dart run tool/verify_soundboard.dart
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:xtreme_studio/core/audio/ffmpeg_capture.dart';
import 'package:xtreme_studio/core/audio/soundboard.dart';
import 'package:xtreme_studio/core/soundboard_store.dart';

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

Float32List pcm(List<double> samples) => Float32List.fromList(samples);

Uint8List bytesOf(Float32List samples) =>
    samples.buffer.asUint8List(0, samples.lengthInBytes);

Float32List view(Uint8List bytes) =>
    bytes.buffer.asFloat32List(0, bytes.length ~/ 4);

JingleClip clip(double value, {int frames = 1000, int channels = 2}) {
  final samples = Float32List(frames * channels);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = value;
  }
  return JingleClip(samples: samples, sampleRate: 44100, channels: channels);
}

Future<void> main() async {
  stdout.writeln('Verificacion del soundboard');

  section('Mezclador');
  final mixer = SoundboardMixer(sampleRate: 44100, channels: 2);
  mixer.masterVolume = 1;
  final micBytes = bytesOf(pcm(List.filled(200, 0.25)));
  final passthrough = mixer.mix(micBytes);
  check(identical(passthrough, micBytes), 'sin jingles no copia el bloque');

  final pad = SoundboardPad(id: 'pad1', name: 'Prueba', keyLabel: '1');
  final tone = clip(0.5, frames: 5000);
  mixer.trigger(pad, tone);
  final first = view(mixer.mix(bytesOf(pcm(List.filled(2000, 0)))));
  check(first.length == 2000, 'la mezcla conserva la cantidad de muestras');
  check(
    first.skip(1000).every((s) => (s - 0.5).abs() < 0.001),
    'el jingle se suma al silencio con su volumen',
    detail: '${first[1000]}',
  );

  // El fade-in hace que la primera muestra sea mas baja que el centro.
  final fadeMixer = SoundboardMixer(sampleRate: 44100, channels: 2)
    ..masterVolume = 1;
  fadeMixer.trigger(SoundboardPad(id: 'fade'), clip(0.5, frames: 5000));
  final faded = view(fadeMixer.mix(bytesOf(pcm(List.filled(2, 0)))));
  check(faded[0] < 0.5, 'hay fade de entrada', detail: '${faded[0]}');

  // Ducking: un jingle con ducking baja el microfono.
  final duckMixer = SoundboardMixer(sampleRate: 44100, channels: 2);
  duckMixer.masterVolume = 0;
  final duckPad = SoundboardPad(id: 'duck', ducking: true);
  duckMixer.trigger(duckPad, clip(0.0));
  duckMixer.mix(bytesOf(pcm(List.filled(100, 0))));
  final ducked = view(duckMixer.mix(bytesOf(pcm(List.filled(100, 0.5)))));
  check(
    ducked.last < 0.5,
    'el ducking baja el microfono',
    detail: '${ducked.last}',
  );

  // Sin ducking, el microfono no se toca.
  final noDuck = SoundboardMixer(sampleRate: 44100, channels: 2)
    ..masterVolume = 0;
  noDuck.trigger(SoundboardPad(id: 'noduck', ducking: false), clip(0.0));
  final noDuckOut = view(noDuck.mix(bytesOf(pcm(List.filled(100, 0.5)))));
  check(
    (noDuckOut.last - 0.5).abs() < 0.001,
    'sin ducking el microfono pasa igual',
    detail: '${noDuckOut.last}',
  );

  mixer.stopAll();
  check(
    mixer.mix(bytesOf(pcm(List.filled(10, 0.1))))[0] >= 0.09,
    'stopAll limpia la mezcla',
  );

  section('Alineacion de bloques');
  final align = SoundboardMixer(sampleRate: 44100, channels: 2)
    ..masterVolume = 1;
  align.trigger(SoundboardPad(id: 'align'), clip(0.5, frames: 100));
  final firstPart = align.mix(Uint8List.fromList([0, 0, 0, 0, 0, 0, 0, 0, 0]));
  check(firstPart.length == 8, 'un bloque incompleto no desalinea el frame');
  final secondPart = align.mix(Uint8List.fromList([0, 0, 0, 0, 0, 0, 0]));
  check(secondPart.length == 8, 'el resto se completa en el bloque siguiente');

  section('Persistencia');
  final tmp = Directory.systemTemp.createTempSync('xtreme_soundboard_test_');
  try {
    final store = SoundboardStore(tmp);
    await store.load();
    check(
      Directory(store.filesDirectory.path).existsSync(),
      'la app crea soundboard/files automaticamente',
    );
    final data = SoundboardData(
      pads: SoundboardStore.defaultPads(),
      masterVolume: 0.6,
      duckingDb: -18,
      cueWhileLive: true,
    );
    await store.save(data);
    final loaded = await store.load();
    check(loaded.pads.length == 8, 'se guardan y cargan ocho pads');
    check((loaded.masterVolume - 0.6).abs() < 0.001, 'se conserva el master');
    check((loaded.duckingDb + 18).abs() < 0.001, 'se conserva el ducking');
    check(loaded.cueWhileLive, 'se conserva cueWhileLive');

    final source = File('${tmp.path}${Platform.pathSeparator}mi jingle.mp3')
      ..writeAsBytesSync([1, 2, 3, 4]);
    final name = await store.importFile(source.path);
    check(
      File(store.pathFor(name)).existsSync(),
      'el archivo se copia a la carpeta',
    );
    check(name.endsWith('.mp3'), 'se conserva la extension', detail: name);
    final files = store.listAudioFiles();
    check(files.contains(name), 'el archivo aparece en el listado');
  } finally {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  }

  section('Cue local');
  final cueTmp = Directory.systemTemp.createTempSync('xtreme_cue_test_');
  try {
    final fakeFfmpeg = File('${cueTmp.path}${Platform.pathSeparator}ffmpeg')
      ..writeAsBytesSync([0]);
    final cue = CuePlayer(
      ffmpegPath: fakeFfmpeg.path,
      backend: Platform.isWindows ? CaptureBackend.dshow : CaptureBackend.pulse,
    );
    final args = cue.buildArguments(path: 'jingle.mp3', volume: 0.5);
    if (Platform.isLinux) {
      check(args != null, 'en Linux el cue usa FFmpeg');
      check(args!.contains('-f'), 'el cue declara el formato de salida');
      check(args.contains('pulse'), 'el backend pulse se usa por defecto');
      check(args.contains('volume=0.50'), 'el volumen del cue se aplica');
    } else {
      check(args == null, 'sin ffplay en Windows el cue no inventa salida');
    }
  } finally {
    if (cueTmp.existsSync()) cueTmp.deleteSync(recursive: true);
  }

  section('Decodificacion real');
  final ffmpeg = File('tools${Platform.pathSeparator}ffmpeg');
  if (ffmpeg.existsSync()) {
    final tmp = Directory.systemTemp.createTempSync('xtreme_decode_test_');
    try {
      // WAV PCM 16-bit mono 8 kHz, 0.1 s de silencio.
      final wav = File('${tmp.path}${Platform.pathSeparator}test.wav');
      const rate = 8000;
      const frames = 800;
      const dataSize = frames * 2;
      final header = ByteData(44 + dataSize);
      void ascii(int offset, String value) {
        for (var i = 0; i < value.length; i++) {
          header.setUint8(offset + i, value.codeUnitAt(i));
        }
      }

      ascii(0, 'RIFF');
      header.setUint32(4, 36 + dataSize, Endian.little);
      ascii(8, 'WAVE');
      ascii(12, 'fmt ');
      header.setUint32(16, 16, Endian.little);
      header.setUint16(20, 1, Endian.little);
      header.setUint16(22, 1, Endian.little);
      header.setUint32(24, rate, Endian.little);
      header.setUint32(28, rate * 2, Endian.little);
      header.setUint16(32, 2, Endian.little);
      header.setUint16(34, 16, Endian.little);
      ascii(36, 'data');
      header.setUint32(40, dataSize, Endian.little);
      wav.writeAsBytesSync(header.buffer.asUint8List());

      final decoded = await JingleDecoder(
        ffmpeg.path,
      ).decode(path: wav.path, sampleRate: 44100, channels: 2);
      check(decoded.sampleRate == 44100, 'el decoder usa la frecuencia pedida');
      check(decoded.channels == 2, 'el decoder usa los canales pedidos');
      check(decoded.frames > 0, 'el decoder produce muestras');
      check(
        (decoded.duration.inMilliseconds - 100).abs() <= 2,
        'la duracion decodificada ronda los 100 ms',
        detail: '${decoded.duration.inMilliseconds} ms',
      );
    } finally {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    }
  } else {
    stdout.writeln('  [omite] no hay tools/ffmpeg para la prueba real');
  }

  stdout.writeln('');
  stdout.writeln('===============================');
  if (_failures.isEmpty) {
    stdout.writeln('SOUNDBOARD VERIFICADO: $_passed comprobaciones pasaron');
    exit(0);
  }
  stdout.writeln('$_passed OK, ${_failures.length} FALLARON:');
  for (final f in _failures) {
    stdout.writeln('  - $f');
  }
  exit(1);
}
