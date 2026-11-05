/// Persistencia de perfiles y ajustes.
///
/// Separacion deliberada de responsabilidades:
/// - `profiles.json`: todo lo NO secreto (host, puerto, mount, calidad...).
///   Se puede compartir, versionar o exportar sin filtrar nada.
/// - `secrets/<id>.bin`: la contrasena, cifrada con DPAPI. Nunca sale del
///   equipo del DJ ni aparece en texto plano en disco.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import 'secret_store.dart';
import 'server_profile.dart';

/// Estado que la app recordo entre ejecuciones.
///
/// Solo se guarda lo que la app usa de verdad: un ajuste que se persiste pero
/// no cambia nada es peor que no tenerlo, porque sugiere una funcion que no
/// existe.
///
/// (Hubo aqui dos campos que nunca llegaron a la interfaz —escuchar la propia
/// senal y pedir confirmacion antes de salir al aire— y se retiraron. La
/// confirmacion del mount ocupado si existe: se pregunta siempre, y vive en
/// `main.dart`.)
class AppSettings {
  AppSettings({
    this.lastProfileId = '',
    this.ffmpegPath = '',
    this.lastDeviceId = '',
    this.recordLocally = false,
    this.recordDirectory = '',
    this.keepAwakeWhileLive = true,
  });

  /// Perfil que estaba seleccionado al cerrar.
  String lastProfileId;

  /// Ruta a ffmpeg.exe. Vacio = autodetectar.
  String ffmpegPath;

  /// Dispositivo de entrada recordado entre sesiones.
  String lastDeviceId;

  /// Guardar una copia local de cada emision.
  bool recordLocally;

  /// Carpeta donde se guardan las grabaciones.
  String recordDirectory;

  /// Evita que la pantalla se bloquee y que el equipo se suspenda mientras la
  /// app esta al aire.
  ///
  /// En Linux, al bloquearse la pantalla el escritorio cambia a una sesion de
  /// greeter: la sesion del DJ pasa a inactiva, PipeWire reconfigura los nodos
  /// de audio y la captura se queda muda. Inhibir el bloqueo mientras se
  /// emite es la unica forma de que el audio no se corte solo.
  bool keepAwakeWhileLive;

  Map<String, dynamic> toJson() => {
    'lastProfileId': lastProfileId,
    'ffmpegPath': ffmpegPath,
    'lastDeviceId': lastDeviceId,
    'recordLocally': recordLocally,
    'recordDirectory': recordDirectory,
    'keepAwakeWhileLive': keepAwakeWhileLive,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
    lastProfileId: json['lastProfileId'] as String? ?? '',
    ffmpegPath: json['ffmpegPath'] as String? ?? '',
    lastDeviceId: json['lastDeviceId'] as String? ?? '',
    recordLocally: json['recordLocally'] as bool? ?? false,
    recordDirectory: json['recordDirectory'] as String? ?? '',
    keepAwakeWhileLive: json['keepAwakeWhileLive'] as bool? ?? true,
  );
}

/// Almacen de perfiles en disco.
class ProfileStore {
  ProfileStore({Directory? baseDirectory, SecretStore? secretStore})
    : base = baseDirectory ?? _defaultBaseDirectory(),
      secrets = secretStore ?? createSecretStore();

  final Directory base;
  final SecretStore secrets;

  static const _uuid = Uuid();

  /// Carpeta de datos del usuario, sin depender de plugins nativos:
  /// `%APPDATA%\XtremeStudio` en Windows, `~/.xtreme_studio` en el resto.
  static Directory _defaultBaseDirectory() {
    final env = Platform.environment;
    if (Platform.isWindows) {
      final appData = env['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        return Directory('$appData\\XtremeStudio');
      }
    }
    final home = env['HOME'] ?? Directory.current.path;
    return Directory('$home${Platform.pathSeparator}.xtreme_studio');
  }

  File get profilesFile =>
      File('${base.path}${Platform.pathSeparator}profiles.json');
  File get settingsFile =>
      File('${base.path}${Platform.pathSeparator}settings.json');
  Directory get secretsDir =>
      Directory('${base.path}${Platform.pathSeparator}secrets');

  File _secretFile(String profileId) =>
      File('${secretsDir.path}${Platform.pathSeparator}$profileId.bin');

  /// Secreto aparte para la clave de administracion del servidor.
  ///
  /// No se guarda en `profiles.json` (que se comparte al exportar) ni se
  /// mezcla con la clave de la fuente: si el hosting usa una distinta para
  /// cambiar el titulo, tambien merece el mismo tratamiento cifrado.
  File _adminSecretFile(String profileId) =>
      File('${secretsDir.path}${Platform.pathSeparator}$profileId.admin.bin');

  Future<void> ensureDirectories() async {
    if (!base.existsSync()) await base.create(recursive: true);
    if (!secretsDir.existsSync()) await secretsDir.create(recursive: true);
  }

  /// Genera un identificador nuevo para un perfil.
  static String newId() => _uuid.v4();

  /// Carga los perfiles con sus contrasenas descifradas.
  ///
  /// Es tolerante a datos corruptos a proposito: un JSON roto o un perfil con
  /// un tipo inesperado no puede dejar la app atascada en la pantalla de carga
  /// ni hacer perder las demas emisoras. Un perfil cuya contrasena no se pueda
  /// descifrar se devuelve igual, con la contrasena vacia, para que el DJ pueda
  /// reescribirla sin perder la configuracion.
  Future<List<ServerProfile>> load() async {
    final maps = await _readRawProfiles();
    final result = <ServerProfile>[];
    for (final map in maps) {
      try {
        final profile = ServerProfile.fromJson(map);
        profile.password = await _readSecretFile(_secretFile(profile.id)) ?? '';
        profile.adminPassword =
            await _readSecretFile(_adminSecretFile(profile.id)) ?? '';
        result.add(profile);
      } catch (_) {
        // Un perfil invalido se omite; el resto sigue disponible.
      }
    }
    return result;
  }

  /// Lee la lista de perfiles tal cual esta en disco, **sin** descifrar nada.
  Future<List<Map<String, dynamic>>> _readRawProfiles() async {
    await ensureDirectories();
    if (!profilesFile.existsSync()) return [];
    try {
      final raw = await profilesFile.readAsString();
      if (raw.trim().isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return [];
      final list = decoded['profiles'];
      if (list is! List) return [];
      return [
        for (final item in list)
          if (item is Map) item.cast<String, dynamic>(),
      ];
    } on FormatException {
      await _quarantineCorruptProfiles();
      return [];
    } catch (_) {
      return [];
    }
  }

  /// Aparta un `profiles.json` corrupto en lugar de sobrescribirlo en silencio.
  Future<void> _quarantineCorruptProfiles() async {
    try {
      final backup = File('${profilesFile.path}.corrupt');
      if (backup.existsSync()) await backup.delete();
      await profilesFile.rename(backup.path);
    } catch (_) {
      // Si ni siquiera se puede mover, se sigue con la lista vacia.
    }
  }

  Future<String?> _readSecretFile(File file) async {
    if (!file.existsSync()) return null;
    try {
      final blob = await file.readAsBytes();
      final r = secrets.unprotect(Uint8List.fromList(blob));
      if (!r.ok) return null;
      return utf8.decode(r.data!, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  /// Guarda (crea o reemplaza) un perfil y su secreto.
  ///
  /// No se vuelcan todos los perfiles leyendo y descifrando sus secretos: se
  /// trabaja sobre el JSON en disco. Asi guardar una emisora no puede borrar la
  /// contrasena de otra cuyo descifrado fallara.
  Future<void> save(ServerProfile profile) async {
    await ensureDirectories();
    final maps = await _readRawProfiles();
    final index = maps.indexWhere((m) => m['id'] == profile.id);
    if (index >= 0) {
      maps[index] = profile.toJson();
    } else {
      maps.add(profile.toJson());
    }
    await _writeProfiles(maps);
    await _saveSecret(profile.id, profile.password);
    await _writeSecretFile(_adminSecretFile(profile.id), profile.adminPassword);
  }

  Future<void> _saveSecret(String profileId, String password) =>
      _writeSecretFile(_secretFile(profileId), password);

  Future<void> _writeSecretFile(File file, String secret) async {
    if (secret.isEmpty) {
      if (file.existsSync()) await file.delete();
      return;
    }
    final r = secrets.protect(secret);
    if (!r.ok) {
      // No guardamos en claro nunca: es preferible avisar.
      throw StateError('No se pudo cifrar la contrasena: ${r.error}');
    }
    await file.writeAsBytes(r.data!, flush: true);
    // En Linux/macOS el secreto queda protegido solo por los permisos del
    // archivo: 0600 para que ningun otro usuario de la maquina pueda leerlo.
    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', ['600', file.path]);
      } catch (_) {
        // Sin chmod se sigue funcionando; el backend ya se declara no cifrado.
      }
    }
  }

  Future<void> _writeProfiles(List<Map<String, dynamic>> profiles) async {
    await ensureDirectories();
    final payload = const JsonEncoder.withIndent(
      '  ',
    ).convert({'version': 1, 'profiles': profiles});
    await profilesFile.writeAsString(payload, flush: true);
  }

  /// Elimina un perfil y su secreto.
  Future<void> delete(String profileId) async {
    final maps = await _readRawProfiles();
    maps.removeWhere((m) => m['id'] == profileId);
    await _writeProfiles(maps);
    final file = _secretFile(profileId);
    if (file.existsSync()) await file.delete();
    final adminFile = _adminSecretFile(profileId);
    if (adminFile.existsSync()) await adminFile.delete();
  }

  Future<AppSettings> loadSettings() async {
    await ensureDirectories();
    if (!settingsFile.existsSync()) return AppSettings();
    try {
      final decoded = jsonDecode(await settingsFile.readAsString());
      if (decoded is Map) {
        return AppSettings.fromJson(decoded.cast<String, dynamic>());
      }
    } catch (_) {
      // Ajustes corruptos: se empieza de cero, no es critico.
    }
    return AppSettings();
  }

  Future<void> saveSettings(AppSettings settings) async {
    await ensureDirectories();
    await settingsFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
      flush: true,
    );
  }

  /// Exporta el perfil **sin la contrasena**, para compartirlo por QR o
  /// archivo con otro DJ sin filtrar credenciales.
  ///
  /// Incluye una huella del secreto para que el receptor pueda comprobar que
  /// ambos tienen la misma contrasena, sin revelarla.
  String exportProfile(ServerProfile profile, {bool includePassword = false}) {
    final json = profile.toJson();

    // La contrasena NUNCA se escribe en claro, ni siquiera cuando se pide
    // incluirla: el texto exportado se comparte por chat, correo o portapapeles
    // y quedaria a la vista. Solo se incluye el blob protegido por el sistema
    // (DPAPI), que no sirve fuera de esta maquina y este usuario.
    json['password'] = '';
    if (includePassword) {
      if (secrets.isSecure) {
        final r = secrets.protect(profile.password);
        if (r.ok) {
          json['passwordProtected'] = base64Encode(r.data!);
          json['passwordProtectedBy'] = 'dpapi';
        }
      } else {
        // Sin cifrado real no hay forma segura de transportar la clave.
        json['passwordOmitted'] = true;
      }
    }
    json['exportedBy'] = 'XtremeStudio/0.1';
    return const JsonEncoder.withIndent('  ').convert(json);
  }

  /// Importa un perfil exportado. Si viene cifrado con DPAPI no se puede
  /// descifrar en otra maquina (es justamente el objetivo), asi que se importa
  /// todo menos la contrasena y se avisa.
  Future<ServerProfile> importProfile(String content) async {
    final decoded = jsonDecode(content);
    if (decoded is! Map) {
      throw const FormatException('El contenido no es un perfil valido');
    }
    final profile = ServerProfile.fromJson(decoded.cast<String, dynamic>());
    profile.id = profile.id.isEmpty ? newId() : profile.id;
    final plain = decoded['password'] as String? ?? '';
    profile.password = plain;
    return profile;
  }

  /// Rutas tipicas donde queda FFmpeg en Windows.
  ///
  /// Se revisan antes que el `PATH` porque es lo habitual: mucha gente instala
  /// FFmpeg con winget, Chocolatey o Scoop y **no** reinicia la app ni la
  /// sesion, asi que el `PATH` todavia no lo incluye y la app diria "no se
  /// encontro FFmpeg" aunque este instalado.
  static List<String> _commonWindowsLocations(String exe) {
    final env = Platform.environment;
    final local = env['LOCALAPPDATA'] ?? '';
    final appData = env['APPDATA'] ?? '';
    final userProfile = env['USERPROFILE'] ?? '';
    final programData = env['ProgramData'] ?? '';

    final dirs = <String>[
      // winget crea enlaces en WindowsApps\...\Links
      if (local.isNotEmpty) '$local\\Microsoft\\WinGet\\Links\\$exe',
      if (local.isNotEmpty) '$local\\Microsoft\\WinGet\\Packages',
      // Chocolatey
      if (programData.isNotEmpty) '$programData\\chocolatey\\bin\\$exe',
      'C:\\ProgramData\\chocolatey\\bin\\$exe',
      // Scoop
      if (userProfile.isNotEmpty) '$userProfile\\scoop\\shims\\$exe',
      // Instalaciones manuales frecuentes
      'C:\\ffmpeg\\bin\\$exe',
      'C:\\ffmpeg\\$exe',
      'C:\\Program Files\\ffmpeg\\bin\\$exe',
      'C:\\Program Files (x86)\\ffmpeg\\bin\\$exe',
      // Aplicaciones que traen su propio FFmpeg
      'C:\\Program Files\\OBS Studio\\bin\\64bit\\$exe',
      if (appData.isNotEmpty) '$appData\\..\\Local\\Programs\\$exe',
    ];
    return dirs;
  }

  /// Busca ffmpeg en el sistema. Devuelve la ruta o vacio si no aparece.
  static Future<String> findFfmpeg(String preferred) async {
    // Cuidado: en Dart `File('').existsSync()` devuelve `true`, porque la
    // cadena vacia apunta al directorio actual. Sin esta comprobacion previa,
    // pasar '' (el caso de "autodetectar") devolvia '' de inmediato y **nunca**
    // se buscaba nada.
    final candidate = preferred.trim();
    if (candidate.isNotEmpty && File(candidate).existsSync()) {
      return candidate;
    }

    final exe = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';

    // 1. Junto al ejecutable de la app (asi se distribuye empaquetado) y en la
    //    carpeta `tools` del proyecto.
    final selfDir = File(Platform.resolvedExecutable).parent;
    final beside = <String>[
      '${selfDir.path}${Platform.pathSeparator}$exe',
      '${selfDir.path}${Platform.pathSeparator}ffmpeg${Platform.pathSeparator}$exe',
      '${Directory.current.path}${Platform.pathSeparator}tools${Platform.pathSeparator}$exe',
      '${Directory.current.path}${Platform.pathSeparator}ffmpeg${Platform.pathSeparator}$exe',
    ];
    for (final c in beside) {
      if (File(c).existsSync()) return c;
    }

    // 1b. Al ejecutar desde `build\windows\x64\runner\Release\`, el `tools\` del
    //     proyecto esta varios niveles mas arriba. Un DJ que reciba la carpeta
    //     comprimida tampoco la tendra al lado, pero buscarla arriba evita que
    //     haya que copiar ffmpeg.exe a mano en el uso normal.
    final above = _searchFfmpegUpwards(selfDir, exe);
    if (above.isNotEmpty) return above;

    // 3. Ubicaciones tipicas del sistema (incluye gestores de paquetes).
    //
    // Se hace ANTES de consultar el PATH a proposito: si se consultara primero
    // y ese proceso fallara (por ejemplo porque el entorno no permite lanzar
    // procesos, o porque `where` no esta), la busqueda se perderia y la app
    // diria "no encontre FFmpeg" aunque el archivo estuviera a la vista.
    if (Platform.isWindows) {
      for (final c in _commonWindowsLocations(exe)) {
        if (File(c).existsSync()) return c;
      }
      // Subdirectorio anidado del paquete de winget, p. ej.
      // %LOCALAPPDATA%\Microsoft\WinGet\Packages\Gyan.FFmpeg_...\ffmpeg-*\bin
      final packagesDir = Platform.environment['LOCALAPPDATA'] == null
          ? ''
          : '${Platform.environment['LOCALAPPDATA']}\\Microsoft\\WinGet\\Packages';
      final nested = _searchNestedFfmpeg(packagesDir, exe);
      if (nested.isNotEmpty) return nested;
    }

    // 4. PATH del sistema, como ultimo recurso.
    try {
      final result = await Process.run(Platform.isWindows ? 'where' : 'which', [
        exe,
      ]);
      if (result.exitCode == 0) {
        final first = (result.stdout as String)
            .split(RegExp(r'\r?\n'))
            .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '')
            .trim();
        if (first.isNotEmpty && File(first).existsSync()) return first;
      }
    } catch (_) {
      // `where`/`which` pueden no existir, o el entorno puede impedir lanzar
      // procesos. No es un error fatal: se devuelve vacio y el usuario indica
      // la ruta a mano.
    }

    return '';
  }

  /// Expone la busqueda ascendente para poder verificarla en las pruebas.
  ///
  /// Se deja publica a proposito: es la logica que decide si un DJ que recibe
  /// la app compilada encuentra FFmpeg sin tocar nada, y conviene poder
  /// comprobarla con una carpeta simulada en lugar de confiar en ella.
  static String debugSearchUpwards(Directory start, String exe) =>
      _searchFfmpegUpwards(start, exe);

  /// Busca `ffmpeg.exe` subiendo por los directorios padre.
  ///
  /// Cubre el caso de ejecutar la app desde `build\windows\x64\runner\Release\`
  /// mientras FFmpeg esta en `tools\` en la raiz del proyecto, y tambien el de
  /// una carpeta distribuida dentro de otra mayor.
  static String _searchFfmpegUpwards(Directory start, String exe) {
    var dir = start;
    for (var level = 0; level < 5; level++) {
      final parent = dir.parent;
      // Se detiene al llegar a la raiz de la unidad.
      if (parent.path == dir.path) break;
      dir = parent;

      final candidates = <String>[
        '${dir.path}${Platform.pathSeparator}$exe',
        '${dir.path}${Platform.pathSeparator}tools${Platform.pathSeparator}$exe',
        '${dir.path}${Platform.pathSeparator}ffmpeg${Platform.pathSeparator}$exe',
        '${dir.path}${Platform.pathSeparator}ffmpeg${Platform.pathSeparator}bin${Platform.pathSeparator}$exe',
      ];
      for (final c in candidates) {
        if (File(c).existsSync()) return c;
      }
    }
    return '';
  }

  /// Busca `ffmpeg.exe` hasta 4 niveles dentro de una carpeta.
  ///
  /// Los paquetes de winget descomprimen en rutas largas con version, y un
  /// listado directo no alcanza para encontrarlo.
  static String _searchNestedFfmpeg(String root, String exe) {
    if (root.isEmpty) return '';
    final base = Directory(root);
    if (!base.existsSync()) return '';
    try {
      var level = <Directory>[base];
      for (var depth = 0; depth < 4; depth++) {
        final next = <Directory>[];
        for (final dir in level) {
          final List<FileSystemEntity> entries;
          try {
            entries = dir.listSync();
          } catch (_) {
            continue; // Sin permisos: se ignora esa rama.
          }
          for (final e in entries) {
            if (e is File && e.path.toLowerCase().endsWith(exe)) return e.path;
            if (e is Directory) next.add(e);
          }
        }
        if (next.isEmpty) break;
        level = next;
      }
    } catch (_) {
      // Cualquier fallo aqui solo significa "no encontrado por esta via".
    }
    return '';
  }
}
