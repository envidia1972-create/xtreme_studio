/// Verificacion de la deteccion de tipo de servidor.
///
/// Se prueba contra el hosting real del usuario, que tiene varios puertos: es el
/// caso que motiva la funcion (mismo host, distinto software por puerto).
///
/// Uso: dart run tool/verify_server_detect.dart
library;

import 'dart:io';

import 'package:xtreme_studio/core/net/server_detect.dart';
import 'package:xtreme_studio/core/server_profile.dart';

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

Future<void> main(List<String> args) async {
  stdout.writeln('Verificacion de la deteccion del tipo de servidor');

  // ------------------------------------------------------- casos locales
  section('Casos sin red');

  final sinHost = await detectServer(
    host: '',
    port: 8000,
    expected: ServerProtocol.shoutcast2,
  );
  check(
    sinHost.confidence == DetectionConfidence.ninguna &&
        sinHost.protocol == ServerProtocol.shoutcast2,
    'sin host se conserva el tipo elegido por el DJ',
    detail: sinHost.evidence,
  );

  // Un host que no existe: no debe romper ni cambiar la configuracion.
  final inexistente = await detectServer(
    host: 'host-que-no-existe.invalid',
    port: 8000,
    expected: ServerProtocol.shoutcast1,
    timeout: const Duration(seconds: 4),
  );
  check(
    inexistente.confidence == DetectionConfidence.ninguna &&
        inexistente.protocol == ServerProtocol.shoutcast1,
    'si el servidor no responde se conserva el tipo elegido',
    detail: inexistente.evidence,
  );

  // Un puerto cerrado en un host real.
  final cerrado = await detectServer(
    host: 'a10.asurahosting.com',
    port: 7999,
    expected: ServerProtocol.icecast2,
    timeout: const Duration(seconds: 5),
  );
  check(
    cerrado.confidence == DetectionConfidence.ninguna,
    'un puerto cerrado no produce una deteccion falsa',
    detail: cerrado.evidence,
  );

  // ------------------------------------------------------- servidor real
  if (args.contains('--sin-red')) {
    stdout.writeln('');
    stdout.writeln('(se omiten las pruebas contra el servidor real)');
  } else {
    section('Servidor real del usuario (a10.asurahosting.com)');

    // Cada puerto de este hosting corre un software distinto: es justo el caso
    // que hace fallar a la app cuando el tipo queda en el valor por defecto.
    const casos = <int, ServerProtocol>{
      8000: ServerProtocol.shoutcast2,
      8010: ServerProtocol.icecast2,
      9000: ServerProtocol.icecast2,
      7000: ServerProtocol.icecast2,
    };

    for (final entry in casos.entries) {
      final port = entry.key;
      final esperado = entry.value;

      // A proposito se pasa un tipo INCORRECTO como valor esperado, para
      // comprobar que la deteccion lo corrige.
      final equivocado = esperado == ServerProtocol.icecast2
          ? ServerProtocol.shoutcast2
          : ServerProtocol.icecast2;

      final d = await detectServer(
        host: 'a10.asurahosting.com',
        port: port,
        expected: equivocado,
        timeout: const Duration(seconds: 10),
      );

      stdout.writeln('  puerto $port:');
      stdout.writeln('    detectado : ${d.protocol.shortLabel} '
          '(${d.confidence.name})');
      stdout.writeln('    software  : ${d.serverSoftware ?? "(no identificado)"}');
      stdout.writeln('    evidencia : ${d.evidence}');

      check(
        d.protocol == esperado,
        'el puerto $port se detecta como ${esperado.shortLabel}',
        detail: 'detectado: ${d.protocol.shortLabel}',
      );
      check(
        d.confidence == DetectionConfidence.alta,
        'la deteccion del puerto $port es concluyente',
        detail: d.confidence.name,
      );
      check(
        d.protocol != equivocado,
        'la deteccion corrige un tipo configurado equivocado (puerto $port)',
      );
    }
  }

  stdout.writeln('');
  stdout.writeln('===============================');
  if (_failures.isEmpty) {
    stdout.writeln('DETECCION VERIFICADA: $_passed comprobaciones pasaron');
    exit(0);
  }
  stdout.writeln('$_passed OK, ${_failures.length} FALLARON:');
  for (final f in _failures) {
    stdout.writeln('  - $f');
  }
  exit(1);
}
