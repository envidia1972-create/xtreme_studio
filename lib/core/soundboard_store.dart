/// Persistencia del soundboard y de los archivos de jingles.
library;

import 'dart:convert';
import 'dart:io';

import 'audio/soundboard.dart';

class SoundboardData {
  SoundboardData({
    required this.pads,
    this.masterVolume = 0.8,
    this.duckingDb = -12.0,
    this.cueWhileLive = false,
  });

  final List<SoundboardPad> pads;
  double masterVolume;
  double duckingDb;
  bool cueWhileLive;
}

class SoundboardStore {
  SoundboardStore(this.base);

  final Directory base;

  Directory get directory =>
      Directory('${base.path}${Platform.pathSeparator}soundboard');

  Directory get filesDirectory =>
      Directory('${directory.path}${Platform.pathSeparator}files');

  File get indexFile =>
      File('${directory.path}${Platform.pathSeparator}soundboard.json');

  static List<SoundboardPad> defaultPads() => [
    for (var i = 0; i < 8; i++)
      SoundboardPad(
        id: 'pad${i + 1}',
        name: 'Jingle ${i + 1}',
        keyLabel: '${i + 1}',
      ),
  ];

  Future<SoundboardData> load() async {
    if (!indexFile.existsSync()) {
      return SoundboardData(pads: defaultPads());
    }
    try {
      final raw = jsonDecode(await indexFile.readAsString());
      if (raw is! Map<String, dynamic>) {
        return SoundboardData(pads: defaultPads());
      }
      final pads = <SoundboardPad>[];
      final rawPads = raw['pads'];
      if (rawPads is List) {
        for (final item in rawPads) {
          if (item is Map<String, dynamic>) {
            pads.add(SoundboardPad.fromJson(item));
          }
        }
      }
      if (pads.isEmpty) pads.addAll(defaultPads());
      // La app siempre trabaja con ocho pads. Los archivos viejos con menos
      // se completan sin borrar los que ya existian.
      final defaults = defaultPads();
      for (var i = pads.length; i < 8; i++) {
        pads.add(defaults[i]);
      }
      return SoundboardData(
        pads: pads.take(8).toList(),
        masterVolume: ((raw['masterVolume'] as num?)?.toDouble() ?? 0.8).clamp(
          0.0,
          1.0,
        ),
        duckingDb: ((raw['duckingDb'] as num?)?.toDouble() ?? -12.0).clamp(
          -40.0,
          0.0,
        ),
        cueWhileLive: raw['cueWhileLive'] as bool? ?? false,
      );
    } catch (_) {
      // Un JSON corrupto no debe impedir abrir la app; se empieza limpio.
      return SoundboardData(pads: defaultPads());
    }
  }

  Future<void> save(SoundboardData data) async {
    await directory.create(recursive: true);
    await indexFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'masterVolume': data.masterVolume,
        'duckingDb': data.duckingDb,
        'cueWhileLive': data.cueWhileLive,
        'pads': [for (final pad in data.pads) pad.toJson()],
      }),
    );
  }

  String pathFor(String fileName) {
    if (fileName.isEmpty) return '';
    return '${filesDirectory.path}${Platform.pathSeparator}$fileName';
  }

  /// Copia un archivo externo a la carpeta del soundboard y devuelve su nombre
  /// relativo. Si ya esta dentro, no lo duplica.
  Future<String> importFile(String sourcePath) async {
    final source = File(sourcePath);
    if (!source.existsSync()) {
      throw StateError('No se encontro el archivo: $sourcePath');
    }
    await filesDirectory.create(recursive: true);

    final sourceResolved = source.absolute.path;
    final filesResolved = filesDirectory.absolute.path;
    final prefix = '$filesResolved${Platform.pathSeparator}';
    if (sourceResolved.startsWith(prefix)) {
      return sourceResolved.substring(prefix.length);
    }

    final rawName = source.uri.pathSegments.last;
    final safeName = rawName.replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_');
    var name = safeName.isEmpty
        ? 'jingle-${DateTime.now().millisecondsSinceEpoch}.mp3'
        : safeName;
    var target = File(pathFor(name));
    if (target.existsSync()) {
      final dot = name.lastIndexOf('.');
      final stem = dot > 0 ? name.substring(0, dot) : name;
      final ext = dot > 0 ? name.substring(dot) : '';
      name = '$stem-${DateTime.now().millisecondsSinceEpoch}$ext';
      target = File(pathFor(name));
    }
    await source.copy(target.path);
    return name;
  }

  List<String> listAudioFiles() {
    if (!filesDirectory.existsSync()) return const [];
    final result = <String>[];
    for (final entity in filesDirectory.listSync()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (isSoundboardAudioFile(name)) {
        result.add(name);
      }
    }
    result.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return result;
  }

  Future<void> removeFile(String fileName) async {
    if (fileName.isEmpty) return;
    final file = File(pathFor(fileName));
    if (file.existsSync()) {
      try {
        await file.delete();
      } catch (_) {
        // El pad igual se puede vaciar aunque el archivo este bloqueado.
      }
    }
  }

  Future<void> openDirectory() async {
    await directory.create(recursive: true);
    if (Platform.isWindows) {
      await Process.run('explorer.exe', [directory.path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [directory.path]);
    } else {
      await Process.run('xdg-open', [directory.path]);
    }
  }
}
