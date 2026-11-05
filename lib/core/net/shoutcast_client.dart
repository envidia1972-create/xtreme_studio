/// Cliente de ingesta **SHOUTcast v1** y **v2**.
///
/// Estos servidores no usan HTTP normal para publicar: hay un "handshake" con
/// el password y, en v1, el DJ queda en el puerto base mientras los oyentes
/// van al puerto+1. Ese es justamente el motivo por el que delegar todo a
/// ffmpeg falla en muchos hostings: `-f mp3` a un Shoutcast no negocia el
/// handshake. Aqui lo hacemos nosotros.
///
/// SHOUTcast v1 y v2 usan el protocolo legacy de publicacion: conectar al
/// puerto base + 1 y enviar **solo la contrasena**. El usuario no participa.
/// El servidor responde con una linea `OK2` o `invalid password`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'icecast_client.dart'
    show SocketConnector, IcecastException, defaultSocketConnector;
import '../diagnostic_log.dart';

/// Variante del protocolo Shoutcast.
enum ShoutcastVersion { v1, v2 }

/// Cliente de publicacion para SHOUTcast.
class ShoutcastClient {
  ShoutcastClient({
    required this.host,
    required this.port,
    int? sourcePort,
    required this.password,
    this.username = 'source',
    this.adminUsername = '',
    this.adminPassword = '',
    this.version = ShoutcastVersion.v2,
    this.streamId = 1,
    this.name = '',
    this.genre = '',
    this.url = '',
    this.isPublic = false,
    this.bitrateKbps = 128,
    this.sampleRate = 44100,
    this.channels = 2,
    this.contentType = 'audio/mpeg',
    SocketConnector? connector,
  }) : sourcePort = sourcePort ?? port + 1,
       _connect = connector ?? defaultSocketConnector;

  final String host;

  /// Puerto base del hosting (el que usan los oyentes).
  final int port;

  /// Puerto de publicacion. Por defecto es `port + 1`, como BUTT y los DSP.
  final int sourcePort;
  final String password;
  final String username;

  /// Credenciales de administracion, si el hosting usa unas distintas de las
  /// de la fuente para cambiar el titulo (`/admin.cgi`).
  final String adminUsername;
  final String adminPassword;

  final ShoutcastVersion version;
  final int streamId;
  final String name;
  final String genre;
  final String url;
  final bool isPublic;
  final int bitrateKbps;
  final int sampleRate;
  final int channels;
  final String contentType;

  final SocketConnector _connect;

  Socket? _socket;
  bool _connected = false;
  bool _metadataSupported = true;
  bool _socketClosed = false;
  int _bytesSent = 0;
  StreamSubscription<List<int>>? _socketSub;

  /// Se dispara cuando el servidor corta la conexion a mitad de la emision.
  ///
  /// `socket.add()` sobre un socket muerto no lanza error en Dart, asi que sin
  /// esta vigilancia la app seguiria mostrando "AL AIRE" mientras los oyentes
  /// escuchan silencio.
  final _connectionLost = StreamController<void>.broadcast();
  Stream<void> get onConnectionLost => _connectionLost.stream;

  bool get isConnected => _connected;

  /// `true` si el servidor confirmo `OK2` (acepta metadatos en el flujo).
  bool get metadataSupported => _metadataSupported;

  int get bytesSent => _bytesSent;

  /// Cabeceras del handshake.
  ///
  /// El protocolo legacy de SHOUTcast (el que usan BUTT y los DSP) es:
  ///   1. conectar al puerto base + 1;
  ///   2. enviar **solo la contrasena**, seguida de un salto de linea;
  ///   3. enviar Host, icy-* y content-type.
  ///
  /// El usuario no forma parte del handshake. La contrasena se envia tal cual,
  /// aunque contenga `:`; no se parte ni se codifica en Base64.
  String buildHandshake() {
    final b = StringBuffer()
      ..write('$password\n')
      ..write('Host: $host:$port\r\n')
      ..write('icy-name:${name.isEmpty ? 'No Name' : name}\r\n')
      ..write('icy-genre:$genre\r\n')
      ..write('icy-url:$url\r\n')
      ..write('icy-pub:${isPublic ? 1 : 0}\r\n')
      ..write('icy-br:$bitrateKbps\r\n')
      ..write('content-type:$contentType\r\n');

    // NO se anuncia `icy-metaint`: este cliente no entrelaza metadatos en el
    // flujo. El titulo se actualiza por `/admin.cgi`.
    // `sid` se omite para el stream por defecto (como BUTT). Solo se envia si
    // un perfil pidiera explicitamente un stream distinto.
    if (version == ShoutcastVersion.v2 && streamId > 1) {
      b.write('sid:$streamId\r\n');
    }

    b.write('\r\n');
    return b.toString();
  }

  /// Lee la respuesta de una linea del servidor: `OK`, `OK2` o `invalid...`.
  Future<void> connect() async {
    await close();

    Socket socket;
    try {
      socket = await _connect(host, sourcePort, useTls: false);
    } on SocketException catch (e) {
      final donde = sourcePort == port ? '$host:$port' : '$host:$sourcePort';
      final aclaracion = sourcePort == port
          ? ''
          : ' (publicacion Shoutcast; el puerto base $port es para oyentes)';
      throw IcecastException(
        'No se pudo conectar a $donde$aclaracion. '
        '(${e.osError?.message ?? e.message})',
      );
    }

    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;
    // Ver comentario en IcecastClient: los EPIPE llegan por `done`.
    unawaited(
      socket.done.catchError((Object _) {
        _onSocketDown();
      }),
    );

    try {
      _socketClosed = false;
      final lineCompleter = Completer<String>();
      final buffer = <int>[];

      // Una sola suscripcion para toda la vida del socket: sirve para leer la
      // linea del handshake y, despues, para enterarse de que el servidor
      // cerro la conexion. Un socket de Dart admite un unico `listen`.
      _socketSub = socket.listen(
        (data) {
          if (lineCompleter.isCompleted) return; // Ya al aire: se ignora.
          buffer.addAll(data);
          final newline = buffer.indexOf(10);
          if (newline >= 0) {
            lineCompleter.complete(
              latin1.decode(buffer.sublist(0, newline + 1), allowInvalid: true),
            );
          }
        },
        onError: (Object e) {
          if (!lineCompleter.isCompleted) {
            lineCompleter.completeError(IcecastException('Error de red: $e'));
          } else {
            _onSocketDown();
          }
        },
        onDone: () {
          if (!lineCompleter.isCompleted) {
            lineCompleter.complete(latin1.decode(buffer, allowInvalid: true));
          } else {
            _onSocketDown();
          }
        },
        cancelOnError: false,
      );

      socket.write(buildHandshake());
      await socket.flush();

      final line = await lineCompleter.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw IcecastException(
          'El servidor no respondio al handshake en 15 s. '
          'Revisa host, puerto y firewall.',
        ),
      );

      final response = line.trim();
      final lower = response.toLowerCase();

      if (response == 'OK2') {
        _connected = true;
        _metadataSupported = true;
      } else if (response == 'OK') {
        // v1 clasico: acepta la fuente pero no metadatos en el flujo.
        _connected = true;
        _metadataSupported = false;
      } else if (lower.startsWith('http/')) {
        // Un servidor que habla HTTP (Icecast, Liquidsoap, AzuraCast) responde
        // `HTTP/1.0 500 Invalid request` a una linea que no es una peticion
        // valida. NO es una clave rechazada: el puerto no es Shoutcast.
        final status = RegExp(
          r'^HTTP/\d(?:\.\d)?\s+(\d{3})',
        ).firstMatch(response);
        throw IcecastException(
          'El servidor respondio como HTTP, no como Shoutcast. '
          'Es probable que sea Icecast o Liquidsoap: cambia el tipo de '
          'servidor a Icecast2 en el perfil.',
          statusCode: status != null ? int.parse(status.group(1)!) : null,
          serverMessage: response,
        );
      } else if (lower.contains('invalid') || lower.contains('password')) {
        throw IcecastException(
          'La contrasena fue rechazada por el servidor',
          serverMessage: response,
        );
      } else if (response.isEmpty) {
        throw IcecastException(
          'El servidor cerro la conexion sin responder. '
          'Verifica que el puerto $port sea el de publicacion (los oyentes '
          'suelen ir al ${port + 1}).',
        );
      } else {
        throw IcecastException(
          'Respuesta inesperada del servidor',
          serverMessage: response,
        );
      }

      _bytesSent = 0;
    } catch (_) {
      await close();
      rethrow;
    }
  }

  /// Envia audio. En v1 sin soporte de metadatos se ignora cualquier titulo.
  void send(Uint8List audio) {
    final socket = _socket;
    if (socket == null || !_connected) return;
    // Igual que en Icecast: un error de escritura sincrono no puede tumbar la
    // app; se trata como conexion perdida para que el motor reconecte.
    try {
      socket.add(audio);
      _bytesSent += audio.length;
    } catch (_) {
      _onSocketDown();
    }
  }

  /// Fuerza la salida de lo pendiente y detecta una red estancada.
  ///
  /// Ver el comentario equivalente en `IcecastClient.flush`: sin esta
  /// vigilancia, un servidor que deja de leer mantiene la app en "AL AIRE"
  /// mientras el audio se acumula en memoria.
  Future<void> flush({Duration timeout = const Duration(seconds: 5)}) async {
    final socket = _socket;
    if (socket == null || !_connected) return;
    try {
      await socket.flush().timeout(timeout);
    } catch (_) {
      _onSocketDown();
    }
  }

  /// Cambia el titulo que suena.
  ///
  /// En Shoutcast los metadatos **no** van en el flujo: se envian como una
  /// peticion HTTP aparte a `/admin.cgi` con el parametro `song`. Por eso este
  /// metodo es asincrono y no puede fallar la emision.
  ///
  /// El puerto de administracion **no** es siempre `port + 1`:
  /// - En **v2** el DNAS multiplexa fuentes, oyentes y administracion en el
  ///   mismo `portbase`, que es el puerto configurado.
  /// - En **v1** la administracion queda en el puerto base, que es la fuente
  ///   menos uno.
  ///
  /// Se prueban los puertos candidatos y se acepta el primero que responda
  /// bien. Tambien se usan las credenciales de administracion si el hosting
  /// pide una clave distinta de la de la fuente.
  Future<bool> setMetadata(
    String song, {
    String? artist,
    String? title,
    String? sid,
  }) async {
    final value =
        (artist != null &&
            artist.isNotEmpty &&
            title != null &&
            title.isNotEmpty)
        ? '$artist - $title'
        : song;
    if (value.trim().isEmpty) return false;

    String? effectiveSid;
    if (sid != null && sid.isNotEmpty) {
      effectiveSid = sid;
    } else if (version == ShoutcastVersion.v2 && streamId > 0) {
      effectiveSid = '$streamId';
    }

    final deadline = DateTime.now().add(const Duration(seconds: 8));
    for (final credentials in _adminCredentials()) {
      for (final adminPort in _metadataPorts) {
        if (DateTime.now().isAfter(deadline)) return false;
        final ok = await _sendMetadata(
          adminPort: adminPort,
          value: value,
          user: credentials.$1,
          pass: credentials.$2,
          sid: effectiveSid,
        );
        if (ok) return true;
      }
    }
    DiagnosticLog.instance?.write(
      'red',
      'metadatos Shoutcast ${version.name}: el servidor no acepto el titulo '
          'en el puerto ${_metadataPorts.join(", ")}',
    );
    return false;
  }

  /// Puertos donde puede estar `/admin.cgi`, en orden de probabilidad.
  ///
  /// En v2 el DNAS multiplexa todo en el puerto de la fuente. En v1 la
  /// administración queda en el puerto base (fuente - 1). **No** se prueban
  /// puertos vecinos arbitrarios: en un hosting compartido el `+1` puede ser
  /// otra emisora y no se le debe cambiar el título por error.
  List<int> get _metadataPorts {
    // En v1 y v2 el panel de administracion esta en el puerto base; el
    // puerto base + 1 es exclusivamente para la fuente.
    final candidates = [port];
    return candidates.where((p) => p > 0 && p <= 65535).toList();
  }

  /// Credenciales a probar: primero las de administracion y despues las de la
  /// fuente (hay hostings donde son la misma).
  List<(String, String)> _adminCredentials() {
    final pairs = <(String, String)>[];
    if (adminPassword.isNotEmpty) {
      pairs.add((
        adminUsername.isEmpty ? 'admin' : adminUsername,
        adminPassword,
      ));
    }
    if (password.isNotEmpty && password != adminPassword) {
      pairs.add((username, password));
    }
    return pairs;
  }

  Future<bool> _sendMetadata({
    required int adminPort,
    required String value,
    required String user,
    required String pass,
    String? sid,
  }) async {
    Socket? socket;
    try {
      socket = await _connect(host, adminPort, useTls: false);
      socket.setOption(SocketOption.tcpNoDelay, true);
      final query = [
        'pass=${Uri.encodeComponent(pass)}',
        'mode=updinfo',
        'song=${Uri.encodeComponent(value)}',
        if (sid != null) 'sid=${Uri.encodeComponent(sid)}',
      ].join('&');
      // SHOUTcast espera la contrasena como parametro `pass`; la cabecera
      // basica se envia ademas porque algunos hostings la usan.
      socket.write(
        'GET /admin.cgi?$query HTTP/1.0\r\n'
        'Host: $host:$adminPort\r\n'
        'Authorization: Basic ${base64Encode(utf8.encode('$user:$pass'))}\r\n'
        'User-Agent: XtremeStudio/0.1\r\n'
        'Connection: close\r\n\r\n',
      );
      await socket.flush().timeout(const Duration(seconds: 4));
      final response = await _readResponse(
        socket,
      ).timeout(const Duration(seconds: 3));
      return _metadataAccepted(response);
    } catch (_) {
      return false;
    } finally {
      try {
        socket?.destroy();
      } catch (_) {}
    }
  }

  /// Lee la respuesta corta de `/admin.cgi` (nunca un flujo de audio).
  Future<String> _readResponse(Socket socket) {
    final buffer = BytesBuilder(copy: true);
    final completer = Completer<String>();
    StreamSubscription<List<int>>? sub;

    void finish() {
      if (completer.isCompleted) return;
      completer.complete(latin1.decode(buffer.takeBytes(), allowInvalid: true));
      unawaited(sub?.cancel());
    }

    sub = socket.listen(
      (data) {
        if (buffer.length < 4096) buffer.add(data);
        if (buffer.length >= 4096) finish();
      },
      onError: (_) => finish(),
      onDone: finish,
      cancelOnError: false,
    );
    return completer.future;
  }

  /// `true` solo si el servidor confirmo el cambio.
  ///
  /// El DNAS responde `OK`/`OK2` o una pagina con "Updated"; con la clave
  /// equivocada responde `Invalid password` (a veces detras de un 200). Por eso
  /// no alcanza con mirar el codigo HTTP.
  bool _metadataAccepted(String response) {
    final text = response.trim();
    if (text.isEmpty) return false;

    final lower = text.toLowerCase();
    if (lower.contains('invalid') ||
        lower.contains('failed') ||
        lower.contains('denied') ||
        lower.contains('error')) {
      return false;
    }

    final status = RegExp(r'^HTTP/\d(?:\.\d)?\s+(\d{3})').firstMatch(text);
    if (status != null) {
      final code = int.parse(status.group(1)!);
      return code >= 200 && code < 300;
    }

    // Respuesta de protocolo Shoutcast sin cabecera HTTP: `OK2`.
    return lower.startsWith('ok') || lower.contains('updated');
  }

  /// Marca la conexion como caida y avisa una sola vez.
  void _onSocketDown() {
    if (_socketClosed) return;
    _socketClosed = true;
    if (!_connected) return;
    _connected = false;
    if (!_connectionLost.isClosed) _connectionLost.add(null);
  }

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
      } catch (_) {}
      try {
        await socket.close().timeout(const Duration(seconds: 2));
      } catch (_) {}
      socket.destroy();
    }
  }

  /// Libera los recursos del cliente (incluido el aviso de caida).
  Future<void> dispose() async {
    await close();
    await _connectionLost.close();
  }
}
