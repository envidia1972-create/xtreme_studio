/// Envoltorio de FFmpeg para captura y codificacion.
///
/// Division clara de trabajo:
/// - **FFmpeg** captura el dispositivo de entrada y codifica a MP3. Tambien
///   produce un flujo PCM de niveles para los vumetros.
/// - **Dart** se queda el MP3 por `stdout` y decide a donde va (Icecast o
///   Shoutcast), lo que permite reconectar sin reiniciar la captura.
///
/// Plataformas soportadas:
/// - **Windows**: capturador `dshow` (DirectShow/WASAPI).
/// - **Linux**: `pulse` (PulseAudio/PipeWire) o `alsa`, segun lo que incluya
///   la build de FFmpeg y lo que haya en el equipo. Nunca se asume uno: se
///   consulta `ffmpeg -devices` y se elige el que existe de verdad.
///
/// Los nombres de dispositivo se pasan como un argumento mas (con `-i`), no por
/// un archivo intermedio, para sobrevivir a nombres con acentos, espacios y
/// comillas.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../server_profile.dart';

/// Capturador de audio que FFmpeg usa para leer la entrada.
enum CaptureBackend {
  /// Windows: DirectShow.
  dshow('dshow', 'DirectShow (Windows)'),

  /// Linux: servidor de audio PulseAudio o PipeWire.
  pulse('pulse', 'PulseAudio/PipeWire (Linux)'),

  /// Linux: ALSA directo (sin servidor de por medio).
  alsa('alsa', 'ALSA (Linux)');

  const CaptureBackend(this.ffmpegName, this.label);

  /// Nombre del formato de entrada de FFmpeg (`-f <nombre>`).
  final String ffmpegName;

  /// Etiqueta legible para la interfaz y los mensajes de error.
  final String label;

  /// `true` para los capturadores disponibles en Linux.
  bool get isLinux => this == pulse || this == alsa;

  /// Capturador que se intenta primero en la plataforma actual.
  ///
  /// En Linux se prefiere PulseAudio porque es lo que usan GNOME, KDE y
  /// PipeWire, y permite elegir microfonos y monitores por nombre. Si la build
  /// de FFmpeg no trae `pulse`, el motor cae a ALSA automaticamente.
  static CaptureBackend forPlatform() {
    if (Platform.isWindows) return dshow;
    if (Platform.isLinux) return pulse;
    return dshow;
  }
}

/// Dispositivo de entrada disponible en el sistema.
class InputDevice {
  const InputDevice({
    required this.id,
    required this.name,
    this.isMonitor = false,
  });

  /// Identificador que se le pasa a FFmpeg.
  ///
  /// Windows: nombre del dispositivo dshow.
  /// Linux/Pulse: nombre de la fuente (`alsa_input...`, `...monitor`).
  /// Linux/ALSA: PCM de ALSA (`plughw:0,0`, `default`, ...).
  final String id;

  /// Nombre legible para el DJ.
  final String name;

  /// `true` si es un monitor del altavoz (captura lo que suena en el equipo).
  ///
  /// Es la opcion practica para probar la app sin microfono, y tambien para
  /// emitir musica que reproduce otro programa.
  final bool isMonitor;

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

  /// Resultado de la deteccion, para no repetirla en cada refresco de la lista.
  CaptureBackend? _resolvedBackend;
  bool? _pulseReachable;
  Set<String>? _inputFormats;
  Set<AudioCodec>? _availableCodecs;

  bool get isAvailable =>
      executablePath.isNotEmpty && File(executablePath).existsSync();

  /// Version de FFmpeg, para mostrarla en la pantalla de ajustes.
  Future<String> version() async {
    if (!isAvailable) return '';
    try {
      final process = await Process.start(executablePath, ['-version']);
      // La salida se acumula hasta que el flujo se cierra. No basta con
      // `await exitCode` y cancelar: Dart puede completar el codigo de salida
      // antes de entregar los ultimos datos y la version saldria vacia.
      final stdoutFuture = process.stdout.fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      );
      await process.exitCode;
      final bytes = await stdoutFuture;
      // UTF-8 explicito, igual que en el resto de las salidas de FFmpeg.
      final text = utf8.decode(bytes, allowMalformed: true);
      return text.split(RegExp(r'\r?\n')).first.trim();
    } catch (_) {
      return '';
    }
  }

  /// Ejecuta una herramienta del sistema y devuelve su salida **como bytes**.
  ///
  /// No se usa `Process.run` por dos motivos:
  /// 1. Decodifica con la codificacion del sistema; `pactl` y FFmpeg emiten
  ///    UTF-8 y un nombre con acentos se corromperia.
  /// 2. Un servidor de audio que no responde dejaria la app esperando para
  ///    siempre. Aqui hay un limite de tiempo y el proceso se mata.
  Future<ProcessResult?> _runTool(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 5),
    Map<String, String>? environment,
  }) async {
    try {
      final process = await Process.start(
        executable,
        arguments,
        environment: environment,
      );
      final outFuture = process.stdout.fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      );
      final errFuture = process.stderr.fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      );
      var code = -1;
      try {
        code = await process.exitCode.timeout(timeout);
      } on TimeoutException {
        try {
          process.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }
      // Se espera a que los flujos se cierren: si se cancelara la escucha justo
      // al terminar el proceso, se perderia la ultima salida (y con ella, por
      // ejemplo, la lista de capturadores de `-devices`).
      final out = await outFuture;
      final err = await errFuture;
      return ProcessResult(process.pid, code, out, err);
    } catch (_) {
      // Herramienta ausente o entorno que no permite lanzar procesos.
      return null;
    }
  }

  static String _decode(Object? bytes) {
    if (bytes is List<int>) return utf8.decode(bytes, allowMalformed: true);
    return bytes?.toString() ?? '';
  }

  /// Formatos de entrada que la build de FFmpeg trae compilados.
  Future<Set<String>> _supportedInputFormats() async {
    final cached = _inputFormats;
    if (cached != null) return cached;
    final result = await _runTool(executablePath, ['-hide_banner', '-devices']);
    final formats = <String>{};
    if (result != null) {
      final text = '${_decode(result.stdout)}\n${_decode(result.stderr)}';
      // Cada linea util tiene la forma ` DE pulse` o ` D  alsa`.
      final regex = RegExp(r'^\s*D[E]?\s+(\w+)', multiLine: true);
      for (final match in regex.allMatches(text)) {
        formats.add(match.group(1)!);
      }
    }
    _inputFormats = formats;
    return formats;
  }

  /// `true` si hay un servidor PulseAudio/PipeWire escuchando.
  ///
  /// Devuelve `null` cuando no se puede saber (por ejemplo, `pactl` no esta
  /// instalado). En ese caso se confia en Pulse si FFmpeg lo soporta, porque es
  /// lo habitual en escritorios Linux.
  Future<bool?> _pulseServerReachable() async {
    final cached = _pulseReachable;
    if (cached != null) return cached;
    final result = await _runTool(
      'pactl',
      ['info'],
      timeout: const Duration(seconds: 3),
      environment: const {'LANG': 'C', 'LC_ALL': 'C'},
    );
    if (result == null) return null;
    final reachable = result.exitCode == 0;
    _pulseReachable = reachable;
    return reachable;
  }

  /// Codecs que la build de FFmpeg puede codificar de verdad.
  ///
  /// No se ofrece AAC+ solo porque exista en la lista de la interfaz: si el
  /// binario no trae `libfdk_aac`, la emision fallaria. Esta comprobacion se
  /// hace una vez y se cachea.
  Future<Set<AudioCodec>> availableCodecs() async {
    final cached = _availableCodecs;
    if (cached != null) return cached;

    final result = await _runTool(executablePath, [
      '-hide_banner',
      '-encoders',
    ]);
    final encoders = <String>{};
    if (result != null) {
      final text = '${_decode(result.stdout)}\n${_decode(result.stderr)}';
      final regex = RegExp(r'^\s*A\S*\s+(\S+)', multiLine: true);
      for (final match in regex.allMatches(text)) {
        encoders.add(match.group(1)!);
      }
    }

    final codecs = <AudioCodec>{};
    if (encoders.contains('libmp3lame')) codecs.add(AudioCodec.mp3);
    if (encoders.contains('aac')) codecs.add(AudioCodec.aac);
    if (encoders.contains('libfdk_aac')) codecs.add(AudioCodec.aacPlus);

    // Un FFmpeg sin `-encoders` legible no debe dejar la app sin ninguna
    // opcion: MP3 es el minimo historico y el que usa el perfil por defecto.
    if (codecs.isEmpty) codecs.add(AudioCodec.mp3);
    _availableCodecs = codecs;
    return codecs;
  }

  /// Decide que capturador usar en Linux.
  ///
  /// Se expone para poder verificarlo con todas las combinaciones (FFmpeg con
  /// Pulse pero sin servidor, solo ALSA, etc.) sin depender del equipo donde se
  /// ejecuten las pruebas.
  static CaptureBackend chooseLinuxBackend({
    required bool hasPulse,
    required bool hasAlsa,
    required bool? pulseReachable,
  }) {
    if (hasPulse) {
      // Si Pulse esta compilado pero no hay servidor escuchando y ALSA existe,
      // se usa ALSA en lugar de fallar al abrir el microfono.
      if (pulseReachable == false && hasAlsa) return CaptureBackend.alsa;
      return CaptureBackend.pulse;
    }
    if (hasAlsa) return CaptureBackend.alsa;
    // No se pudo detectar nada: se devuelve Pulse (lo habitual en Linux) y el
    // error real de FFmpeg se explicara con un mensaje concreto.
    return CaptureBackend.pulse;
  }

  /// Decide que capturador usar en este equipo.
  ///
  /// No se asume PulseAudio solo porque el sistema sea Linux: se consulta la
  /// build de FFmpeg. Si trae `pulse` se prefiere (GNOME/KDE/PipeWire lo usan y
  /// permite elegir monitores). Si no, se usa `alsa`. Si Pulse esta compilado
  /// pero no hay servidor, y ALSA tambien existe, se cae a ALSA en lugar de
  /// fallar al abrir el microfono.
  Future<CaptureBackend> resolveBackend() async {
    final cached = _resolvedBackend;
    if (cached != null) return cached;

    if (!Platform.isLinux) {
      _resolvedBackend = CaptureBackend.forPlatform();
      return _resolvedBackend!;
    }

    final formats = await _supportedInputFormats();
    final hasPulse = formats.contains('pulse');
    final hasAlsa = formats.contains('alsa');
    final reachable = hasPulse ? await _pulseServerReachable() : null;

    final chosen = chooseLinuxBackend(
      hasPulse: hasPulse,
      hasAlsa: hasAlsa,
      pulseReachable: reachable,
    );
    _resolvedBackend = chosen;
    return chosen;
  }

  /// Lista los dispositivos de entrada (microfonos, linea, monitores).
  ///
  /// En Windows usa el volcado de `dshow`; en Linux consulta PulseAudio
  /// (`pactl`) o ALSA (`arecord`), segun el backend disponible.
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
  Future<List<InputDevice>> listAudioDevices({CaptureBackend? backend}) async {
    if (!isAvailable) return [];

    if (Platform.isWindows) {
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
        // codificacion. Se espera al cierre de los flujos: cancelar apenas
        // termina el proceso puede descartar las ultimas lineas del volcado.
        final stderrFuture = process.stderr.fold<List<int>>(
          <int>[],
          (acc, chunk) => acc..addAll(chunk),
        );
        final stdoutFuture = process.stdout.fold<List<int>>(
          <int>[],
          (acc, chunk) => acc..addAll(chunk),
        );

        await process.exitCode;
        final stderrBytes = await stderrFuture;
        final stdoutBytes = await stdoutFuture;

        final text =
            '${utf8.decode(stdoutBytes, allowMalformed: true)}\n'
            '${utf8.decode(stderrBytes, allowMalformed: true)}';
        return _parseDshowDevices(text);
      } catch (_) {
        return [];
      }
    }

    if (!Platform.isLinux) return [];

    final chosen = backend ?? await resolveBackend();
    return _listLinuxDevices(chosen);
  }

  /// Dispositivos de Linux para el backend elegido.
  ///
  /// Se agrega siempre una entrada `default`: es valida tanto en PulseAudio como
  /// en ALSA y evita que el DJ se quede sin ninguna opcion si la enumeracion
  /// falla (por ejemplo, `pactl` no instalado pero el servidor funcionando).
  Future<List<InputDevice>> _listLinuxDevices(CaptureBackend backend) async {
    final devices = <InputDevice>[
      const InputDevice(
        id: 'default',
        name: 'Predeterminado del sistema (default)',
      ),
    ];

    if (backend == CaptureBackend.alsa) {
      devices.addAll(await _listAlsaDevices());
    } else {
      devices.addAll(await _listPulseSources());
    }

    final seen = <String>{};
    return [
      for (final device in devices)
        if (seen.add(device.id)) device,
    ];
  }

  /// Lee las fuentes de PulseAudio/PipeWire.
  ///
  /// Se fuerza `LANG=C` porque `pactl` traduce las etiquetas (`Nombre:`,
  /// `Descripción:`). Parsear un texto localizado es fragil; en ingles las
  /// claves (`Name:`, `Description:`, `Monitor of Sink:`) son estables.
  Future<List<InputDevice>> _listPulseSources() async {
    final result = await _runTool(
      'pactl',
      ['list', 'sources'],
      environment: const {'LANG': 'C', 'LC_ALL': 'C'},
    );
    if (result == null || result.exitCode != 0) return [];
    return parsePulseSources(_decode(result.stdout));
  }

  /// Extrae las fuentes del texto de `pactl list sources`.
  ///
  /// Publica para poder verificarla con salidas reales de PulseAudio y de
  /// PipeWire sin depender de que el equipo de pruebas tenga audio.
  static List<InputDevice> parsePulseSources(String text) {
    final devices = <InputDevice>[];
    // Cada fuente empieza con `Source #N`; el bloque termina en la siguiente.
    final blocks = text.split(RegExp(r'^Source #\d+\s*$', multiLine: true));
    for (final block in blocks.skip(1)) {
      final name = _field(block, 'Name');
      if (name == null || name.isEmpty) continue;

      var description = _field(block, 'Description');
      final monitorSink = _field(block, 'Monitor of Sink');
      final isMonitor =
          name.endsWith('.monitor') ||
          (monitorSink != null && monitorSink != 'n/a');

      // `pactl` se ejecuta con LANG=C para que las claves sean estables; eso
      // deja las descripciones en ingles. La interfaz esta en espanol, asi que
      // se traduce lo unico que se muestra de forma sistematica.
      if (description != null && description.startsWith('Monitor of ')) {
        description = 'Monitor de ${description.substring(11)}';
      }

      var label = name;
      if (description != null &&
          description.isNotEmpty &&
          description != '(null)' &&
          description != name) {
        label = '$description — $name';
      }
      if (isMonitor && !label.toLowerCase().contains('monitor')) {
        label = 'Monitor: $label';
      }

      devices.add(InputDevice(id: name, name: label, isMonitor: isMonitor));
    }
    return devices;
  }

  static String? _field(String block, String name) {
    final regex = RegExp(
      '^[ \t]*${RegExp.escape(name)}:[ \t]*(.*)\$',
      multiLine: true,
    );
    final match = regex.firstMatch(block);
    return match?.group(1)?.trim();
  }

  /// Lee las entradas de ALSA.
  ///
  /// Primero se intenta `arecord -l` (tarjetas de sonido reales). Si el equipo
  /// solo tiene dispositivos virtuales (por ejemplo, el plugin `pipewire` de
  /// ALSA), esa salida viene vacia y se usa `arecord -L`, que lista todos los
  /// PCM disponibles.
  Future<List<InputDevice>> _listAlsaDevices() async {
    const cLocale = {'LANG': 'C', 'LC_ALL': 'C'};

    final listResult = await _runTool('arecord', ['-l'], environment: cLocale);
    if (listResult != null) {
      final devices = parseAlsaCards(_decode(listResult.stdout));
      if (devices.isNotEmpty) return devices;
    }

    final pcmResult = await _runTool('arecord', ['-L'], environment: cLocale);
    if (pcmResult == null) return const [];
    return parseAlsaPcms(_decode(pcmResult.stdout));
  }

  /// Extrae las tarjetas de `arecord -l`.
  ///
  /// Ejemplo:
  /// `card 0: PCH [HDA Intel PCH], device 0: ALC3227 Analog [ALC3227 Analog]`
  static List<InputDevice> parseAlsaCards(String text) {
    final devices = <InputDevice>[];
    final seen = <String>{};
    final regex = RegExp(
      r'^card (\d+): \w+ \[([^\]]+)\], device (\d+): ([^\[]+)\[([^\]]+)\]',
      multiLine: true,
    );
    for (final match in regex.allMatches(text)) {
      final card = match.group(1)!;
      final deviceNumber = match.group(3)!;
      final cardName = match.group(2)!.trim();
      final deviceName = match.group(4)!.trim();
      final id = 'plughw:$card,$deviceNumber';
      if (!seen.add(id)) continue;
      devices.add(InputDevice(id: id, name: '$cardName: $deviceName ($id)'));
    }
    return devices;
  }

  /// Extrae los PCM de `arecord -L` (incluye dispositivos virtuales).
  static List<InputDevice> parseAlsaPcms(String text) {
    final devices = <InputDevice>[];
    final seen = <String>{};
    final lines = text.split(RegExp(r'\r?\n'));
    String? current;
    String description = '';
    void flush() {
      if (current == null) return;
      _addAlsaPcm(devices, seen, current!, description);
      current = null;
      description = '';
    }

    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      if (line.startsWith(' ') || line.startsWith('\t')) {
        if (current != null && description.isEmpty) {
          description = line.trim();
        }
        continue;
      }
      flush();
      current = line.trim();
      description = '';
    }
    flush();
    return devices;
  }

  static void _addAlsaPcm(
    List<InputDevice> devices,
    Set<String> seen,
    String id,
    String description,
  ) {
    // `null` descarta el audio: no sirve para emitir. `default` ya esta en la
    // lista principal y se agrega una sola vez.
    if (id == 'null' || id == 'default' || id.isEmpty) return;
    if (!seen.add(id)) return;
    devices.add(
      InputDevice(
        id: id,
        name: description.isEmpty ? id : '$id — $description',
      ),
    );
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
    this.codec = AudioCodec.mp3,
    this.meterOnly = false,
    CaptureBackend? backend,
  }) : _backend = backend;

  final String deviceName;
  final int bitrateKbps;
  final int sampleRate;
  final int channels;

  /// Codec con el que se codifica el audio enviado (y grabado).
  final AudioCodec codec;

  /// Ganancia de entrada en dB (el control de volumen del DJ).
  final double gainDb;

  /// Emitir tambien un PCM de niveles por stderr.
  final bool metering;

  /// Solo medir niveles: no produce audio por stdout.
  ///
  /// Lo usa el monitor de entrada que mantiene el vumetro activo fuera del
  /// aire. Al no codificar MP3/AAC gasta mucho menos CPU y no genera un flujo
  /// que nadie va a escuchar.
  final bool meterOnly;

  /// Capturador elegido. `null` = el preferido de la plataforma.
  ///
  /// Las pruebas lo fijan de forma explicita para poder comprobar la linea de
  /// comandos de Windows y de Linux en cualquier equipo.
  final CaptureBackend? _backend;

  /// Capturador efectivo que se usara en la linea de comandos.
  CaptureBackend get backend => _backend ?? CaptureBackend.forPlatform();

  /// Argumentos que abren el dispositivo de entrada.
  ///
  /// Se expone porque el diagnostico de fallos vuelve a abrir el mismo
  /// dispositivo con otra salida (`-f null`), y debe usar exactamente el mismo
  /// capturador: si no, el mensaje de error hablaria de otro dispositivo.
  List<String> get inputArguments {
    switch (backend) {
      case CaptureBackend.dshow:
        return [
          '-f',
          'dshow',
          '-audio_buffer_size',
          '50',
          '-i',
          'audio=${_escapeDshow(deviceName)}',
        ];
      case CaptureBackend.pulse:
        return [
          '-f',
          'pulse',
          '-i',
          deviceName.trim().isEmpty ? 'default' : deviceName,
        ];
      case CaptureBackend.alsa:
        return [
          '-f',
          'alsa',
          '-i',
          deviceName.trim().isEmpty ? 'default' : deviceName,
        ];
    }
  }

  /// Construye la linea de comandos.
  ///
  /// Salidas normales:
  ///  1. Audio codificado (MP3 o AAC) hacia `pipe:1` -> lo consume el motor.
  ///  2. PCM crudo s16le mono 8 kHz hacia `pipe:2` -> vumetros.
  ///
  /// Con [meterOnly] solo se genera la salida 2: es el monitor de entrada que
  /// mantiene el vumetro vivo sin estar al aire.
  ///
  /// La grabacion local NO se hace aqui: el motor duplica el mismo flujo que
  /// ya viaja al servidor, asi lo grabado es exactamente lo que oyeron los
  /// oyentes y no se gasta CPU en codificar dos veces.
  List<String> build(String executablePath) {
    final args = <String>[
      '-hide_banner',
      '-loglevel',
      'error',
      // Captura del dispositivo de entrada (dshow, pulse o alsa).
      ...inputArguments,
      // Cadena de filtros: ganancia y limitador para no saturar el codec.
      '-af',
      _filterChain(),
    ];

    if (!meterOnly) {
      args.addAll(['-ac', '$channels', '-ar', '$sampleRate']);
      // El mapeo se hace explicito (`-map 0:a:0`) en cada salida: con dos
      // salidas, dejar que FFmpeg elija el flujo por su cuenta es una fuente
      // clasica de "el audio sale sin filtros" o "el vumetro mide otra cosa".
      args.addAll(['-map', '0:a:0', ...codecOutputArguments]);
    }

    // Niveles por stderr. Se emiten tambien en modo `meterOnly`.
    if (metering || meterOnly) {
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

  /// Argumentos del encoder de salida para el codec elegido.
  List<String> get codecOutputArguments {
    switch (codec) {
      case AudioCodec.mp3:
        return [
          '-c:a',
          'libmp3lame',
          '-b:a',
          '${bitrateKbps}k',
          // Sin etiqueta ID3 ni cabecera Xing al inicio: el servidor recibe
          // solo tramas MP3, que es lo que espera un flujo Icecast.
          '-id3v2_version',
          '0',
          '-write_xing',
          '0',
          '-f',
          'mp3',
          'pipe:1',
        ];
      case AudioCodec.aac:
        return [
          '-c:a',
          'aac',
          '-b:a',
          '${bitrateKbps}k',
          '-f',
          'adts',
          'pipe:1',
        ];
      case AudioCodec.aacPlus:
        return [
          '-c:a',
          'libfdk_aac',
          // HE-AAC v2 para estereo (mejor eficiencia a 32-48 kbps); HE-AAC v1
          // en mono, porque v2 necesita dos canales.
          '-profile:a',
          channels == 1 ? 'aac_he' : 'aac_he_v2',
          '-b:a',
          '${bitrateKbps}k',
          '-f',
          'adts',
          'pipe:1',
        ];
    }
  }

  /// Tipo MIME que corresponde al codec elegido.
  String get mimeType => codec.mimeType;

  /// Extension del archivo de grabacion para el codec elegido.
  String get fileExtension => codec.fileExtension;

  /// El comando completo en una linea, para mostrarlo o copiarlo.
  ///
  /// Sirve para diagnosticar: si un dispositivo no captura, el DJ puede pegar
  /// esto en una consola y ver el error real de FFmpeg. Ademas es la unica
  /// forma practica de revisar la configuracion en una PC ajena.
  String preview() {
    final exe = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
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
    // Evita que un pico distorsione el audio enviado a los oyentes.
    filters.add('alimiter=limit=0.95:attack=5:release=50');
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
  /// 3. Si sigue vivo, forzarlo por PID: `taskkill` en Windows; `kill -9` en
  ///    Linux/macOS.
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
    if (Platform.isWindows) {
      try {
        final result = await Process.run('taskkill', [
          '/F',
          '/T',
          '/PID',
          '$pid',
        ]).timeout(const Duration(seconds: 5));
        // taskkill devuelve 128 si el proceso ya no existia: eso tambien es
        // exito.
        _lastStopDetail = 'taskkill ${result.exitCode}';
      } catch (e) {
        _lastStopDetail = 'taskkill fallo: $e';
      }
    } else {
      // En Linux no existe taskkill. `kill -9` por PID es lo unico que no
      // depende de que el proceso escuche el cierre de stdin.
      try {
        final killed = Process.killPid(pid, ProcessSignal.sigkill);
        _lastStopDetail = killed
            ? 'kill -9 $pid'
            : 'kill -9 $pid (ya no existia)';
      } catch (e) {
        _lastStopDetail = 'kill -9 fallo: $e';
      }
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
  double _peakHoldDb = -60;
  DateTime _peakHoldAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Pico actual en dBFS (-60 a 0).
  double get peakDb => _peakDb;

  /// Pico retenido para el numero del vumetro.
  ///
  /// Mantiene el maximo durante 2 segundos para que la lectura no baile con
  /// cada bloque de PCM. La barra sigue usando [peakDb].
  double get peakHoldDb => _peakHoldDb;

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

    final now = DateTime.now();
    if (newPeak >= _peakHoldDb ||
        now.difference(_peakHoldAt) > const Duration(seconds: 2)) {
      _peakHoldDb = newPeak;
      _peakHoldAt = now;
    }
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
    _peakHoldDb = -60;
    _peakHoldAt = DateTime.fromMillisecondsSinceEpoch(0);
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
    final isAsciiText =
        b == 0x09 || b == 0x0A || b == 0x0D || (b >= 0x20 && b <= 0x7E);
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
    final process = await Process.start(ffmpegPath, [
      '-hide_banner',
      // El mismo capturador y el mismo dispositivo que la captura real: el
      // diagnostico debe reproducir exactamente el fallo.
      ...args.inputArguments,
      // Un solo resultado para que FFmpeg intente abrir el dispositivo y
      // termine enseguida, en vez de quedarse capturando.
      '-t',
      '0.2',
      '-f',
      'null',
      '-',
    ], environment: environment.isEmpty ? null : environment);

    // Se leen las dos salidas a la vez para no bloquear el proceso.
    //
    // El decodificador UTF-8 se aplica al flujo completo, no bloque por bloque:
    // un caracter acentuado puede quedar partido entre dos bloques y
    // decodificarlo por separado lo corrompe (el mismo fallo que hacia
    // imposible abrir un dispositivo con acentos).
    final stderrFuture = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final stdoutFuture = process.stdout.drain<void>();

    try {
      await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
    final stderrText = await stderrFuture;
    await stdoutFuture;

    return stderrText
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
      t.contains('no such source') ||
      t.contains('device not found') ||
      t.contains('none found') ||
      t.contains('could not enumerate') ||
      t.contains('cannot open audio device') ||
      t.contains('failed to open pulse');
}

/// Convierte un texto de error de FFmpeg en algo entendible.
///
/// [backend] permite distinguir mensajes que FFmpeg escribe igual en Windows y
/// en Linux. Por ejemplo, `No such file or directory` puede significar que falta
/// el ejecutable o que la fuente de PulseAudio ya no existe; sin saber que
/// capturador se estaba usando, el mensaje al DJ seria el equivocado.
String explainFfmpegError(String stderrText, {CaptureBackend? backend}) {
  final t = stderrText.toLowerCase();
  final isPulse = backend == CaptureBackend.pulse || t.contains('pulse');
  final isAlsa = backend == CaptureBackend.alsa || t.contains('alsa');

  // La build de FFmpeg no trae el capturador que la app intenta usar. Es un
  // fallo de instalacion, no del microfono: decirlo evita que el DJ compre uno.
  if (t.contains('unknown input format')) {
    final which = t.contains("'pulse'")
        ? 'PulseAudio'
        : t.contains("'alsa'")
        ? 'ALSA'
        : 'el capturador de audio';
    return 'Este FFmpeg no incluye soporte para $which. Usa el paquete de FFmpeg '
        'de tu distribucion (suele traer pulse y alsa) o una build "full".';
  }

  // PulseAudio/PipeWire: servidor caido o fuente inexistente.
  if (isPulse &&
      (t.contains('connection refused') ||
          t.contains('connection failure') ||
          t.contains('failed to connect') ||
          t.contains('no such process'))) {
    return 'No se pudo conectar con el servidor de audio (PulseAudio/PipeWire). '
        'Comprueba que el sonido del equipo funcione y volve a intentar.';
  }
  if (isPulse &&
      (t.contains('no such source') ||
          t.contains('failed to open pulse') ||
          t.contains('no such file or directory'))) {
    return 'No se encontro la fuente de audio seleccionada. '
        'Elegi otro dispositivo en Ajustes.';
  }

  // ALSA: plugin que falta, dispositivo ocupado o inexistente.
  if (isAlsa && t.contains('cannot open shared library')) {
    return 'ALSA no pudo cargar su plugin de audio. Instala el paquete '
        '"alsa-plugins" (o usa PulseAudio en Ajustes).';
  }
  if (isAlsa && t.contains('cannot open audio device')) {
    if (t.contains('busy')) {
      return 'Otro programa esta usando el dispositivo de audio. '
          'Cerralo o elegi otro dispositivo.';
    }
    return 'No se encontro el dispositivo ALSA seleccionado. '
        'Elegi otro dispositivo en Ajustes.';
  }

  if (t.contains('device or resource busy') ||
      t.contains('device already in use') ||
      t.contains('access is denied') ||
      t.contains('permission denied')) {
    return 'Otro programa esta usando el microfono (Zoom, OBS, Teams...). '
        'Cerralo o elegi otro dispositivo.';
  }
  if (t.contains('could not find audio only device') ||
      t.contains('could not find') && t.contains('device')) {
    return 'No se encontro el dispositivo de audio seleccionado. '
        'Elegi otro microfono en Ajustes.';
  }
  if (t.contains('unknown encoder') && t.contains('libmp3lame')) {
    return 'El FFmpeg instalado no incluye el codificador MP3 (libmp3lame). '
        'Descarga una build "full" o "gpl".';
  }
  if (t.contains('no such file or directory')) {
    if (isPulse ||
        isAlsa ||
        t.contains('audio device') ||
        t.contains('input file')) {
      return 'No se encontro el dispositivo de audio seleccionado. '
          'Elegi otro dispositivo en Ajustes.';
    }
    return 'No se encontro el ejecutable de FFmpeg. Revisa la ruta en Ajustes.';
  }
  if (t.isEmpty) return 'FFmpeg termino sin explicar el motivo.';
  return 'FFmpeg reporto: ${stderrText.trim().split(RegExp(r'\r?\n')).take(3).join(' / ')}';
}
