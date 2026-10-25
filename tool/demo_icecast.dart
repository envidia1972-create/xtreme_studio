/// Servidor Icecast minimo para probar la app sin una radio real.
///
/// Acepta la conexion de publicacion (`PUT /mount`), cuenta el audio recibido y
/// responde a la comprobacion de senal (`GET /mount`) como lo haria un oyente.
/// No guarda el audio ni reenvia nada: sirve para ver la app funcionando en
/// local, no para emitir de verdad.
///
/// Uso:
///   dart run tool/demo_icecast.dart [puerto] [mount]
///
/// Ejemplo:
///   dart run tool/demo_icecast.dart 18000 /demo
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Escribe en un socket sin dejar que un cliente que ya se fue tumbe el
/// servidor de pruebas (Broken pipe / Connection reset).
void _safeWrite(Socket socket, String data) {
  try {
    socket.write(data);
  } catch (_) {
    try {
      socket.destroy();
    } catch (_) {}
  }
}

void _safeAdd(Socket socket, List<int> data) {
  try {
    socket.add(data);
  } catch (_) {
    try {
      socket.destroy();
    } catch (_) {}
  }
}

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.tryParse(args[0]) ?? 18000 : 18000;
  final mount = args.length > 1 ? args[1] : '/demo';

  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln(
    'Icecast de prueba escuchando en http://127.0.0.1:$port$mount',
  );
  stdout.writeln('Mount de publicacion: PUT $mount (usuario "source")');
  stdout.writeln('Ctrl+C para terminar.');

  var connections = 0;
  var publishedBytes = 0;
  var publishing = false;

  Timer.periodic(const Duration(seconds: 2), (_) {
    if (publishedBytes > 0) {
      stdout.writeln(
        '  [${DateTime.now().toIso8601String().substring(11, 19)}] '
        'audio recibido: ${(publishedBytes / 1024).toStringAsFixed(1)} KiB '
        '(${publishing ? "al aire" : "sin fuente"})',
      );
    }
  });

  await for (final socket in server) {
    connections++;
    unawaited(socket.done.catchError((Object _) {}));
    final header = <int>[];
    var headersDone = false;
    var isPut = false;
    var bodyBytes = 0;

    socket.listen(
      (data) {
        if (!headersDone) {
          header.addAll(data);
          final text = latin1.decode(header, allowInvalid: true);
          final end = text.indexOf('\r\n\r\n');
          if (end < 0) return;
          headersDone = true;
          final lines = text.substring(0, end).split('\r\n');
          final requestLine = lines.isEmpty ? '' : lines.first;
          isPut =
              requestLine.startsWith('PUT ') ||
              requestLine.startsWith('SOURCE ');
          stdout.writeln('  conexion #$connections: $requestLine');
          if (isPut) {
            publishing = true;
            _safeWrite(socket, 'HTTP/1.1 100 Continue\r\n\r\n');
          } else if (requestLine.contains('/admin/metadata')) {
            // Actualizacion de "suena ahora" por la API de Icecast.
            final uri = Uri.tryParse(requestLine.split(' ').elementAt(1));
            final song = uri?.queryParameters['song'] ?? '';
            stdout.writeln('  metadatos: "$song"');
            _safeWrite(
              socket,
              'HTTP/1.1 200 OK\r\n'
              'Content-Type: text/plain\r\n'
              'Content-Length: 2\r\n'
              'Connection: close\r\n\r\nOK',
            );
            unawaited(socket.flush().then((_) => socket.close()));
            return;
          } else {
            // Comprobacion de senal del monitor: responder como un oyente.
            // El cliente puede cerrar en cuanto lee la cabecera, asi que toda
            // escritura va protegida: un Broken pipe no debe tumbar el servidor
            // de pruebas.
            _safeWrite(
              socket,
              'HTTP/1.1 200 OK\r\n'
              'Content-Type: audio/mpeg\r\n'
              'icy-name: Xtreme Studio Demo\r\n'
              'icy-br: 128\r\n'
              'Accept-Ranges: bytes\r\n'
              'Content-Length: 1\r\n'
              'Connection: close\r\n\r\n',
            );
            _safeAdd(socket, [0xFF]);
            unawaited(
              socket
                  .flush()
                  .then((_) => socket.close())
                  .catchError((Object _) => socket.destroy()),
            );
            return;
          }
          final rest = data.sublist(end + 4);
          bodyBytes += rest.length;
          publishedBytes += rest.length;
        } else {
          bodyBytes += data.length;
          publishedBytes += data.length;
        }
      },
      onError: (_) {},
      onDone: () {
        if (isPut) {
          publishing = false;
          stdout.writeln(
            '  conexion #$connections cerrada: ${(bodyBytes / 1024).toStringAsFixed(1)} KiB',
          );
        }
      },
    );
  }
}
