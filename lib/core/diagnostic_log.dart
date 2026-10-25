/// Registro de diagnostico en archivo.
///
/// Existe porque hay fallos que solo ocurren en la maquina del DJ y no se pueden
/// reproducir en otro equipo: si el audio no sale al aire, hace falta saber que
/// dispositivo se intento abrir, con que argumentos y que respondio el servidor.
///
/// El registro se guarda junto a los perfiles:
/// - Windows: `%APPDATA%\XtremeStudio\registro.log`
/// - Linux/macOS: `~/.xtreme_studio/registro.log`
///
/// Es un archivo de texto que el DJ puede enviar tal cual.
///
/// **Privacidad:** nunca se escriben contrasenas. Las lineas que mencionan
/// credenciales se filtran antes de guardarse.
library;

import 'dart:async';
import 'dart:io';

/// Escribe lineas de diagnostico en un archivo y, si hay consola, tambien en
/// pantalla.
class DiagnosticLog {
  DiagnosticLog._(this._file);

  final File _file;

  static DiagnosticLog? _instance;

  /// Registro activo, o `null` si no se pudo abrir el archivo.
  static DiagnosticLog? get instance => _instance;

  File? get file => _file;

  /// Abre el registro. Si no se puede escribir, se desactiva en silencio: un
  /// problema de permisos no debe impedir emitir.
  ///
  /// La escritura se hace de forma **sincrona** a proposito. Con `openWrite` el
  /// fallo llega despues, en una tarea de fondo, y una excepcion no capturada
  /// en un `IOSink` **tumba la aplicacion**. Sincrono y con try/catch, un
  /// problema de permisos solo significa "no hay registro".
  static Future<DiagnosticLog?> open({String? directory}) async {
    if (_instance != null) return _instance;
    try {
      final dir = directory ?? _defaultDirectory();
      final d = Directory(dir);
      if (!d.existsSync()) await d.create(recursive: true);
      final f = File('${d.path}${Platform.pathSeparator}registro.log');

      // Si el archivo crece demasiado, se rota para no llenar el disco.
      if (f.existsSync() && f.lengthSync() > 512 * 1024) {
        final backup = File('${f.path}.1');
        if (backup.existsSync()) backup.deleteSync();
        f.renameSync(backup.path);
      }

      // Prueba real de escritura: si falla, no se activa el registro.
      f.writeAsStringSync('', mode: FileMode.append, flush: true);

      final log = DiagnosticLog._(f);
      _instance = log;
      log.write('sesion', 'Xtreme Studio: nueva sesion');
      return log;
    } catch (_) {
      // Sin registro se sigue funcionando: nunca es un fallo critico.
      return null;
    }
  }

  static String _defaultDirectory() {
    final env = Platform.environment;
    if (Platform.isWindows) {
      final appData = env['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        return '$appData\\XtremeStudio';
      }
    }
    final home = env['HOME'] ?? Directory.current.path;
    return '$home${Platform.pathSeparator}.xtreme_studio';
  }

  /// Escribe una linea con marca de tiempo.
  ///
  /// **Nunca lanza**: si el registro falla (permisos, disco lleno, archivo
  /// bloqueado), la emision debe seguir funcionando igual.
  void write(String category, String message) {
    try {
      final now = DateTime.now();
      final stamp =
          '${now.year}-${_two(now.month)}-${_two(now.day)} '
          '${_two(now.hour)}:${_two(now.minute)}:${_two(now.second)}';
      final safe = _redact(message);
      final line = '[$stamp] [$category] $safe';

      // Se escribe sincronicamente para que cualquier fallo se pueda capturar
      // aqui mismo.
      _file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // Silencio deliberado: el registro es una ayuda, no un requisito.
      // Si falla de forma persistente, se desactiva para no intentar en cada
      // linea.
      _failedWrites++;
      if (_failedWrites > 20) _instance = null;
    }
  }

  int _failedWrites = 0;

  /// Sustituye cualquier contrasena que aparezca en el texto.
  ///
  /// Se aplica a todo, no solo a las lineas de conexion: asi un mensaje de error
  /// que incluya la credencial tampoco la filtra al archivo.
  ///
  /// Nota: se usa `caseSensitive: false` en lugar de `(?i)` porque Dart **no**
  /// admite modificadores en linea al inicio del patron: `(?i)` lanza
  /// `FormatException: Invalid group`. Ese error, dentro del registro, tumbaba
  /// la aplicacion entera.
  static String _redact(String text) => redactSecrets(text);

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// Cierra el registro. Al escribir de forma sincrona no hay nada que volcar,
  /// pero se mantiene el metodo para poder usarlo desde `dispose`.
  Future<void> close() async {
    DiagnosticLog._instance = null;
  }
}

/// Oculta cualquier credencial que aparezca en un texto.
///
/// Es publica para poder verificarla: si el filtro fuera incorrecto, las
/// contrasenas quedarian escritas en disco en texto plano, que es exactamente lo
/// que el resto de la aplicacion evita con DPAPI.
///
/// Nota: se usa `caseSensitive: false` en lugar de `(?i)` porque Dart **no**
/// admite modificadores en linea al inicio del patron: `(?i)` lanza
/// `FormatException: Invalid group`. Ese error, dentro del registro, tumbaba la
/// aplicacion entera al arrancar.
String redactSecrets(String text) {
  var result = text;

  // Se oculta desde la palabra clave hasta el final de la linea.
  //
  // Antes se ocultaba solo la primera palabra siguiente, y con
  // `Authorization: Basic <base64>` quedaba a la vista el token en base64, que
  // contiene la contrasena. Ocultar hasta el fin de linea evita ese error.
  result = result.replaceAllMapped(
    RegExp(
      r'(password|contrasena|contraseña|clave|pass|pwd|authorization)(\s*[:=]\s*).*',
      caseSensitive: false,
    ),
    (m) => '${m.group(1)}${m.group(2)}<oculto>',
  );

  // Respaldo por si la cabecera aparece partida en varias lineas.
  result = result.replaceAllMapped(
    RegExp(r'basic\s+[A-Za-z0-9+/=]{8,}', caseSensitive: false),
    (_) => 'Basic <oculto>',
  );
  return result;
}
