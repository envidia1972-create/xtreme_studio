/// Verificacion de la proteccion contra desplazar a otro DJ.
///
/// Escenario real del Modo B: varios locutores comparten la clave de un mismo
/// mount. Si uno entra sin darse cuenta mientras otro esta al aire, el segundo
/// sale sin aviso. Icecast responde 403 y SHOUTcast 409 en ese caso, y la app
/// debe reconocerlo y pedir confirmacion antes de continuar.
///
/// Uso: dart run tool/verify_occupied_mount.dart
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xtreme_studio/core/audio/broadcast_engine.dart';
import 'package:xtreme_studio/core/net/icecast_client.dart';
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

/// Servidor que responde a la publicacion y registra lo que recibe.
class FakeServer {
  FakeServer({
    required this.putStatus,
    this.putReason = 'Forbidden',
    this.allowAfterRelease = false,
  });

  final int putStatus;
  final String putReason;

  /// Si es `true`, tras recibir `?mode=delete` la publicacion pasa a aceptarse.
  final bool allowAfterRelease;

  ServerSocket? _server;
  int putAttempts = 0;
  int deleteRequests = 0;
  bool released = false;

  int get port => _server!.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((socket) {
      final buffer = <int>[];
      var answered = false;
      socket.listen(
        (data) {
          buffer.addAll(data);
          final text = latin1.decode(buffer, allowInvalid: true);
          if (answered || !text.contains('\r\n\r\n')) return;
          answered = true;

          if (text.startsWith('GET') && text.contains('mode=delete')) {
            deleteRequests++;
            released = true;
            socket.write('HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n');
            // `write` ata el socket a un StreamSink: cerrarlo despues con
            // `close()` lanza "StreamSink is bound to a stream". Se destruye.
            socket.destroy();
            return;
          }

          if (text.startsWith('PUT')) {
            putAttempts++;
            final ocupado = !(allowAfterRelease && released);
            if (ocupado) {
              socket.write(
                'HTTP/1.1 $putStatus $putReason\r\n'
                'Content-Type: text/plain\r\n'
                'Connection: close\r\n\r\n'
                'Mountpoint in use\r\n',
              );
              socket.destroy();
            } else {
              socket.write('HTTP/1.1 100 Continue\r\n\r\n');
            }
          }
        },
        onError: (_) {},
      );
    });
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }
}

ServerProfile makeProfile(int port) => ServerProfile(
  id: 'mount-test',
  name: 'Radio compartida',
  host: '127.0.0.1',
  port: port,
  mount: '/compartido',
  username: 'source',
  password: 'clave-compartida',
);

Future<void> main() async {
  stdout.writeln('Verificacion de la proteccion del mount ocupado');

  section('Reconocimiento del error');

  check(
    BroadcastEngine.isMountOccupiedError(403),
    'un 403 se reconoce como mount ocupado (Icecast)',
  );
  check(
    BroadcastEngine.isMountOccupiedError(409),
    'un 409 se reconoce como mount ocupado (SHOUTcast)',
  );
  check(
    !BroadcastEngine.isMountOccupiedError(401),
    'un 401 NO se confunde con mount ocupado: son credenciales',
  );
  check(
    !BroadcastEngine.isMountOccupiedError(404),
    'un 404 NO se confunde con mount ocupado',
  );
  check(
    !BroadcastEngine.isMountOccupiedError(null),
    'un error de red sin codigo no se confunde con mount ocupado',
  );

  section('Publicacion rechazada por mount ocupado');

  var server = FakeServer(putStatus: 403, putReason: 'Forbidden');
  await server.start();

  var client = IcecastClient(
    host: '127.0.0.1',
    port: server.port,
    mount: '/compartido',
    username: 'source',
    password: 'clave-compartida',
  );

  try {
    await client.connect();
    check(false, 'un 403 deberia impedir la conexion');
  } on IcecastException catch (e) {
    check(
      e.statusCode == 403,
      'el 403 se propaga con su codigo',
      detail: e.statusCode.toString(),
    );
    check(
      BroadcastEngine.isMountOccupiedError(e.statusCode),
      'y el motor puede reconocerlo para preguntar al DJ',
    );
    check(
      e.message.contains('otro DJ'),
      'el mensaje explica que ya hay otro DJ',
      detail: e.message,
    );
  }
  await client.close();
  await server.stop();

  section('Forzar: se pide al servidor liberar el mount');

  server = FakeServer(
    putStatus: 403,
    putReason: 'Forbidden',
    allowAfterRelease: true,
  );
  await server.start();

  client = IcecastClient(
    host: '127.0.0.1',
    port: server.port,
    mount: '/compartido',
    username: 'source',
    password: 'clave-compartida',
  );

  // Primer intento: rechazado.
  try {
    await client.connect();
  } on IcecastException catch (e) {
    check(
      BroadcastEngine.isMountOccupiedError(e.statusCode),
      'el primer intento se rechaza por mount ocupado',
    );
  }

  // El DJ confirma: se pide al servidor que suelte la fuente.
  await client.disconnectSource();
  await Future<void>.delayed(const Duration(milliseconds: 300));

  check(
    server.deleteRequests == 1,
    'se envia la peticion de liberar el mount al servidor',
    detail: 'peticiones mode=delete: ${server.deleteRequests}',
  );

  // Segundo intento: ahora debe aceptarse.
  final retry = IcecastClient(
    host: '127.0.0.1',
    port: server.port,
    mount: '/compartido',
    username: 'source',
    password: 'clave-compartida',
  );
  await retry.connect();
  check(
    retry.isConnected,
    'tras liberarlo, la segunda conexion es aceptada',
  );
  check(
    server.putAttempts >= 2,
    'se hicieron los dos intentos de publicacion',
    detail: 'intentos: ${server.putAttempts}',
  );
  await retry.close();
  await server.stop();

  section('Otros codigos no disparan la proteccion');

  server = FakeServer(putStatus: 401, putReason: 'Unauthorized');
  await server.start();
  client = IcecastClient(
    host: '127.0.0.1',
    port: server.port,
    mount: '/compartido',
    username: 'source',
    password: 'mala',
  );
  try {
    await client.connect();
    check(false, 'un 401 deberia fallar');
  } on IcecastException catch (e) {
    check(
      !BroadcastEngine.isMountOccupiedError(e.statusCode),
      'con credenciales malas NO se ofrece desplazar a nadie',
      detail: 'codigo ${e.statusCode}',
    );
    check(
      e.message.contains('usuario o la contrasena'),
      'el mensaje apunta a las credenciales',
      detail: e.message,
    );
  }
  await client.close();
  await server.stop();

  stdout.writeln('');
  stdout.writeln('===============================');
  if (_failures.isEmpty) {
    stdout.writeln('PROTECCION VERIFICADA: $_passed comprobaciones pasaron');
    exit(0);
  }
  stdout.writeln('$_passed OK, ${_failures.length} FALLARON:');
  for (final f in _failures) {
    stdout.writeln('  - $f');
  }
  exit(1);
}
