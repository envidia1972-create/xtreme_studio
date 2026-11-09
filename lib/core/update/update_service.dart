/// Consulta y descarga de releases de Xtreme Studio.
///
/// Por defecto habla con la API publica de GitHub Releases. Tambien acepta un
/// `latest.json` propio con la misma informacion basica, para no depender de
/// GitHub en el futuro.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'app_version.dart';
import 'update_models.dart';
import 'version.dart';

class UpdateService {
  UpdateService({
    Uri? manifestUrl,
    this.currentVersion = appVersion,
    this.platform,
    this.requireHttps = true,
    HttpClient? client,
  }) : manifestUrl = manifestUrl ?? Uri.parse(updateManifestUrl),
       _client = client,
       _ownsClient = client == null;

  final Uri manifestUrl;
  final String currentVersion;
  final UpdatePlatform? platform;
  final bool requireHttps;
  HttpClient? _client;
  final bool _ownsClient;

  UpdatePlatform get effectivePlatform =>
      platform ?? UpdatePlatformInfo.current;

  HttpClient get _http {
    final existing = _client;
    if (existing != null) return existing;
    final created = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12)
      ..idleTimeout = const Duration(seconds: 5);
    _client = created;
    return created;
  }

  Future<void> dispose() async {
    if (_ownsClient) _client?.close(force: true);
    _client = null;
  }

  /// Devuelve la release mas reciente, o `null` si el proyecto no tiene
  /// releases publicadas.
  Future<UpdateInfo?> check() async {
    if (requireHttps && manifestUrl.scheme != 'https') {
      throw UpdateException(
        'La URL de actualizaciones debe usar HTTPS: $manifestUrl',
      );
    }
    final response = await _http
        .getUrl(manifestUrl)
        .timeout(const Duration(seconds: 12));
    response.followRedirects = true;
    response.headers.set(
      HttpHeaders.userAgentHeader,
      'XtremeStudio/$currentVersion',
    );
    response.headers.set(
      HttpHeaders.acceptHeader,
      'application/vnd.github+json',
    );
    final closed = await response.close().timeout(const Duration(seconds: 15));
    final bytes = await _readBody(closed, maxBytes: 2 * 1024 * 1024);
    if (closed.statusCode == 404) return null;
    if (closed.statusCode != 200) {
      final hint = closed.statusCode == 403 || closed.statusCode == 401
          ? ' El repositorio de actualizaciones debe ser publico.'
          : '';
      throw UpdateException(
        'El servidor de actualizaciones respondio HTTP '
        '${closed.statusCode}.$hint',
      );
    }

    final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    if (decoded is! Map<String, dynamic>) {
      throw UpdateException(
        'El manifiesto de actualizaciones no es JSON valido.',
      );
    }
    final info = decoded['tag_name'] != null
        ? _fromGitHub(decoded)
        : _fromManifest(decoded);
    if (!isNewerVersion(info.latestVersion, currentVersion)) {
      return info;
    }
    return _withChecksum(info);
  }

  UpdateInfo _fromGitHub(Map<String, dynamic> root) {
    final tag = (root['tag_name'] as String? ?? '').trim();
    if (tag.isEmpty) {
      throw UpdateException('La release no tiene tag de version.');
    }
    final notes = (root['body'] as String? ?? '').trim();
    final page = Uri.tryParse(root['html_url'] as String? ?? '');
    final assets = <UpdateAsset>[];
    final rawAssets = root['assets'];
    if (rawAssets is List) {
      for (final raw in rawAssets) {
        if (raw is! Map<String, dynamic>) continue;
        final name = (raw['name'] as String? ?? '').trim();
        final url = Uri.tryParse(raw['browser_download_url'] as String? ?? '');
        if (name.isEmpty || url == null || !url.hasScheme) continue;
        final digest = (raw['digest'] as String? ?? '').trim();
        final sha = digest.startsWith('sha256:')
            ? digest.substring('sha256:'.length)
            : '';
        assets.add(
          UpdateAsset(
            name: name,
            url: url,
            size: (raw['size'] as num?)?.toInt() ?? 0,
            sha256: sha,
          ),
        );
      }
    }
    return UpdateInfo(
      latestVersion: tag,
      currentVersion: currentVersion,
      notes: notes,
      pageUrl: page != null && page.hasScheme ? page : null,
      assets: assets,
      publishedAt: DateTime.tryParse(root['published_at'] as String? ?? ''),
    );
  }

  UpdateInfo _fromManifest(Map<String, dynamic> root) {
    final version = (root['version'] as String? ?? '').trim();
    if (version.isEmpty) {
      throw UpdateException('El manifiesto no indica la version.');
    }
    final notes = (root['notes'] as String? ?? '').trim();
    final page = Uri.tryParse(root['page_url'] as String? ?? '');
    final assets = <UpdateAsset>[];
    final rawAssets = root['assets'];
    if (rawAssets is List) {
      for (final raw in rawAssets) {
        if (raw is! Map<String, dynamic>) continue;
        final name = (raw['name'] as String? ?? '').trim();
        final url = Uri.tryParse(raw['url'] as String? ?? '');
        if (name.isEmpty || url == null || !url.hasScheme) continue;
        assets.add(
          UpdateAsset(
            name: name,
            url: url,
            size: (raw['size'] as num?)?.toInt() ?? 0,
            sha256: (raw['sha256'] as String? ?? '').trim(),
          ),
        );
      }
    }
    return UpdateInfo(
      latestVersion: version,
      currentVersion: currentVersion,
      notes: notes,
      pageUrl: page != null && page.hasScheme ? page : null,
      assets: assets,
    );
  }

  /// Busca el checksum en el asset `digest` o en el archivo de checksums de la
  /// release. Sin checksum no se permite instalar.
  Future<UpdateInfo> _withChecksum(UpdateInfo info) async {
    final asset = info.assetFor(effectivePlatform);
    if (asset == null || asset.hasChecksum) return info;
    final checksumAsset = info.assets.where((a) {
      final name = a.name.toLowerCase();
      return name.contains('checksum') ||
          name.endsWith('.sha256') ||
          name == 'sha256sums';
    }).firstOrNull;
    if (checksumAsset == null) return info;
    try {
      final text = await _getText(checksumAsset.url);
      final hash = parseChecksums(text)[asset.name];
      if (hash == null || !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(hash)) {
        return info;
      }
      return UpdateInfo(
        latestVersion: info.latestVersion,
        currentVersion: info.currentVersion,
        notes: info.notes,
        pageUrl: info.pageUrl,
        assets: [
          for (final a in info.assets)
            if (a.name == asset.name)
              a.copyWith(sha256: hash.toLowerCase())
            else
              a,
        ],
        publishedAt: info.publishedAt,
      );
    } catch (_) {
      return info;
    }
  }

  /// Descarga el asset y verifica su SHA-256.
  Future<File> download(
    UpdateInfo info, {
    void Function(int received, int total)? onProgress,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final asset = info.assetFor(effectivePlatform);
    if (asset == null) {
      throw UpdateException(
        'La release no incluye un paquete para tu plataforma.',
      );
    }
    if (!asset.hasChecksum) {
      throw UpdateException(
        'La release no publico un checksum SHA-256; no se puede instalar de '
        'forma segura. Abri la pagina de descarga.',
      );
    }
    final request = await _http
        .getUrl(asset.url)
        .timeout(const Duration(seconds: 20));
    request.followRedirects = true;
    request.maxRedirects = 5;
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'XtremeStudio/$currentVersion',
    );
    final response = await request.close().timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw UpdateException(
        'No se pudo descargar la actualizacion (HTTP ${response.statusCode}).',
      );
    }
    final total = response.contentLength > 0
        ? response.contentLength
        : asset.size;
    final temp = await Directory.systemTemp.createTemp(
      'xtreme-update-download-',
    );
    final file = File('${temp.path}${Platform.pathSeparator}${asset.name}');
    final sink = file.openWrite();
    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    var received = 0;
    try {
      await for (final chunk in response.timeout(timeout)) {
        received += chunk.length;
        if (received > 512 * 1024 * 1024) {
          throw UpdateException('La actualizacion supera el limite de 512 MB.');
        }
        hasher.add(chunk);
        sink.add(chunk);
        onProgress?.call(received, total > 0 ? total : received);
      }
      await sink.flush();
      await sink.close();
      hasher.close();
      final actual = digestSink.value?.toString().toLowerCase() ?? '';
      if (actual != asset.sha256.toLowerCase()) {
        throw UpdateException(
          'El checksum de la actualizacion no coincide. Se cancelo la '
          'instalacion.',
        );
      }
      if (asset.size > 0 && received != asset.size) {
        throw UpdateException(
          'El tamano descargado no coincide con el publicado.',
        );
      }
      return file;
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<String> _getText(Uri url) async {
    final request = await _http
        .getUrl(url)
        .timeout(const Duration(seconds: 12));
    request.followRedirects = true;
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'XtremeStudio/$currentVersion',
    );
    final response = await request.close().timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw UpdateException(
        'No se pudo leer el checksum (HTTP ${response.statusCode}).',
      );
    }
    final bytes = await _readBody(response, maxBytes: 1024 * 1024);
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<Uint8List> _readBody(
    Stream<List<int>> stream, {
    required int maxBytes,
  }) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (builder.length + chunk.length > maxBytes) {
        throw UpdateException('La respuesta del servidor es demasiado grande.');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}

/// Parsea lineas `hash  archivo` (o `hash *archivo`) de un checksums.txt.
Map<String, String> parseChecksums(String text) {
  final result = <String, String>{};
  for (final line in const LineSplitter().convert(text)) {
    final match = RegExp(
      r'^\s*([a-fA-F0-9]{64})\s+\*?(.+?)\s*$',
    ).firstMatch(line);
    if (match == null) continue;
    final hash = match.group(1)!.toLowerCase();
    final name = match.group(2)!.trim();
    if (name.isEmpty) continue;
    result[name.split(RegExp(r'[/\\]')).last] = hash;
  }
  return result;
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
