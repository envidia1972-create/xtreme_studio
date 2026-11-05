/// Pruebas del nucleo que se ejecutan **sin** `dart test`.
///
/// Motivo: en este entorno el sandbox bloquea los subprocesos del compilador
/// (`dartaotruntime`), asi que `dart test` y `dart analyze` no arrancan. Este
/// archivo llama al codigo real y comprueba los resultados, de modo que el
/// nucleo queda verificado de verdad: protocolo, metadatos, vumetros, cifrado
/// y persistencia.
///
/// Uso: dart run tool/verify_core.dart
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:xtreme_studio/core/audio/ffmpeg_capture.dart';
import 'package:xtreme_studio/core/audio/gain_stage.dart';
import 'package:xtreme_studio/core/diagnostic_log.dart';
import 'package:xtreme_studio/core/net/icecast_client.dart';
import 'package:xtreme_studio/core/net/shoutcast_client.dart';
import 'package:xtreme_studio/core/profile_store.dart';
import 'package:xtreme_studio/core/screen_guard.dart';
import 'package:xtreme_studio/core/secret_store.dart';
import 'package:xtreme_studio/core/server_profile.dart';

int _passed = 0;
final List<String> _failures = [];

/// Comprueba una condicion y registra el resultado.
void check(bool condition, String description, {String? detail}) {
  if (condition) {
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

/// Servidor TCP que imita a Icecast: responde al PUT y guarda los bytes.
class FakeIcecast {
  FakeIcecast(this.statusCode, this.reason);

  final int statusCode;
  final String reason;

  ServerSocket? _server;
  int get port => _server!.port;
  String request = '';
  final List<int> audio = [];
  bool _headerSent = false;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((socket) {
      socket.listen((data) {
        if (!_headerSent) {
          request += latin1.decode(data, allowInvalid: true);
          if (request.contains('\r\n\r\n')) {
            socket.write('HTTP/1.1 $statusCode $reason\r\n\r\n');
            _headerSent = true;
          }
        } else {
          audio.addAll(data);
        }
      }, onError: (_) {});
    });
  }

  Future<void> stop() async => _server?.close();
}

/// Servidor que solo registra la peticion de metadatos y responde un codigo.
class FakeAdminServer {
  FakeAdminServer(this.statusCode, this.reason);

  final int statusCode;
  final String reason;
  ServerSocket? _server;
  final List<String> requests = [];

  int get port => _server!.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((socket) {
      final buffer = <int>[];
      var responded = false;
      socket.listen(
        (data) {
          if (responded) return;
          buffer.addAll(data);
          final text = latin1.decode(buffer, allowInvalid: true);
          if (text.contains('\r\n\r\n')) {
            responded = true;
            requests.add(text);
            socket.write(
              'HTTP/1.1 $statusCode $reason\r\n'
              'Content-Length: 0\r\n'
              'Connection: close\r\n\r\n',
            );
            socket.close();
          }
        },
        onError: (_) {},
        onDone: () {},
      );
    });
  }

  Future<void> stop() async => _server?.close();
}

Future<void> main() async {
  stdout.writeln('Verificacion del nucleo de Xtreme Studio');
  stdout.writeln(
    '(ejecuta el codigo real; sin red salvo el servidor simulado)',
  );

  await _peticionIcecast();
  await _conexionIcecast();
  await _erroresHttp();
  await _metadatosAdministracion();
  await _shoutcast();
  await _shoutcastServidor();
  await _redEstancada();
  await _tlsAutofirmado();
  await _vumetros();
  await _captura();
  await _cifrado();
  await _persistencia();
  await _pantalla();
  await _perfil();

  stdout.writeln('');
  stdout.writeln('===============================');
  if (_failures.isEmpty) {
    stdout.writeln('TODO CORRECTO: $_passed comprobaciones pasaron');
    exit(0);
  }
  stdout.writeln('$_passed OK, ${_failures.length} FALLARON:');
  for (final f in _failures) {
    stdout.writeln('  - $f');
  }
  exit(1);
}

Future<void> _peticionIcecast() async {
  section('Peticion HTTP de Icecast');
  final client = IcecastClient(
    host: 'radio.ejemplo.com',
    port: 8000,
    mount: '/miradio',
    username: 'source',
    password: 'secreto123',
    iceName: 'Mi Radio',
    iceGenre: 'Variado',
  );
  final req = client.buildPutRequest();

  check(req.startsWith('PUT /miradio HTTP/1.1'), 'usa PUT al mount correcto');
  check(
    !req.contains('icy-metaint'),
    'NO inserta metadatos dentro del flujo de audio',
  );
  check(
    req.contains('Content-Type: audio/mpeg'),
    'declara el tipo de audio del codec',
  );
  check(
    req.contains('Expect: 100-continue'),
    'pide validacion previa de credenciales',
  );
  check(!req.contains('secreto123'), 'la contrasena NO viaja en texto plano');
  check(
    req.contains(base64Encode(utf8.encode('source:secreto123'))),
    'la contrasena viaja en Basic auth (base64)',
  );
  check(req.contains('ice-name: Mi Radio'), 'envia el nombre de la emisora');

  // El usuario tampoco bloquea en Icecast: si queda vacio se usa `source`,
  // que es lo que espera el servidor por convencion.
  final sinUsuario = IcecastClient(
    host: 'radio.ejemplo.com',
    port: 8000,
    mount: '/',
    username: '',
    password: 'secreto123',
  );
  check(
    sinUsuario.buildPutRequest().contains(
      base64Encode(utf8.encode('source:secreto123')),
    ),
    'Icecast usa "source" cuando el usuario queda vacio',
  );
}

Future<void> _conexionIcecast() async {
  section('Handshake con Icecast');
  final fake = FakeIcecast(100, 'Continue');
  await fake.start();

  final client = IcecastClient(
    host: '127.0.0.1',
    port: fake.port,
    mount: '/test',
    username: 'source',
    password: 'p',
  );

  await client.connect();
  check(client.isConnected, 'un 100 Continue establece la conexion');
  await client.close();
  check(!client.isConnected, 'cerrar deja el cliente desconectado');
  await fake.stop();
}

Future<void> _erroresHttp() async {
  section('Diagnostico de errores del servidor');

  for (final caso in [
    (401, 'Unauthorized', 'usuario o la contrasena'),
    (403, 'Forbidden', 'otro DJ'),
    (404, 'Not Found', 'mount no existe'),
  ]) {
    final fake = FakeIcecast(caso.$1, caso.$2);
    await fake.start();
    final client = IcecastClient(
      host: '127.0.0.1',
      port: fake.port,
      mount: '/test',
      username: 'source',
      password: 'p',
    );
    try {
      await client.connect();
      check(false, 'HTTP ${caso.$1} deberia fallar');
    } on IcecastException catch (e) {
      check(
        e.statusCode == caso.$1 && e.message.contains(caso.$3),
        'HTTP ${caso.$1} se explica como: "${caso.$3}"',
        detail: e.message,
      );
    }
    await fake.stop();
  }

  // Host inexistente: el mensaje debe ser util, no un volcado tecnico.
  final bad = IcecastClient(
    host: 'no-existe.invalid',
    port: 8000,
    mount: '/x',
    username: 's',
    password: 'p',
  );
  try {
    await bad.connect();
    check(false, 'un host inexistente deberia fallar');
  } on IcecastException catch (e) {
    check(
      e.message.contains('No se pudo conectar'),
      'host inexistente da mensaje claro',
    );
  }
}

Future<void> _metadatosAdministracion() async {
  section('Metadatos por /admin/metadata (lo que usa Zeno.fm)');

  final fake = FakeAdminServer(200, 'OK');
  await fake.start();
  final client = IcecastClient(
    host: '127.0.0.1',
    port: fake.port,
    mount: '/miradio',
    username: 'source',
    password: 'secreto123',
  );
  final ok = await client.setMetadata('Artista - Tema');
  check(ok, 'un 200 del servidor confirma el cambio de titulo');
  final request = fake.requests.isEmpty ? '' : fake.requests.first;
  check(
    request.startsWith('GET /admin/metadata?'),
    'la actualizacion va por una peticion HTTP aparte',
    detail: request.split('\r\n').first,
  );
  check(
    request.contains('mode=updinfo') &&
        request.contains('mount=%2Fmiradio') &&
        request.contains('song=Artista'),
    'envia mount, mode=updinfo y song codificados',
    detail: request.split('\r\n').first,
  );
  check(
    request.contains(base64Encode(utf8.encode('source:secreto123'))),
    'autentica la actualizacion con las credenciales del mount',
  );
  await fake.stop();

  // Un servidor que rechaza la actualizacion debe devolver false, no fingir
  // que el titulo cambio.
  final denied = FakeAdminServer(401, 'Unauthorized');
  await denied.start();
  final deniedClient = IcecastClient(
    host: '127.0.0.1',
    port: denied.port,
    mount: '/miradio',
    username: 'source',
    password: 'mala',
  );
  check(
    !await deniedClient.setMetadata('No debe entrar'),
    'un 401 se informa como fallo de metadatos',
  );
  await denied.stop();

  // El audio no puede llevar ningun byte de texto: los servidores lo
  // interpretarian como MP3/AAC y se oiria ruido de fondo.
  final audioServer = FakeIcecast(100, 'Continue');
  await audioServer.start();
  final audioClient = IcecastClient(
    host: '127.0.0.1',
    port: audioServer.port,
    mount: '/test',
    username: 'source',
    password: 'p',
  );
  await audioClient.connect();
  audioClient.send(Uint8List(100)..fillRange(0, 100, 0x41));
  await audioClient.close();
  await Future<void>.delayed(const Duration(milliseconds: 200));
  check(
    audioServer.audio.length == 100 &&
        audioServer.audio.every((b) => b == 0x41),
    'el audio viaja intacto, sin bloques de metadatos intercalados',
    detail: 'recibidos ${audioServer.audio.length} bytes',
  );
  await audioServer.stop();

  // El codec tambien define el Content-Type que se anuncia al servidor.
  final aacClient = IcecastClient(
    host: 'radio.ejemplo.com',
    port: 8000,
    mount: '/aac',
    username: 'source',
    password: 'p',
    contentType: 'audio/aac',
  );
  check(
    aacClient.buildPutRequest().contains('Content-Type: audio/aac'),
    'anuncia audio/aac cuando el codec es AAC',
  );
}

Future<void> _shoutcast() async {
  section('Shoutcast v1 / v2');

  final v1 = ShoutcastClient(
    host: 'h',
    port: 8000,
    password: 'clave',
    version: ShoutcastVersion.v1,
  );
  final hs1 = v1.buildHandshake();
  check(hs1.startsWith('clave\n'), 'v1 envia solo la contrasena');
  check(hs1.contains('Host: h:8000'), 'v1 envia el Host del puerto base');
  check(!hs1.contains('sid:'), 'v1 no envia sid');
  check(!hs1.contains('#1'), 'v1 no agrega #1 a la contrasena');

  final v2 = ShoutcastClient(
    host: 'h',
    port: 8000,
    password: 'clave',
    username: 'dj',
    version: ShoutcastVersion.v2,
    streamId: 1,
  );
  final hs2 = v2.buildHandshake();
  check(hs2.startsWith('clave\n'), 'v2 envia solo la contrasena');
  check(!hs2.contains('dj:'), 'v2 ignora el usuario');
  check(!hs2.contains('sid:'), 'v2 omite sid para el stream por defecto');

  // El usuario no es obligatorio en Shoutcast: v2 cae en `source` y v1 lo
  // ignora. Es justo lo que necesita un hosting que solo entrega la clave.
  final v2SinUsuario = ShoutcastClient(
    host: 'h',
    port: 8000,
    password: 'clave',
    username: '',
    version: ShoutcastVersion.v2,
  );
  check(
    v2SinUsuario.buildHandshake().startsWith('clave\n'),
    'v2 no inventa un usuario cuando el campo queda vacio',
  );

  // La contrasena puede contener `:`; solo el primer `:` separa usuario/clave.
  final v2ClaveConDosPuntos = ShoutcastClient(
    host: 'h',
    port: 8000,
    password: 'Luis:pENgt',
    username: 'dj',
    version: ShoutcastVersion.v2,
  );
  check(
    v2ClaveConDosPuntos.buildHandshake().startsWith('Luis:pENgt\n'),
    'v2 conserva una contrasena que contiene dos puntos',
  );

  final v1ConUsuario = ShoutcastClient(
    host: 'h',
    port: 8000,
    password: 'clave',
    username: 'Luis',
    version: ShoutcastVersion.v1,
  );
  check(
    v1ConUsuario.buildHandshake().startsWith('clave\n'),
    'v1 ignora el usuario aunque el DJ escriba uno',
  );
  // Este cliente no entrelaza metadatos en el flujo; anunciar `icy-metaint`
  // haria que el servidor y los reproductores esperen bloques que no llegan.
  check(
    !hs2.contains('icy-metaint'),
    'v2 NO anuncia metadatos en el flujo (se actualizan por la API)',
  );

  final perfilSc2 = ServerProfile(
    id: 'sc2',
    name: 'SC2',
    host: 'h',
    port: 8885,
    protocol: ServerProtocol.shoutcast2,
  );
  final perfilIce = ServerProfile(
    id: 'ice',
    name: 'Ice',
    host: 'h',
    port: 8885,
  );
  check(
    perfilSc2.sourcePort == 8886,
    'Shoutcast publica en el puerto base + 1',
  );
  check(perfilIce.sourcePort == 8885, 'Icecast publica en el puerto indicado');

  // El puerto del perfil es el de oyentes; la fuente va al +1. Se comprueba
  // con un servidor real en el puerto de publicacion y un perfil que solo
  // declara el puerto base.
  final sourceServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  var sourceHandshake = '';
  var sourceResponded = false;
  final sourceSub = sourceServer.listen((socket) {
    socket.listen((data) {
      sourceHandshake += latin1.decode(data, allowInvalid: true);
      if (!sourceResponded && sourceHandshake.contains('\n')) {
        sourceResponded = true;
        socket.write('OK2\r\n');
      }
    }, onError: (_) {});
  });
  final basePort = sourceServer.port - 1;
  final sourceClient = ShoutcastClient(
    host: '127.0.0.1',
    port: basePort,
    password: 'Luis:pENgt',
  );
  await sourceClient.connect();
  check(
    sourceClient.isConnected,
    'Shoutcast conecta automaticamente al puerto base + 1',
  );
  check(
    sourceHandshake.startsWith('Luis:pENgt\n'),
    'Shoutcast envia la contrasena sola, sin usuario',
  );
  check(
    sourceHandshake.contains('Host: 127.0.0.1:$basePort'),
    'Shoutcast conserva el puerto base en el Host',
  );
  await sourceClient.close();
  await sourceSub.cancel();
  await sourceServer.close();

  // Respuesta OK2.
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final sub = server.listen((s) {
    s.listen((_) {}, onError: (_) {});
    s.write('OK2\r\n');
  });
  final c = ShoutcastClient(
    host: '127.0.0.1',
    port: server.port,
    sourcePort: server.port,
    password: 'p',
  );
  await c.connect();
  check(c.isConnected, 'OK2 conecta la fuente');
  check(c.metadataSupported, 'OK2 habilita los metadatos');
  await c.close();
  await sub.cancel();
  await server.close();

  // Respuesta de clave mala.
  final server2 = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final sub2 = server2.listen((s) {
    s.listen((_) {}, onError: (_) {});
    s.write('invalid password\r\n');
  });
  final c2 = ShoutcastClient(
    host: '127.0.0.1',
    port: server2.port,
    sourcePort: server2.port,
    password: 'mala',
  );
  try {
    await c2.connect();
    check(false, 'invalid password deberia fallar');
  } on IcecastException catch (e) {
    check(
      e.message.contains('rechazada'),
      'la clave invalida se reporta claramente',
    );
  }
  await sub2.cancel();
  await server2.close();

  // Un servidor HTTP (Icecast/Liquidsoap) responde 500 a un handshake de
  // Shoutcast. No debe informarse como "clave rechazada": el problema es el
  // tipo de servidor, y el mensaje tiene que decirlo.
  final server3 = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final sub3 = server3.listen((s) {
    s.listen((_) {}, onError: (_) {});
    s.write('HTTP/1.0 500 Invalid request\r\n\r\n');
  });
  final c3 = ShoutcastClient(
    host: '127.0.0.1',
    port: server3.port,
    sourcePort: server3.port,
    password: 'clave',
  );
  try {
    await c3.connect();
    check(false, 'un servidor HTTP deberia rechazar el handshake de Shoutcast');
  } on IcecastException catch (e) {
    check(
      !e.message.toLowerCase().contains('rechazada'),
      'HTTP 500 no se confunde con una contrasena rechazada',
    );
    check(
      e.message.contains('Icecast'),
      'HTTP 500 sugiere cambiar el tipo de servidor a Icecast',
    );
    check(e.statusCode == 500, 'HTTP 500 conserva el codigo real del servidor');
  }
  await sub3.cancel();
  await server3.close();
}

/// Espera a que se cumpla una condicion, sin bloquear mas de [timeout].
Future<bool> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return condition();
}

Future<void> _shoutcastServidor() async {
  section('Shoutcast contra servidor simulado');

  // ------------------------------------------------- caida a mitad de emision
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final clients = <Socket>[];
  final subs = <StreamSubscription<List<int>>>[];
  server.listen((socket) {
    clients.add(socket);
    // El servidor simulado tambien puede recibir EPIPE al cortar: sin observar
    // `done`, el test terminaria con un error no capturado.
    unawaited(socket.done.catchError((Object _) {}));
    subs.add(socket.listen((_) {}, onError: (_) {}));
    socket.write('OK2\r\n');
  });

  final client = ShoutcastClient(
    host: '127.0.0.1',
    port: server.port,
    sourcePort: server.port,
    password: 'clave',
  );
  var lost = 0;
  final lostSub = client.onConnectionLost.listen((_) => lost++);
  await client.connect();
  check(client.isConnected, 'OK2 deja la fuente conectada');

  // El servidor cierra la conexion sin aviso HTTP: el cliente debe detectarlo.
  for (final socket in clients) {
    socket.destroy();
  }
  final detected = await _waitUntil(() => lost > 0);
  check(detected, 'la caida del servidor se detecta en Shoutcast');
  check(
    lost == 1,
    'el aviso de caida se emite una sola vez',
    detail: 'eventos: $lost',
  );
  check(!client.isConnected, 'el cliente queda marcado como desconectado');

  await lostSub.cancel();
  await client.dispose();
  for (final sub in subs) {
    await sub.cancel();
  }
  await server.close();

  // ------------------------------------- metadatos por el panel de Shoutcast
  final admin = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  var request = '';
  final adminSubs = <StreamSubscription<List<int>>>[];
  admin.listen((socket) {
    unawaited(socket.done.catchError((Object _) {}));
    adminSubs.add(
      socket.listen((data) {
        request += latin1.decode(data, allowInvalid: true);
        if (request.contains('\r\n\r\n')) {
          socket.write('OK2\r\n');
          unawaited(socket.close());
        }
      }, onError: (_) {}),
    );
  });

  // En Shoutcast v2 la administracion usa el mismo puerto que la fuente (el
  // DNAS multiplexa todo en `portbase`). Antes se usaba `port + 1` y por eso
  // el cambio de titulo fallaba en hostings como AsuraHosting.
  final metaClient = ShoutcastClient(
    host: '127.0.0.1',
    port: admin.port,
    password: 'clave del dj',
    username: 'locutor',
  );
  final sent = await metaClient.setMetadata('Tema & "prueba"');
  await _waitUntil(() => request.contains('\r\n\r\n'));
  check(sent, 'v2 actualiza el titulo en el mismo puerto de la fuente');
  check(
    request.contains('pass=clave%20del%20dj'),
    'Shoutcast envia la contrasena en el parametro pass (no solo Basic auth)',
    detail: request.split('\r\n').first,
  );
  check(
    request.contains('mode=updinfo'),
    'la peticion usa el modo de actualizacion de Shoutcast',
  );
  check(
    request.contains('song=Tema%20%26%20%22prueba%22'),
    'el titulo viaja codificado y no rompe la URL',
  );
  check(request.contains('sid=1'), 'v2 envia el sid del stream');

  for (final sub in adminSubs) {
    await sub.cancel();
  }
  await admin.close();

  // Una clave rechazada no puede reportarse como exito: el cliente antes
  // devolvia `true` con solo abrir el socket, sin mirar la respuesta.
  final denied = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final deniedSub = denied.listen((socket) {
    unawaited(socket.done.catchError((Object _) {}));
    socket.listen((_) {
      socket.write('Invalid password\r\n');
      unawaited(socket.close());
    }, onError: (_) {});
  });
  final deniedClient = ShoutcastClient(
    host: '127.0.0.1',
    port: denied.port,
    password: 'mala',
  );
  final rejected = await deniedClient.setMetadata('Tema');
  check(!rejected, 'Invalid password no se reporta como exito');
  await deniedSub.cancel();
  await denied.close();

  // v1: la fuente se conecta a portbase + 1 y la administracion queda en
  // portbase. El cliente recibe el puerto base; el +1 se calcula al publicar.
  final v1Admin = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final v1Sub = v1Admin.listen((socket) {
    unawaited(socket.done.catchError((Object _) {}));
    socket.listen((_) {
      socket.write('OK2\r\n');
      unawaited(socket.close());
    }, onError: (_) {});
  });
  final v1Client = ShoutcastClient(
    host: '127.0.0.1',
    port: v1Admin.port,
    password: 'clave',
    version: ShoutcastVersion.v1,
  );
  check(
    await v1Client.setMetadata('Tema'),
    'v1 encuentra /admin.cgi en el puerto base (fuente - 1)',
  );
  await v1Sub.cancel();
  await v1Admin.close();
}

Future<void> _redEstancada() async {
  section('Red estancada (backpressure)');

  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final sockets = <Socket>[];
  final subs = <StreamSubscription<List<int>>>[];

  server.listen((socket) {
    sockets.add(socket);
    unawaited(socket.done.catchError((Object _) {}));
    final buffer = <int>[];
    late StreamSubscription<List<int>> sub;
    var headersDone = false;
    sub = socket.listen((data) {
      if (headersDone) return;
      buffer.addAll(data);
      if (latin1.decode(buffer, allowInvalid: true).contains('\r\n\r\n')) {
        headersDone = true;
        socket.write('HTTP/1.1 100 Continue\r\n\r\n');
        // Se deja de leer a proposito: a partir de aqui el servidor se
        // comporta como una red caida que no cierra el socket.
        sub.pause();
      }
    }, onError: (_) {});
    subs.add(sub);
  });

  final client = IcecastClient(
    host: '127.0.0.1',
    port: server.port,
    mount: '/estancado',
    username: 'source',
    password: 'p',
  );
  await client.connect();
  var lost = false;
  final lostSub = client.onConnectionLost.listen((_) => lost = true);

  // Se llena el buffer del sistema. El tamaño de los buffers TCP varia por
  // sistema (en Linux pueden sumar decenas de MB), asi que se envian 128 MB:
  // muy por encima de lo que cabe en memoria del nucleo, y suficiente para que
  // el flush ya no pueda completar mientras el servidor no lea.
  final chunk = Uint8List(64 * 1024);
  for (var i = 0; i < 2048; i++) {
    client.send(chunk);
  }

  await client.flush(timeout: const Duration(seconds: 1));
  // El aviso viaja por un StreamController y se entrega en el siguiente turno
  // del bucle de eventos: hay que esperarlo, no mirarlo en el acto.
  await _waitUntil(() => lost);
  check(lost, 'un flush que no completa marca la conexion como perdida');
  check(
    !client.isConnected,
    'la conexion estancada deja de aceptar audio para no crecer sin limite',
  );

  await lostSub.cancel();
  await client.dispose();
  for (final sub in subs) {
    await sub.cancel();
  }
  for (final socket in sockets) {
    socket.destroy();
  }
  await server.close();
}

// Certificado autofirmado de prueba (CN=localhost, valido 10 años). Se embebe
// para que la prueba no dependa de que el sistema tenga `openssl` instalado.
const String _selfSignedCert = '''
-----BEGIN CERTIFICATE-----
MIIDCTCCAfGgAwIBAgIUMlUEW7FZVs+SGqFiNvsHj1kj5dIwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MB4XDTI2MTAyNTAyMjIzM1oXDTM2MTAy
MjAyMjIzM1owFDESMBAGA1UEAwwJbG9jYWxob3N0MIIBIjANBgkqhkiG9w0BAQEF
AAOCAQ8AMIIBCgKCAQEAnwdQGz3Maak3+J3P+cRyi9rysPwY0ox0rrQxdruvJpHP
JDcdU1h8a4q+Uha2Z5VrmHeBEFNsEsG0nb7XQwm9YCdJvz4O3K+M2Wem35FRzD1j
uGK2ixavopkcAd7yMTJkweNenHIswyrXgcmCvHJ/AmER7yK77TTYGvBgBNA/O9C6
TDWH1TCjkqcZxtDv2LLp8ih8kumz5KO6vtNhxj0Z2YTyOq65HVSBqGBkwrhdtyjS
qEN3QT+UOOqaGErauYJPS5NyLkDCXefaIjvucAeD3K3JFQ98zR8ZGIh2bgbkNWCU
tK9a44pf2KHZ0bD32hz/TbBpdojnxf0Z0Rvc0i61wwIDAQABo1MwUTAdBgNVHQ4E
FgQU5mp6N4EKZHy59aNAuNf7h95k7ogwHwYDVR0jBBgwFoAU5mp6N4EKZHy59aNA
uNf7h95k7ogwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAQEAbhxb
5mQ6AiI7gRnGUOjI/c1gn++O04An+WVN4Koz+OndNHEyEAPrgRBUUtfGrQ92+2I2
jbsPoe8jak8WZu5XChz3HIppFNH12S6Hxt+GacvslZ40YWTJrqGoj6pIgjK0fvfJ
LmRh/fRrwm+ubQfwK1DeZXcIUzQoV5utiEKsg5uPCXvmpL5GVQDcz+DLxL8olmfw
QPGTMAF//tAQAVTFo5qWxtXjSWI7HRZAL5QBllau6cXOoFo27VoQtH4nuoLXg0it
i3PzOwme0ckLI42E+KfS9tKg5hBqe0eiPEUMgLuB5wBF+Zs3LaTsNzfP1qky4aTt
YOImu05LAKz4MvhiXg==
-----END CERTIFICATE-----
''';

const String _selfSignedKey = '''
-----BEGIN PRIVATE KEY-----
MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQCfB1AbPcxpqTf4
nc/5xHKL2vKw/BjSjHSutDF2u68mkc8kNx1TWHxrir5SFrZnlWuYd4EQU2wSwbSd
vtdDCb1gJ0m/Pg7cr4zZZ6bfkVHMPWO4YraLFq+imRwB3vIxMmTB416ccizDKteB
yYK8cn8CYRHvIrvtNNga8GAE0D870LpMNYfVMKOSpxnG0O/YsunyKHyS6bPko7q+
02HGPRnZhPI6rrkdVIGoYGTCuF23KNKoQ3dBP5Q46poYStq5gk9Lk3IuQMJd59oi
O+5wB4PcrckVD3zNHxkYiHZuBuQ1YJS0r1rjil/YodnRsPfaHP9NsGl2iOfF/RnR
G9zSLrXDAgMBAAECggEAClVc0LBW0ITU5LxIb9fig5DyFSsEZ+YFjPabgjYW3wA5
gAZuyuQkjY5h6I6eQqPUbn9RbSCmlJ9un5NvhGUlH5Ld+WXMbG2hztyr3LoiIQ3a
JXiQmQAb4IpnZf25KhY2styV4L+QhgwKHd5ctucPtrVdB3dv062L31BARP/NJBNF
UUlhoOjFZ0079dOj8HYCdWMqSJf1+5hXYiafTvppEHBNfVhd20zuU3aYDqpS+gfJ
OWIDDTY44eH13Ksli2lvwFNZOtiRKCtaC5u72unoxLKDoc4eVA8YZmLvL+zqNiko
XY9BKNRsQmRh+i4/FXpAujwc9NfGoksBkzjzWbIRHQKBgQDSOPnYUnriNkA5j6OQ
VDBMacsqDRH8IFQ4UUsm3CP7x5mSgS5fWm/aDyRZ41/cW0TaeXm8XgbkxTbIMezs
MJbahB41l0/bhTJpgiHGfAK7WaNdjDUj/L1PxstjcFtm4YcKBwROYNLaVW+eZ9QH
c1GCcmNw/8SbzNwJV7ZyPUu6RwKBgQDBqHylH45kJe3omRGNzNTq7+AP9btt2hzk
1jEvm1WPhCVjpzwrAwTHUMz6iR4ntME82qSNhG7+YHHrSm2Mg4KyJA8ocHrGhT0L
72CNkZ/egfEPz1KhD8ckkza+HepclyBbDeAG8eUNp3eVKVicIwZjXlxwTlNP2LBL
4lsDFbAqpQKBgCcD4gKu1BWVoffM27tWlJwp6kXEpTjYuyi0lbEBnEAHPE4/YV7b
BvU+aC2ykEDyQ2YUs24tOTROEau38FOpdOXbLUwe5/hC0SdZunD+5PbmXPZophgm
uO/MYkTzPlNqucg3oyn0uE1DG/MXK/eyBEekeSYoodGUhKXLPJYZICvTAoGARbaJ
aEe70oF0605u60TZQNmpJxWmqxzhWd9hRWn9mvRPIViKaFFl3vpPT8Ecgd6n0WhD
5E3QRvIhEDpyxSpyWf5xFnWnPN+p4ioB7/SEQG02giJ39FLhtWDpS/co7rvYge60
vstFUWz/t0pzA4H4Qr0tOaB4jT3L+QU7Dhk4maECgYBHgeD6TI7JElxoGZqMo5Vl
cT9dqxAFpjhm4oDY4U8BIXDeEScojO6idAjwXWCkworoizTPumeLWkywDk56vtc/
2KjBL/ClWtykazw9jlkIUthg+keZzyqZBlGqFiNdUjrUAjWDZ27M0XsQ9lcalhN2
a0klWs4BTnl3/fkcY00aMA==
-----END PRIVATE KEY-----
''';

Future<void> _tlsAutofirmado() async {
  section('TLS con certificado autofirmado');

  final context = SecurityContext()
    ..useCertificateChainBytes(utf8.encode(_selfSignedCert))
    ..usePrivateKeyBytes(utf8.encode(_selfSignedKey));
  final server = await SecureServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
    context,
  );
  final subs = <StreamSubscription<List<int>>>[];
  server.listen(
    (socket) {
      unawaited(socket.done.catchError((Object _) {}));
      final buffer = <int>[];
      subs.add(
        socket.listen((data) {
          buffer.addAll(data);
          if (latin1.decode(buffer, allowInvalid: true).contains('\r\n\r\n')) {
            socket.write('HTTP/1.1 100 Continue\r\n\r\n');
          }
        }, onError: (_) {}),
      );
    },
    // La primera conexion falla a proposito (certificado rechazado): el
    // servidor ve un error de handshake que no debe tumbar el test.
    onError: (_) {},
  );

  // 1) Sin permiso explicito, el certificado autofirmado debe rechazarse.
  final strict = IcecastClient(
    host: '127.0.0.1',
    port: server.port,
    mount: '/tls',
    username: 'source',
    password: 'p',
    useTls: true,
  );
  try {
    await strict.connect();
    check(false, 'un certificado autofirmado se rechaza por defecto');
  } on IcecastException catch (e) {
    check(
      e.message.contains('certificado'),
      'el rechazo explica que el certificado no es valido',
      detail: e.message,
    );
  } catch (e) {
    check(false, 'el rechazo se informa como error de emision', detail: '$e');
  } finally {
    await strict.close();
  }

  // 2) Con el permiso del perfil, la emision funciona.
  final relaxed = IcecastClient(
    host: '127.0.0.1',
    port: server.port,
    mount: '/tls',
    username: 'source',
    password: 'p',
    useTls: true,
    allowBadCertificate: true,
  );
  try {
    await relaxed.connect();
    check(
      relaxed.isConnected,
      'al aceptar el certificado autofirmado se puede emitir',
    );
  } on Object catch (e) {
    check(false, 'la conexion con certificado aceptado funciona', detail: '$e');
  } finally {
    await relaxed.close();
  }

  for (final sub in subs) {
    await sub.cancel();
  }
  await server.close();
}

Future<void> _vumetros() async {
  section('Vumetros (nivel de audio)');

  final silence = LevelMeter();
  silence.feed(Uint8List(2000));
  check(silence.isSilent, 'el silencio se detecta como silencio');
  check(
    silence.peakDb < -50,
    'el pico del silencio esta por debajo de -50 dBFS',
  );

  final full = LevelMeter();
  final pcm = Uint8List(2000);
  final view = ByteData.sublistView(pcm);
  for (var i = 0; i < 1000; i++) {
    view.setInt16(i * 2, i.isEven ? 32767 : -32768, Endian.little);
  }
  full.feed(pcm);
  check(
    full.peakDb > -1 && full.peakDb <= 0,
    'fondo de escala mide ~0 dBFS',
    detail: full.peakDb.toStringAsFixed(2),
  );

  final half = LevelMeter();
  final pcm2 = Uint8List(2000);
  final view2 = ByteData.sublistView(pcm2);
  for (var i = 0; i < 1000; i++) {
    view2.setInt16(i * 2, i.isEven ? 16384 : -16384, Endian.little);
  }
  half.feed(pcm2);
  check(
    (half.peakDb - (-6.02)).abs() < 0.3,
    'media escala mide ~-6 dBFS',
    detail: half.peakDb.toStringAsFixed(2),
  );

  final drop = LevelMeter();
  drop.feed(pcm);
  final peakBefore = drop.peakDb;
  drop.feed(Uint8List(2000));
  check(
    drop.peakDb < peakBefore && drop.peakDb > -60,
    'el vumetro cae suavemente y no salta a cero',
    detail:
        'antes ${peakBefore.toStringAsFixed(1)} -> ahora ${drop.peakDb.toStringAsFixed(1)}',
  );
}

Future<void> _captura() async {
  section('Linea de comandos de la captura');

  const args = CaptureArgs(
    deviceName: 'Micrófono (Realtek)',
    sampleRate: 44100,
    channels: 2,
    backend: CaptureBackend.dshow,
  );
  final cmd = args.build('ffmpeg.exe');
  check(cmd.contains('dshow'), 'usa el capturador dshow de Windows');
  check(
    cmd.contains('audio=Micrófono (Realtek)'),
    'pasa el nombre del dispositivo con acentos',
  );
  check(cmd.contains('f32le'), 'entrega PCM en coma flotante (f32le)');
  check(cmd.contains('pipe:1'), 'el PCM sale por stdout hacia el motor');
  check(
    cmd.contains('44100') && cmd.contains('2'),
    'respeta la frecuencia y los canales del perfil',
  );
  check(
    !cmd.contains('libmp3lame') && !cmd.contains('libfdk_aac'),
    'la captura NO codifica: el codificador es un proceso aparte',
  );
  check(
    !cmd.any((a) => a.startsWith('volume=')),
    'la captura NO lleva la ganancia: se aplica en Dart para poder cambiarla '
    'sin reiniciar el proceso',
  );
  check(
    !cmd.contains('pipe:2'),
    'los niveles ya no comparten la salida de error con el PCM',
  );

  section('Linea de comandos del codificador');

  const encArgs = EncoderArgs(bitrateKbps: 128, sampleRate: 44100, channels: 2);
  final encCmd = encArgs.build('ffmpeg');
  check(
    encCmd.contains('f32le') && encCmd.contains('pipe:0'),
    'el codificador recibe el mismo PCM flotante por stdin',
  );
  check(
    encCmd.contains('-analyzeduration') &&
        encCmd.contains('-probesize') &&
        encCmd.contains('0'),
    'el codificador no analiza el flujo en vivo antes de emitir',
    detail: 'sin esto FFmpeg retiene los primeros segundos de audio',
  );
  check(encCmd.contains('libmp3lame'), 'codifica en MP3 con LAME');
  check(encCmd.contains('128k'), 'respeta el bitrate elegido');
  check(encCmd.contains('pipe:1'), 'el MP3 sale por stdout hacia el motor');
  check(
    encCmd.any((a) => a.contains('alimiter=limit=0.95')),
    'el limitador de seguridad sigue en la cadena del codificador',
  );
  check(
    !encCmd.any((a) => a.startsWith('volume=')),
    'el codificador no aplica ganancia: viene ya procesada desde Dart',
  );

  // Codecs alternativos: el mismo codificador debe poder enviar MP3, AAC-LC o
  // AAC+. La captura es identica en los tres casos.
  const aacArgs = EncoderArgs(
    bitrateKbps: 96,
    sampleRate: 44100,
    channels: 2,
    codec: AudioCodec.aac,
  );
  final aacCmd = aacArgs.build('ffmpeg');
  check(
    aacCmd.contains('aac') && aacCmd.contains('adts'),
    'AAC-LC se codifica con el encoder nativo y contenedor ADTS',
  );
  check(!aacCmd.contains('libmp3lame'), 'AAC no usa el encoder MP3');

  const aacPlusArgs = EncoderArgs(
    bitrateKbps: 48,
    sampleRate: 44100,
    channels: 2,
    codec: AudioCodec.aacPlus,
  );
  final aacPlusCmd = aacPlusArgs.build('ffmpeg');
  check(
    aacPlusCmd.contains('libfdk_aac') && aacPlusCmd.contains('aac_he_v2'),
    'AAC+ usa libfdk_aac con perfil HE-AAC v2',
  );

  const codecSettings = AudioSettings(
    codec: AudioCodec.aacPlus,
    bitrateKbps: 64,
    sampleRate: 44100,
    channels: 2,
  );
  final codecRoundTrip = AudioSettings.fromJson(codecSettings.toJson());
  check(
    codecRoundTrip.codec == AudioCodec.aacPlus &&
        codecRoundTrip.bitrateKbps == 64,
    'el codec y el bitrate se conservan al guardar el perfil',
  );

  check(
    args.preview().contains('-f dshow') && args.preview().contains('pipe:1'),
    'el comando de captura se puede copiar y pegar',
    detail: args.preview(),
  );
  check(
    encArgs.preview().contains('-f f32le') &&
        encArgs.preview().contains('libmp3lame'),
    'el comando del codificador se puede copiar y pegar',
    detail: encArgs.preview(),
  );

  section('Ganancia en vivo sin reiniciar la captura');

  Uint8List floats(List<double> values) {
    final data = Uint8List(values.length * 4);
    final view = ByteData.sublistView(data);
    for (var i = 0; i < values.length; i++) {
      view.setFloat32(i * 4, values[i], Endian.little);
    }
    return data;
  }

  double peakOf(Uint8List data) {
    final view = ByteData.sublistView(data);
    var peak = 0.0;
    for (var i = 0; i < data.length ~/ 4; i++) {
      final v = view.getFloat32(i * 4, Endian.little).abs();
      if (v > peak) peak = v;
    }
    return peak;
  }

  final stage = GainStage();
  final input = floats([0.25, -0.25, 0.125, -0.125]);
  stage.gainDb = 6.0206; // x2
  final doubled = stage.process(input);
  check(
    (peakOf(doubled) - 0.5).abs() < 0.001,
    '+6 dB duplica la amplitud de la misma captura',
    detail: peakOf(doubled).toStringAsFixed(3),
  );
  stage.gainDb = -6.0206; // x0.5
  final halved = stage.process(input);
  check(
    (peakOf(halved) - 0.125).abs() < 0.001,
    'bajar la ganancia en la misma instancia reduce el nivel',
    detail: peakOf(halved).toStringAsFixed(3),
  );
  stage.gainDb = 12;
  final boosted = stage.process(floats([0.8, -0.8]));
  check(
    peakOf(boosted) > 1.0,
    'una ganancia alta conserva el excedente en coma flotante para que el '
    'limitador lo recorte, en vez de saturar en Dart',
    detail: peakOf(boosted).toStringAsFixed(2),
  );

  // Bloques partidos a mitad de muestra: el resto debe esperar al siguiente.
  stage.gainDb = 0;
  final all = floats([0.5, -0.5]);
  final first = stage.process(all.sublist(0, 3));
  final rest = stage.process(all.sublist(3));
  final joined = Uint8List(first.length + rest.length)
    ..setAll(0, first)
    ..setAll(first.length, rest);
  check(
    first.isEmpty && joined.length == 8,
    'un bloque partido se reensambla sin desalinear el audio',
  );
  check(
    (peakOf(joined) - 0.5).abs() < 0.001,
    'el bloque reensamblado conserva las muestras originales',
  );

  // El vumetro debe medir el PCM flotante que sale de la ganancia.
  final meterFloat = LevelMeter();
  meterFloat.feedFloat(doubled);
  check(
    (meterFloat.peakDb - (-6.02)).abs() < 0.3,
    'el vumetro mide el PCM flotante ya amplificado',
    detail: meterFloat.peakDb.toStringAsFixed(2),
  );
  meterFloat.clearHold();
  check(
    meterFloat.peakDb > -20,
    'limpiar el pico retenido no borra la barra (solo el numero)',
  );

  section('Capturadores de Linux (PulseAudio y ALSA)');

  // Linux no usa dshow: segun lo que traiga la build de FFmpeg se captura por
  // PulseAudio/PipeWire (preferido) o por ALSA. La app no debe asumir uno.
  const pulseArgs = CaptureArgs(
    deviceName: 'alsa_input.pci-0000_00_1b.0.analog-stereo',
    sampleRate: 44100,
    channels: 2,
    backend: CaptureBackend.pulse,
  );
  final pulseCmd = pulseArgs.build('ffmpeg');
  check(
    pulseCmd.contains('-f') && pulseCmd.contains('pulse'),
    'PulseAudio usa el capturador pulse de FFmpeg',
  );
  final pulseInput = pulseCmd.indexOf('-i');
  check(
    pulseInput >= 0 &&
        pulseCmd[pulseInput + 1] == 'alsa_input.pci-0000_00_1b.0.analog-stereo',
    'PulseAudio pasa el nombre de la fuente tal cual',
    detail: pulseInput >= 0 ? pulseCmd[pulseInput + 1] : 'sin -i',
  );
  check(!pulseCmd.contains('dshow'), 'en Linux no se cuela dshow');

  const pulseDefault = CaptureArgs(
    deviceName: '',
    sampleRate: 44100,
    channels: 2,
    backend: CaptureBackend.pulse,
  );
  final pulseDefaultCmd = pulseDefault.build('ffmpeg');
  final pulseDefaultInput = pulseDefaultCmd.indexOf('-i');
  check(
    pulseDefaultInput >= 0 &&
        pulseDefaultCmd[pulseDefaultInput + 1] == 'default',
    'sin dispositivo elegido, PulseAudio usa la fuente predeterminada',
  );

  const alsaArgs = CaptureArgs(
    deviceName: 'plughw:0,0',
    sampleRate: 44100,
    channels: 2,
    backend: CaptureBackend.alsa,
  );
  final alsaCmd = alsaArgs.build('ffmpeg');
  check(
    alsaCmd.contains('alsa') && !alsaCmd.contains('pulse'),
    'ALSA usa el capturador alsa de FFmpeg',
  );
  final alsaInput = alsaCmd.indexOf('-i');
  check(
    alsaInput >= 0 && alsaCmd[alsaInput + 1] == 'plughw:0,0',
    'ALSA pasa el PCM elegido (plughw:tarjeta,dispositivo)',
  );

  final expectedDefault = Platform.isWindows
      ? CaptureBackend.dshow
      : CaptureBackend.pulse;
  check(
    CaptureBackend.forPlatform() == expectedDefault,
    'el capturador preferido por plataforma es el esperado',
    detail: CaptureBackend.forPlatform().label,
  );

  final pulsePreview = pulseArgs.preview();
  check(
    pulsePreview.contains('-f pulse') && pulsePreview.contains('pipe:1'),
    'el comando copiable de Linux muestra PulseAudio y las tuberias',
    detail: pulsePreview,
  );

  section('Deteccion del capturador disponible');
  check(
    FfmpegLocator.chooseLinuxBackend(
          hasPulse: true,
          hasAlsa: true,
          pulseReachable: true,
        ) ==
        CaptureBackend.pulse,
    'con PulseAudio y ALSA disponibles se prefiere PulseAudio',
  );
  check(
    FfmpegLocator.chooseLinuxBackend(
          hasPulse: true,
          hasAlsa: true,
          pulseReachable: false,
        ) ==
        CaptureBackend.alsa,
    'si Pulse no responde y hay ALSA, se cae a ALSA',
  );
  check(
    FfmpegLocator.chooseLinuxBackend(
          hasPulse: false,
          hasAlsa: true,
          pulseReachable: null,
        ) ==
        CaptureBackend.alsa,
    'si la build de FFmpeg no trae pulse, se usa ALSA',
  );
  check(
    FfmpegLocator.chooseLinuxBackend(
          hasPulse: true,
          hasAlsa: false,
          pulseReachable: null,
        ) ==
        CaptureBackend.pulse,
    'si solo hay pulse compilado, se usa Pulse',
  );

  section('Mensajes de error entendibles');
  check(
    explainFfmpegError('Access is denied.').contains('Otro programa'),
    'microfono ocupado por Zoom/OBS se explica',
  );
  check(
    explainFfmpegError(
      'Could not find audio only device',
    ).contains('No se encontro el dispositivo'),
    'dispositivo inexistente se explica',
  );
  check(
    explainFfmpegError('Unknown encoder libmp3lame').contains('libmp3lame'),
    'FFmpeg sin MP3 se explica',
  );
  check(
    explainFfmpegError(
      "Unknown input format: 'pulse'",
      backend: CaptureBackend.pulse,
    ).contains('no incluye soporte'),
    'una build de FFmpeg sin Pulse se explica',
  );
  check(
    explainFfmpegError(
      "Unknown input format: 'alsa'",
      backend: CaptureBackend.alsa,
    ).contains('no incluye soporte'),
    'una build de FFmpeg sin ALSA se explica',
  );
  check(
    explainFfmpegError(
      'PulseAudio server connection failure: Connection refused',
      backend: CaptureBackend.pulse,
    ).contains('No se pudo conectar'),
    'el servidor Pulse caido se explica',
  );
  check(
    explainFfmpegError(
      'Failed to open pulse device "no-existe": No such source',
      backend: CaptureBackend.pulse,
    ).contains('No se encontro la fuente'),
    'la fuente de Pulse inexistente se explica',
  );
  check(
    explainFfmpegError(
      'cannot open audio device plughw:0,0 (Device or resource busy)',
      backend: CaptureBackend.alsa,
    ).contains('Otro programa'),
    'el dispositivo ALSA ocupado se explica',
  );
  check(
    explainFfmpegError(
      'ALSA lib pcm.c: Cannot open shared library libasound_module_pcm_pipewire.so',
      backend: CaptureBackend.alsa,
    ).contains('alsa-plugins'),
    'la falta del plugin de ALSA se explica',
  );
  check(
    explainFfmpegError(
      'cannot open audio device hw:99,0 (No such device)',
      backend: CaptureBackend.alsa,
    ).contains('No se encontro el dispositivo'),
    'el dispositivo ALSA inexistente se explica',
  );

  section('Enumeracion de dispositivos en Linux (parseo)');
  // Salida real de `pactl list sources` con LANG=C en PipeWire.
  const pactlSample = """
Source #37
	State: RUNNING
	Name: VBAN-In
	Description: luisnobregon-HP-Stream
	Monitor of Sink: n/a
	Properties:
		media.class = "Audio/Source"

Source #56
	State: SUSPENDED
	Name: alsa_output.pci-0000_00_1b.0.analog-stereo.monitor
	Description: Monitor of Built-in Audio
	Monitor of Sink: alsa_output.pci-0000_00_1b.0.analog-stereo
	Properties:
		media.class = "Audio/Sink"

Source #57
	State: SUSPENDED
	Name: alsa_input.pci-0000_00_1b.0.analog-stereo
	Description: Built-in Audio
	Monitor of Sink: n/a
""";
  final pulseDevices = FfmpegLocator.parsePulseSources(pactlSample);
  check(
    pulseDevices.length == 3,
    'se leen las tres fuentes de Pulse',
    detail: '${pulseDevices.length}',
  );
  check(
    pulseDevices.any((d) => d.id == 'VBAN-In' && !d.isMonitor),
    'se conserva el nombre real de la fuente',
  );
  check(
    pulseDevices.any(
      (d) =>
          d.id == 'alsa_output.pci-0000_00_1b.0.analog-stereo.monitor' &&
          d.isMonitor,
    ),
    'el monitor del altavoz se marca como monitor',
  );
  check(
    pulseDevices.any(
      (d) => d.isMonitor && d.name.contains('Monitor de Built-in Audio'),
    ),
    'la descripcion del monitor se muestra en espanol',
  );
  check(
    pulseDevices.any(
      (d) =>
          d.id == 'alsa_input.pci-0000_00_1b.0.analog-stereo' &&
          d.name.contains('Built-in Audio'),
    ),
    'la descripcion legible acompana al nombre tecnico',
  );

  const arecordSample = """
**** List of CAPTURE Hardware Devices ****
card 0: PCH [HDA Intel PCH], device 0: ALC3227 Analog [ALC3227 Analog]
  Subdevices: 1/1
  Subdevice #0: subdevice #0
card 1: USB [USB Audio], device 0: USB Audio [USB Audio]
  Subdevices: 1/1
  Subdevice #0: subdevice #0
""";
  final alsaCards = FfmpegLocator.parseAlsaCards(arecordSample);
  check(
    alsaCards.length == 2,
    'se leen las tarjetas de arecord -l',
    detail: '${alsaCards.length}',
  );
  check(
    alsaCards.first.id == 'plughw:0,0' && alsaCards.first.name.contains('PCH'),
    'la tarjeta se traduce al PCM que entiende FFmpeg',
  );

  const arecordPcmSample = """
null
    Discard all samples (playback) or generate zero samples (capture)
pipewire
    PipeWire Sound Server
default
    Default ALSA Output (currently PipeWire Media Server)
hw:CARD=PCH,DEV=0
    HDA Intel PCH, ALC3227 Analog
    Hardware device with all software conversions
""";
  final alsaPcms = FfmpegLocator.parseAlsaPcms(arecordPcmSample);
  check(
    alsaPcms.any((d) => d.id == 'pipewire'),
    'los PCM virtuales de ALSA tambien se ofrecen',
  );
  check(
    alsaPcms.any(
      (d) => d.id == 'hw:CARD=PCH,DEV=0' && d.name.contains('HDA Intel PCH'),
    ),
    'el PCM de hardware lleva su descripcion',
  );
  check(
    !alsaPcms.any((d) => d.id == 'null' || d.id == 'default'),
    'se descartan null y default (default ya esta en la lista)',
  );

  check(
    looksLikeMissingDevice('Failed to open pulse device "mic": No such source'),
    'una fuente de Pulse desaparecida se reconoce como dispositivo ausente',
  );

  // --------------------------------------------------------- stderr mixto
  section('Separacion entre PCM de niveles y mensajes de FFmpeg');

  // El PCM de niveles y los mensajes de FFmpeg comparten la misma salida. Si no
  // se separan, los bytes de texto se interpretan como audio (el vumetro salta
  // solo) y el motivo real del fallo se pierde.
  check(
    looksLikeText(utf8.encode('ffmpeg: device already in use')),
    'un mensaje de FFmpeg se reconoce como texto',
  );
  check(
    looksLikeText(
      utf8.encode('[dshow @ 0000] Could not find audio only device'),
    ),
    'una linea de log de FFmpeg se reconoce como texto',
  );
  check(
    !looksLikeText(Uint8List.fromList([0x00, 0x80, 0x12, 0xFF, 0x01, 0x9A])),
    'el PCM binario NO se confunde con texto',
  );
  {
    // Onda cuadrada real: debe tratarse como audio, no como texto.
    final pcm = Uint8List(200);
    final view = ByteData.sublistView(pcm);
    for (var i = 0; i < 100; i++) {
      view.setInt16(i * 2, i.isEven ? 16384 : -16384, Endian.little);
    }
    check(!looksLikeText(pcm), 'una onda PCM real no se confunde con texto');
  }
  check(!looksLikeText(Uint8List(0)), 'un bloque vacio no se considera texto');
  check(
    looksLikeText(utf8.encode('error: acceso denegado\n')),
    'un mensaje con acentos y salto de linea se reconoce',
  );

  // Lo que de verdad hace el motor: separar bloques y quedarse con el
  // diagnostico. Este es el camino que explica un fallo real al DJ.
  section('Diagnostico reconstruido desde la salida de FFmpeg');

  {
    // FFmpeg escribe el motivo como un bloque de texto propio (no mezclado con
    // PCM: cuando falla al abrir el dispositivo, todavia no hay audio).
    final errorBlock = Uint8List.fromList(
      utf8.encode(
        '[dshow @ 0000] Could not find audio only device with name [Mic]\n',
      ),
    );
    final lines = collectFfmpegLines(errorBlock);
    check(
      lines.length == 1 &&
          lines.first.contains('Could not find audio only device'),
      'las lineas de FFmpeg se extraen del bloque',
      detail: lines.length == 1 ? lines.first : '${lines.length} lineas',
    );
    check(
      explainFfmpegError(
        lines.join('\n'),
      ).contains('No se encontro el dispositivo'),
      'con esas lineas se produce el mensaje final que ve el DJ',
    );
  }

  {
    // Un bloque que mezcla texto y binario: se prefiere tratarlo como audio
    // antes que arriesgar un diagnostico inventado con bytes de PCM.
    final mixed = Uint8List.fromList(<int>[
      ...utf8.encode('texto'),
      ...List<int>.filled(24, 0x00),
    ]);
    check(
      collectFfmpegLines(mixed).isEmpty,
      'un bloque mixto se descarta como diagnostico (se prefiere el PCM)',
    );
  }

  {
    // PCM real: una onda senoidal, con bytes repartidos por todo el rango, que
    // es lo que produce un microfono. (Una onda cuadrada con valores como
    // 20000/-20000 resulta indistinguible de texto byte a byte, porque sus
    // bytes caen justo en el rango ASCII imprimible: por eso se usa una onda
    // realista.)
    final pcmOnly = Uint8List(400);
    final view = ByteData.sublistView(pcmOnly);
    for (var i = 0; i < 200; i++) {
      final value = (30000 * math.sin(i / 12.0)).round();
      view.setInt16(i * 2, value, Endian.little);
    }
    check(
      collectFfmpegLines(pcmOnly).isEmpty,
      'un bloque de PCM real no aporta lineas de diagnostico',
    );
    final meter = LevelMeter();
    meter.feed(pcmOnly);
    check(
      meter.peakDb > -12 && meter.peakDb <= 0,
      'y ese mismo bloque si mueve el vumetro como audio',
      detail: '${meter.peakDb.toStringAsFixed(1)} dBFS',
    );
  }

  {
    final multi = Uint8List.fromList(
      utf8.encode('linea uno\nlinea dos\n\nlinea tres\n'),
    );
    final lines = collectFfmpegLines(multi);
    check(
      lines.length == 3,
      'se descartan las lineas vacias',
      detail: lines.toString(),
    );
  }

  // ------------------------------------------- diagnostico de un solo disparo
  section('Diagnostico activo cuando la captura muere');

  // Textos reales que produce FFmpeg al fallar al abrir el dispositivo. Son los
  // que el motor obtiene al relanzar FFmpeg pidiendo un instante de audio.
  const realDeviceErrors = <String, String>{
    '[dshow @ 0000] Could not find audio only device with name [Mic] among '
            'source devices.':
        'No se encontro el dispositivo',
    "dshow: Could not open audio device\nAccess is denied.": 'Otro programa',
    'Unknown encoder libmp3lame': 'libmp3lame',
  };

  for (final entry in realDeviceErrors.entries) {
    final lines = collectFfmpegLines(
      Uint8List.fromList(utf8.encode(entry.key)),
    );
    final hint = explainFfmpegError(lines.join('\n'));
    check(
      hint.contains(entry.value),
      'el error real "${entry.key.split('\n').first}" se traduce a algo util',
      detail: hint,
    );
  }

  // Si el diagnostico no aporta nada, el motor debe decirlo en vez de inventar.
  check(
    explainFfmpegError('').contains('sin explicar el motivo'),
    'un diagnostico vacio se declara como tal (sin inventar un motivo)',
  );
}

Future<void> _cifrado() async {
  section('Almacen de credenciales');
  final store = createSecretStore();

  const secreto = 'miClaveSuperSecreta!123';
  final protected = store.protect(secreto);

  if (Platform.isWindows) {
    check(store.isSecure, 'DPAPI esta disponible en Windows');
    check(protected.ok, 'la contrasena se puede cifrar');
    if (protected.ok) {
      final blob = protected.data!;
      final asText = latin1.decode(blob, allowInvalid: true);
      check(
        !asText.contains('miClaveSuperSecreta'),
        'el blob cifrado NO contiene la contrasena en claro',
      );
      check(
        blob.isNotEmpty,
        'el blob tiene contenido',
        detail: '${blob.length} bytes',
      );

      final back = store.unprotect(blob);
      check(back.ok, 'el blob cifrado se puede descifrar');
      if (back.ok) {
        check(
          utf8.decode(back.data!) == secreto,
          'el descifrado devuelve la contrasena original',
        );
      }
    }
  } else {
    // En Linux/macOS no hay DPAPI. El backend debe ser honesto y no fingir
    // cifrado; la proteccion real son los permisos 0600 del archivo.
    check(
      !store.isSecure,
      'en ${Platform.operatingSystem} el backend avisa que no hay cifrado',
    );
    check(protected.ok, 'la contrasena se puede guardar igual');
    if (protected.ok) {
      final back = store.unprotect(protected.data!);
      check(back.ok, 'el secreto guardado se puede recuperar');
      if (back.ok) {
        check(
          utf8.decode(back.data!) == secreto,
          'el secreto recuperado coincide',
        );
      }
    }
  }

  // Un blob manipulado debe fallar en lugar de devolver basura.
  final corrupto = Uint8List.fromList(List.filled(64, 7));
  final r = store.unprotect(corrupto);
  check(!r.ok, 'un blob manipulado se rechaza en vez de descifrarse mal');
}

Future<void> _persistencia() async {
  section('Persistencia de perfiles y secretos');
  final temp = await Directory.systemTemp.createTemp('xtreme_test_');
  try {
    final store = ProfileStore(baseDirectory: temp);
    await store.ensureDirectories();

    final profile = ServerProfile(
      id: ProfileStore.newId(),
      name: 'Radio Prueba',
      host: 'stream.ejemplo.fm',
      port: 8000,
      mount: 'miradio',
      username: 'source',
      password: 'ClaveDelDJ2026',
      adminUsername: 'admin',
      adminPassword: 'ClaveAdmin2026',
      stationName: 'Radio Prueba FM',
      publicUrl: 'https://ejemplo.fm/miradio',
      useTls: true,
      allowBadCertificate: true,
      inputDeviceId: 'Microfono de la radio',
      autoReconnect: false,
    );

    await store.save(profile);
    check(true, 'el perfil se guarda sin errores');

    // El archivo de configuracion no debe contener la contrasena.
    final configText = await store.profilesFile.readAsString();
    check(
      !configText.contains('ClaveDelDJ2026'),
      'profiles.json NO contiene la contrasena',
    );
    check(
      !configText.contains('ClaveAdmin2026'),
      'profiles.json NO contiene la clave de administracion',
    );
    check(
      configText.contains('stream.ejemplo.fm'),
      'profiles.json si contiene host y configuracion',
    );

    // El archivo de secreto debe existir y estar cifrado.
    final secretFile = File(
      '${store.secretsDir.path}${Platform.pathSeparator}${profile.id}.bin',
    );
    check(secretFile.existsSync(), 'existe un archivo de secreto por perfil');
    if (secretFile.existsSync()) {
      final blob = await secretFile.readAsBytes();
      final text = latin1.decode(blob, allowInvalid: true);
      if (Platform.isWindows) {
        check(
          !text.contains('ClaveDelDJ2026'),
          'el archivo de secreto esta cifrado, no en claro',
        );
      } else {
        check(
          text.startsWith('xtreme-plain-v1:'),
          'el archivo de secreto usa el formato marcado de la plataforma',
        );
        final mode = await Process.run('stat', ['-c', '%a', secretFile.path]);
        check(
          (mode.stdout as String).trim() == '600',
          'el archivo de credenciales es privado (permisos 0600)',
        );
      }
    }

    // Al recargar debe volver la contrasena.
    final loaded = await store.load();
    check(loaded.length == 1, 'se recarga un perfil');
    check(
      loaded.first.password == 'ClaveDelDJ2026',
      'la contrasena se recupera descifrada',
    );
    check(
      loaded.first.adminPassword == 'ClaveAdmin2026',
      'la clave de administracion se recupera descifrada',
    );
    check(
      loaded.first.adminUsername == 'admin',
      'el usuario de administracion se recupera',
    );
    check(
      loaded.first.normalizedMount == '/miradio',
      'el mount se normaliza con barra inicial',
    );
    check(
      loaded.first.allowBadCertificate,
      'se recuerda aceptar el certificado autofirmado de esta emisora',
    );
    check(
      loaded.first.inputDeviceId == 'Microfono de la radio',
      'se recuerda el microfono asignado a la emisora',
    );
    check(
      !loaded.first.autoReconnect,
      'se recuerda si la reconexion automatica esta desactivada',
    );

    // Exportar sin contrasena no debe filtrarla.
    final exported = store.exportProfile(loaded.first);
    check(
      !exported.contains('ClaveDelDJ2026'),
      'exportar un perfil NO incluye la contrasena',
    );
    check(
      !exported.contains('ClaveAdmin2026'),
      'exportar un perfil NO incluye la clave de administracion',
    );

    // Tampoco puede filtrarla cuando se pide incluirla: al compartir el texto
    // por chat o correo, una clave en claro quedaria a la vista de todos.
    final exportedWithPassword = store.exportProfile(
      loaded.first,
      includePassword: true,
    );
    check(
      !exportedWithPassword.contains('ClaveDelDJ2026'),
      'exportar con includePassword tampoco escribe la clave en claro',
    );

    // La importacion debe aceptar ese mismo texto sin contrasena.
    final reimportado = await store.importProfile(exported);
    check(
      reimportado.host == loaded.first.host &&
          reimportado.mount == loaded.first.mount,
      'la importacion recupera host y mount',
    );
    check(
      reimportado.password.isEmpty,
      'la importacion no inventa la contrasena',
    );

    // Borrado.
    await store.delete(profile.id);
    final after = await store.load();
    check(after.isEmpty, 'el perfil se elimina');
    check(!secretFile.existsSync(), 'el secreto se elimina junto al perfil');
    final adminSecretFile = File(
      '${store.secretsDir.path}${Platform.pathSeparator}'
      '${profile.id}.admin.bin',
    );
    check(
      !adminSecretFile.existsSync(),
      'la clave de administracion se elimina junto al perfil',
    );

    // ------------------------------------------------------------ ajustes
    final settings = AppSettings()
      ..lastProfileId = 'abc'
      ..ffmpegPath = r'C:\ffmpeg\bin\ffmpeg.exe'
      ..lastDeviceId = 'Microfono (Realtek)'
      ..recordLocally = true
      ..recordDirectory = r'C:\Grabaciones'
      ..keepAwakeWhileLive = false;
    await store.saveSettings(settings);

    final reloaded = await store.loadSettings();
    check(
      reloaded.ffmpegPath == settings.ffmpegPath,
      'la ruta de FFmpeg se conserva entre sesiones',
    );
    check(
      reloaded.lastDeviceId == settings.lastDeviceId,
      'el dispositivo elegido se recuerda al reabrir la app',
    );
    check(
      reloaded.recordLocally &&
          reloaded.recordDirectory == settings.recordDirectory,
      'la configuracion de grabacion se conserva',
    );
    check(
      !reloaded.keepAwakeWhileLive,
      'se recuerda si el DJ quiere evitar el bloqueo de pantalla',
    );
    check(
      AppSettings().keepAwakeWhileLive,
      'evitar el bloqueo viene activado de fabrica',
    );
    check(
      reloaded.lastProfileId == 'abc',
      'se recuerda cual era la emisora activa',
    );

    // ------------------------------------- datos corruptos no bloquean la app
    await store.profilesFile.writeAsString('{ esto no es JSON');
    final trasCorrupto = await store.load();
    check(
      trasCorrupto.isEmpty,
      'un profiles.json corrupto se ignora en vez de lanzar',
    );
    check(
      File('${store.profilesFile.path}.corrupt').existsSync(),
      'el archivo corrupto se conserva aparte para poder recuperarlo',
    );
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<void> _pantalla() async {
  section('Bloqueo de pantalla y suspension');

  // gdbus responde `(uint32 42, )`; dbus-send responde con una cabecera.
  check(
    ScreenGuard.parseCookie('(uint32 42, )') == 42,
    'se lee el cookie que devuelve gdbus',
  );
  check(
    ScreenGuard.parseCookie(
          'method return time=1.2 sender=:1.52 -> destination=:1.52 '
          'serial=9 reply_serial=2\n   uint32 7',
        ) ==
        7,
    'se lee el cookie que devuelve dbus-send',
  );
  check(
    ScreenGuard.parseCookie('(true,)') == null,
    'una respuesta sin cookie no se confunde con un numero',
  );
  check(
    ScreenGuard.parseCookie('') == null,
    'una respuesta vacia no rompe la lectura del cookie',
  );

  // Con el ajuste apagado no se lanza ningun comando externo.
  final apagado = ScreenGuard(enabled: false);
  await apagado.start();
  check(
    !apagado.isRunning,
    'con el ajuste apagado no se inhibe el bloqueo de pantalla',
  );
  await apagado.stop();
}

Future<void> _perfil() async {
  section('Validacion de perfiles');
  final incompleto = ServerProfile(id: 'x', name: '', host: '');
  final problemas = incompleto.validate();
  check(problemas.isNotEmpty, 'un perfil vacio se rechaza');
  check(
    problemas.any((p) => p.contains('nombre')),
    'se exige el nombre del perfil',
  );
  check(
    problemas.any((p) => p.contains('servidor')),
    'se exige el host del servidor',
  );
  check(
    problemas.any((p) => p.contains('contrasena')),
    'se exige la contrasena',
  );

  final ok = ServerProfile(
    id: 'y',
    name: 'Radio',
    host: 'h',
    port: 8000,
    username: 'source',
    password: 'p',
  );
  check(ok.validate().isEmpty, 'un perfil completo pasa la validacion');

  // Importar un perfil exportado (que nunca incluye la contrasena) no debe
  // fallar por falta de clave: se guarda y se le pide al DJ que la escriba.
  final importado = ServerProfile(
    id: 'z',
    name: 'Radio importada',
    host: 'h',
    port: 8000,
    username: 'source',
  );
  check(
    importado.validate(requirePassword: false).isEmpty,
    'un perfil importado sin contrasena se puede guardar',
  );
  check(
    importado.validate().any((p) => p.contains('contrasena')),
    'pero no se puede salir al aire sin escribirla',
  );

  // ------------------------------------------------------------- ganancia
  section('Ganancia de entrada');

  final conGanancia = ServerProfile(
    id: 'g',
    name: 'Radio',
    host: 'h',
    port: 8000,
    username: 'source',
    password: 'p',
  );
  check(conGanancia.gainDb == 0.0, 'una emisora nueva arranca sin ganancia');

  conGanancia.gainDb = 6.5;
  check(conGanancia.validate().isEmpty, '+6.5 dB es un valor aceptable');

  conGanancia.gainDb = 30.0;
  check(
    conGanancia.validate().any((p) => p.contains('ganancia')),
    'una ganancia absurda se rechaza antes de emitir',
    detail: conGanancia.validate().join(' | '),
  );

  conGanancia.gainDb = -30.0;
  check(
    conGanancia.validate().any((p) => p.contains('ganancia')),
    'una atenuacion absurda tambien se rechaza',
  );

  conGanancia.gainDb = 4.0;
  final copia = conGanancia.duplicate(newId: 'g2');
  check(copia.gainDb == 4.0, 'duplicar una emisora conserva su ganancia');

  // La ganancia debe sobrevivir al guardado, porque cada emisora puede usar un
  // microfono distinto y seria molesto reajustarla cada vez.
  final roundTrip = ServerProfile.fromJson(conGanancia.toJson());
  check(
    roundTrip.gainDb == 4.0,
    'la ganancia se conserva al guardar y recargar el perfil',
    detail: '${roundTrip.gainDb}',
  );

  // Y debe aplicarse en la etapa de ganancia del motor (Dart), no como filtro
  // de FFmpeg: asi se puede cambiar en vivo sin reiniciar la captura.
  final gainStage = GainStage(gainDb: conGanancia.gainDb);
  check(
    (gainStage.linearGain - 1.5849).abs() < 0.001,
    'la ganancia del perfil se convierte a factor lineal para el audio',
    detail: gainStage.linearGain.toStringAsFixed(4),
  );

  // ------------------------------------------------- reconexion automatica
  section('Reconexion automatica por emisora');

  final conReconexion = ServerProfile(
    id: 'r',
    name: 'Radio',
    host: 'h',
    port: 8000,
    username: 'source',
    password: 'p',
  );
  check(
    conReconexion.autoReconnect,
    'una emisora nueva reconecta automaticamente (lo esperable en radio)',
  );

  conReconexion.autoReconnect = false;
  check(
    !conReconexion.autoReconnect,
    'se puede desactivar: hay casos donde reiniciar solo es peor',
  );

  final roundTripReconnect = ServerProfile.fromJson(conReconexion.toJson());
  check(
    !roundTripReconnect.autoReconnect,
    'el ajuste de reconexion sobrevive al guardado y recarga',
  );

  check(
    conReconexion.duplicate(newId: 'r2').autoReconnect == false,
    'duplicar una emisora conserva su ajuste de reconexion',
  );

  // El motor debe consultar el perfil, no una constante: es el fallo que tenia
  // esta funcion (el ajuste existia en la interfaz pero el motor lo ignoraba).
  final engineSrc = File(
    'lib/core/audio/broadcast_engine.dart',
  ).readAsStringSync();
  check(
    engineSrc.contains('profile.autoReconnect'),
    'el motor consulta el ajuste del perfil antes de reconectar',
  );
  check(
    RegExp(r'profile\.autoReconnect').allMatches(engineSrc).isNotEmpty &&
        engineSrc.contains('reconexion automatica esta desactivada'),
    'y explica al DJ cuando no reconecta por estar desactivado',
  );

  // -------------------------------------------------- reparacion de nombres
  section('Nombres de dispositivo mal codificados');

  // Estos son los valores REALES que quedaron guardados en un equipo con
  // Windows en espanol: FFmpeg emite UTF-8 y la version anterior lo decodificaba
  // como Latin-1, dejando el nombre doblemente codificado. Ese nombre no existe
  // en el sistema y hacia fallar la captura sin explicacion.
  const casos = <String, String>{
    'Mezcla estÃ©reo (Realtek Audio)': 'Mezcla estéreo (Realtek Audio)',
    'LÃ­nea (USB AUDIO  CODEC)': 'Línea (USB AUDIO  CODEC)',
    'Varios micrÃ³fonos (Realtek Audio)': 'Varios micrófonos (Realtek Audio)',
  };

  for (final entry in casos.entries) {
    final fixed = repairDeviceName(entry.key);
    check(
      fixed == entry.value,
      'se recupera el nombre real de "${entry.key}"',
      detail: 'obtenido: "$fixed"',
    );
  }

  // Un nombre correcto no debe tocarse: si la reparacion fallara en esto,
  // romperia equipos que hoy funcionan.
  const correctos = <String>[
    'Mezcla estéreo (Realtek Audio)',
    'Línea (USB AUDIO  CODEC)',
    'Micrófono (Realtek Audio)',
    'Microphone (USB Audio Device)',
    'Stereo Mix (Realtek Audio)',
  ];
  final danados = <String>[];
  for (final name in correctos) {
    if (repairDeviceName(name) != name) {
      danados.add('$name -> ${repairDeviceName(name)}');
    }
  }
  check(
    danados.isEmpty,
    'un nombre ya correcto no se modifica',
    detail: danados.join(' | '),
  );

  // El comando de captura debe llevar el nombre reparado, con sus acentos en
  // UTF-8, que es lo que espera FFmpeg.
  {
    final args = CaptureArgs(
      deviceName: repairDeviceName('Mezcla estÃ©reo (Realtek Audio)'),
      sampleRate: 44100,
      channels: 2,
      backend: CaptureBackend.dshow,
    );
    final cmd = args.build('ffmpeg.exe');
    final idx = cmd.indexOf('-i');
    check(
      idx >= 0 && cmd[idx + 1] == 'audio=Mezcla estéreo (Realtek Audio)',
      'el comando de captura usa el nombre reparado, sin doble codificacion',
      detail: idx >= 0 ? cmd[idx + 1] : 'sin -i',
    );
  }

  // ------------------------------------------- expresiones regulares
  section('Expresiones regulares y filtrado de secretos');

  // Dart NO admite modificadores en linea al inicio del patron. Escribir un
  // modificador en linea (la letra i entre parentesis al principio del patron)
  // lanza FormatException en tiempo de ejecucion, no al compilar. Ese error,
  // dentro del registro de diagnostico, tumbaba la aplicacion entera al
  // arrancar, y ninguna comprobacion estructural lo detectaba.
  //
  // La forma correcta es pasar `caseSensitive: false`.
  {
    final dartFiles = <File>[
      ...Directory('lib').listSync(recursive: true).whereType<File>(),
      ...Directory('tool').listSync(recursive: true).whereType<File>(),
    ].where((f) => f.path.endsWith('.dart'));

    final offenders = <String>[];
    // El patron se arma por concatenacion a proposito: escrito literalmente en
    // este archivo, el verificador se marcaria a si mismo (profecia
    // autocumplida), porque el texto del patron aparece en el propio codigo.
    final inlineFlagPattern = RegExp(
      // ignore: prefer_adjacent_string_concatenation
      r'RegExp\(\s*r?[' + "'" + r'"]\(\?' + r'[ismxU]',
      caseSensitive: false,
    );
    for (final f in dartFiles) {
      final src = f.readAsStringSync();
      for (final m in inlineFlagPattern.allMatches(src)) {
        final line = src.substring(0, m.start).split('\n').length;
        offenders.add('${f.path}:$line');
      }
    }
    check(
      offenders.isEmpty,
      'ningun RegExp usa modificadores en linea ((?i)) que Dart no admite',
      detail: offenders.join(', '),
    );
  }

  // Cada expresion regular del nucleo debe poder construirse de verdad.
  {
    const patterns = <String>[
      r'(password|contrasena|contraseña|clave|pass|pwd|authorization)\s*[:=]\s*\S+',
      r'basic\s+[A-Za-z0-9+/=]{8,}',
      r'"([^"]+)"\s*\((audio|video)\)',
      r"StreamTitle='([^']*)'",
      r'^HTTP/\d\.\d\s+(\d{3})',
      r'\r?\n',
    ];
    final failures = <String>[];
    for (final p in patterns) {
      try {
        RegExp(p);
      } catch (e) {
        failures.add('$p -> $e');
      }
    }
    check(
      failures.isEmpty,
      'las expresiones regulares del nucleo son validas',
      detail: failures.join(' | '),
    );
  }

  // El filtro de secretos es lo que garantiza que el registro no guarde
  // contrasenas: si fallara, quedarian en disco en texto plano.
  {
    const secreto = 'MiClaveSecreta123';
    final basic = base64Encode(utf8.encode('source:$secreto'));
    final casos = <String>[
      'password=$secreto',
      'Password: $secreto',
      'clave=$secreto',
      'Authorization: Basic $basic',
    ];
    final fallos = <String>[];
    for (final caso in casos) {
      final limpio = redactSecrets(caso);
      if (limpio.contains(secreto) || limpio.contains(basic)) {
        fallos.add('"$caso" -> "$limpio"');
      }
    }
    check(
      fallos.isEmpty,
      'el filtro de secretos oculta toda contrasena',
      detail: fallos.join(' | '),
    );
  }
}
