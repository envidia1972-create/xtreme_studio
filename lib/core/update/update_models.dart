/// Modelos de una release y del estado de actualizacion.
library;

import 'dart:io';

import 'app_version.dart';
import 'version.dart';

enum UpdatePlatform { windows, linux, macos, unknown }

extension UpdatePlatformInfo on UpdatePlatform {
  static UpdatePlatform get current {
    if (Platform.isWindows) return UpdatePlatform.windows;
    if (Platform.isLinux) return UpdatePlatform.linux;
    if (Platform.isMacOS) return UpdatePlatform.macos;
    return UpdatePlatform.unknown;
  }

  String get label => switch (this) {
    UpdatePlatform.windows => 'Windows x64',
    UpdatePlatform.linux => 'Linux x64',
    UpdatePlatform.macos => 'macOS',
    UpdatePlatform.unknown => 'plataforma desconocida',
  };
}

class UpdateAsset {
  const UpdateAsset({
    required this.name,
    required this.url,
    this.size = 0,
    this.sha256 = '',
  });

  final String name;
  final Uri url;
  final int size;

  /// SHA-256 en minusculas. Vacio = la release no publico checksum.
  final String sha256;

  bool get hasChecksum => RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(sha256);

  UpdateAsset copyWith({String? sha256}) => UpdateAsset(
    name: name,
    url: url,
    size: size,
    sha256: sha256 ?? this.sha256,
  );
}

class UpdateInfo {
  const UpdateInfo({
    required this.latestVersion,
    required this.currentVersion,
    required this.notes,
    required this.pageUrl,
    required this.assets,
    this.publishedAt,
  });

  final String latestVersion;
  final String currentVersion;
  final String notes;
  final Uri? pageUrl;
  final List<UpdateAsset> assets;
  final DateTime? publishedAt;

  bool get isNewer => isNewerVersion(latestVersion, currentVersion);

  UpdateAsset? assetFor(UpdatePlatform platform) {
    final matches = assets.where((asset) {
      final name = asset.name.toLowerCase();
      return switch (platform) {
        UpdatePlatform.windows =>
          name.contains('windows') && name.endsWith('.zip'),
        UpdatePlatform.linux =>
          name.contains('linux') &&
              (name.endsWith('.tar.gz') ||
                  name.endsWith('.tgz') ||
                  name.endsWith('.appimage')),
        UpdatePlatform.macos => name.contains('macos') && name.endsWith('.zip'),
        UpdatePlatform.unknown => false,
      };
    }).toList();
    if (matches.isEmpty) return null;
    matches.sort((a, b) {
      final ax64 = a.name.toLowerCase().contains('x64') ? 0 : 1;
      final bx64 = b.name.toLowerCase().contains('x64') ? 0 : 1;
      return ax64.compareTo(bx64);
    });
    return matches.first;
  }

  UpdateAsset? get windowsAsset => assetFor(UpdatePlatform.windows);

  String get displayVersion => latestVersion.startsWith('v')
      ? latestVersion.substring(1)
      : latestVersion;

  String get currentDisplayVersion => currentVersion.startsWith('v')
      ? currentVersion.substring(1)
      : currentVersion;

  static const empty = UpdateInfo(
    latestVersion: appVersion,
    currentVersion: appVersion,
    notes: '',
    pageUrl: null,
    assets: [],
  );
}

class UpdateException implements Exception {
  UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}
