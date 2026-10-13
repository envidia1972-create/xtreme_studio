/// Comprueba que las llamadas a los widgets internos pasen los argumentos
/// obligatorios que esos widgets declaran.
///
/// Motivo: al agregar un campo `required` a una clase interna
/// (`_LivePanel`, `_TrackPanel`, `_GainPanel`...), Dart falla al compilar si
/// alguna llamada no lo pasa. Es un error de tipos que no se ve leyendo el
/// codigo y que `flutter analyze` detecta, pero que en el entorno de desarrollo
/// no se puede ejecutar. Esta comprobacion lo cubre.
///
/// Uso: dart run tool/verify_widget_arguments.dart
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

/// Argumentos obligatorios declarados por una clase interna.
class _WidgetSpec {
  _WidgetSpec(this.name, this.requiredParams);

  final String name;
  final List<String> requiredParams;
}

/// Extrae, para cada clase interna del archivo, los parametros `required this.x`
/// de su constructor.
Map<String, _WidgetSpec> _collectSpecs(String source) {
  final specs = <String, _WidgetSpec>{};

  final classRegex = RegExp(r'class\s+(_[A-Za-z0-9_]+)\s+extends\s+\w+');
  for (final m in classRegex.allMatches(source)) {
    final className = m.group(1)!;
    // Se toma el texto desde la declaracion hasta el final del constructor.
    final rest = source.substring(m.end);
    final ctorStart = rest.indexOf(className);
    if (ctorStart < 0) continue;

    // El constructor termina en `);` a nivel de la firma.
    final ctorEnd = rest.indexOf(');', ctorStart);
    if (ctorEnd < 0) continue;
    final ctor = rest.substring(ctorStart, ctorEnd);

    final required = <String>[];
    for (final r in RegExp(r'required\s+this\.(\w+)').allMatches(ctor)) {
      required.add(r.group(1)!);
    }
    if (required.isNotEmpty) {
      specs[className] = _WidgetSpec(className, required);
    }
  }

  return specs;
}

/// Extrae los nombres de argumentos usados en cada llamada a `className(`.
List<List<String>> _callArguments(String source, String className) {
  final result = <List<String>>[];
  final pattern = RegExp('\\b${RegExp.escape(className)}\\s*\\(');

  for (final m in pattern.allMatches(source)) {
    // Se recorre el bloque de argumentos respetando el anidamiento.
    var depth = 0;
    var end = m.end - 1;
    for (var i = m.end - 1; i < source.length; i++) {
      final c = source[i];
      if (c == '(') depth++;
      if (c == ')') {
        depth--;
        if (depth == 0) {
          end = i;
          break;
        }
      }
    }
    final argsRaw = source.substring(m.end, end);

    // La declaracion del constructor tambien encaja con el patron `Nombre(`,
    // pero su cuerpo contiene `required this.x`: se distingue asi en lugar de
    // mirar el texto anterior, que es fragil.
    if (argsRaw.contains('required this.') || argsRaw.contains('this.')) {
      continue;
    }

    // Se vacian las cadenas de texto: un mensaje como 'sin audio: revisa' se
    // confundiria con un parametro llamado `audio`.
    final args = argsRaw
        .replaceAll(RegExp(r"'[^']*'"), "''")
        .replaceAll(RegExp(r'"[^"]*"'), '""');

    // Argumentos de nivel superior: `nombre:` que no esten dentro de un
    // parentesis o corchete anidado.
    final names = <String>[];
    var nested = 0;
    final buffer = StringBuffer();
    for (var i = 0; i < args.length; i++) {
      final c = args[i];
      if (c == '(' || c == '[' || c == '{') nested++;
      if (c == ')' || c == ']' || c == '}') nested--;
      if (c == ':' && nested == 0) {
        final name = buffer.toString().trim();
        final wordMatch = RegExp(r'(\w+)$').firstMatch(name);
        if (wordMatch != null) names.add(wordMatch.group(1)!);
        buffer.clear();
        continue;
      }
      if (c == ',' && nested == 0) {
        buffer.clear();
        continue;
      }
      if (c != '\n') buffer.write(c);
    }
    result.add(names);
  }

  return result;
}

/// Campos declarados por una clase interna, con su cuerpo completo.
///
/// Extrae los nombres de los campos (`final Tipo nombre;` y `Tipo nombre;`)
/// para poder comprobar tambien los argumentos **de mas**: pasar un parametro
/// que la clase no declara es un error de compilacion, y es un descuido tan
/// facil como omitir uno obligatorio.
Map<String, Set<String>> _collectFields(String source) {
  final result = <String, Set<String>>{};

  final classRegex = RegExp(r'class\s+(_[A-Za-z0-9_]+)\s+extends\s+\w+\s*\{');
  for (final m in classRegex.allMatches(source)) {
    final className = m.group(1)!;
    // Cuerpo de la clase: desde la llave inicial hasta su cierre.
    var depth = 0;
    var end = m.end - 1;
    for (var i = m.end - 1; i < source.length; i++) {
      if (source[i] == '{') depth++;
      if (source[i] == '}') {
        depth--;
        if (depth == 0) {
          end = i;
          break;
        }
      }
    }
    final body = source.substring(m.end, end);

    final fields = <String>{};
    // Se buscan las declaraciones de campo al final de una linea, terminadas en
    // `;`. Es mas robusto que intentar describir el tipo: cubre
    // `final Future<void> Function() onToggle;`, `bool compact;`, etc.
    for (final line in body.split('\n')) {
      final trimmed = line.trim();
      if (!trimmed.endsWith(';')) continue;
      if (trimmed.startsWith('//')) continue;
      // El nombre es la ultima palabra antes del `;`.
      final m = RegExp(r'([a-zA-Z_]\w*)\s*;\s*$').firstMatch(trimmed);
      if (m != null) fields.add(m.group(1)!);
    }
    result[className] = fields;
  }

  return result;
}

void main() {
  stdout.writeln('Verificacion de argumentos de los widgets internos');

  final uiDir = Directory('lib${Platform.pathSeparator}ui');
  if (!uiDir.existsSync()) {
    stdout.writeln('No existe lib/ui');
    exit(2);
  }

  final files = uiDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList()
    ..add(File('lib${Platform.pathSeparator}main.dart'));

  var allOk = true;
  final problems = <String>[];

  section('Widgets internos: argumentos obligatorios');

  for (final file in files) {
    if (!file.existsSync()) continue;
    final source = file.readAsStringSync();
    final specs = _collectSpecs(source);
    if (specs.isEmpty) continue;

    final usedNames = <String>{};

    for (final spec in specs.values) {
      final calls = _callArguments(source, spec.name);
      usedNames.add(spec.name);
      for (var i = 0; i < calls.length; i++) {
        final args = calls[i];
        final missing = spec.requiredParams.where((p) => !args.contains(p)).toList();
        if (missing.isNotEmpty) {
          problems.add(
            '${file.path}: ${spec.name} (llamada ${i + 1}) sin '
            '${missing.join(', ')}',
          );
          allOk = false;
        }
      }
    }
  }

  check(allOk, 'todas las llamadas pasan los argumentos obligatorios',
      detail: problems.take(8).join(' | '));

  // ------------------------------------------ argumentos que no existen
  section('Argumentos que el widget no declara');

  var extrasOk = true;
  final extras = <String>[];

  for (final file in files) {
    if (!file.existsSync()) continue;
    final source = file.readAsStringSync();
    final fields = _collectFields(source);
    if (fields.isEmpty) continue;

    for (final entry in fields.entries) {
      final className = entry.key;
      final declared = entry.value;
      if (declared.isEmpty) continue;

      // Los parametros del constructor (required this.x / this.x) son campos
      // validos aunque el regex de campos no los capture.
      final ctorParams = <String>{};
      final ctorMatch = RegExp(
        '${RegExp.escape(className)}\\s*\\(([^)]*)\\)',
      ).firstMatch(source);
      if (ctorMatch != null) {
        for (final p in RegExp(r'this\.(\w+)')
            .allMatches(ctorMatch.group(1) ?? '')) {
          ctorParams.add(p.group(1)!);
        }
      }

      final valid = {...declared, ...ctorParams};

      final calls = _callArguments(source, className);
      for (var i = 0; i < calls.length; i++) {
        for (final arg in calls[i]) {
          // `key:` de un mapa o una etiqueta anidada no es un parametro; solo
          // se revisan los que no existen entre los campos declarados.
          if (!valid.contains(arg)) {
            extras.add('${file.path}: $className recibe "$arg" (llamada ${i + 1})');
            extrasOk = false;
          }
        }
      }
    }
  }

  check(extrasOk, 'ninguna llamada pasa argumentos que el widget no declara',
      detail: extras.take(8).join(' | '));

  // Comprobacion inversa: un widget interno que se define y nunca se usa suele
  // ser resto de un refactor (como paso con las clases de marcador que se
  // quedaron al rehacer el layout).
  section('Widgets internos sin usar');

  var unusedOk = true;
  final unused = <String>[];

  for (final file in files) {
    if (!file.existsSync()) continue;
    final source = file.readAsStringSync();

    // Se revisan TODAS las clases internas, no solo las que tienen parametros
    // obligatorios: al redisenar el layout quedan widgets definidos que ya nadie
    // usa, y eso es codigo muerto que confunde.
    final allClasses = <String>{
      for (final m in RegExp(r'class\s+(_[A-Za-z0-9_]+)\s+extends\s+\w+')
          .allMatches(source))
        m.group(1)!,
    };

    for (final name in allClasses) {
      final calls = _callArguments(source, name);
      // Si existe una clase de estado asociada, el widget esta en uso aunque no
      // se vean llamadas directas en este archivo.
      final hasStateClass = RegExp('State<${RegExp.escape(name)}>')
          .hasMatch(source);
      if (calls.isEmpty && !hasStateClass) {
        unused.add('${file.path}: $name se define y no se usa');
        unusedOk = false;
      }
    }
  }

  check(unusedOk, 'no quedan widgets internos definidos sin usar',
      detail: unused.take(8).join(' | '));

  stdout.writeln('');
  stdout.writeln('===============================');
  if (_failures.isEmpty) {
    stdout.writeln('ARGUMENTOS VERIFICADOS: $_passed comprobaciones pasaron');
    exit(0);
  }
  stdout.writeln('$_passed OK, ${_failures.length} FALLARON:');
  for (final f in _failures) {
    stdout.writeln('  - $f');
  }
  exit(1);
}
