/// Fachada unica de publicacion: decide entre Icecast y Shoutcast segun el
/// perfil y expone una sola interfaz para el motor de emision.
library;

import 'dart:async';
import 'dart:typed_data';

import '../server_profile.dart';
import 'icecast_client.dart';
import 'server_detect.dart';
import 'shoutcast_client.dart';

/// Resultado de "probar conexion": lo que la UI le muestra al DJ.
class ConnectionTestResult {
  const ConnectionTestResult({
    required this.ok,
    required this.message,
    this.statusCode,
    this.details = const [],
  });

  final bool ok;
  final String message;
  final int? statusCode;

  /// Detalles utiles: mount efectivo, protocolo usado, capacidades.
  final List<String> details;
}

/// Publicador generico sobre un perfil.
class Broadcaster {
  Broadcaster(this.profile);

  final ServerProfile profile;

  IcecastClient? _icecast;
  ShoutcastClient? _shoutcast;
  StreamSubscription<void>? _lostSub;

  /// Aviso de que el servidor corto la conexion a mitad de la emision.
  ///
  /// Se reemite desde el cliente correspondiente para que el motor pueda
  /// reconectar; sin esto la app seguiria mostrando "AL AIRE" mientras el
  /// publico escucha silencio.
  final _connectionLost = StreamController<void>.broadcast();
  Stream<void> get onConnectionLost => _connectionLost.stream;

  bool get isConnected =>
      (_icecast?.isConnected ?? false) || (_shoutcast?.isConnected ?? false);

  int get bytesSent =>
      _icecast?.bytesSent ?? _shoutcast?.bytesSent ?? 0;

  /// Conecta segun el protocolo del perfil.
  Future<void> connect() async {
    if (profile.protocol == ServerProtocol.icecast2) {
      final client = IcecastClient(
        host: profile.host,
        port: profile.effectivePort,
        mount: profile.normalizedMount,
        username: profile.username,
        password: profile.password,
        useTls: profile.useTls,
        iceName: profile.stationName,
        iceGenre: profile.genre,
        iceDescription: profile.description,
      );
      await client.connect();
      _icecast = client;
      _lostSub?.cancel();
      _lostSub = client.onConnectionLost.listen((_) {
        if (!_connectionLost.isClosed) _connectionLost.add(null);
      });
    } else {
      final client = ShoutcastClient(
        host: profile.host,
        port: profile.effectivePort,
        password: profile.password,
        username: profile.username,
        version: profile.protocol == ServerProtocol.shoutcast1
            ? ShoutcastVersion.v1
            : ShoutcastVersion.v2,
        name: profile.stationName,
        genre: profile.genre,
        bitrateKbps: profile.audio.bitrateKbps,
        sampleRate: profile.audio.sampleRate,
        channels: profile.audio.channels,
      );
      await client.connect();
      _shoutcast = client;
    }
  }

  void send(Uint8List audio) {
    _icecast?.send(audio);
    _shoutcast?.send(audio);
  }

  /// Cambia el "suena ahora". En Icecast va insertado en el flujo; en
  /// Shoutcast va por peticion HTTP al panel.
  Future<bool> setMetadata(String song) async {
    if (_icecast != null) {
      _icecast!.setMetadata(song);
      return true;
    }
    final sc = _shoutcast;
    if (sc == null) return false;
    return sc.setMetadata(song);
  }

  Future<void> close() async {
    await _lostSub?.cancel();
    _lostSub = null;
    await _icecast?.close();
    await _shoutcast?.close();
    _icecast = null;
    _shoutcast = null;
  }

  /// Libera tambien el canal de avisos.
  Future<void> dispose() async {
    await close();
    await _connectionLost.close();
  }

  /// Cierra la fuente con la peticion de borrado (Icecast) para liberar el
  /// mount al instante en lugar de esperar el timeout del servidor.
  Future<void> releaseMount() async {
    await _icecast?.disconnectSource();
  }
}

/// Prueba la conexion **sin enviar audio** y devuelve un diagnostico legible.
///
/// Usa `Expect: 100-continue` (Icecast) o el handshake (Shoutcast) para que el
/// servidor valide las credenciales antes de recibir un solo byte de audio.
/// Asi el boton "Probar conexion" no interrumpe a nadie que este al aire.
///
/// Si el servidor rechaza con 401 se consulta **de que tipo es**: en un mismo
/// hosting es habitual que un puerto sea Icecast y otro SHOUTcast, y elegir mal
/// produce un "contrasena incorrecta" que en realidad es un error de protocolo.
/// Mandar al DJ a revisar sus credenciales cuando el problema es otro es una
/// perdida de tiempo garantizada.
Future<ConnectionTestResult> testConnection(ServerProfile profile) async {
  final problems = profile.validate();
  if (problems.isNotEmpty) {
    return ConnectionTestResult(
      ok: false,
      message: problems.first,
      details: problems,
    );
  }

  final broadcaster = Broadcaster(profile);
  final details = <String>[
    'Protocolo configurado: ${profile.protocol.shortLabel}',
    'Destino: ${profile.summary}',
  ];

  try {
    await broadcaster.connect();
    details.add('Handshake aceptado por el servidor');
    if (profile.protocol == ServerProtocol.icecast2) {
      details.add('Soporta metadatos en vivo (icy-metaint)');
    } else if (broadcaster._shoutcast?.metadataSupported == true) {
      details.add('Servidor OK2: acepta actualizacion de titulo');
    }
    await broadcaster.close();
    return ConnectionTestResult(
      ok: true,
      message: 'Conexion correcta: el servidor acepto las credenciales',
      details: details,
    );
  } on IcecastException catch (e) {
    await broadcaster.close();

    if (e.statusCode == 401) {
      final detected = await detectServer(
        host: profile.host,
        port: profile.effectivePort,
        expected: profile.protocol,
        useTls: profile.useTls,
      );
      details.add('Deteccion del servidor: ${detected.evidence}');
      if (detected.serverSoftware != null) {
        details.add('Software: ${detected.serverSoftware}');
      }

      if (detected.isCertain && detected.protocol != profile.protocol) {
        return ConnectionTestResult(
          ok: false,
          message: 'El puerto ${profile.effectivePort} es '
              '${detected.protocol.shortLabel}, no '
              '${profile.protocol.shortLabel}. Cambia el tipo de servidor en el '
              'perfil.',
          statusCode: e.statusCode,
          details: details,
        );
      }
    }

    return ConnectionTestResult(
      ok: false,
      message: e.message,
      statusCode: e.statusCode,
      details: [...details, if (e.serverMessage != null) e.serverMessage!],
    );
  } catch (e) {
    await broadcaster.close();
    return ConnectionTestResult(
      ok: false,
      message: 'Error inesperado: $e',
      details: details,
    );
  }
}
