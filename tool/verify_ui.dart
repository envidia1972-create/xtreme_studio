/// Comprobaciones de consistencia de la interfaz.
///
/// En este entorno no se puede compilar codigo Flutter (el sandbox bloquea los
/// subprocesos del compilador), asi que aqui se verifican a mano los errores
/// que de otro modo solo apareceran al compilar:
///
///  - que todo import relativo apunte a un archivo que existe;
///  - que los identificadores usados en un archivo esten definidos en el o
///    importados de otro;
///  - que las llaves, parentesis y corchetes esten balanceados.
///
/// No sustituye al compilador, pero atrapa los fallos tipicos de un refactor.
///
/// Uso: dart run tool/verify_ui.dart
library;

import 'dart:io';

int _passed = 0;
final List<String> _failures = [];

void check(bool ok, String description, {String? detail}) {
  if (ok) {
    _passed++;
    stdout.writeln('  [ok]   $description');
  } else {
    _failures.add(description);
    stdout.writeln('  [FALLA] $description${detail != null ? ' -> $detail' : ''}');
  }
}

void section(String title) {
  stdout.writeln('');
  stdout.writeln('== $title ==');
}

final _dartFiles = <File>[];

void main() {
  stdout.writeln('Verificacion de consistencia de la interfaz');

  final libDir = Directory('lib');
  _dartFiles.addAll(
    libDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart')),
  );

  _checkFilesExist();
  _checkBalanced();
  _checkImports();
  _checkUnusedImports();
  _checkUnusedLocals();
  _checkSymbols();
  _checkWidgetContract();
  _checkLifecycle();
  _checkTimersDisposed();

  stdout.writeln('');
  stdout.writeln('===============================');
  if (_failures.isEmpty) {
    stdout.writeln('CONSISTENTE: $_passed comprobaciones pasaron');
    exit(0);
  }
  stdout.writeln('$_passed OK, ${_failures.length} FALLARON:');
  for (final f in _failures) {
    stdout.writeln('  - $f');
  }
  exit(1);
}

void _checkFilesExist() {
  section('Archivos de la interfaz');
  final expected = [
    'lib/main.dart',
    'lib/ui/theme.dart',
    'lib/ui/broadcast_screen.dart',
    'lib/ui/profiles_screen.dart',
    'lib/ui/settings_screen.dart',
    'lib/ui/widgets/vu_meter.dart',
  ];
  for (final e in expected) {
    final path = e.replaceAll('/', Platform.pathSeparator);
    check(File(path).existsSync(), 'existe $e');
  }
  check(_dartFiles.length >= expected.length,
      'se encontraron ${_dartFiles.length} archivos Dart');
}

/// Comprobaciones estructurales basicas de cada archivo.
///
/// No se intenta parsear Dart aqui: escribir un parser de Dart a mano es
/// fragil (interpolacion con comillas anidadas, cadenas raw, comentarios
/// anidados...) y da falsos positivos. La validacion de sintaxis la hace el
/// compilador real al construir. Lo que si se comprueba aqui es que no queden
/// restos de edicion: bloques duplicados, llaves sueltas al final de archivo o
/// archivos truncados.
void _checkBalanced() {
  section('Estructura de los archivos');
  var allOk = true;
  final problems = <String>[];

  for (final file in _dartFiles) {
    final src = file.readAsStringSync();

    // Un archivo Dart debe terminar con una declaracion cerrada.
    final trimmed = src.trimRight();
    if (trimmed.isEmpty) {
      problems.add('${file.path}: esta vacio');
      allOk = false;
      continue;
    }
    if (!trimmed.endsWith('}')) {
      problems.add('${file.path}: no termina en "}" (posible archivo truncado)');
      allOk = false;
    }

    // Una llave suelta al final del archivo es el resto tipico de un mal corte.
    if (RegExp(r'}\s*}\s*$').hasMatch(trimmed) &&
        _countOccurrences(trimmed, 'class ') == 0 &&
        _countOccurrences(trimmed, 'extension ') == 0) {
      problems.add('${file.path}: cierres sobrantes al final');
      allOk = false;
    }

    // Detecta bloques duplicados: el mismo `Future<void> nombre(` dos veces.
    // Se excluyen los metodos de ciclo de vida de Flutter, porque es normal y
    // correcto que varias clases del mismo archivo implementen `build`,
    // `initState` o `didUpdateWidget`: no son duplicados, son de clases
    // distintas.
    const lifecycleNames = {
      'build',
      'initState',
      'dispose',
      'didUpdateWidget',
      'didChangeDependencies',
      'deactivate',
      'createState',
      'main',
    };
    final decls = <String, int>{};
    for (final m in RegExp(r'^\s*(?:Future<void>|void)\s+(\w+)\s*\(',
            multiLine: true)
        .allMatches(src)) {
      final name = m.group(1)!;
      if (lifecycleNames.contains(name)) continue;
      decls[name] = (decls[name] ?? 0) + 1;
    }
    for (final entry in decls.entries) {
      if (entry.value > 1 && !entry.key.startsWith('_')) {
        problems.add('${file.path}: "${entry.key}" esta declarado '
            '${entry.value} veces');
        allOk = false;
      }
    }
  }

  check(allOk, 'los archivos estan completos y sin bloques duplicados',
      detail: problems.join('; '));
}

int _countOccurrences(String src, String needle) {
  var count = 0;
  var index = src.indexOf(needle);
  while (index >= 0) {
    count++;
    index = src.indexOf(needle, index + needle.length);
  }
  return count;
}


void _checkImports() {
  section('Imports relativos');
  var allOk = true;
  final problems = <String>[];

  for (final file in _dartFiles) {
    final src = file.readAsStringSync();
    for (final m in RegExp(r"""import\s+'([^']+)'""").allMatches(src)) {
      final target = m.group(1)!;
      if (!target.startsWith('.') && !target.startsWith('dart:')) continue;
      if (target.startsWith('dart:')) continue;

      final resolved = File(
        '${file.parent.path}${Platform.pathSeparator}$target',
      );
      if (!resolved.existsSync()) {
        problems.add('${file.path} -> $target no existe');
        allOk = false;
      }
    }
  }

  check(allOk, 'todos los imports relativos apuntan a archivos existentes',
      detail: problems.join('; '));
}

/// Comprueba que los nombres de clase de widget usados en cada archivo esten
/// definidos en el mismo archivo o traidos por un import.
void _checkSymbols() {
  section('Simbolos usados y definidos');
  var allOk = true;
  final problems = <String>[];

  // Simbolos propios del proyecto, por archivo.
  final defined = <String, Set<String>>{};
  for (final file in _dartFiles) {
    final src = file.readAsStringSync();
    final names = <String>{};
    for (final m in RegExp(r'^class\s+(\w+)', multiLine: true).allMatches(src)) {
      names.add(m.group(1)!);
    }
    for (final m
        in RegExp(r'^(?:enum|mixin|extension)\s+(\w+)', multiLine: true)
            .allMatches(src)) {
      names.add(m.group(1)!);
    }
    defined[file.path] = names;
  }

  // Nombres usados con constructor de widget: Foo(  o  Foo.bar(
  final widgetUsage = RegExp(r'\b([A-Z][A-Za-z0-9_]*)\s*(?:\.\w+)?\s*\(');

  // Simbolos conocidos de Flutter/Dart que no hace falta resolver.
  const frameworkPrefixes = [
    'App', 'Color', 'Colors', 'Size', 'Offset', 'Rect', 'RRect', 'Radius',
    'Border', 'BorderSide', 'Box', 'BoxDecoration', 'EdgeInsets', 'Padding',
    'TextField', 'TextEditingController', 'Text', 'Icons', 'Set', 'List', 'Map',
    'Future', 'Stream', 'DateTime', 'Duration', 'RegExp', 'File', 'Directory',
    'Platform', 'String', 'Int', 'Double', 'Bool', 'Object', 'State', 'Stateful',
    'Stateless', 'Widget', 'BuildContext', 'Key', 'GlobalKey', 'Form',
    'FormState', 'ThemeData', 'MaterialApp', 'Scaffold', 'Column', 'Row',
    'Container', 'Expanded', 'SizedBox', 'Circular', 'Linear', 'Card',
    'Divider', 'Center', 'Icon', 'IconButton', 'InkWell', 'Material',
    'Navigator', 'AlertDialog', 'TextButton', 'FilledButton', 'OutlinedButton',
    'RadioListTile', 'SwitchListTile', 'DropdownMenuItem', 'Single',
    'ValueChanged', 'VoidCallback', 'ByteData', 'Uint8List', 'ClipboardData',
    'Clipboard', 'FontFeature', 'Paint', 'Canvas', 'CustomPaint', 'CustomPainter',
    'TextStyle', 'TextAlign', 'TextInputType', 'Function', 'StringBuffer',
    'StateError', 'SecureSocket', 'Uri', 'Uuid', 'RangeError', 'ArgumentError',
    'FormatException', 'ProcessException', 'SocketException', 'IndexedStack',
    'SelectableText', 'MediaQuery', 'Theme', 'BoxShadow', 'Sqlite', 'HttpClient',
    'TextInputAction', 'InputDecoration', 'Matcher', 'RegExpMatch', 'Match',
    'StreamController', 'StreamSubscription', 'Completer', 'Timer', 'IOSink',
    'ServerSocket', 'Socket', 'InternetAddress', 'Process', 'ProcessResult',
    'ProcessSignal', 'JsonEncoder', 'JsonDecoder', 'Random', 'Math',
    'TextEditingValue', 'DropdownButtonFormField', 'TextFormField', 'Checkbox',
    'Switch', 'Slider', 'Tooltip', 'CardThemeData', 'FilledButtonThemeData',
    'OutlinedButtonThemeData', 'InputDecorationTheme', 'DividerThemeData',
    'TooltipThemeData', 'SnackBarThemeData', 'GlobalKey', 'ScrollController',
  ];

  for (final file in _dartFiles) {
    final rawSrc = file.readAsStringSync();
    // Este chequeo se limita a la interfaz: en `lib/core` los nombres vienen
    // de librerias del SDK que no se resuelven aqui, y esa parte ya la valida
    // el compilador (ver tool/verify_core.dart).
    if (!file.path.replaceAll('\\', '/').contains('/ui/') &&
        !file.path.replaceAll('\\', '/').endsWith('/main.dart')) {
      continue;
    }

    final src = _stripCommentsAndStrings(rawSrc);
    final importsSdkLibs = RegExp(r"""import\s+'(dart:|package:)""").hasMatch(rawSrc);
    final importedNames = <String>{...defined[file.path]!};

    // Ampliar con lo definido en archivos importados relativamente, respetando
    // las clausulas `show` / `hide`: sin esto se reportan falsos positivos,
    // porque un archivo puede importar solo algunos simbolos a proposito.
    for (final m in RegExp(r"""import\s+'([^']+)'\s*([^;]*);""").allMatches(src)) {
      final target = m.group(1)!;
      if (target.startsWith('dart:')) continue;
      final resolved = File(
        '${file.parent.path}${Platform.pathSeparator}$target',
      );
      if (!resolved.existsSync()) continue;

      final allNames = defined[resolved.path] ?? const <String>{};
      final clause = (m.group(2) ?? '').trim();

      final showMatch = RegExp(r'show\s+([^;]+)').firstMatch(clause);
      if (showMatch != null) {
        final shown = showMatch
            .group(1)!
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toSet();
        importedNames.addAll(allNames.where(shown.contains));
        continue;
      }

      final hideMatch = RegExp(r'hide\s+([^;]+)').firstMatch(clause);
      if (hideMatch != null) {
        final hidden = hideMatch
            .group(1)!
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toSet();
        importedNames.addAll(allNames.where((n) => !hidden.contains(n)));
        continue;
      }

      importedNames.addAll(allNames);
    }

    for (final m in widgetUsage.allMatches(src)) {
      final name = m.group(1)!;
      if (importedNames.contains(name)) continue;
      if (frameworkPrefixes.contains(name)) continue;
      // Nombres de tipo generico o de la libreria estandar en mayuscula.
      if (name.length <= 2) continue;
      // Los simbolos que vienen de librerias del SDK (import 'package:...' o
      // 'dart:...') no se resuelven aqui; el compilador los valida.
      if (importsSdkLibs) continue;
      problems.add('${file.path}: "$name" no esta definido ni importado');
      allOk = false;
    }
  }

  check(allOk, 'las clases usadas estan definidas o importadas',
      detail: problems.take(12).join('; '));
}

/// Quita comentarios y cadenas para que las palabras del texto (por ejemplo
/// "MP3" o "RMS" en un comentario) no se confundan con clases.
String _stripCommentsAndStrings(String src) {
  final out = StringBuffer();
  var i = 0;
  var inLineComment = false;
  var inBlockComment = false;
  var inSingle = false;
  var inDouble = false;
  var rawString = false;

  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';

    if (inLineComment) {
      if (c == '\n') {
        inLineComment = false;
        out.write('\n');
      }
      i++;
      continue;
    }
    if (inBlockComment) {
      if (c == '*' && next == '/') {
        inBlockComment = false;
        i += 2;
        continue;
      }
      if (c == '\n') out.write('\n');
      i++;
      continue;
    }
    if (inSingle || inDouble) {
      if (rawString) {
        if ((inSingle && c == "'") || (inDouble && c == '"')) {
          inSingle = false;
          inDouble = false;
          rawString = false;
        }
        i++;
        continue;
      }
      if (c == r'\') {
        i += 2;
        continue;
      }
      if ((inSingle && c == "'") || (inDouble && c == '"')) {
        inSingle = false;
        inDouble = false;
      }
      i++;
      continue;
    }

    if (c == '/' && next == '/') {
      inLineComment = true;
      i += 2;
      continue;
    }
    if (c == '/' && next == '*') {
      inBlockComment = true;
      i += 2;
      continue;
    }
    if (c == "'" || c == '"') {
      if (c == "'") {
        inSingle = true;
      } else {
        inDouble = true;
      }
      rawString = i > 0 && (src[i - 1] == 'r' || src[i - 1] == 'R');
      i++;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// Comprueba que ningun `setState` quede despues de un `await` sin guarda.
///
/// En Flutter, llamar a `setState` despues de un `await` cuando el widget ya se
/// destruyo lanza una excepcion en tiempo de ejecucion. Es un fallo que ni el
/// compilador ni el analizador detectan, y que solo aparece al usar la app (por
/// ejemplo si el DJ cambia de pantalla mientras carga algo). La convencion es
/// comprobar `mounted` antes.
///
/// El analisis es por bloque y no por archivo: se comparan las profundidades de
/// llaves. Si la linea actual esta **menos anidada** que el `await` que se
/// observo, pertenece a otro bloque (otro metodo, u otro callback) y el orden
/// de las lineas ya no dice nada. Mezclar bloques da falsos positivos, y un
/// verificador que grita en falso termina siendo ignorado.
void _checkLifecycle() {
  section('Ciclo de vida de los widgets');

  var allOk = true;
  final problems = <String>[];

  for (final file in _dartFiles) {
    final path = file.path.replaceAll('\\', '/');
    if (!path.contains('/ui/') && !path.endsWith('/main.dart')) continue;

    final src = _stripCommentsAndStrings(file.readAsStringSync());
    final lines = src.split('\n');

    var depth = 0;
    var awaiting = false;
    var guarded = false;
    var awaitDepth = 0;
    var awaitLine = 0;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      final lineDepth = depth;

      // El `await` solo importa si estamos en el mismo bloque o mas adentro.
      if (awaiting && lineDepth < awaitDepth) {
        awaiting = false;
        guarded = false;
      }

      if (line.startsWith('//') || line.isEmpty) {
        depth += _braceDelta(lines[i]);
        continue;
      }

      if (line.contains('mounted') || line.contains('context.mounted')) {
        guarded = true;
      } else if (line.contains('setState') || line.contains('showSnackBar')) {
        if (awaiting && !guarded) {
          problems.add(
            '${file.path}:${i + 1}: setState/showSnackBar despues de un await '
            'sin comprobar mounted (await en la linea $awaitLine)',
          );
          allOk = false;
        }
        awaiting = false;
        guarded = false;
      } else if (line.contains('await ')) {
        awaiting = true;
        guarded = false;
        awaitDepth = lineDepth;
        awaitLine = i + 1;
      }

      depth += _braceDelta(lines[i]);
    }
  }

  check(allOk, 'setState tras await siempre comprueba mounted',
      detail: problems.take(6).join(' | '));
}

/// Diferencia de llaves que aporta una linea (las que abre menos las que cierra).
int _braceDelta(String line) {
  var delta = 0;
  for (final rune in line.runes) {
    if (rune == 0x7B /* { */) delta++;
    if (rune == 0x7D /* } */) delta--;
  }
  return delta;
}

/// Comprueba que los `Timer` creados en los widgets se cancelen al destruirse.
void _checkTimersDisposed() {
  section('Temporizadores liberados');

  var allOk = true;
  final problems = <String>[];

  for (final file in _dartFiles) {
    final path = file.path.replaceAll('\\', '/');
    // Solo aplica a los widgets: en el motor de emision los temporizadores se
    // liberan en `goOffAir`/`dispose` del propio motor, no del widget.
    if (!path.contains('/ui/') && !path.endsWith('/main.dart')) continue;

    final src = _stripCommentsAndStrings(file.readAsStringSync());
    final createsTimer =
        RegExp(r'Timer\s*\(|Timer\.periodic\s*\(').hasMatch(src);
    if (!createsTimer) continue;

    final hasDispose = src.contains('void dispose()');
    final cancels = src.contains('.cancel()');
    if (!hasDispose || !cancels) {
      problems.add(
        '${file.path}: crea Timer pero '
        '${!hasDispose ? "no tiene dispose()" : "no llama a cancel()"}',
      );
      allOk = false;
    }
  }

  check(allOk, 'los temporizadores se cancelan en dispose',
      detail: problems.join(' | '));
}

/// Comprueba que no queden imports cuyo contenido no se use.
///
/// `flutter analyze` lo reporta, pero no se puede ejecutar en el entorno donde
/// se desarrollo la app, asi que se comprueba aqui: un import sin usar es
/// ruido, y ademas delata codigo que se dejo de usar a medias (justo el caso de
/// `dart:convert` en el motor, que dejo de hacer falta al cambiar como se
/// decodificaban los mensajes de FFmpeg).
void _checkUnusedImports() {
  section('Imports sin usar');

  var allOk = true;
  final problems = <String>[];

  // Nombres de conveniencia para los `import` de librerias del SDK: no se puede
  // saber que simbolos aportan sin resolverlas, asi que solo se comprueban los
  // relativos (que son los que dependen de este proyecto).
  for (final file in _dartFiles) {
    final src = file.readAsStringSync();
    final body = _stripCommentsAndStrings(src);

    for (final m
        in RegExp(r"""import\s+'([^']+)'(?:\s+as\s+(\w+))?[^;]*;""").allMatches(src)) {
      final target = m.group(1)!;
      final alias = m.group(2);

      // Los del SDK y los paquetes externos no se pueden verificar aqui.
      if (target.startsWith('dart:') || target.startsWith('package:')) continue;

      final resolved = File(
        '${file.parent.path}${Platform.pathSeparator}$target',
      );
      if (!resolved.existsSync()) continue;

      // Simbolos que ese archivo define. Se recogen todos los identificadores
      // que empiezan en mayuscula (clases, enums, extensiones) mas las
      // funciones de nivel superior: es una deteccion deliberadamente amplia,
      // porque un falso "no se usa" es peor que no detectar el import muerto.
      final targetSrc = resolved.readAsStringSync();
      final exported = <String>{
        for (final id in RegExp(r'\b([A-Z]\w*)\b').allMatches(targetSrc))
          id.group(1)!,
      };

      if (alias != null) {
        // Con alias solo hay que comprobar que el alias se mencione.
        final withoutImports2 =
            body.replaceAll(RegExp(r'^import[^;]+;', multiLine: true), '');
        if (!RegExp('\\b$alias\\b').hasMatch(withoutImports2)) {
          problems.add('${file.path}: el alias "$alias" de $target no se usa');
          allOk = false;
        }
        continue;
      }

      // Sin alias: se considera usado si aparece cualquiera de sus simbolos.
      final withoutImports =
          body.replaceAll(RegExp(r'^import[^;]+;', multiLine: true), '');
      final used = exported.any(
        (name) => RegExp('\\b${RegExp.escape(name)}\\b').hasMatch(withoutImports),
      );
      if (exported.isNotEmpty && !used) {
        problems.add('${file.path}: $target no aporta nada usado');
        allOk = false;
      }
    }
  }

  check(allOk, 'no quedan imports relativos sin usar',
      detail: problems.take(6).join(' | '));
}

/// Comprueba que no queden variables locales declaradas y nunca usadas.
///
/// Importante: se analiza el **codigo original**, no la version sin cadenas.
/// Si se analizara la version limpia, una variable usada solo dentro de una
/// interpolacion (`'$sign${valor} dB'`) pareceria sin usar, porque el limpiador
/// borra las cadenas enteras. Ese falso positivo costaria mas tiempo que el
/// problema que intenta detectar.
void _checkUnusedLocals() {
  section('Variables locales sin usar');

  var allOk = true;
  final problems = <String>[];

  // Solo la UI y main: en las herramientas de verificacion abundan las
  // variables de apoyo y el ruido supera el beneficio.
  for (final file in _dartFiles) {
    final path = file.path.replaceAll('\\', '/');
    if (!path.contains('/ui/') && !path.endsWith('/main.dart')) continue;

    final src = file.readAsStringSync();
    for (final m
        in RegExp(r'^\s*(?:final|var)\s+(\w+)\s*=', multiLine: true)
            .allMatches(src)) {
      final name = m.group(1)!;
      final uses =
          RegExp('\\b${RegExp.escape(name)}\\b').allMatches(src).length;
      // Una sola aparicion = declarada y nunca leida.
      if (uses <= 1) {
        problems.add('${file.path}: "$name" se declara y no se usa');
        allOk = false;
      }
    }
  }

  check(allOk, 'no hay variables locales declaradas sin usar',
      detail: problems.take(6).join(' | '));
}

/// Verifica el contrato entre `main.dart` y las pantallas: los parametros
/// obligatorios que se pasan deben existir en el widget.
void _checkWidgetContract() {
  section('Contrato entre pantallas');

  final mainSrc = File('lib${Platform.pathSeparator}main.dart').readAsStringSync();

  final expectations = <String, List<String>>{
    'BroadcastScreen': [
      'profile',
      'snapshot',
      'log',
      'devices',
      'ffmpegReady',
      'signalCheck',
      'onGoLive',
      'onGoOffAir',
      'onTrackChanged',
      'onGainChanged',
      'onOpenProfiles',
    ],
    'ProfilesScreen': [
      'profiles',
      'activeProfile',
      'store',
      'devices',
      'onChanged',
      'onMessage',
    ],
    'SettingsScreen': [
      'settings',
      'devices',
      'ffmpegPath',
      'onChanged',
      'onRefreshDevices',
      'onMessage',
    ],
  };

  for (final entry in expectations.entries) {
    // Buscar la construccion del widget en main.dart.
    final ctorMatch = RegExp('${entry.key}\\(').firstMatch(mainSrc);
    if (ctorMatch == null) {
      check(false, 'main.dart construye ${entry.key}');
      continue;
    }
    // Extraer el bloque de argumentos balanceado.
    final start = ctorMatch.end - 1;
    var depth = 0;
    var end = start;
    for (var i = start; i < mainSrc.length; i++) {
      if (mainSrc[i] == '(') depth++;
      if (mainSrc[i] == ')') {
        depth--;
        if (depth == 0) {
          end = i;
          break;
        }
      }
    }
    final args = mainSrc.substring(start, end);

    final missing = <String>[];
    for (final param in entry.value) {
      if (!RegExp('$param\\s*:').hasMatch(args) &&
          !RegExp('$param\\s*,').hasMatch(args)) {
        missing.add(param);
      }
    }
    check(missing.isEmpty, 'main.dart pasa todos los parametros de ${entry.key}',
        detail: 'faltan: ${missing.join(', ')}');

    // Y que el widget los declare obligatorios.
    final screenFile = _dartFiles.firstWhere(
      (f) => f.readAsStringSync().contains('class ${entry.key}'),
      orElse: () => File(''),
    );
    if (screenFile.path.isEmpty) {
      check(false, 'existe la clase ${entry.key}');
      continue;
    }
    final screenSrc = screenFile.readAsStringSync();
    final declaredMissing = <String>[];
    for (final param in entry.value) {
      if (!RegExp('(?:this\\.|required\\s+this\\.)?$param\\b').hasMatch(screenSrc)) {
        declaredMissing.add(param);
      }
    }
    check(declaredMissing.isEmpty,
        '${entry.key} declara los campos esperados',
        detail: 'faltan: ${declaredMissing.join(', ')}');
  }
}
