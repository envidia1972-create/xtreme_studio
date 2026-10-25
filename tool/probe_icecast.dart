// Prueba de conectividad del nucleo: descubre el endpoint de ingesta correcto
// y verifica que el protocolo Icecast habla bien con el servidor del usuario.
//
// No envia audio: usa `Expect: 100-continue` para que el servidor responda
// SOLO al handshake. Asi no interrumpe a ninguna emision que este al aire.
//
// Uso:
//   XTREME_PROBE_HOST=stream.ejemplo.fm \
//   XTREME_PROBE_MOUNT=/mi-mount \
//   XTREME_PROBE_USER=source \
//   XTREME_PROBE_PASS=... \
//   dart run tool/probe_icecast.dart
//
// La contrasena se lee del entorno a proposito: este archivo se versiona y no
// puede llevar credenciales reales. Sin XTREME_PROBE_PASS solo se prueban los
// handshakes con clave incorrecta.

import 'dart:async';
import 'dart:io';

import 'package:xtreme_studio/core/net/icecast_client.dart';

final host = Platform.environment['XTREME_PROBE_HOST'] ?? 'stream.zeno.fm';
final mount = Platform.environment['XTREME_PROBE_MOUNT'] ?? '/stream';
final goodUser = Platform.environment['XTREME_PROBE_USER'] ?? 'source';
final goodPass = Platform.environment['XTREME_PROBE_PASS'] ?? '';

class Attempt {
  Attempt(this.label, this.host, this.port, this.mount, this.user, this.pass);
  final String label;
  final String host;
  final int port;
  final String mount;
  final String user;
  final String pass;
}

Future<void> tryAttempt(Attempt a) async {
  stdout.write('${a.label.padRight(52)} ');
  final client = IcecastClient(
    host: a.host,
    port: a.port,
    mount: a.mount,
    username: a.user,
    password: a.pass,
    iceName: 'Xtreme Studio Probe',
  );
  try {
    await client.connect();
    stdout.writeln('ACEPTADO (handshake OK)');
    // Cerramos de inmediato: no enviamos audio, no rompemos nada.
    await client.close();
  } on IcecastException catch (e) {
    stdout.writeln('RECHAZADO -> ${e.message}'
        '${e.statusCode != null ? ' [HTTP ${e.statusCode}]' : ''}');
    await client.close();
  } catch (e) {
    stdout.writeln('ERROR -> $e');
    await client.close();
  }
}

Future<void> main() async {
  stdout.writeln('=== Sonda de ingesta Icecast ===');
  stdout.writeln('Objetivo: $host / mount $mount\n');

  // 1) Verificar que el host resuelve y el puerto abre.
  for (final port in [8000, 80]) {
    stdout.write('TCP $host:$port ... ');
    try {
      final s = await Socket.connect(host, port,
          timeout: const Duration(seconds: 8));
      stdout.writeln('abierto (local ${s.address.address}:${s.port})');
      s.destroy();
    } catch (e) {
      stdout.writeln('fallo: $e');
    }
  }
  stdout.writeln('');

  // 2) Probar el handshake con credenciales invalidas y, si se paso la clave
  // por el entorno, tambien con las validas.
  final attempts = <Attempt>[
    Attempt('A. /source en :8000 con clave MALA', host, 8000, '$mount/source',
        goodUser, 'clave-incorrecta'),
    Attempt('B. $mount en :8000 con clave MALA', host, 8000, mount, goodUser,
        'clave-incorrecta'),
    if (goodPass.isNotEmpty) ...[
      Attempt('C. /source en :8000 con clave BUENA', host, 8000,
          '$mount/source', goodUser, goodPass),
      Attempt('D. $mount en :8000 con clave BUENA', host, 8000, mount, goodUser,
          goodPass),
      Attempt('E. $mount en :80 con clave BUENA', host, 80, mount, goodUser,
          goodPass),
    ],
  ];
  if (goodPass.isEmpty) {
    stdout.writeln('(sin XTREME_PROBE_PASS: se omiten las pruebas con clave '
        'valida)\n');
  }

  for (final a in attempts) {
    await tryAttempt(a);
  }

  stdout.writeln('\nNota: un RECHAZADO por clave mala demuestra que el mount');
  stdout.writeln('existe; un ACEPTADO confirma el endpoint correcto.');
  exit(0);
}
