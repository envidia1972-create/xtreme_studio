/// Cliente de ingesta **Icecast 2** (y compatibles: AzuraCast, Zeno.fm,
/// Icecast-KH, SHOUTcast v2 en modo HTTP).
///
/// Implementado en Dart puro, no delegado a ffmpeg, por tres razones:
///
/// 1. **Metadatos en vivo**: insertamos los bloques `icy-metaint` en el propio
///    flujo de bytes, asi el "suena ahora" cambia al instante sin reconectar.
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
    Future<Socket> Function(String host, int port, {bool useTls});

Future<Socket> defaultSocketConnector(
  String host,
  int port, {
  bool useTls = false,
}) async {
  if (useTls) {
    return SecureSocket.connect(
      host,
      port,
      onBadCertificate: (_) => false,
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
    this.metadataInterval = 8192,
    this.userAgent = 'XtremeStudio/0.1',
    this.iceName = '',
    this.iceGenre = '',
    this.iceDescription = '',
    SocketConnector? connector,
  }) : _connect = connector ?? defaultSocketConnector;

  final String host;
  final int port;
  final String mount;
  final String username;
  final String password;
  final bool useTls;

  /// Cada cuantos bytes de audio se intercala un bloque de metadatos.
  /// 8192 es el valor estandar y el que entienden todos los reproductores.
  final int metadataInterval;

  final String userAgent;
  final String iceName;
  final String iceGenre;
  final String iceDescription;

  final SocketConnector _connect;

  Socket? _socket;
  Uint8List? _pendingMetadata;
  int _bytesSinceMetadata = 0;
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
      ..write('Content-Type: audio/mpeg\r\n')
      ..write('Expect: 100-continue\r\n');

    if (metadataInterval > 0) {
      b.write('icy-metaint: $metadataInterval\r\n');
    }
    if (iceName.isNotEmpty) b.write('ice-name: $iceName\r\n');
    if (iceGenre.isNotEmpty) b.write('ice-genre: $iceGenre\r\n');
    if (iceDescription.isNotEmpty) b.write('ice-description: $iceDescription\r\n');
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
      socket = await _connect(host, port, useTls: useTls);
    } on SocketException catch (e) {
      throw IcecastException(
        'No se pudo conectar a $host:$port. Revisa el host y el puerto. '
        '(${e.osError?.message ?? e.message})',
      );
    }

    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;

    try {
      socket.write(buildPutRequest());
      await socket.flush();

      final response = await _readHttpResponse(socket);
      final status = response.statusCode;

      // 100 Continue: el servidor acepto las credenciales y espera audio.
      if (status == 100) {
        _connected = true;
        _bytesSinceMetadata = 0;
        _bytesSent = 0;
        _pendingMetadata = null;
        _socketClosed = false;
        return;
      }

      if (status == 200 || status == 201) {
        _connected = true;
        _bytesSinceMetadata = 0;
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

  /// Envia un bloque de audio MP3 ya codificado.
  ///
  /// El entrelazado de Icecast funciona asi: se envian exactamente
  /// `metadataInterval` bytes de audio y **justo despues** va un bloque de
  /// metadatos, cuyo primer byte indica su longitud (0 = "sin cambios").
  ///
  /// Dos errores tipicos que aqui se evitan a proposito:
  /// 1. Emitir un bloque de metadatos **antes** del primer bloque de audio:
  ///    desincroniza a los reproductores.
  /// 2. Emitir un bloque vacio y ademas el bloque con el titulo nuevo: el
  ///    entrelazado se dobla y el audio se desplaza.
  void send(Uint8List audio) {
    final socket = _socket;
    if (socket == null || !_connected || audio.isEmpty) return;

    if (metadataInterval <= 0) {
      socket.add(audio);
      _bytesSent += audio.length;
      return;
    }

    var offset = 0;
    while (offset < audio.length) {
      final room = metadataInterval - _bytesSinceMetadata;
      final remaining = audio.length - offset;
      final take = remaining < room ? remaining : room;

      socket.add(Uint8List.sublistView(audio, offset, offset + take));
      _bytesSent += take;
      offset += take;
      _bytesSinceMetadata += take;

      // Solo en un limite exacto se publica un bloque de metadatos, y nunca
      // se emite uno vacio si hay un titulo esperando.
      if (_bytesSinceMetadata >= metadataInterval) {
        final pending = _pendingMetadata;
        socket.add(pending ?? _emptyMetadataBlock);
        _pendingMetadata = null;
        _bytesSinceMetadata = 0;
      }
    }
  }

  /// Programa un cambio de "suena ahora". Se aplica en el proximo limite.
  void setMetadata(String song, {String? artist, String? title}) {
    String value;
    if (artist != null && title != null && artist.isNotEmpty && title.isNotEmpty) {
      value = '$artist - $title';
    } else {
      value = song;
    }
    // Icecast 2 espera: StreamTitle='...';
    final payload = "StreamTitle='${value.replaceAll("'", '')}';";
    final bytes = utf8.encode(payload);

    // El bloque de metadatos es una longitud en multiplos de 16 + los datos.
    var blocks = (bytes.length / 16).ceil();
    // Sin signo de 8 bits: un titulo enorme se corta en vez de corromper el flujo.
    if (blocks > 255) {
      blocks = 255;
    }
    final padded = Uint8List(1 + blocks * 16);
    padded[0] = blocks;
    padded.setRange(1, 1 + bytes.length.clamp(0, blocks * 16), bytes);
    _pendingMetadata = padded;
  }

  static final Uint8List _emptyMetadataBlock = Uint8List(1);

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
    _pendingMetadata = null;
    if (socket != null) {
      try {
        await socket.flush();
      } catch (_) {
        // El socket ya podia estar muerto; no es un error del usuario.
      }
      try {
        await socket.close();
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
      final socket = await _connect(host, port, useTls: useTls);
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
