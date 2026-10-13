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
import 'package:xtreme_studio/core/diagnostic_log.dart';
import 'package:xtreme_studio/core/net/icecast_client.dart';
import 'package:xtreme_studio/core/net/shoutcast_client.dart';
import 'package:xtreme_studio/core/profile_store.dart';
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
    stdout.writeln('  [FALLA] $description${detail != null ? ' -> $detail' : ''}');
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
      socket.listen(
        (data) {
          if (!_headerSent) {
            request += latin1.decode(data, allowInvalid: true);
            if (request.contains('\r\n\r\n')) {
              socket.write('HTTP/1.1 $statusCode $reason\r\n\r\n');
              _headerSent = true;
            }
          } else {
            audio.addAll(data);
          }
        },
        onError: (_) {},
      );
    });
  }

  Future<void> stop() async => _server?.close();
}

Future<void> main() async {
  stdout.writeln('Verificacion del nucleo de Xtreme Studio');
  stdout.writeln('(ejecuta el codigo real; sin red salvo el servidor simulado)');

  await _peticionIcecast();
  await _conexionIcecast();
  await _erroresHttp();
  await _metadatosEnFlujo();
  await _shoutcast();
  await _vumetros();
  await _captura();
  await _cifrado();
  await _persistencia();
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
  check(req.contains('icy-metaint: 8192'), 'anuncia intervalo de metadatos');
  check(req.contains('Expect: 100-continue'), 'pide validacion previa de credenciales');
  check(
    !req.contains('secreto123'),
    'la contrasena NO viaja en texto plano',
  );
  check(
    req.contains(base64Encode(utf8.encode('source:secreto123'))),
    'la contrasena viaja en Basic auth (base64)',
  );
  check(req.contains('ice-name: Mi Radio'), 'envia el nombre de la emisora');
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
    check(e.message.contains('No se pudo conectar'), 'host inexistente da mensaje claro');
  }
}

Future<void> _metadatosEnFlujo() async {
  section('Metadatos intercalados (lo que ve el oyente)');
  final fake = FakeIcecast(100, 'Continue');
  await fake.start();

  final client = IcecastClient(
    host: '127.0.0.1',
    port: fake.port,
    mount: '/test',
    username: 'source',
    password: 'p',
    metadataInterval: 16,
  );
  await client.connect();
  client.setMetadata('Artista - Tema');
  client.send(Uint8List(64)..fillRange(0, 64, 0x41));
  await client.close();
  // El socket local puede cerrarse antes de que el servidor procese el ultimo
  // trozo: se le da un instante para drenar, si no la prueba es una carrera.
  await Future<void>.delayed(const Duration(milliseconds: 200));

  final text = latin1.decode(fake.audio, allowInvalid: true);
  check(text.contains('StreamTitle='), 'el titulo va en formato StreamTitle');
  check(text.contains('Artista - Tema'), 'el titulo llega integro');

  // El flujo se parsea EXACTAMENTE como lo haria un reproductor de Icecast:
  // se leen 16 bytes de audio y despues 1 byte de longitud (en unidades de 16)
  // que indica cuantos bytes de metadatos siguen.
  final parseo = _parsearIcecast(fake.audio, 16);
  check(
    parseo.audioIntegro,
    'todos los bloques de audio llegan intactos y en orden',
    detail: 'bloques verificados: ${parseo.bloquesAudio}',
  );
  check(
    parseo.audioTotal == 64,
    'el parser recupera exactamente los 64 bytes de audio enviados',
    detail: 'recuperados ${parseo.audioTotal}',
  );
  check(
    parseo.titulos.contains('Artista - Tema'),
    'el parser lee el titulo en su posicion correcta',
    detail: parseo.titulos.toString(),
  );

  await fake.stop();

  // Sin metadatos, el flujo debe ser exacto.
  final fake2 = FakeIcecast(100, 'Continue');
  await fake2.start();
  final client2 = IcecastClient(
    host: '127.0.0.1',
    port: fake2.port,
    mount: '/test',
    username: 'source',
    password: 'p',
    metadataInterval: 0,
  );
  await client2.connect();
  client2.send(Uint8List(100)..fillRange(0, 100, 0x42));
  await client2.close();
  await Future<void>.delayed(const Duration(milliseconds: 200));
  check(
    fake2.audio.length == 100 && fake2.audio.every((b) => b == 0x42),
    'con metadatos desactivados el audio pasa sin modificar',
    detail: 'recibidos ${fake2.audio.length} bytes',
  );
  await fake2.stop();
}

/// Resultado de parsear un flujo de Icecast.
class _Parseo {
  _Parseo(this.audioTotal, this.bloquesAudio, this.audioIntegro, this.titulos);

  final int audioTotal;
  final int bloquesAudio;
  final bool audioIntegro;
  final List<String> titulos;
}

/// Recorre el flujo igual que un reproductor: `interval` bytes de audio, luego
/// una longitud (x16) y los metadatos correspondientes, y repite.
_Parseo _parsearIcecast(List<int> flujo, int interval) {
  var i = 0;
  var audioTotal = 0;
  var bloquesAudio = 0;
  var integro = true;
  final titulos = <String>[];

  while (i < flujo.length) {
    final disponible = flujo.length - i;
    if (disponible < interval) {
      // Resto final: audio suelto, sin metadatos detras.
      audioTotal += disponible;
      break;
    }
    final bloqueOk = flujo.sublist(i, i + interval).every((b) => b == 0x41);
    if (!bloqueOk) integro = false;
    bloquesAudio++;
    audioTotal += interval;
    i += interval;

    if (i >= flujo.length) break;

    final lenByte = flujo[i];
    final metaBytes = lenByte * 16;
    final fin = (i + 1 + metaBytes).clamp(0, flujo.length);
    final meta = latin1.decode(flujo.sublist(i + 1, fin), allowInvalid: true);
    final match = RegExp(r"StreamTitle='([^']*)'").firstMatch(meta);
    if (match != null) titulos.add(match.group(1)!);
    i += 1 + metaBytes;
  }

  return _Parseo(audioTotal, bloquesAudio, integro, titulos);
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
  check(hs1.startsWith('clave:#1'), 'v1 usa el handshake password#1');
  check(!hs1.contains('sid:'), 'v1 no envia sid');

  final v2 = ShoutcastClient(
    host: 'h',
    port: 8000,
    password: 'clave',
    username: 'dj',
    version: ShoutcastVersion.v2,
    streamId: 1,
  );
  final hs2 = v2.buildHandshake();
  check(hs2.startsWith('dj:clave'), 'v2 usa usuario:password');
  check(hs2.contains('sid:1'), 'v2 envia el sid');
  check(hs2.contains('icy-metaint:8192'), 'v2 anuncia metadatos');

  // Respuesta OK2.
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final sub = server.listen((s) {
    s.listen((_) {}, onError: (_) {});
    s.write('OK2\r\n');
  });
  final c = ShoutcastClient(host: '127.0.0.1', port: server.port, password: 'p');
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
  final c2 = ShoutcastClient(host: '127.0.0.1', port: server2.port, password: 'mala');
  try {
    await c2.connect();
    check(false, 'invalid password deberia fallar');
  } on IcecastException catch (e) {
    check(e.message.contains('rechazada'), 'la clave invalida se reporta claramente');
  }
  await sub2.cancel();
  await server2.close();
}

Future<void> _vumetros() async {
  section('Vumetros (nivel de audio)');

  final silence = LevelMeter();
  silence.feed(Uint8List(2000));
  check(silence.isSilent, 'el silencio se detecta como silencio');
  check(silence.peakDb < -50, 'el pico del silencio esta por debajo de -50 dBFS');

  final full = LevelMeter();
  final pcm = Uint8List(2000);
  final view = ByteData.sublistView(pcm);
  for (var i = 0; i < 1000; i++) {
    view.setInt16(i * 2, i.isEven ? 32767 : -32768, Endian.little);
  }
  full.feed(pcm);
  check(full.peakDb > -1 && full.peakDb <= 0,
      'fondo de escala mide ~0 dBFS', detail: '${full.peakDb.toStringAsFixed(2)}');

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
    detail: '${half.peakDb.toStringAsFixed(2)}',
  );

  final drop = LevelMeter();
  drop.feed(pcm);
  final peakBefore = drop.peakDb;
  drop.feed(Uint8List(2000));
  check(
    drop.peakDb < peakBefore && drop.peakDb > -60,
    'el vumetro cae suavemente y no salta a cero',
    detail: 'antes ${peakBefore.toStringAsFixed(1)} -> ahora ${drop.peakDb.toStringAsFixed(1)}',
  );
}

Future<void> _captura() async {
  section('Linea de comandos de FFmpeg');

  const args = CaptureArgs(
    deviceName: 'Micrófono (Realtek)',
    bitrateKbps: 128,
    sampleRate: 44100,
    channels: 2,
    gainDb: 3.0,
  );
  final cmd = args.build('ffmpeg.exe');
  check(cmd.contains('dshow'), 'usa el capturador dshow de Windows');
  check(
    cmd.contains('audio=Micrófono (Realtek)'),
    'pasa el nombre del dispositivo con acentos',
  );
  check(cmd.contains('libmp3lame'), 'codifica en MP3 con LAME (sin royalties)');
  check(cmd.contains('128k'), 'respeta el bitrate elegido');
  check(cmd.contains('pipe:1'), 'el MP3 sale por stdout hacia nuestro motor');
  check(cmd.contains('pipe:2'), 'los niveles salen por stderr');

  // El filtro de audio va como UN SOLO argumento tras `-af`.
  final af = cmd.indexOf('-af');
  check(af >= 0 && af + 1 < cmd.length, 'declara la cadena de filtros con -af');
  final filtros = af >= 0 ? cmd[af + 1] : '';
  check(
    filtros.contains('alimiter=limit=0.95'),
    'incluye limitador anti-saturacion',
    detail: filtros,
  );
  check(
    filtros.contains('volume=3.00dB'),
    'aplica la ganancia pedida por el DJ',
    detail: filtros,
  );

  // Con dos salidas, cada una debe mapear el flujo de audio explicitamente:
  // si se deja a la seleccion automatica de FFmpeg, es habitual que una salida
  // se quede sin el filtro de ganancia o sin el limitador.
  final maps = <int>[];
  for (var i = 0; i < cmd.length; i++) {
    if (cmd[i] == '-map') maps.add(i);
  }
  check(
    maps.length == 2,
    'mapea explicitamente el audio en las dos salidas (MP3 y niveles)',
    detail: 'se encontraron ${maps.length} mapeos',
  );
  check(
    maps.every((i) => i + 1 < cmd.length && cmd[i + 1] == '0:a:0'),
    'ambas salidas toman el mismo flujo filtrado',
    detail: maps.map((i) => cmd[i + 1]).join(', '),
  );

  // La salida MP3 debe ir antes de la salida de niveles, y cada una a su pipe.
  final mp3Pipe = cmd.indexOf('pipe:1');
  final meterPipe = cmd.indexOf('pipe:2');
  check(mp3Pipe > 0 && meterPipe > mp3Pipe,
      'el MP3 sale antes que el PCM de niveles y cada uno a su tuberia');

  const sinGanancia = CaptureArgs(
    deviceName: 'Mic',
    bitrateKbps: 64,
    sampleRate: 22050,
    channels: 1,
    gainDb: 0,
  );
  check(
    !sinGanancia.build('ffmpeg').any((a) => a.startsWith('volume=')),
    'sin ganancia no agrega el filtro de volumen',
  );

  section('Mensajes de error entendibles');
  check(
    explainFfmpegError('Access is denied.').contains('Otro programa'),
    'microfono ocupado por Zoom/OBS se explica',
  );
  check(
    explainFfmpegError('Could not find audio only device')
        .contains('No se encontro el dispositivo'),
    'dispositivo inexistente se explica',
  );
  check(
    explainFfmpegError('Unknown encoder libmp3lame').contains('libmp3lame'),
    'FFmpeg sin MP3 se explica',
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
    looksLikeText(utf8.encode('[dshow @ 0000] Could not find audio only device')),
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
  check(
    !looksLikeText(Uint8List(0)),
    'un bloque vacio no se considera texto',
  );
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
    final errorBlock = Uint8List.fromList(utf8.encode(
      '[dshow @ 0000] Could not find audio only device with name [Mic]\n',
    ));
    final lines = collectFfmpegLines(errorBlock);
    check(
      lines.length == 1 && lines.first.contains('Could not find audio only device'),
      'las lineas de FFmpeg se extraen del bloque',
      detail: lines.length == 1 ? lines.first : '${lines.length} lineas',
    );
    check(
      explainFfmpegError(lines.join('\n')).contains('No se encontro el dispositivo'),
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
        'source devices.': 'No se encontro el dispositivo',
    "dshow: Could not open audio device\nAccess is denied.": 'Otro programa',
    'Unknown encoder libmp3lame': 'libmp3lame',
  };

  for (final entry in realDeviceErrors.entries) {
    final lines = collectFfmpegLines(Uint8List.fromList(utf8.encode(entry.key)));
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
  section('Cifrado de credenciales (DPAPI)');
  final store = createSecretStore();
  check(store.isSecure, 'el cifrado del sistema esta disponible en Windows');

  const secreto = 'miClaveSuperSecreta!123';
  final protected = store.protect(secreto);
  check(protected.ok, 'la contrasena se puede cifrar');
  if (protected.ok) {
    final blob = protected.data!;
    final asText = latin1.decode(blob, allowInvalid: true);
    check(
      !asText.contains('miClaveSuperSecreta'),
      'el blob cifrado NO contiene la contrasena en claro',
    );
    check(blob.length > 0, 'el blob tiene contenido', detail: '${blob.length} bytes');

    final back = store.unprotect(blob);
    check(back.ok, 'el blob cifrado se puede descifrar');
    if (back.ok) {
      check(
        utf8.decode(back.data!) == secreto,
        'el descifrado devuelve la contrasena original',
      );
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
      stationName: 'Radio Prueba FM',
      publicUrl: 'https://ejemplo.fm/miradio',
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
      check(
        !text.contains('ClaveDelDJ2026'),
        'el archivo de secreto esta cifrado, no en claro',
      );
    }

    // Al recargar debe volver la contrasena.
    final loaded = await store.load();
    check(loaded.length == 1, 'se recarga un perfil');
    check(loaded.first.password == 'ClaveDelDJ2026',
        'la contrasena se recupera descifrada');
    check(loaded.first.normalizedMount == '/miradio',
        'el mount se normaliza con barra inicial');

    // Exportar sin contrasena no debe filtrarla.
    final exported = store.exportProfile(loaded.first);
    check(
      !exported.contains('ClaveDelDJ2026'),
      'exportar un perfil NO incluye la contrasena',
    );

    // Borrado.
    await store.delete(profile.id);
    final after = await store.load();
    check(after.isEmpty, 'el perfil se elimina');
    check(!secretFile.existsSync(), 'el secreto se elimina junto al perfil');

    // ------------------------------------------------------------ ajustes
    final settings = AppSettings()
      ..lastProfileId = 'abc'
      ..ffmpegPath = r'C:\ffmpeg\bin\ffmpeg.exe'
      ..lastDeviceId = 'Microfono (Realtek)'
      ..recordLocally = true
      ..recordDirectory = r'C:\Grabaciones';
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
      reloaded.recordLocally && reloaded.recordDirectory == settings.recordDirectory,
      'la configuracion de grabacion se conserva',
    );
    check(
      reloaded.lastProfileId == 'abc',
      'se recuerda cual era la emisora activa',
    );
  } finally {
    await temp.delete(recursive: true);
  }
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
  check(
    conGanancia.validate().isEmpty,
    '+6.5 dB es un valor aceptable',
  );

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

  // Y debe llegar al comando de FFmpeg como filtro real.
  final cmdGain = CaptureArgs(
    deviceName: 'Mic',
    bitrateKbps: 128,
    sampleRate: 44100,
    channels: 2,
    gainDb: conGanancia.gainDb,
  ).build('ffmpeg');
  final afIndex = cmdGain.indexOf('-af');
  check(
    afIndex >= 0 && cmdGain[afIndex + 1].contains('volume=4.00dB'),
    'la ganancia del perfil llega como filtro a FFmpeg',
    detail: afIndex >= 0 ? cmdGain[afIndex + 1] : 'sin -af',
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
  final engineSrc = File('lib/core/audio/broadcast_engine.dart').readAsStringSync();
  check(
    engineSrc.contains('profile.autoReconnect'),
    'el motor consulta el ajuste del perfil antes de reconectar',
  );
  check(
    RegExp(r'profile\.autoReconnect').allMatches(engineSrc).length >= 1 &&
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
  check(danados.isEmpty, 'un nombre ya correcto no se modifica',
      detail: danados.join(' | '));

  // El comando de captura debe llevar el nombre reparado, con sus acentos en
  // UTF-8, que es lo que espera FFmpeg.
  {
    final args = CaptureArgs(
      deviceName: repairDeviceName('Mezcla estÃ©reo (Realtek Audio)'),
      bitrateKbps: 128,
      sampleRate: 44100,
      channels: 2,
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
    check(failures.isEmpty, 'las expresiones regulares del nucleo son validas',
        detail: failures.join(' | '));
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
    check(fallos.isEmpty, 'el filtro de secretos oculta toda contrasena',
        detail: fallos.join(' | '));
  }
}
