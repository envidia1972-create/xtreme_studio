/// Envoltorio de FFmpeg para Windows: captura y codificacion.
///
/// Division clara de trabajo:
/// - **FFmpeg** captura el dispositivo de entrada (WASAPI/dshow) y codifica a
///   MP3. Tambien produce un flujo PCM de niveles para los vumetros.
/// - **Dart** se queda el MP3 por `stdout` y decide a donde va (Icecast o
///   Shoutcast), lo que permite reconectar sin reiniciar la captura.
///
/// Rutas y nombres de dispositivo de Windows se pasan por archivo de
/// argumentos (`-f concat` no; aqui usamos `-i` con escape manual) para
/// sobrevivir a nombres con acentos, espacios y comillas.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
/// Dispositivo de entrada disponible en el sistema.
class InputDevice {
  const InputDevice({required this.id, required this.name});

  /// Identificador alternativo estable: nombre del dispositivo dshow.
  final String id;

  /// Nombre tal como lo muestra Windows.
  final String name;

  @override
  String toString() => name;

  @override
  bool operator ==(Object other) => other is InputDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Descubre los dispositivos de captura usando el propio FFmpeg.
///
/// `-list_devices true` imprime la lista por *stderr* y termina con error,
/// que es el comportamiento esperado.
class FfmpegLocator {
  FfmpegLocator(this.executablePath);

  final String executablePath;

  bool get isAvailable =>
      executablePath.isNotEmpty && File(executablePath).existsSync();

  /// Version de FFmpeg, para mostrarla en la pantalla de ajustes.
  Future<String> version() async {
    if (!isAvailable) return '';
    try {
      final bytes = <int>[];
      final process = await Process.start(executablePath, ['-version']);
      final sub = process.stdout.listen(bytes.addAll);
      await process.exitCode;
      await sub.cancel();
      // UTF-8 explicito, igual que en el resto de las salidas de FFmpeg.
      final text = utf8.decode(bytes, allowMalformed: true);
      return text.split(RegExp(r'\r?\n')).first.trim();
    } catch (_) {
      return '';
    }
  }

  /// Lista los dispositivos de entrada (microfonos, linea, loopback virtual).
  ///
  /// **Importante:** la salida se decodifica como UTF-8 a mano, no con la
  /// codificacion del sistema.
  ///
  /// FFmpeg escribe los nombres de dispositivo en UTF-8. Si se deja que Dart
  /// decodifique con la pagina de codigos del sistema (Latin-1 en Windows en
  /// espanol), `Micrófono` se convierte en `MicrÃ³fono`: el nombre queda
  /// **doblemente codificado**. Peor aun, ese nombre corrupto se le pasa luego a
  /// FFmpeg al abrir el dispositivo, que responde "Could not find audio only
  /// device" y la emision no arranca, sin ninguna pista de por que.
  Future<List<InputDevice>> listAudioDevices() async {
    if (!isAvailable) return [];
    if (!Platform.isWindows) return _listNonWindows();

    try {
      final process = await Process.start(executablePath, [
        '-hide_banner',
        '-list_devices',
        'true',
        '-f',
        'dshow',
        '-i',
        'dummy',
      ]);

      // Se acumulan los BYTES y se decodifican despues, para controlar la
      // codificacion.
      final stderrBytes = <int>[];
      final stdoutBytes = <int>[];
      final subErr = process.stderr.listen(stderrBytes.addAll);
      final subOut = process.stdout.listen(stdoutBytes.addAll);

      await process.exitCode;
      await subErr.cancel();
      await subOut.cancel();

      final text = '${utf8.decode(stdoutBytes, allowMalformed: true)}\n'
          '${utf8.decode(stderrBytes, allowMalformed: true)}';
      return _parseDshowDevices(text);
    } catch (_) {
      return [];
    }
  }

  /// Extrae los dispositivos de audio del volcado de dshow.
  ///
  /// Ejemplo de linea:
  /// `[dshow @ 0000]   "Micrófono (Realtek Audio)" (audio)`
  static List<InputDevice> _parseDshowDevices(String text) {
    final devices = <InputDevice>[];
    final seen = <String>{};
    // Solo nos interesa el bloque de audio; los de video se descartan.
    final regex = RegExp(r'"([^"]+)"\s*\((audio|video)\)');
    for (final match in regex.allMatches(text)) {
      final name = match.group(1)!;
      final kind = match.group(2)!;
      if (kind != 'audio') continue;
      if (name.startsWith('@device')) continue;
      if (seen.add(name)) {
        devices.add(InputDevice(id: name, name: name));
      }
    }
    return devices;
  }

  Future<List<InputDevice>> _listNonWindows() async {
    // En Linux/macOS se puede extender con avfoundation/pulse; por ahora la
    // app se centra en Windows.
    return [];
  }
}

/// Argumentos de captura y codificacion, separados para poder probarlos.
class CaptureArgs {
  const CaptureArgs({
    required this.deviceName,
    required this.bitrateKbps,
    required this.sampleRate,
    required this.channels,
    this.gainDb = 0.0,
    this.metering = true,
  });

  final String deviceName;
  final int bitrateKbps;
  final int sampleRate;
  final int channels;

  /// Ganancia de entrada en dB (el control de volumen del DJ).
  final double gainDb;

  /// Emitir tambien un PCM de niveles por stderr.
  final bool metering;

  /// Construye la linea de comandos.
  ///
  /// Salidas:
  ///  1. MP3 hacia `pipe:1` (stdout) -> lo consume el motor en Dart.
  ///  2. PCM crudo s16le mono 8 kHz hacia `pipe:2` (stderr) -> vumetros.
  ///
  /// La grabacion local NO se hace aqui: el motor duplica el mismo MP3 que
  /// ya viaja al servidor, asi lo grabado es exactamente lo que oyeron los
  /// oyentes y no se gasta CPU en codificar dos veces.
  List<String> build(String executablePath) {
    final args = <String>[
      '-hide_banner',
      '-loglevel',
      'error',
      // Captura del dispositivo de entrada.
      '-f',
      'dshow',
      '-audio_buffer_size',
      '50',
      '-i',
      'audio=${_escapeDshow(deviceName)}',
      // Cadena de filtros: ganancia y limitador para no saturar el MP3.
      '-af',
      _filterChain(),
      '-ac',
      '$channels',
      '-ar',
      '$sampleRate',
      // Salida 1: MP3 hacia stdout.
      //
      // El mapeo se hace explicito (`-map 0:a:0`) en cada salida: con dos
      // salidas, dejar que FFmpeg elija el flujo por su cuenta es una fuente
      // clasica de "el MP3 sale sin filtros" o "el vumetro mide otra cosa".
      '-map',
      '0:a:0',
      '-c:a',
      'libmp3lame',
      '-b:a',
      '${bitrateKbps}k',
      '-f',
      'mp3',
      'pipe:1',
    ];

    // Salida 2: niveles por stderr.
    if (metering) {
      args.addAll([
        '-map',
        '0:a:0',
        '-c:a',
        'pcm_s16le',
        '-ac',
        '1',
        '-ar',
        '8000',
        '-f',
        's16le',
        'pipe:2',
      ]);
    }

    return args;
  }

  /// El comando completo en una linea, para mostrarlo o copiarlo.
  ///
  /// Sirve para diagnosticar: si un dispositivo no captura, el DJ puede pegar
  /// esto en una consola y ver el error real de FFmpeg. Ademas es la unica
  /// forma practica de revisar la configuracion en una PC ajena.
  String preview() {
    const exe = 'ffmpeg.exe';
    final parts = <String>[exe];
    for (final a in build(exe)) {
      // Se citan solo los argumentos que lo necesitan, para que el comando se
      // pueda pegar tal cual en cmd o PowerShell.
      if (a.isEmpty || a.contains(' ') || a.contains('(') || a.contains(')')) {
        parts.add('"$a"');
      } else {
        parts.add(a);
      }
    }
    return parts.join(' ');
  }

  String _filterChain() {
    final filters = <String>[];
    if (gainDb.abs() > 0.01) {
      filters.add('volume=${gainDb.toStringAsFixed(2)}dB');
    }
    // Evita que un pico distorsione el MP3 enviado a los oyentes.
    filters.add('alimiter=limit=0.95');
    return filters.join(',');
  }

  /// dshow necesita que el nombre del dispositivo se pase literal.
  static String _escapeDshow(String name) => name;
}

/// Proceso de captura/codificacion en ejecucion.
class CaptureProcess {
  CaptureProcess._(this._process, this.args);

  final Process _process;
  final CaptureArgs args;

  /// MP3 codificado listo para enviar al servidor.
  Stream<Uint8List> get audio =>
      _process.stdout.map((d) => Uint8List.fromList(d));

  /// PCM crudo para los vumetros (vacio si `metering` esta desactivado).
  Stream<Uint8List> get meter =>
      _process.stderr.map((d) => Uint8List.fromList(d));

  int? get pid => _process.pid;

  Future<int> get exitCode => _process.exitCode;

  /// Codigo de salida si el proceso ya termino; `null` si sigue vivo.
  ///
  /// Sirve para verificar el apagado sin quedarse esperando: un `await` sobre
  /// `exitCode` nunca se resuelve mientras el proceso siga en marcha.
  int? get exitCodeIfFinished => _exitCode;
  int? _exitCode;

  /// `true` mientras el proceso de captura este en ejecucion.
  bool get isRunning => _exitCode == null;

  static Future<CaptureProcess> start({
    required String ffmpegPath,
    required CaptureArgs args,
    Map<String, String> environment = const {},
  }) async {
    final process = await Process.start(
      ffmpegPath,
      args.build(ffmpegPath),
      environment: environment.isEmpty ? null : environment,
    );
    final capture = CaptureProcess._(process, args);
    // Se guarda el codigo de salida cuando ocurra, sin bloquear a nadie.
    unawaited(process.exitCode.then((code) => capture._exitCode = code));
    return capture;
  }

  /// Corta la captura. En Windows `kill` termina el proceso sin aviso, que es
  /// exactamente lo que queremos al pulsar "SALIR".
  /// Detiene el proceso de captura y **garantiza** que no quede vivo.
  ///
  /// Es critico que esto termine siempre: si FFmpeg sobrevive, el microfono
  /// queda ocupado y la app no puede volver a emitir. Y si la espera se cuelga,
  /// el boton "SALIR DEL AIRE" deja de responder mientras la emision sigue
  /// sonando en la radio.
  ///
  /// Por eso hay tres pasos, cada uno con limite de tiempo:
  /// 1. `kill` normal.
  /// 2. Cerrar la entrada estandar, pero **sin esperar indefinidamente**: si el
  ///    proceso no la esta leyendo, ese `await` se queda colgado para siempre.
  /// 3. Si sigue vivo, forzarlo por PID con `taskkill`.
  Future<void> stop() async {
    // 1.
    try {
      _process.kill(ProcessSignal.sigkill);
    } catch (_) {
      // Puede haber muerto ya por su cuenta.
    }

    // 2. Se cierra la entrada estandar sin bloquear: es solo una cortesia para
    //    que FFmpeg termine ordenadamente si lo esta escuchando.
    try {
      await _process.stdin.close().timeout(const Duration(seconds: 2));
    } catch (_) {
      // Cuelgue o error: da igual, sigue el paso 3.
    }

    // 3. Se comprueba si termino y, si no, se fuerza.
    try {
      await _process.exitCode.timeout(const Duration(seconds: 3));
      return; // Termino solo.
    } catch (_) {
      // Sigue vivo: se fuerza por PID.
    }

    final pid = _process.pid;
    try {
      final result = await Process.run(
        'taskkill',
        ['/F', '/T', '/PID', '$pid'],
      ).timeout(const Duration(seconds: 5));
      // taskkill devuelve 128 si el proceso ya no existia: eso tambien es exito.
      _lastStopDetail = 'taskkill ${result.exitCode}';
    } catch (e) {
      _lastStopDetail = 'taskkill fallo: $e';
    }

    try {
      _process.kill(ProcessSignal.sigkill);
    } catch (_) {}
  }

  /// Detalle de la ultima parada, para el registro de diagnostico.
  String? get lastStopDetail => _lastStopDetail;
  String? _lastStopDetail;
}

/// Calcula nivel de audio (peak y RMS) desde PCM s16le mono.
///
/// Se calcula en Dart a proposito: decodificar el MP3 otra vez solo para medir
/// seria desperdiciar CPU en la cabina del DJ.
class LevelMeter {
  LevelMeter({this.smoothing = 0.35});

  /// 0 = sin suavizado, 1 = congelado. Suaviza el movimiento del vumetro.
  final double smoothing;
  double _peakDb = -60;
  double _rmsDb = -60;

  /// Pico actual en dBFS (-60 a 0).
  double get peakDb => _peakDb;

  /// RMS (nivel promedio percibido) en dBFS.
  double get rmsDb => _rmsDb;

  /// `true` si la senal esta practicamente en silencio.
  bool get isSilent => _peakDb < -50;

  /// Alimenta un bloque PCM y actualiza los niveles.
  void feed(Uint8List pcm) {
    if (pcm.length < 2) return;
    final sampleCount = pcm.length ~/ 2;
    var peak = 0.0;
    var sumSquares = 0.0;

    final view = ByteData.sublistView(pcm, 0, sampleCount * 2);
    for (var i = 0; i < sampleCount; i++) {
      final sample = view.getInt16(i * 2, Endian.little) / 32768.0;
      final abs = sample.abs();
      if (abs > peak) peak = abs;
      sumSquares += sample * sample;
    }

    final rms = sampleCount > 0 ? math.sqrt(sumSquares / sampleCount) : 0.0;
    final newPeak = _toDb(peak);
    final newRms = _toDb(rms);

    // Caida suave: evita que el vumetro "tiemble" en cada bloque.
    _peakDb = _smooth(_peakDb, newPeak);
    _rmsDb = _smooth(_rmsDb, newRms);
  }

  double _smooth(double current, double target) {
    if (target > current) return target; // ataque inmediato
    return current * smoothing + target * (1 - smoothing); // caida suave
  }

  /// Factor de normalizacion de 8 bits de rango a dBFS.
  static double _toDb(double amplitude) {
    if (amplitude <= 0.000001) return -60;
    final db = 20 * (math.log(amplitude) / math.ln10);
    return db < -60 ? -60 : db;
  }

  void reset() {
    _peakDb = -60;
    _rmsDb = -60;
  }
}

/// `true` si el bloque parece un mensaje de texto de FFmpeg y no PCM.
///
/// El PCM de niveles y los mensajes de FFmpeg comparten la misma salida de
/// error, y eso trae dos problemas si no se distingue:
///
/// 1. Los bytes de texto se interpretarian como muestras de audio y harian
///    saltar el vumetro sin motivo.
/// 2. El motivo real del fallo ("device already in use", "Unknown encoder")
///    se perderia, y el DJ solo veria un "FFmpeg termino" sin explicacion.
///
/// Se aceptan ASCII imprimible, saltos de linea y bytes de continuacion UTF-8
/// (los mensajes pueden traer acentos). El PCM aleatorio tiene una probabilidad
/// muy baja de cumplir esto en un bloque completo, y ademas siempre hay algo de
/// texto cuando FFmpeg falla antes de capturar.
bool looksLikeText(Uint8List data) {
  if (data.isEmpty) return false;
  var printable = 0;
  for (final b in data) {
    final isAsciiText = b == 0x09 || b == 0x0A || b == 0x0D || (b >= 0x20 && b <= 0x7E);
    // Bytes de inicio y continuacion de secuencias UTF-8 multibyte.
    final isUtf8 = b >= 0x80;
    if (isAsciiText || isUtf8) printable++;
  }
  // Se exige que casi todo el bloque sea texto: asi el PCM (que es ruido
  // binario) no se confunde con un mensaje.
  return printable == data.length;
}

/// Separa y limpia los mensajes de FFmpeg de un bloque de su salida.
///
/// Devuelve las lineas utiles del bloque, o vacio si no parecia texto. Se usa
/// para acumular el motivo real de un fallo, que es lo unico que permite
/// decirle al DJ que hacer.
List<String> collectFfmpegLines(Uint8List data) {
  if (!looksLikeText(data)) return const [];
  final text = String.fromCharCodes(data);
  return text
      .split(RegExp(r'\r?\n'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
}

/// Ejecuta un diagnostico de un solo disparo sobre el mismo dispositivo.
///
/// Cuando la captura muere, el motivo real ("device already in use", "Could not
/// find audio only device") no siempre llega por la salida de error: esa salida
/// ya esta ocupada por el PCM de los vumetros, y FFmpeg puede morir antes de
/// escribir nada.
///
/// En lugar de rendirse con un "termino sin explicar el motivo", se lanza una
/// segunda ejecucion identica pidiendo solo un instante de audio: asi FFmpeg
/// intenta abrir el dispositivo y escribe su diagnostico sin competir con el
/// flujo PCM. Devuelve las lineas utiles, o vacio si no se pudo obtener nada.
Future<List<String>> diagnoseCaptureFailure({
  required String ffmpegPath,
  required CaptureArgs args,
  Map<String, String> environment = const {},
  Duration timeout = const Duration(seconds: 12),
}) async {
  try {
    final process = await Process.start(
      ffmpegPath,
      [
        '-hide_banner',
        '-f',
        'dshow',
        '-audio_buffer_size',
        '50',
        '-i',
        'audio=${args.deviceName}',
        // Un solo resultado para que FFmpeg intente abrir el dispositivo y
        // termine enseguida, en vez de quedarse capturando.
        '-t',
        '0.2',
        '-f',
        'null',
        '-',
      ],
      environment: environment.isEmpty ? null : environment,
    );

    // Se leen las dos salidas a la vez para no bloquear el proceso.
    final stderrText = StringBuffer();
    final outSub = process.stdout.listen((_) {});
    final errSub = process.stderr.listen(
      // Los mensajes de FFmpeg vienen en UTF-8. Decodificarlos con
      // `String.fromCharCodes` (Latin-1) los corrompe: es el mismo fallo que
      // hacia imposible abrir un dispositivo con acentos.
      (d) => stderrText.write(utf8.decode(d, allowMalformed: true)),
    );

    try {
      await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
    await outSub.cancel();
    await errSub.cancel();

    return stderrText
        .toString()
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  } catch (_) {
    // Si ni siquiera se puede lanzar el diagnostico, no hay nada que informar.
    return const [];
  }
}

/// Corrige un nombre de dispositivo guardado con la codificacion equivocada.
///
/// Las versiones anteriores de la app guardaban el nombre decodificado como
/// Latin-1 en lugar de UTF-8, asi que `Mezcla estéreo` quedo guardado como
/// `Mezcla estÃ©reo`. Ese nombre no existe en el sistema y hace fallar la
/// captura.
///
/// Aqui se detecta (la secuencia `Ã` seguida de otro caracter es la firma del
/// UTF-8 mal decodificado) y se intenta recuperar el nombre original.
String repairDeviceName(String name) {
  if (!name.contains('Ã') && !name.contains('Â')) return name;
  try {
    // Se vuelve a codificar como Latin-1 y se decodifica como UTF-8: asi se
    // deshace la doble codificacion.
    final bytes = <int>[];
    for (final unit in name.codeUnits) {
      if (unit > 0xFF) return name; // No se puede recuperar: se deja igual.
      bytes.add(unit);
    }
    final fixed = utf8.decode(bytes, allowMalformed: false);
    return fixed;
  } catch (_) {
    // Si no se puede recuperar con seguridad, se devuelve el original.
    return name;
  }
}

/// `true` si el texto de FFmpeg indica que no encontro el dispositivo pedido.
///
/// Cubre un caso muy frecuente: la app arranco cuando todavia no habia ningun
/// microfono conectado (o el elegido se desconecto despues). Cuando eso pasa,
/// conviene volver a buscar dispositivos y ofrecer elegir uno, en lugar de
/// dejar al DJ con una lista vacia y un mensaje generico.
bool looksLikeMissingDevice(String stderrText) {
  final t = stderrText.toLowerCase();
  return t.contains('could not find') ||
      t.contains('no such device') ||
      t.contains('device not found') ||
      t.contains('none found') ||
      t.contains('could not enumerate');
}

/// Convierte un texto de error de FFmpeg en algo entendible.
String explainFfmpegError(String stderrText) {
  final t = stderrText.toLowerCase();
  if (t.contains('could not find audio only device') ||
      t.contains('could not find') && t.contains('device')) {
    return 'No se encontro el dispositivo de audio seleccionado. '
        'Elegi otro microfono en Ajustes.';
  }
  if (t.contains('device already in use') || t.contains('access is denied')) {
    return 'Otro programa esta usando el microfono (Zoom, OBS, Teams...). '
        'Cerralo o elegi otro dispositivo.';
  }
  if (t.contains('unknown encoder') && t.contains('libmp3lame')) {
    return 'El FFmpeg instalado no incluye el codificador MP3 (libmp3lame). '
        'Descarga una build "full" o "gpl".';
  }
  if (t.contains('no such file or directory')) {
    return 'No se encontro el ejecutable de FFmpeg. Revisa la ruta en Ajustes.';
  }
  if (t.isEmpty) return 'FFmpeg termino sin explicar el motivo.';
  return 'FFmpeg reporto: ${stderrText.trim().split(RegExp(r'\r?\n')).take(3).join(' / ')}';
}
