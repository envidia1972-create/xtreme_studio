/// Cliente de ingesta **SHOUTcast v1** y **v2**.
///
/// Estos servidores no usan HTTP normal para publicar: hay un "handshake" con
/// el password y, en v1, el DJ queda en el puerto base mientras los oyentes
/// van al puerto+1. Ese es justamente el motivo por el que delegar todo a
/// ffmpeg falla en muchos hostings: `-f mp3` a un Shoutcast no negocia el
/// handshake. Aqui lo hacemos nosotros.
///
/// SHOUTcast v1 espera que se le envie el password como "usuario" y `#1` como
/// password; v2 espera `user:pass` y un campo `sid`. Ambos responden con una
/// linea `OK2` o `invalid password`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'icecast_client.dart' show SocketConnector, IcecastException, defaultSocketConnector;

/// Variante del protocolo Shoutcast.
enum ShoutcastVersion { v1, v2 }

/// Cliente de publicacion para SHOUTcast.
class ShoutcastClient {
  ShoutcastClient({
    required this.host,
    required this.port,
    required this.password,
    this.username = 'source',
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
  }) : _connect = connector ?? defaultSocketConnector;

  final String host;
  final int port;
  final String password;
  final String username;
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
  int _bytesSent = 0;

  bool get isConnected => _connected;

  /// `true` si el servidor confirmo `OK2` (acepta metadatos en el flujo).
  bool get metadataSupported => _metadataSupported;

  int get bytesSent => _bytesSent;

  /// Cabeceras del handshake segun la version.
  ///
  /// v1: `password#1` (el usuario real es irrelevante para el servidor).
  /// v2: `user:pass` + `sid` + `icy-*`.
  String buildHandshake() {
    final b = StringBuffer();

    if (version == ShoutcastVersion.v1) {
      b.write('$password:#1\r\n');
    } else {
      b.write('$username:$password\r\n');
    }

    b
      ..write('icy-name:$name\r\n')
      ..write('icy-genre:$genre\r\n')
      ..write('icy-url:$url\r\n')
      ..write('icy-pub:${isPublic ? 1 : 0}\r\n')
      ..write('icy-br:$bitrateKbps\r\n');

    if (version == ShoutcastVersion.v2) {
      b
        ..write('content-type:$contentType\r\n')
        ..write('icy-metaint:8192\r\n');
      // `sid` solo se envia cuando la fuente apunta a un stream concreto.
      if (streamId > 0) b.write('sid:$streamId\r\n');
    }

    b.write('\r\n');
    return b.toString();
  }

  /// Lee la respuesta de una linea del servidor: `OK`, `OK2` o `invalid...`.
  Future<void> connect() async {
    await close();

    Socket socket;
    try {
      socket = await _connect(host, port, useTls: false);
    } on SocketException catch (e) {
      throw IcecastException(
        'No se pudo conectar a $host:$port. '
        '(${e.osError?.message ?? e.message})',
      );
    }

    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;

    try {
      socket.write(buildHandshake());
      await socket.flush();

      final line = await _readLine(socket).timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw IcecastException(
          'El servidor no respondio al handshake en 15 s. '
          'Revisa host, puerto y firewall.',
        ),
      );

      final response = line.trim();

      if (response == 'OK2') {
        _connected = true;
        _metadataSupported = true;
      } else if (response == 'OK') {
        // v1 clasico: acepta la fuente pero no metadatos en el flujo.
        _connected = true;
        _metadataSupported = false;
      } else if (response.toLowerCase().contains('invalid') ||
          response.toLowerCase().contains('password')) {
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
    socket.add(audio);
    _bytesSent += audio.length;
  }

  /// Cambia el titulo que suena.
  ///
  /// En Shoutcast los metadatos **no** van en el flujo: se envian como una
  /// peticion HTTP aparte al puerto de administracion con el parametro
  /// `song`. Por eso este metodo es asincrono y no puede fallar la emision.
  Future<bool> setMetadata(
    String song, {
    String? artist,
    String? title,
    String? sid,
  }) async {
    final value = (artist != null && artist.isNotEmpty && title != null && title.isNotEmpty)
        ? '$artist - $title'
        : song;

    // El puerto de administracion de Shoutcast es el de la fuente +1.
    final adminPort = port + 1;
    try {
      final socket = await _connect(host, adminPort, useTls: false);
      final encodedSong = Uri.encodeComponent(value);
      final path = sid != null
          ? '/admin.cgi?mode=updinfo&song=$encodedSong&sid=$sid'
          : '/admin.cgi?mode=updinfo&song=$encodedSong';
      socket.write(
        'GET $path HTTP/1.0\r\n'
        'Host: $host:$adminPort\r\n'
        'Authorization: Basic ${base64Encode(utf8.encode('$username:$password'))}\r\n'
        'User-Agent: XtremeStudio/0.1\r\n'
        'Connection: close\r\n\r\n',
      );
      await socket.flush();
      await socket.close();
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String> _readLine(Socket socket) async {
    final chunks = <int>[];
    final completer = Completer<String>();
    late StreamSubscription<List<int>> sub;

    sub = socket.listen(
      (data) {
        chunks.addAll(data);
        if (chunks.contains(10)) {
          sub.cancel();
          if (!completer.isCompleted) {
            completer.complete(latin1.decode(chunks, allowInvalid: true));
          }
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) {
          completer.completeError(IcecastException('Error de red: $e'));
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.complete(latin1.decode(chunks, allowInvalid: true));
        }
      },
      cancelOnError: false,
    );

    return completer.future;
  }

  Future<void> close() async {
    _connected = false;
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      try {
        await socket.flush();
      } catch (_) {}
      try {
        await socket.close();
      } catch (_) {}
      socket.destroy();
    }
  }
}
