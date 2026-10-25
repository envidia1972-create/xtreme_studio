/// Prueba de publicacion contra el servidor real del usuario.
///
/// **No envia audio**: usa `Expect: 100-continue` (Icecast) o el handshake
/// (SHOUTcast), de modo que el servidor responde ANTES de recibir un solo byte.
/// Asi se valida la autenticacion sin desplazar al Auto DJ.
///
/// Uso: dart run tool/probe_asura.dart
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Las credenciales se leen del entorno: este archivo se versiona.
final host = Platform.environment['ASURA_HOST'] ?? 'a10.asurahosting.com';
final user = Platform.environment['ASURA_USER'] ?? 'source';
final pass = Platform.environment['ASURA_PASS'] ?? '';

/// Resultado de un intento.
class Attempt {
  Attempt(this.label, this.detail);
  final String label;
  final String detail;
  final bool ok = false;
}

/// Intenta publicar en Icecast con `PUT /` y Expect: 100-continue.
Future<String> tryIcecast(int port) async {
  try {
    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 10),
    );
    socket.setOption(SocketOption.tcpNoDelay, true);

    final auth = base64Encode('$user:$pass'.codeUnits);
    socket.write(
      'PUT / HTTP/1.1\r\n'
      'Host: $host:$port\r\n'
      'Authorization: Basic $auth\r\n'
      'User-Agent: XtremeStudio/0.1\r\n'
      'Content-Type: audio/mpeg\r\n'
      'Expect: 100-continue\r\n'
      'ice-name: Prueba Xtreme Studio\r\n'
      'Connection: close\r\n\r\n',
    );
    await socket.flush();

    // Se lee la respuesta del handshake, sin enviar audio.
    final chunks = <int>[];
    final completer = Completer<String>();
    late StreamSubscription<List<int>> sub;
    sub = socket.listen(
      (d) {
        chunks.addAll(d);
        final t = String.fromCharCodes(chunks);
        if (t.contains('\r\n\r\n') && !completer.isCompleted) {
          completer.complete(t);
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.complete('ERROR: $e');
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(String.fromCharCodes(chunks));
        }
      },
      cancelOnError: false,
    );

    final response = await completer.future.timeout(
      const Duration(seconds: 12),
      onTimeout: () => 'SIN RESPUESTA en 12 s',
    );
    await sub.cancel();
    socket.destroy();

    final firstLine = response.split(RegExp(r'\r?\n')).first;
    return firstLine;
  } catch (e) {
    return 'ERROR: $e';
  }
}

/// Intenta el handshake de SHOUTcast v1 (`password:#1`).
Future<String> tryShoutcastV1(int port) async {
  try {
    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 10),
    );
    socket.setOption(SocketOption.tcpNoDelay, true);
    socket.write(
      '$pass:#1\r\n'
      'icy-name:Prueba Xtreme Studio\r\n'
      'icy-genre:Variado\r\n'
      'icy-br:128\r\n'
      'icy-pub:0\r\n\r\n',
    );
    await socket.flush();

    final chunks = <int>[];
    final completer = Completer<String>();
    late StreamSubscription<List<int>> sub;
    sub = socket.listen(
      (d) {
        chunks.addAll(d);
        if (chunks.contains(10) && !completer.isCompleted) {
          completer.complete(String.fromCharCodes(chunks));
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.complete('ERROR: $e');
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(
            String.fromCharCodes(chunks).isEmpty
                ? '(cerro sin responder)'
                : String.fromCharCodes(chunks),
          );
        }
      },
      cancelOnError: false,
    );

    final response = await completer.future.timeout(
      const Duration(seconds: 12),
      onTimeout: () => 'SIN RESPUESTA en 12 s',
    );
    await sub.cancel();
    socket.destroy();
    return response.split(RegExp(r'\r?\n')).first.trim();
  } catch (e) {
    return 'ERROR: $e';
  }
}

/// Intenta el handshake de SHOUTcast v2 (`usuario:password` + sid).
Future<String> tryShoutcastV2(int port) async {
  try {
    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 10),
    );
    socket.setOption(SocketOption.tcpNoDelay, true);
    socket.write(
      '$user:$pass\r\n'
      'icy-name:Prueba Xtreme Studio\r\n'
      'icy-genre:Variado\r\n'
      'icy-br:128\r\n'
      'icy-pub:0\r\n'
      'content-type:audio/mpeg\r\n'
      'sid:1\r\n\r\n',
    );
    await socket.flush();

    final chunks = <int>[];
    final completer = Completer<String>();
    late StreamSubscription<List<int>> sub;
    sub = socket.listen(
      (d) {
        chunks.addAll(d);
        if (chunks.contains(10) && !completer.isCompleted) {
          completer.complete(String.fromCharCodes(chunks));
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.complete('ERROR: $e');
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(
            String.fromCharCodes(chunks).isEmpty
                ? '(cerro sin responder)'
                : String.fromCharCodes(chunks),
          );
        }
      },
      cancelOnError: false,
    );

    final response = await completer.future.timeout(
      const Duration(seconds: 12),
      onTimeout: () => 'SIN RESPUESTA en 12 s',
    );
    await sub.cancel();
    socket.destroy();
    return response.split(RegExp(r'\r?\n')).first.trim();
  } catch (e) {
    return 'ERROR: $e';
  }
}

Future<void> main() async {
  stdout.writeln('=== Prueba de publicacion en $host ===');
  stdout.writeln('Usuario: $user');
  stdout.writeln('NO se envia audio: se valida solo el handshake.');
  stdout.writeln('');

  for (final port in [8885, 8886]) {
    stdout.writeln('---------- PUERTO $port ----------');
    final icecast = await tryIcecast(port);
    stdout.writeln('  Icecast 2 (PUT /)      -> $icecast');

    final sc1 = await tryShoutcastV1(port);
    stdout.writeln('  Shoutcast v1 (pass#1)  -> $sc1');

    final sc2 = await tryShoutcastV2(port);
    stdout.writeln('  Shoutcast v2 (user)    -> $sc2');
    stdout.writeln('');
  }

  stdout.writeln('Interpretacion:');
  stdout.writeln('  "100 Continue" o "200"  = credenciales correctas');
  stdout.writeln('  "401"                   = usuario/contrasena rechazados');
  stdout.writeln('  "OK2"                   = Shoutcast acepto la fuente');
  stdout.writeln('  "Invalid password"      = contrasena rechazada');
}
