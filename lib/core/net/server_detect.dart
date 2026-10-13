/// Deteccion del tipo de servidor de streaming.
///
/// Existe por un problema real y muy facil de sufrir: **el mismo hosting puede
/// tener Icecast en un puerto y SHOUTcast en otro**. Si el DJ deja el tipo en
/// "Icecast 2" (el valor por defecto) pero su puerto es un SHOUTcast, la app
/// hace un `PUT` con autenticacion Icecast contra un servidor que espera el
/// handshake de SHOUTcast. El servidor responde `401` y la app informa
/// "usuario o contrasena incorrectos", que es una conclusion **equivocada**:
/// las credenciales estan bien, lo que no coincide es el protocolo.
///
/// Cada servidor se delata por lo que responde en rutas conocidas, asi que se
/// puede preguntar antes de intentar publicar. La sonda **no envia
/// credenciales**: consulta rutas publicas de estado.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../server_profile.dart';

/// Cuanta confianza merece el resultado de la deteccion.
enum DetectionConfidence {
  /// No se pudo determinar: se conserva lo que eligio el DJ.
  ninguna,

  /// Hay indicios, pero conviene que el DJ confirme.
  media,

  /// Respuesta inequivoca del servidor.
  alta,
}

/// Resultado de la deteccion.
class ServerDetection {
  const ServerDetection({
    required this.protocol,
    required this.confidence,
    required this.evidence,
    this.serverSoftware,
  });

  final ServerProtocol protocol;
  final DetectionConfidence confidence;

  /// Explicacion legible de en que se baso.
  final String evidence;

  /// Software identificado, para mostrar al DJ.
  final String? serverSoftware;

  bool get isCertain => confidence == DetectionConfidence.alta;
}

/// Pregunta al servidor que tipo es.
///
/// [expected] es lo que el DJ tenia configurado: se devuelve cuando no se puede
/// determinar nada, para no cambiarle la configuracion a ciegas.
Future<ServerDetection> detectServer({
  required String host,
  required int port,
  required ServerProtocol expected,
  bool useTls = false,
  Duration timeout = const Duration(seconds: 8),
}) async {
  if (host.trim().isEmpty) {
    return ServerDetection(
      protocol: expected,
      confidence: DetectionConfidence.ninguna,
      evidence: 'Sin servidor indicado.',
    );
  }

  HttpClient? client;
  try {
    client = HttpClient()..connectionTimeout = timeout;

    // 1. `/status-json.xsl` es la firma de Icecast y AzuraCast.
    final icecast = await _tryGet(
      client,
      host: host,
      port: port,
      path: '/status-json.xsl',
      useTls: useTls,
      timeout: timeout,
    );

    if (icecast != null &&
        icecast.body.contains('icestats') &&
        icecast.body.trimLeft().startsWith('{')) {
      return const ServerDetection(
        protocol: ServerProtocol.icecast2,
        confidence: DetectionConfidence.alta,
        evidence: 'El servidor responde en /status-json.xsl, una ruta que solo '
            'existe en Icecast y AzuraCast.',
        serverSoftware: 'Icecast',
      );
    }

    // 2. SHOUTcast se identifica por el aviso que manda con el flujo.
    final shout = await _tryGet(
      client,
      host: host,
      port: port,
      path: '/',
      useTls: useTls,
      timeout: timeout,
    );

    if (shout != null) {
      final notice = shout.icyNotices.join(' ');
      final lower = notice.toLowerCase();

      if (lower.contains('shoutcast')) {
        // La version cambia el handshake: v1 usa `password:#1`, v2 usa
        // `usuario:password` con `sid`.
        final looksV2 = RegExp(r'v2\.\d').hasMatch(lower) ||
            lower.contains('dnas/posix') ||
            lower.contains('dnas/win');
        final clean = notice.replaceAll(RegExp(r'<[^>]+>'), ' ').trim();
        return ServerDetection(
          protocol:
              looksV2 ? ServerProtocol.shoutcast2 : ServerProtocol.shoutcast1,
          confidence: DetectionConfidence.alta,
          evidence: 'El servidor se identifica como SHOUTcast'
              '${clean.isEmpty ? '' : ' ($clean)'}.',
          serverSoftware: looksV2 ? 'SHOUTcast DNAS v2' : 'SHOUTcast DNAS v1',
        );
      }

      final server = (shout.serverHeader ?? '').toLowerCase();
      if (server.contains('icecast')) {
        return const ServerDetection(
          protocol: ServerProtocol.icecast2,
          confidence: DetectionConfidence.alta,
          evidence: 'El servidor se identifica como Icecast en sus cabeceras.',
          serverSoftware: 'Icecast',
        );
      }

      if (shout.statusCode == 401 || shout.statusCode == 403) {
        return ServerDetection(
          protocol: expected,
          confidence: DetectionConfidence.media,
          evidence: 'El servidor pidio autenticacion y no se pudo identificar '
              'el tipo con certeza.',
        );
      }
    }

    return ServerDetection(
      protocol: expected,
      confidence: DetectionConfidence.ninguna,
      evidence: 'El servidor no respondio a las rutas de deteccion. Se '
          'mantiene el tipo que elegiste.',
    );
  } catch (e) {
    return ServerDetection(
      protocol: expected,
      confidence: DetectionConfidence.ninguna,
      evidence: 'No se pudo consultar el servidor ($e). Se mantiene el tipo '
          'que elegiste.',
    );
  } finally {
    client?.close(force: true);
  }
}

class _Probe {
  const _Probe({
    required this.statusCode,
    required this.body,
    required this.serverHeader,
    required this.icyNotices,
  });

  final int statusCode;
  final String body;
  final String? serverHeader;
  final List<String> icyNotices;
}

/// Consulta corta: lee cabeceras y como mucho 4 KB, nunca un flujo entero.
Future<_Probe?> _tryGet(
  HttpClient client, {
  required String host,
  required int port,
  required String path,
  required bool useTls,
  required Duration timeout,
}) async {
  try {
    final scheme = useTls ? 'https' : 'http';
    final uri = Uri.parse('$scheme://$host:$port$path');
    final request = await client.getUrl(uri).timeout(timeout);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.userAgentHeader, 'XtremeStudio/0.1');
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-2047');

    final response = await request.close().timeout(timeout);

    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > 4096) break;
    }

    // Las cabeceras `icy-*` no son estandar, asi que se buscan a mano.
    final notices = <String>[];
    response.headers.forEach((name, values) {
      if (name.toLowerCase().startsWith('icy-notice')) {
        notices.add(values.join(' '));
      }
    });

    return _Probe(
      statusCode: response.statusCode,
      body: utf8.decode(bytes, allowMalformed: true),
      serverHeader: response.headers.value(HttpHeaders.serverHeader),
      icyNotices: notices,
    );
  } catch (_) {
    return null;
  }
}
