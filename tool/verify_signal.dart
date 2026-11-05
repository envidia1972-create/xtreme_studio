/// Verificacion del monitor de senal (comprobacion desde el lado del oyente).
///
/// Levanta un servidor HTTP simulado que imita a Icecast respondiendo a la
/// peticion del mount, y comprueba que el monitor distingue correctamente entre
/// "los oyentes reciben audio" y cada forma de fallo.
///
/// Uso: dart run tool/verify_signal.dart
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xtreme_studio/core/net/stream_health.dart';
import 'package:xtreme_studio/core/server_profile.dart';

int _passed = 0;
final List<String> _failures = [];

void check(bool ok, String description, {String? detail}) {
  if (ok) {
    _passed++;
    stdout.writeln('  [ok]   $description');
  } else {
    _failures.add(description);
    stdout.writeln(
      '  [FALLA] $description${detail != null ? ' -> $detail' : ''}',
    );
  }
}

void section(String title) {
  stdout.writeln('');
  stdout.writeln('== $title ==');
}

/// Servidor HTTP que responde a peticiones de stream.
///
/// [rejectHead] reproduce el comportamiento de los servidores reales de Zeno.fm:
/// responden 405 a `HEAD` pero sirven el audio con `GET`. Es el caso que
/// obligo a usar GET en el monitor, asi que conviene tenerlo cubierto.
class FakeStreamServer {
  FakeStreamServer({
    required this.status,
    this.contentType = 'audio/mpeg',
    this.reason = 'OK',
    this.redirectTo,
    this.hang = false,
    this.rejectHead = false,
  });

  final int status;
  final String contentType;
  final String reason;
  final bool hang;
  final String? redirectTo;
  final bool rejectHead;

  ServerSocket? _server;
  int requests = 0;
  String? lastPath;
  String? lastMethod;

  int get port => _server!.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((socket) async {
      // Se lee la peticion hasta el fin de cabeceras.
      final buffer = <int>[];
      await for (final data in socket) {
        buffer.addAll(data);
        if (latin1.decode(buffer, allowInvalid: true).contains('\r\n\r\n')) {
          break;
        }
      }
      final text = latin1.decode(buffer, allowInvalid: true);
      final firstLine = text.split('\r\n').first;
      final parts = firstLine.split(' ');
      lastMethod = parts.isNotEmpty ? parts[0] : null;
      lastPath = parts.length > 1 ? parts[1] : null;
      requests++;

      if (hang) {
        // Nunca responde: sirve para probar el timeout.
        return;
      }

      // Servidor que no admite HEAD (como Zeno.fm) pero si GET.
      if (rejectHead && lastMethod == 'HEAD') {
        try {
          socket.write(
            'HTTP/1.1 405 Method Not Allowed\r\n'
            'Server: fake-icecast\r\n'
            'Content-Length: 0\r\n'
            'Connection: close\r\n\r\n',
          );
          await socket.flush();
          await socket.close();
        } catch (_) {}
        return;
      }

      final headers = StringBuffer()
        ..write('HTTP/1.1 $status $reason\r\n')
        ..write('Server: fake-icecast\r\n');
      if (redirectTo != null) {
        headers.write('Location: $redirectTo\r\n');
      } else if (contentType.isNotEmpty) {
        headers.write('Content-Type: $contentType\r\n');
      }
      headers.write('Content-Length: 0\r\n');
      headers.write('Connection: close\r\n\r\n');
      try {
        socket.write(headers.toString());
        await socket.flush();
        await socket.close();
      } catch (_) {}
    });
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }
}

ServerProfile profileFor(
  int port, {
  String mount = '/stream',
  String publicUrl = '',
}) {
  final p = ServerProfile(
    id: 'x',
    name: 'Radio',
    host: '127.0.0.1',
    port: port,
    mount: mount,
    username: 'source',
    password: 'p',
  );
  p.publicUrl = publicUrl;
  return p;
}

Future<void> main() async {
  stdout.writeln('Verificacion del monitor de senal (vista del oyente)');

  // ------------------------------------------------------------- URL de escucha
  section('URL de escucha');

  final withPublic = ServerProfile(
    id: 'a',
    name: 'R',
    host: 'radio.fm',
    publicUrl: 'https://radio.fm/en-vivo',
  );
  final monitorA = StreamHealthMonitor(profile: withPublic);
  check(
    monitorA.resolveListenerUrl()?.toString() == 'https://radio.fm/en-vivo',
    'si el perfil tiene URL publica, se usa esa',
    detail: monitorA.resolveListenerUrl().toString(),
  );

  final derived = ServerProfile(
    id: 'b',
    name: 'R',
    host: 'stream.zeno.fm',
    port: 8000,
    mount: 'miradio',
  );
  final monitorB = StreamHealthMonitor(profile: derived);
  check(
    monitorB.resolveListenerUrl()?.toString() ==
        'http://stream.zeno.fm:8000/miradio',
    'sin URL publica, se deduce del host, puerto y mount',
    detail: monitorB.resolveListenerUrl().toString(),
  );

  final shoutcast = ServerProfile(
    id: 'sc',
    name: 'R',
    host: 'radio.fm',
    port: 8885,
    protocol: ServerProtocol.shoutcast2,
  );
  check(
    StreamHealthMonitor(profile: shoutcast).resolveListenerUrl() == null,
    'Shoutcast sin URL publica no inventa un puerto de escucha',
  );
  shoutcast.publicUrl = 'https://radio.fm/en-vivo';
  check(
    StreamHealthMonitor(profile: shoutcast).resolveListenerUrl()?.toString() ==
        'https://radio.fm/en-vivo',
    'Shoutcast usa la URL publica cuando el hosting la provee',
  );

  final noHost = ServerProfile(id: 'c', name: 'R', host: '');
  check(
    StreamHealthMonitor(profile: noHost).resolveListenerUrl() == null,
    'sin host ni URL publica no hay nada que comprobar',
  );

  // ------------------------------------------------------------------- casos
  section('Servidor sirviendo audio');

  var server = FakeStreamServer(status: 200, contentType: 'audio/mpeg');
  await server.start();
  var result = await StreamHealthMonitor(
    profile: profileFor(server.port),
    timeout: const Duration(seconds: 5),
  ).check();
  check(
    result.isHealthy,
    'un 200 con audio/mpeg se considera publicada',
    detail: result.message,
  );
  check(
    server.lastMethod == 'GET',
    'se usa GET (no HEAD) porque hay hostings que rechazan HEAD',
    detail: 'metodo: ${server.lastMethod}',
  );
  check(
    server.lastPath == '/stream',
    'se pide el mount del perfil',
    detail: 'ruta: ${server.lastPath}',
  );
  await server.stop();

  // Caso real de Zeno.fm: rechaza HEAD con 405 pero sirve el audio con GET.
  // Este caso obligo a usar GET; si alguien lo cambia a HEAD, esta prueba falla.
  server = FakeStreamServer(
    status: 200,
    contentType: 'audio/aac',
    rejectHead: true,
  );
  await server.start();
  result = await StreamHealthMonitor(profile: profileFor(server.port)).check();
  check(
    result.isHealthy,
    'un servidor que rechaza HEAD pero sirve GET se considera publicada',
    detail: result.message,
  );
  check(
    server.lastMethod == 'GET',
    'la peticion usada fue GET, no HEAD',
    detail: 'metodo: ${server.lastMethod}',
  );
  await server.stop();

  // Icecast real suele declarar audio/aac, ogg, etc.
  server = FakeStreamServer(status: 200, contentType: 'audio/aac');
  await server.start();
  result = await StreamHealthMonitor(profile: profileFor(server.port)).check();
  check(
    result.isHealthy,
    'un 200 con audio/aac tambien es valido',
    detail: result.message,
  );
  await server.stop();

  // Servidor que no declara content-type: se acepta pero se informa.
  server = FakeStreamServer(status: 200, contentType: '');
  await server.start();
  result = await StreamHealthMonitor(profile: profileFor(server.port)).check();
  check(
    result.isHealthy,
    'un 200 sin content-type se acepta (algunos servidores no lo declaran)',
    detail: result.message,
  );
  await server.stop();

  section('Fallos que debe detectar');

  server = FakeStreamServer(
    status: 404,
    reason: 'Not Found',
    contentType: 'text/plain',
  );
  await server.start();
  result = await StreamHealthMonitor(profile: profileFor(server.port)).check();
  check(
    result.status == SignalStatus.noSource,
    'un 404 se interpreta como "no hay fuente en el mount"',
    detail: result.message,
  );
  check(
    result.status.isProblem,
    'ese estado se marca como problema para el DJ',
  );
  await server.stop();

  server = FakeStreamServer(status: 401, reason: 'Unauthorized');
  await server.start();
  result = await StreamHealthMonitor(profile: profileFor(server.port)).check();
  check(
    result.status == SignalStatus.noSource,
    'un 401 se interpreta como mount protegido',
    detail: result.message,
  );
  await server.stop();

  // Puerto cerrado: nadie escucha ahi.
  server = FakeStreamServer(status: 200);
  await server.start();
  final closedPort = server.port;
  await server.stop();
  result = await StreamHealthMonitor(
    profile: profileFor(closedPort),
    timeout: const Duration(seconds: 4),
  ).check();
  check(
    result.status == SignalStatus.unreachable,
    'un puerto cerrado se detecta como servidor inalcanzable',
    detail: result.message,
  );
  await server.stop();

  // Servidor que acepta la conexion y nunca responde.
  server = FakeStreamServer(status: 200, hang: true);
  await server.start();
  result = await StreamHealthMonitor(
    profile: profileFor(server.port),
    timeout: const Duration(seconds: 2),
  ).check();
  check(
    result.status == SignalStatus.unreachable,
    'un servidor que no responde se detecta por timeout',
    detail: result.message,
  );
  await server.stop();

  section('Casos que NO deben alarmar al DJ');

  // 405: el servidor no admite la comprobacion pero esta bien.
  server = FakeStreamServer(status: 405, reason: 'Method Not Allowed');
  await server.start();
  result = await StreamHealthMonitor(profile: profileFor(server.port)).check();
  check(
    result.status == SignalStatus.unexpected,
    'un 405 no se confunde con falta de fuente',
    detail: result.message,
  );
  check(
    !result.status.isProblem,
    'un 405 NO alarma al DJ: es "no pude comprobar", no un fallo',
  );
  await server.stop();

  // 200 pero es una pagina web, no un stream.
  server = FakeStreamServer(status: 200, contentType: 'text/html');
  await server.start();
  result = await StreamHealthMonitor(profile: profileFor(server.port)).check();
  check(
    result.status == SignalStatus.unexpected,
    'un 200 con text/html avisa que la URL no es el stream',
    detail: result.message,
  );
  check(
    !result.status.isProblem,
    'una URL mal cargada no se reporta como caida de la emision',
  );
  await server.stop();

  // Sin configuracion: no debe intentar nada.
  result = await StreamHealthMonitor(profile: noHost).check();
  check(
    result.status == SignalStatus.notConfigured,
    'sin URL no se hace peticion y se explica por que',
    detail: result.message,
  );
  check(
    !result.status.isProblem,
    'la falta de URL no se trata como fallo de emision',
  );

  // ------------------------------------------------------------- redirecciones
  section('Redirecciones (Zeno.fm y otros CDN)');

  final target = FakeStreamServer(status: 200, contentType: 'audio/mpeg');
  await target.start();
  final redirector = FakeStreamServer(
    status: 302,
    reason: 'Found',
    contentType: '',
    redirectTo: 'http://127.0.0.1:${target.port}/miradio',
  );
  await redirector.start();

  result = await StreamHealthMonitor(
    profile: profileFor(redirector.port),
    timeout: const Duration(seconds: 6),
  ).check();
  check(
    result.isHealthy,
    'sigue la redireccion del CDN y confirma el audio',
    detail: result.message,
  );
  check(
    target.requests >= 1,
    'la peticion llego al destino de la redireccion',
    detail: 'peticiones al destino: ${target.requests}',
  );
  await redirector.stop();
  await target.stop();

  // ------------------------------------------------------------------ resumen
  stdout.writeln('');
  stdout.writeln('===============================');
  if (_failures.isEmpty) {
    stdout.writeln('MONITOR VERIFICADO: $_passed comprobaciones pasaron');
    exit(0);
  }
  stdout.writeln('$_passed OK, ${_failures.length} FALLARON:');
  for (final f in _failures) {
    stdout.writeln('  - $f');
  }
  exit(1);
}
