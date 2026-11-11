/// Verificacion del chequeo y la descarga de actualizaciones.
///
/// Uso: dart run tool/verify_update.dart
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:xtreme_studio/core/update/update_installer.dart';
import 'package:xtreme_studio/core/update/update_models.dart';
import 'package:xtreme_studio/core/update/update_service.dart';
import 'package:xtreme_studio/core/update/version.dart';

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

class TestServer {
  TestServer(this.server) {
    server.listen(_handle);
  }

  final HttpServer server;
  final bytes = Uint8List.fromList(List<int>.generate(4096, (i) => i % 251));
  String manifest = '';
  int requests = 0;

  late final String sha = sha256.convert(bytes).toString();

  String get base => 'http://127.0.0.1:${server.port}';

  Future<void> _handle(HttpRequest request) async {
    requests++;
    if (request.uri.path == '/latest.json') {
      request.response.headers.contentType = ContentType.json;
      request.response.write(manifest);
      await request.response.close();
      return;
    }
    if (request.uri.path == '/asset.zip') {
      request.response.headers.contentType = ContentType.binary;
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
      return;
    }
    request.response.statusCode = 404;
    await request.response.close();
  }

  Future<void> close() => server.close(force: true);
}

String githubManifest(
  TestServer server, {
  required String sha,
  String tag = 'v0.2.0',
}) {
  return jsonEncode({
    'tag_name': tag,
    'body': 'Correcciones y mejoras',
    'html_url':
        'https://github.com/envidia1972-create/xtreme_studio/releases/tag/$tag',
    'published_at': '2026-11-09T00:00:00Z',
    'assets': [
      {
        'name': 'XtremeStudio-0.2.0-windows-x64.zip',
        'browser_download_url': '${server.base}/asset.zip',
        'size': server.bytes.length,
        'digest': 'sha256:$sha',
      },
    ],
  });
}

Future<void> main() async {
  stdout.writeln('Verificacion de actualizaciones');

  section('Comparacion de versiones');
  check(isNewerVersion('0.2.0', '0.1.0'), '0.2.0 es mas nueva que 0.1.0');
  check(isNewerVersion('v0.1.1', '0.1.0'), 'v0.1.1 es mas nueva que 0.1.0');
  check(
    !isNewerVersion('0.1.0', '0.1.0'),
    'la misma version no es actualizacion',
  );
  check(
    !isNewerVersion('0.1.0', '0.2.0'),
    'una version anterior no es actualizacion',
  );
  check(
    isNewerVersion('1.0.0+5', '1.0.0+4'),
    'el build number tambien se compara',
  );
  check(compareVersions('0.10.0', '0.9.9') > 0, '0.10.0 > 0.9.9');

  section('Checksums');
  final parsed = parseChecksums(
    '${'a' * 64}  archivo.zip\n${'b' * 64} *otro.zip\nbasura\n',
  );
  check(parsed['archivo.zip'] == 'a' * 64, 'parsea hash + dos espacios');
  check(parsed['otro.zip'] == 'b' * 64, 'parsea hash + asterisco');

  section('GitHub Releases');
  final server = TestServer(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
  );
  server.manifest = githubManifest(server, sha: server.sha);
  try {
    final service = UpdateService(
      manifestUrl: Uri.parse('${server.base}/latest.json'),
      currentVersion: '0.1.0',
      platform: UpdatePlatform.windows,
      requireHttps: false,
    );
    final info = await service.check();
    check(info != null, 'lee una release de GitHub');
    check(info!.isNewer, 'detecta que la release es nueva');
    check(info.latestVersion == 'v0.2.0', 'conserva el tag de version');
    check(info.windowsAsset != null, 'selecciona el ZIP de Windows');
    check(info.windowsAsset!.hasChecksum, 'lee el SHA-256 del asset');
    check(info.notes.contains('Correcciones'), 'lee las notas de la release');
    final archive = await service.download(info);
    check(archive.existsSync(), 'descarga el archivo');
    if (archive.existsSync()) {
      final bytes = await archive.readAsBytes();
      check(
        sha256.convert(bytes).toString() == server.sha,
        'el archivo descargado coincide con el checksum',
      );
      await archive.parent.delete(recursive: true);
    }
    await service.dispose();

    final noUpdate = UpdateService(
      manifestUrl: Uri.parse('${server.base}/latest.json'),
      currentVersion: '0.2.0',
      platform: UpdatePlatform.windows,
      requireHttps: false,
    );
    final same = await noUpdate.check();
    check(
      same != null && !same.isNewer,
      'no ofrece actualizar a la misma version',
    );
    await noUpdate.dispose();

    server.manifest = githubManifest(server, sha: '0' * 64, tag: 'v0.3.0');
    final bad = UpdateService(
      manifestUrl: Uri.parse('${server.base}/latest.json'),
      currentVersion: '0.1.0',
      platform: UpdatePlatform.windows,
      requireHttps: false,
    );
    final badInfo = await bad.check();
    var rejected = false;
    try {
      await bad.download(badInfo!);
    } on UpdateException {
      rejected = true;
    }
    check(rejected, 'rechaza una descarga con checksum incorrecto');
    await bad.dispose();
  } finally {
    await server.close();
  }

  section('Manifiesto propio');
  final customServer = TestServer(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
  );
  customServer.manifest = jsonEncode({
    'version': '0.4.0',
    'notes': 'Version propia',
    'page_url': 'https://ejemplo.com/radio',
    'assets': [
      {
        'name': 'XtremeStudio-0.4.0-windows-x64.zip',
        'url': '${customServer.base}/asset.zip',
        'size': customServer.bytes.length,
        'sha256': customServer.sha,
      },
    ],
  });
  try {
    final service = UpdateService(
      manifestUrl: Uri.parse('${customServer.base}/latest.json'),
      currentVersion: '0.1.0',
      platform: UpdatePlatform.windows,
      requireHttps: false,
    );
    final info = await service.check();
    check(info?.latestVersion == '0.4.0', 'lee un latest.json propio');
    check(info?.windowsAsset != null, 'selecciona el asset propio');
    check(info?.windowsAsset?.hasChecksum == true, 'lee el SHA-256 propio');
    await service.dispose();
  } finally {
    await customServer.close();
  }

  section('Seleccion por plataforma');
  final assets = [
    UpdateAsset(
      name: 'XtremeStudio-0.2.0-windows-x64.zip',
      url: Uri.parse('https://x/win'),
    ),
    UpdateAsset(
      name: 'XtremeStudio-0.2.0-linux-x64.tar.gz',
      url: Uri.parse('https://x/linux'),
    ),
  ];
  final info = UpdateInfo(
    latestVersion: '0.2.0',
    currentVersion: '0.1.0',
    notes: '',
    pageUrl: null,
    assets: assets,
  );
  check(
    info.assetFor(UpdatePlatform.windows)?.name.contains('windows') == true,
    'elige Windows',
  );
  check(
    info.assetFor(UpdatePlatform.linux)?.name.contains('linux') == true,
    'elige Linux',
  );
  check(info.assetFor(UpdatePlatform.macos) == null, 'sin asset para macOS');

  section('Actualizador Windows');
  final script = UpdateInstaller.buildWindowsUpdaterScript();
  check(script.contains('Wait-Process'), 'espera a que cierre la app');
  check(script.contains('Expand-Archive'), 'extrae el ZIP');
  check(script.contains('xtreme_studio.exe'), 'vuelve a abrir el ejecutable');
  check(script.contains('update-backup'), 'guarda copia de seguridad');

  section('Actualizador Linux');
  final linuxScript = UpdateInstaller.buildLinuxUpdaterScript();
  check(linuxScript.contains('kill -0'), 'espera a que cierre la app');
  check(linuxScript.contains('tar -xzf'), 'extrae el tar.gz');
  check(linuxScript.contains('xtreme_studio'), 'vuelve a abrir el ejecutable');
  check(linuxScript.contains('update-backup'), 'guarda copia de seguridad');
  check(linuxScript.contains('nohup'), 'relanza fuera del proceso actual');

  check(
    UpdateInstaller.supportsCurrentPlatform ==
        (Platform.isWindows || Platform.isLinux),
    'soporte coherente con la plataforma',
  );

  stdout.writeln('');
  stdout.writeln('===============================');
  if (_failures.isEmpty) {
    stdout.writeln(
      'ACTUALIZACIONES VERIFICADAS: $_passed comprobaciones pasaron',
    );
    exit(0);
  }
  stdout.writeln('$_passed OK, ${_failures.length} FALLARON:');
  for (final f in _failures) {
    stdout.writeln('  - $f');
  }
  exit(1);
}
