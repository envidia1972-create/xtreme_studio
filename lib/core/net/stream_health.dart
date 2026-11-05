/// Verificacion de la senal **desde el lado del oyente**.
///
/// El motor de emision detecta cuando se cae *nuestro* socket contra el
/// servidor. Pero eso no cubre todos los fallos reales: el servidor puede
/// seguir aceptando nuestra conexion mientras deja de servir el mount (fuente
/// rechazada tras el handshake, sesion duplicada, mount bloqueado por el
/// panel). En ese caso el DJ ve "AL AIRE" y no lo escucha nadie.
///
/// Este monitor pregunta lo mismo que preguntaria un oyente: pide la URL
/// publica y comprueba que el servidor responda con audio.
///
/// Se usa `GET` (no `HEAD`) a proposito: hay servidores, como los de Zeno.fm,
/// que **rechazan `HEAD` con 405** aunque sirvan el audio sin problema. Con
/// `HEAD` el monitor daria falsas alarmas justo en los hostings mas usados.
/// Para no descargar el flujo se lee unicamente la cabecera de respuesta y se
/// cierra la conexion en cuanto se conocen el codigo y el `content-type`.
library;

import 'dart:async';
import 'dart:io';

import '../server_profile.dart';

/// Estado de la senal vista por un oyente.
enum SignalStatus {
  /// No se ha comprobado todavia.
  unknown,

  /// El servidor sirve audio en el mount: hay oyentes potenciales.
  healthy,

  /// El servidor responde, pero no hay fuente en el mount.
  noSource,

  /// No se pudo alcanzar el servidor de escucha.
  unreachable,

  /// El servidor respondio algo inesperado.
  unexpected,

  /// La comprobacion no se pudo hacer (falta la URL publica).
  notConfigured,
}

extension SignalStatusInfo on SignalStatus {
  String get label => switch (this) {
    SignalStatus.unknown => 'sin comprobar',
    SignalStatus.healthy => 'publicada',
    SignalStatus.noSource => 'sin fuente',
    SignalStatus.unreachable => 'servidor inalcanzable',
    SignalStatus.unexpected => 'respuesta inesperada',
    SignalStatus.notConfigured => 'sin URL publica',
  };

  /// `true` si el estado merece que el DJ se entere.
  ///
  /// `unexpected` **no** cuenta como problema: es la categoria de "no pude
  /// comprobar" (servidor que rechaza la comprobacion, URL que apunta a una
  /// pagina web). Alarmar por eso entrenaria al DJ a ignorar los avisos, que es
  /// peor que no avisar.
  bool get isProblem => switch (this) {
    SignalStatus.noSource || SignalStatus.unreachable => true,
    _ => false,
  };
}

/// Resultado de una comprobacion.
class SignalCheck {
  const SignalCheck({
    required this.status,
    required this.message,
    this.statusCode,
    this.contentType,
    this.url,
  });

  final SignalStatus status;
  final String message;
  final int? statusCode;
  final String? contentType;
  final String? url;

  bool get isHealthy => status == SignalStatus.healthy;
}

/// Comprueba si la emisora esta siendo servida a los oyentes.
///
/// [url] es la direccion de escucha. Si no se indica, se deduce de la
/// configuracion de publicacion del perfil (protocolo, host, puerto y mount),
/// que es lo que hace el boton "comprobar" cuando el DJ no cargo una URL
/// publica aparte.
class StreamHealthMonitor {
  StreamHealthMonitor({
    required this.profile,
    HttpClient? client,
    this.timeout = const Duration(seconds: 8),
  }) : _client = client;

  final ServerProfile profile;
  final Duration timeout;
  HttpClient? _client;

  /// URL de escucha que se comprobara.
  Uri? resolveListenerUrl() {
    // 1. Si el DJ cargo la URL publica, se usa esa: es la verdad para el oyente.
    final publicUrl = profile.publicUrl.trim();
    if (publicUrl.isNotEmpty) {
      final parsed = Uri.tryParse(publicUrl);
      if (parsed != null && parsed.hasScheme && parsed.host.isNotEmpty) {
        return parsed;
      }
    }

    // 2. En Icecast el mount forma parte de la URL de publicacion y la
    //    deduccion es fiable. En Shoutcast no: la fuente va a puerto+1 y el
    //    puerto/path de escucha depende del hosting (puede ser Liquidsoap en
    //    el puerto base). Sin URL publica no se inventa una: eso producia un
    //    404 repetido aunque la emision estuviera sana.
    if (profile.protocol != ServerProtocol.icecast2) return null;
    if (profile.host.trim().isEmpty) return null;
    final scheme = profile.useTls ? 'https' : 'http';
    final mount = profile.normalizedMount;
    return Uri.parse(
      '$scheme://${profile.host}:${profile.effectivePort}$mount',
    );
  }

  /// Pregunta al servidor lo mismo que le preguntaria un reproductor.
  Future<SignalCheck> check() async {
    final url = resolveListenerUrl();
    if (url == null) {
      return SignalCheck(
        status: SignalStatus.notConfigured,
        message: profile.protocol == ServerProtocol.icecast2
            ? 'No hay URL de escucha: carga la URL publica del perfil o '
                  'revisa el host y el mount.'
            : 'Shoutcast no permite deducir la URL de escucha. Carga la URL '
                  'publica que muestra el panel del hosting para comprobar la '
                  'senal.',
      );
    }

    final client =
        _client ?? (_client = HttpClient()..connectionTimeout = timeout);
    // El monitor pregunta lo mismo que un oyente; si la emisora usa un
    // certificado autofirmado, rechazarlo daria una falsa alarma de "sin
    // senal" justo cuando el DJ acaba de habilitarlo en el perfil.
    if (profile.allowBadCertificate) {
      client.badCertificateCallback = (_, _, _) => true;
    }

    try {
      final request = await client.getUrl(url).timeout(timeout);
      request.followRedirects = true;
      request.maxRedirects = 5;
      request.persistentConnection = false;
      request.headers.set(HttpHeaders.userAgentHeader, 'XtremeStudio/0.1');
      // Se piden solo las cabeceras: alcanza para saber si hay audio, y asi no
      // se descarga el flujo entero.
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');

      final response = await request.close().timeout(timeout);

      final status = response.statusCode;
      final contentType =
          response.headers.value(HttpHeaders.contentTypeHeader) ?? '';

      // Se cierra de inmediato: no interesa el cuerpo. Sin esto la conexion
      // seguiria recibiendo audio indefinidamente. El limite de tiempo evita
      // que un servidor que no completa el desligue deje colgada la comprobacion.
      try {
        await response
            .detachSocket()
            .timeout(timeout, onTimeout: () => throw TimeoutException('detach'))
            .then((s) => s.destroy());
      } catch (_) {
        // Si no se puede desligar el socket, se cancela la suscripcion.
        unawaited(response.drain<void>().catchError((_) {}));
      }

      if (status == 200 || status == 206) {
        // Con audio tenemos la confirmacion fuerte; sin `content-type` de audio
        // puede ser un servidor que no lo declara, asi que se acepta un 200
        // pero se informa el tipo real.
        if (contentType.startsWith('audio/') ||
            contentType.contains('mpeg') ||
            contentType.contains('ogg') ||
            contentType.contains('aac') ||
            contentType.isEmpty) {
          return SignalCheck(
            status: SignalStatus.healthy,
            message: contentType.isEmpty
                ? 'El servidor sirve el mount (sin content-type declarado)'
                : 'Los oyentes reciben audio ($contentType)',
            statusCode: status,
            contentType: contentType,
            url: url.toString(),
          );
        }
        return SignalCheck(
          status: SignalStatus.unexpected,
          message:
              'El servidor responde 200 pero no con audio ($contentType). '
              'Revisa que la URL de escucha sea el stream y no una pagina web.',
          statusCode: status,
          contentType: contentType,
          url: url.toString(),
        );
      }

      if (status == 401 || status == 403) {
        return SignalCheck(
          status: SignalStatus.noSource,
          message:
              'El servidor responde $status: el mount esta protegido o '
              'reservado a la fuente. Los oyentes no pueden entrar.',
          statusCode: status,
          url: url.toString(),
        );
      }

      if (status == 404) {
        return SignalCheck(
          status: SignalStatus.noSource,
          message:
              'El servidor responde 404: no hay fuente publicando en este '
              'mount. Los oyentes escucharian silencio o un error.',
          statusCode: status,
          url: url.toString(),
        );
      }

      // 405/501: el servidor no admite la comprobacion. Con GET practicamente
      // no ocurre, pero se mantiene por robustez y, sobre todo, NO se trata
      // como un fallo de emision.
      if (status == 405 || status == 501) {
        return SignalCheck(
          status: SignalStatus.unexpected,
          message:
              'El servidor rechazo la comprobacion (HTTP $status). '
              'No indica un problema de emision.',
          statusCode: status,
          url: url.toString(),
        );
      }

      return SignalCheck(
        status: SignalStatus.unexpected,
        message: 'El servidor respondio HTTP $status al pedir el stream.',
        statusCode: status,
        url: url.toString(),
      );
    } on TimeoutException {
      return SignalCheck(
        status: SignalStatus.unreachable,
        message:
            'El servidor de escucha no respondio en '
            '${timeout.inSeconds} s. Los oyentes tampoco podrian entrar.',
        url: url.toString(),
      );
    } on SocketException catch (e) {
      return SignalCheck(
        status: SignalStatus.unreachable,
        message:
            'No se pudo alcanzar el servidor de escucha: '
            '${e.osError?.message ?? e.message}',
        url: url.toString(),
      );
    } catch (e) {
      return SignalCheck(
        status: SignalStatus.unreachable,
        message: 'Fallo la comprobacion: $e',
        url: url.toString(),
      );
    }
  }

  void dispose() {
    _client?.close(force: true);
    _client = null;
  }
}
