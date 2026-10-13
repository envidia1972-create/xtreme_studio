/// Sonda contra el servidor REAL del usuario, desde el lado del oyente.
///
/// Solo lee: pregunta por el mount igual que un reproductor y descarta el
/// cuerpo. No envia audio, no abre una fuente y por lo tanto **no desplaza a
/// ningun DJ** que este al aire.
///
/// Uso: dart run tool/probe_signal.dart
library;

import 'dart:io';

import 'package:xtreme_studio/core/net/stream_health.dart';
import 'package:xtreme_studio/core/server_profile.dart';

Future<void> main() async {
  stdout.writeln('=== Sonda de senal (solo lectura) ===');
  stdout.writeln('No se envia audio: no se interrumpe a nadie.\n');

  final casos = <(String, ServerProfile)>[
    (
      'Zeno.fm - emisora del usuario (link.zeno.fm)',
      ServerProfile(
        id: 'zeno-link',
        name: 'LatinSound 507',
        host: 'link.zeno.fm',
        port: 80,
        mount: '/5tmrzbywtzzuv',
        username: 'source',
        password: 'no-se-usa-aqui',
      ),
    ),
    (
      'Zeno.fm - host de escucha directo (stream.zeno.fm)',
      ServerProfile(
        id: 'zeno-stream',
        name: 'LatinSound 507',
        host: 'stream.zeno.fm',
        port: 80,
        mount: '/5tmrzbywtzzuv',
        username: 'source',
        password: 'no-se-usa-aqui',
      ),
    ),
    (
      'Mount inexistente (debe decir "sin fuente")',
      ServerProfile(
        id: 'zeno-404',
        name: 'Prueba',
        host: 'stream.zeno.fm',
        port: 80,
        mount: '/este-mount-no-existe-xyz',
        username: 'source',
        password: 'x',
      ),
    ),
  ];

  for (final (label, profile) in casos) {
    stdout.writeln('--- $label');
    final monitor = StreamHealthMonitor(
      profile: profile,
      timeout: const Duration(seconds: 12),
    );
    stdout.writeln('    URL: ${monitor.resolveListenerUrl()}');
    final result = await monitor.check();
    stdout.writeln('    estado: ${result.status.name} (${result.status.label})');
    if (result.statusCode != null) {
      stdout.writeln('    HTTP: ${result.statusCode}');
    }
    if (result.contentType != null && result.contentType!.isNotEmpty) {
      stdout.writeln('    content-type: ${result.contentType}');
    }
    stdout.writeln('    mensaje: ${result.message}');
    stdout.writeln('    es problema?: ${result.status.isProblem}');
    stdout.writeln('');
    monitor.dispose();
  }

  exit(0);
}
