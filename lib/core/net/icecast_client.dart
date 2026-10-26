/// Cliente de ingesta **Icecast 2** (y compatibles: AzuraCast, Zeno.fm,
/// Icecast-KH, SHOUTcast v2 en modo HTTP).
///
/// Implementado en Dart puro, no delegado a ffmpeg, por tres razones:
///
/// 1. **Metadatos en vivo**: se actualizan con una peticion HTTP aparte a
///    `/admin/metadata` (el mecanismo de ICY que usan Icecast y Zeno.fm). No se
///    insertan bytes de texto dentro del audio: el servidor los interpretaria
///    como MP3/AAC y se oirian como ruido de fondo.
/// 2. **Reconexion sin cortar el audio**: si se cae la red solo se rehace el
///    socket; la captura y la codificacion siguen intactas.
/// 3. **Diagnostico real**: vemos el codigo HTTP del servidor y podemos decirle
///    al DJ *por que* fallo (401 contrasena mala, 403 mount ocupado, etc.) en
///    lugar de un "error generico".
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Forma de abrir la conexion TCP. Inyectable para poder probar sin red.
typedef SocketConnector =
    Future<Socket> Function(
      String host,
      int port, {
      bool useTls,
      bool allowBadCertificate,
    });

Future<Socket> defaultSocketConnector(
  String host,
  int port, {
  bool useTls = false,
  bool allowBadCertificate = false,
}) async {
  if (useTls) {
    return SecureSocket.connect(
      host,
      port,
      // Solo se acepta un certificado invalido si el DJ lo activo para esta
      // emisora. Es habitual en radios pequenas con certificado autofirmado.
      onBadCertificate: allowBadCertificate ? (_) => true : (_) => false,
      timeout: const Duration(seconds: 15),
    );
  }
  return Socket.connect(host, port, timeout: const Duration(seconds: 15));
}

/// Error de conexion con contexto util para mostrarle al DJ.
class IcecastException implements Exception {
  IcecastException(this.message, {this.statusCode, this.serverMessage});

  final String message;
  final int? statusCode;
  final String? serverMessage;

  @override
  String toString() {
    final parts = <String>[message];
    if (statusCode != null) parts.add('HTTP $statusCode');
    if (serverMessage != null && serverMessage!.isNotEmpty) {
      parts.add(serverMessage!);
    }
    return parts.join(' - ');
  }
}

/// Cliente de un mount de Icecast.
class IcecastClient {
  IcecastClient({
    required this.host,
    required this.port,
    required this.mount,
    required this.username,
    required this.password,
    this.useTls = false,
    this.allowBadCertificate = false,
    this.userAgent = 'XtremeStudio/0.1',
    this.iceName = '',
    this.iceGenre = '',
    this.iceDescription = '',
    this.contentType = 'audio/mpeg',
    this.adminUsername = '',
    this.adminPassword = '',
    SocketConnector? connector,
  }) : _connect = connector ?? defaultSocketConnector;

  final String host;
  final int port;
  final String mount;
  final String username;
  final String password;
  final bool useTls;

  /// Acepta certificados TLS invalidos (autofirmados) para esta emisora.
  final bool allowBadCertificate;

  /// Tipo MIME del flujo (`audio/mpeg` para MP3, `audio/aac`/`audio/aacp`
  /// para AAC). El servidor lo usa para publicar el mount correctamente.
  final String contentType;

  final String userAgent;
  final String iceName;
  final String iceGenre;
  final String iceDescription;

  /// Credenciales del panel de administracion (opcionales).
  ///
  /// Icecast acepta las credenciales de la fuente para actualizar el titulo de
  /// su propio mount. Si el hosting exige las de administracion, se intentan
  /// como respaldo.
  final String adminUsername;
  final String adminPassword;

  final SocketConnector _connect;

  Socket? _socket;
  bool _connected = false;
  bool _socketClosed = false;
  StreamSubscription<List<int>>? _socketSub;

  /// Se dispara cuando el servidor corta la conexion a mitad de la emision.
  ///
  /// Sin esto, `socket.add()` sobre un socket muerto **no lanza error** en
  /// Dart: los bytes se pierden en el buffer y la app seguiria diciendo
  /// "AL AIRE" sin que nadie escuche. Es el fallo mas peligroso de un emisor.
  final _connectionLost = StreamController<void>.broadcast();
  Stream<void> get onConnectionLost => _connectionLost.stream;

  bool get isConnected => _connected;

  /// Bytes de audio efectivamente aceptados por el servidor.
  int _bytesSent = 0;
  int get bytesSent => _bytesSent;

  /// Encabezado HTTP que espera Icecast. `Expect: 100-continue` permite que el
  /// servidor rechace credenciales invalidas **antes** de que le mandemos
  /// audio, y asi leer un 401 limpio.
  String buildPutRequest() {
    final b = StringBuffer()
      ..write('PUT $mount HTTP/1.1\r\n')
      ..write('Host: $host:$port\r\n')
      ..write('Authorization: Basic ${_basicAuth(username, password)}\r\n')
      ..write('User-Agent: $userAgent\r\n')
      ..write('Content-Type: $contentType\r\n')
      ..write('Expect: 100-continue\r\n');

    if (iceName.isNotEmpty) b.write('ice-name: $iceName\r\n');
    if (iceGenre.isNotEmpty) b.write('ice-genre: $iceGenre\r\n');
    if (iceDescription.isNotEmpty) {
      b.write('ice-description: $iceDescription\r\n');
    }
    if (username.isNotEmpty) b.write('ice-public: 1\r\n');
    b.write('Connection: keep-alive\r\n\r\n');
    return b.toString();
  }

  static String _basicAuth(String user, String pass) =>
      base64Encode(utf8.encode('$user:$pass'));

  /// Conecta y deja la sesion lista para enviar audio.
  ///
  /// Lanza [IcecastException] con un mensaje entendible si el servidor
  /// rechaza la conexion.
  Future<void> connect() async {
    await close();

    Socket socket;
    try {
      socket = await _connect(
        host,
        port,
        useTls: useTls,
        allowBadCertificate: allowBadCertificate,
      );
    } on HandshakeException catch (e) {
      throw IcecastException(
        'El certificado HTTPS de $host:$port no es valido '
        '(${e.message}). Si tu emisora usa un certificado propio, activa '
        '"Aceptar certificado autofirmado" en el perfil.',
      );
    } on TlsException catch (e) {
      throw IcecastException(
        'No se pudo establecer la conexion cifrada con $host:$port: '
        '${e.message}. Revisa que el servidor soporte HTTPS en ese puerto.',
      );
    } on SocketException catch (e) {
      throw IcecastException(
        'No se pudo conectar a $host:$port. Revisa el host y el puerto. '
        '(${e.osError?.message ?? e.message})',
      );
    }

    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;
    // Los errores de escritura (EPIPE) se entregan tambien por `done`, no solo
    // por el flujo de lectura. Sin observarlo, Dart los trata como error no
    // capturado y cierra la app en plena emision.
    unawaited(
      socket.done.catchError((Object _) {
        _onSocketDown();
      }),
    );

    try {
      socket.write(buildPutRequest());
      await socket.flush();

      final response = await _readHttpResponse(socket);
      final status = response.statusCode;

      // 100 Continue: el servidor acepto las credenciales y espera audio.
      if (status == 100 || status == 200 || status == 201) {
        _connected = true;
        _bytesSent = 0;
        _socketClosed = false;
        return;
      }

      throw IcecastException(
        _explainStatus(status),
        statusCode: status,
        serverMessage: response.body,
      );
    } catch (_) {
      await close();
      rethrow;
    }
  }

  /// Traduce el codigo HTTP a algo que el DJ pueda accionar.
  String _explainStatus(int status) => switch (status) {
    401 => 'El servidor rechazo el usuario o la contrasena',
    403 => 'Acceso prohibido: puede que otro DJ ya este al aire en este mount',
    404 => 'El mount no existe en el servidor. Revisa la ruta (ej. /stream)',
    409 => 'El mount ya tiene una fuente activa',
    400 => 'El servidor no acepto la peticion. Revisa el formato del mount',
    _ => 'El servidor respondio con un error',
  };

  /// Envia un bloque de audio ya codificado, sin tocarlo.
  ///
  /// El flujo debe llegar al servidor tal cual: insertar bloques de metadatos
  /// aqui (el viejo `icy-metaint`) hacia que Icecast los tratara como audio y
  /// produjera ruido. El titulo va por [setMetadata], en otra conexion.
  void send(Uint8List audio) {
    final socket = _socket;
    if (socket == null || !_connected || audio.isEmpty) return;

    // `Socket.add` puede lanzar de forma sincrona si el sistema ya detecto que
    // la conexion se corto (EPIPE). Sin este try/catch, esa excepcion sube por
    // el flujo de audio y tumba la app en plena emision.
    try {
      socket.add(audio);
      _bytesSent += audio.length;
    } catch (_) {
      _onSocketDown();
    }
  }

  /// Fuerza la salida de lo pendiente y detecta una red estancada.
  ///
  /// `Socket.add` solo copia al buffer interno: si el servidor deja de leer o
  /// la red se corta en silencio, los bytes se acumulan en memoria y la app
  /// sigue mostrando "AL AIRE" sin que nadie reciba audio. `flush` completa
  /// solo cuando el sistema acepta los datos; si no completa en [timeout], se
  /// da la conexion por perdida para que el motor reconecte.
  Future<void> flush({Duration timeout = const Duration(seconds: 5)}) async {
    final socket = _socket;
    if (socket == null || !_connected) return;
    try {
      await socket.flush().timeout(timeout);
    } catch (_) {
      _onSocketDown();
    }
  }

  /// Cambia el "suena ahora" en Icecast.
  ///
  /// Icecast 2 no acepta metadatos intercalados en el flujo de la fuente: el
  /// titulo se actualiza con una peticion aparte
  /// `/admin/metadata?mount=...&mode=updinfo&song=...`. Las credenciales del
  /// mount (las mismas de la fuente) sirven para su propio mount; si el
  /// hosting exige las de administracion, se usan como respaldo.
  ///
  /// Devuelve `true` solo si el servidor respondio 2xx. Asi la interfaz puede
  /// avisar cuando Zeno.fm (u otro hosting) rechaza el cambio.
  Future<bool> setMetadata(String song, {String? artist, String? title}) async {
    final value =
        (artist != null &&
            artist.isNotEmpty &&
            title != null &&
            title.isNotEmpty)
        ? '$artist - $title'
        : song;
    if (value.trim().isEmpty) return false;

    if (await _sendMetadataRequest(value, username, password)) return true;
    if (adminUsername.isNotEmpty && adminPassword.isNotEmpty) {
      return _sendMetadataRequest(value, adminUsername, adminPassword);
    }
    return false;
  }

  Future<bool> _sendMetadataRequest(
    String value,
    String user,
    String pass,
  ) async {
    Socket? socket;
    try {
      socket = await _connect(
        host,
        port,
        useTls: useTls,
        allowBadCertificate: allowBadCertificate,
      );
      socket.setOption(SocketOption.tcpNoDelay, true);
      final query = Uri(
        queryParameters: {'mount': mount, 'mode': 'updinfo', 'song': value},
      ).query;
      socket.write(
        'GET /admin/metadata?$query HTTP/1.0\r\n'
        'Host: $host:$port\r\n'
        'Authorization: Basic ${_basicAuth(user, pass)}\r\n'
        'User-Agent: $userAgent\r\n'
        'Connection: close\r\n\r\n',
      );
      await socket.flush().timeout(const Duration(seconds: 8));
      final status = await _readStatusCode(
        socket,
      ).timeout(const Duration(seconds: 8));
      return status >= 200 && status < 300;
    } catch (_) {
      return false;
    } finally {
      try {
        socket?.destroy();
      } catch (_) {}
    }
  }

  /// Lee solo la linea de estado de la respuesta HTTP.
  Future<int> _readStatusCode(Socket socket) {
    final completer = Completer<int>();
    StreamSubscription<List<int>>? sub;
    final buffer = <int>[];

    void finish() {
      final text = latin1.decode(buffer, allowInvalid: true);
      final match = RegExp(r'^HTTP/\d\.\d\s+(\d{3})').firstMatch(text);
      if (!completer.isCompleted) {
        completer.complete(match != null ? int.parse(match.group(1)!) : 0);
      }
      unawaited(sub?.cancel());
    }

    sub = socket.listen(
      (data) {
        buffer.addAll(data);
        final text = latin1.decode(buffer, allowInvalid: true);
        if (text.contains('\r\n') || buffer.length > 8192) finish();
      },
      onError: (_) {
        if (!completer.isCompleted) completer.complete(0);
      },
      onDone: () {
        if (!completer.isCompleted) finish();
      },
      cancelOnError: false,
    );
    return completer.future;
  }

  /// Lee la respuesta HTTP **y** deja la conexion vigilada.
  ///
  /// Se hace todo en una sola suscripcion a proposito: el socket de Dart admite
  /// un unico `listen`, asi que escuchar dos veces (una para la respuesta y otra
  /// para detectar la caida) lanza "Stream has already been listened to".
  ///
  /// Tras el `PUT`, Icecast no vuelve a enviar datos durante la emision; lo
  /// unico que puede pasar es que cierre la conexion, y eso llega por `onDone`
  /// o `onError`. Detectar eso es lo que permite reconectar en lugar de seguir
  /// mostrando "AL AIRE" hacia un socket muerto.
  Future<_HttpResponse> _readHttpResponse(Socket socket) async {
    final chunks = <int>[];
    final completer = Completer<_HttpResponse>();
    var headersComplete = false;

    void completeFromHeaders() {
      if (headersComplete) return;
      headersComplete = true;

      final text = latin1.decode(chunks, allowInvalid: true);
      final lines = text.split('\r\n');
      final statusLine = lines.isEmpty ? '' : lines.first;
      final match = RegExp(r'^HTTP/\d\.\d\s+(\d{3})').firstMatch(statusLine);
      final status = match != null ? int.parse(match.group(1)!) : 0;

      // El cuerpo de un error de Icecast es texto plano corto.
      final bodyStart = text.indexOf('\r\n\r\n');
      var body = bodyStart >= 0 ? text.substring(bodyStart + 4) : '';
      body = body.trim();
      if (body.startsWith('HTTP/')) body = '';

      if (!completer.isCompleted) {
        completer.complete(_HttpResponse(status, statusLine, body));
      }
    }

    _socketSub?.cancel();
    _socketSub = socket.listen(
      (data) {
        if (headersComplete) return; // Ya estamos al aire: se ignora.
        chunks.addAll(data);
        final text = latin1.decode(chunks, allowInvalid: true);
        // `\r\n\r\n` cierra las cabeceras. Tambien se corta si el servidor
        // manda un cuerpo enorme sin fin (no es una respuesta valida).
        if (text.contains('\r\n\r\n') || chunks.length > 8192) {
          completeFromHeaders();
        }
      },
      onError: (Object e) {
        if (headersComplete) {
          // Estabamos al aire y se cayo la conexion.
          _onSocketDown();
          return;
        }
        if (!completer.isCompleted) {
          completer.completeError(
            IcecastException('Se corto la conexion antes de responder: $e'),
          );
        }
      },
      onDone: () {
        if (headersComplete) {
          _onSocketDown();
          return;
        }
        // Se cerro sin mandar `\r\n\r\n`: se intenta interpretar lo recibido.
        completeFromHeaders();
        if (!completer.isCompleted) {
          completer.completeError(
            IcecastException(
              'El servidor cerro la conexion sin responder. '
              'Verifica que el puerto sea el de publicacion y que el mount '
              'exista.',
            ),
          );
        }
      },
      cancelOnError: false,
    );

    // Si no hay respuesta en 15 s, asumimos que el servidor no contesta.
    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        _socketSub?.cancel();
        throw IcecastException(
          'El servidor no respondio en 15 s. Revisa host, puerto y firewall.',
        );
      },
    );
  }

  /// Cierra la sesion. Deja el socket listo para una reconexion.
  Future<void> close() async {
    _connected = false;
    // Al cerrar nosotros, no debe dispararse el aviso de caida.
    _socketClosed = true;
    await _socketSub?.cancel();
    _socketSub = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      try {
        await socket.flush().timeout(const Duration(seconds: 2));
      } catch (_) {
        // El socket ya podia estar muerto; no es un error del usuario.
      }
      try {
        await socket.close().timeout(const Duration(seconds: 2));
      } catch (_) {
        // Idem.
      }
      socket.destroy();
    }
  }

  void _onSocketDown() {
    if (_socketClosed) return;
    _socketClosed = true;
    if (!_connected) return;
    _connected = false;
    if (!_connectionLost.isClosed) _connectionLost.add(null);
  }

  /// Pide al servidor que libere el mount.
  ///
  /// Es el `mode=delete` de Icecast: sin esto, el servidor mantiene la fuente
  /// ocupada hasta que expira por timeout, y el proximo DJ no puede entrar.
  Future<void> disconnectSource() async {
    try {
      final socket = await _connect(
        host,
        port,
        useTls: useTls,
        allowBadCertificate: allowBadCertificate,
      );
      unawaited(socket.done.catchError((Object _) {}));
      socket.write(
        'GET $mount?mode=delete HTTP/1.1\r\n'
        'Host: $host:$port\r\n'
        'Authorization: Basic ${_basicAuth(username, password)}\r\n'
        'User-Agent: $userAgent\r\n'
        'Connection: close\r\n\r\n',
      );
      await socket.flush();
      await socket.close();
      socket.destroy();
    } catch (_) {
      // Best effort: si falla, el servidor soltara la fuente por timeout.
    }
  }

  /// Libera los recursos del cliente (incluido el aviso de caida).
  Future<void> dispose() async {
    await close();
    await _connectionLost.close();
  }
}

class _HttpResponse {
  const _HttpResponse(this.statusCode, this.statusLine, this.body);

  final int statusCode;
  final String statusLine;
  final String body;
}
