import 'dart:async';

import 'package:flutter/material.dart';

import 'core/audio/broadcast_engine.dart';
import 'core/audio/input_monitor.dart';
import 'core/audio/ffmpeg_capture.dart';
import 'core/diagnostic_log.dart';
import 'core/net/stream_health.dart';
import 'core/profile_store.dart';
import 'core/server_profile.dart';
import 'ui/broadcast_screen.dart';
import 'ui/profiles_screen.dart';
import 'ui/settings_screen.dart';
import 'ui/theme.dart';

void main() {
  runApp(const XtremeStudioApp());
}

/// Aplicacion Xtreme Studio: consola de emision multi-emisora.
class XtremeStudioApp extends StatelessWidget {
  const XtremeStudioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Xtreme Studio',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(),
      home: const StudioHome(),
    );
  }
}

/// Estado global de la aplicacion mientras esta abierta.
///
/// Se usa un `ChangeNotifier` simple en lugar de una libreria de estado: la
/// app tiene un unico modelo de datos y evita una dependencia mas.
class StudioHome extends StatefulWidget {
  const StudioHome({super.key});

  @override
  State<StudioHome> createState() => _StudioHomeState();
}

class _StudioHomeState extends State<StudioHome> {
  final ProfileStore _store = ProfileStore();

  List<ServerProfile> _profiles = [];
  AppSettings _settings = AppSettings();
  ServerProfile? _activeProfile;

  BroadcastEngine? _engine;
  StreamSubscription<BroadcastSnapshot>? _snapshotSub;
  StreamSubscription<LogEntry>? _logSub;

  /// Captura liviana que mantiene el vumetro activo fuera del aire.
  InputMonitor? _inputMonitor;
  StreamSubscription<InputLevels>? _monitorLevelsSub;
  StreamSubscription<String>? _monitorErrorsSub;
  double _monitorPeakDb = -60;
  double _monitorHoldDb = -60;
  double _monitorRmsDb = -60;

  /// Monitor de senal: comprueba, como lo haria un oyente, que el servidor
  /// este sirviendo el mount. Cubre el caso en que nuestra conexion sigue viva
  /// pero nadie puede escuchar.
  StreamHealthMonitor? _signalMonitor;
  Timer? _signalTimer;
  Timer? _signalInitialCheck;
  SignalCheck? _signalCheck;

  BroadcastSnapshot _snapshot = const BroadcastSnapshot(
    state: BroadcastState.idle,
    peakDb: -60,
    rmsDb: -60,
    secondsOnAir: 0,
    bytesSent: 0,
    reconnectAttempt: 0,
  );
  final List<LogEntry> _log = [];

  /// Ultimo titulo escrito por el DJ. Se conserva aunque todavia no este al
  /// aire, para enviarlo al servidor en cuanto la conexion se establece.
  String _pendingTrack = '';

  List<InputDevice> _devices = [];
  CaptureBackend? _captureBackend;
  Set<AudioCodec> _availableCodecs = const {AudioCodec.mp3};
  String _ffmpegPath = '';
  bool _loading = true;
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // El registro se abre antes que nada: si algo falla al arrancar, queda
    // escrito. Nunca impide que la app funcione (si no se puede escribir, se
    // desactiva en silencio).
    await DiagnosticLog.open();
    DiagnosticLog.instance?.write('app', 'iniciando Xtreme Studio');

    final settings = await _store.loadSettings();
    final profiles = await _store.load();
    final ffmpeg = await ProfileStore.findFfmpeg(settings.ffmpegPath);
    final codecs = ffmpeg.isEmpty
        ? const {AudioCodec.mp3}
        : await FfmpegLocator(ffmpeg).availableCodecs();

    DiagnosticLog.instance?.write(
      'app',
      'arranque: ffmpeg="${ffmpeg.isEmpty ? "(no encontrado)" : ffmpeg}" '
          'emisoras=${profiles.length} '
          'dispositivo_guardado="${settings.lastDeviceId}"',
    );

    // Si no hay perfiles, se ofrece crear el primero en lugar de mostrar una
    // pantalla vacia sin explicacion.
    ServerProfile? active;
    if (profiles.isNotEmpty) {
      active = profiles.firstWhere(
        (p) => p.id == settings.lastProfileId,
        orElse: () => profiles.first,
      );
    }

    if (!mounted) return;
    setState(() {
      _settings = settings;
      _profiles = profiles;
      _activeProfile = active;
      _ffmpegPath = ffmpeg;
      _availableCodecs = codecs;
      _loading = false;
    });

    if (ffmpeg.isNotEmpty) {
      await refreshDevices();
    }
    // Reparacion de datos: versiones anteriores guardaban el nombre del
    // dispositivo mal codificado (`Mezcla estÃ©reo` en lugar de `Mezcla estéreo`)
    // y ese nombre ya no existe en el sistema, asi que la captura fallaba sin
    // explicacion.
    final repaired = repairDeviceName(settings.lastDeviceId);
    if (repaired != settings.lastDeviceId) {
      DiagnosticLog.instance?.write(
        'audio',
        'nombre de dispositivo guardado corrupto: "${settings.lastDeviceId}" '
            '-> corregido a "$repaired"',
      );
      settings.lastDeviceId = repaired;
      await _store.saveSettings(settings);
    }

    // Si el dispositivo guardado ya no existe entre los detectados, se borra
    // para que el DJ tenga que elegir uno de la lista real en lugar de arrastrar
    // un nombre invalido.
    if (_devices.isNotEmpty &&
        settings.lastDeviceId.isNotEmpty &&
        !_devices.any((d) => d.id == settings.lastDeviceId)) {
      DiagnosticLog.instance?.write(
        'audio',
        'el dispositivo guardado "${settings.lastDeviceId}" ya no esta '
            'disponible entre los ${_devices.length} detectados: se pedira '
            'elegir de nuevo',
      );
      settings.lastDeviceId = '';
      await _store.saveSettings(settings);
    }
  }

  /// Relee la lista de dispositivos de entrada.
  Future<void> refreshDevices() async {
    if (_ffmpegPath.isEmpty) return;
    final locator = FfmpegLocator(_ffmpegPath);
    // El capturador se decide con la build real de FFmpeg y con el servidor de
    // audio que este corriendo (PulseAudio/PipeWire o ALSA). No se asume por
    // sistema operativo.
    final backend = await locator.resolveBackend();
    final devices = await locator.listAudioDevices(backend: backend);
    DiagnosticLog.instance?.write(
      'audio',
      'capturador=${backend.label}; dispositivos detectados: ${devices.length}'
          '${devices.isEmpty ? "" : " -> ${devices.map((d) => d.name).join(" | ")}"}',
    );

    if (!mounted) return;
    setState(() {
      _devices = devices;
      _captureBackend = backend;
    });

    // Se limpia el dispositivo guardado si no esta entre los reales.
    await _clearStaleDeviceSelection();
    await _startInputMonitor(force: true);
  }

  /// Dispositivo que se usara para monitorear o salir al aire.
  ///
  /// Orden: microfono del perfil, dispositivo de Ajustes y, por ultimo, el
  /// primero que reporte el sistema.
  String _chosenDeviceId() {
    final profile = _activeProfile;
    final saved = profile?.inputDeviceId.isNotEmpty == true
        ? profile!.inputDeviceId
        : _settings.lastDeviceId;
    final id = saved.isNotEmpty
        ? saved
        : (_devices.isNotEmpty ? _devices.first.id : '');
    return repairDeviceName(id);
  }

  /// Arranca (o reinicia) el monitor de entrada fuera del aire.
  Future<void> _startInputMonitor({bool force = false}) async {
    if (_ffmpegPath.isEmpty) return;
    if (_snapshot.state == BroadcastState.live ||
        _snapshot.state == BroadcastState.starting ||
        _snapshot.state == BroadcastState.reconnecting) {
      return;
    }

    final backend =
        _captureBackend ?? await FfmpegLocator(_ffmpegPath).resolveBackend();
    if (!mounted) return;

    final device = _chosenDeviceId();
    final current = _inputMonitor;
    if (!force &&
        current != null &&
        current.isRunning &&
        current.deviceName == device &&
        current.backend == backend) {
      return;
    }

    await _stopInputMonitor(dispose: true);
    if (!mounted) return;

    final monitor = InputMonitor(
      ffmpegPath: _ffmpegPath,
      deviceName: device,
      backend: backend,
      // El monitor captura sin ganancia; la ganancia del perfil se aplica en
      // la lectura que se muestra. Asi mover el control no reinicia el
      // dispositivo ni deja el vumetro congelado.
      gainDb: 0,
    );
    _inputMonitor = monitor;
    _monitorLevelsSub = monitor.levels.listen((levels) {
      if (!mounted) return;
      setState(() {
        _monitorPeakDb = levels.peakDb;
        _monitorHoldDb = levels.peakHoldDb;
        _monitorRmsDb = levels.rmsDb;
      });
    });
    _monitorErrorsSub = monitor.errors.listen((message) {
      if (!mounted) return;
      DiagnosticLog.instance?.write('audio', 'monitor: $message');
      _logSignal(message, 'warn');
    });

    final ok = await monitor.start();
    if (!ok && mounted) {
      final message = monitor.lastError ?? 'No se pudo monitorear la entrada';
      DiagnosticLog.instance?.write('audio', message);
      _logSignal(message, 'warn');
    }
  }

  Future<void> _stopInputMonitor({bool dispose = false}) async {
    await _monitorLevelsSub?.cancel();
    _monitorLevelsSub = null;
    await _monitorErrorsSub?.cancel();
    _monitorErrorsSub = null;
    final monitor = _inputMonitor;
    _inputMonitor = null;
    if (monitor != null) {
      if (dispose) {
        await monitor.dispose();
      } else {
        await monitor.stop();
      }
    }
    if (mounted) {
      setState(() {
        _monitorPeakDb = -60;
        _monitorHoldDb = -60;
        _monitorRmsDb = -60;
      });
    }
  }

  /// Instantanea que ve la interfaz: fuera del aire usa el monitor de entrada.
  BroadcastSnapshot get _viewSnapshot {
    if (_snapshot.state == BroadcastState.idle ||
        _snapshot.state == BroadcastState.stopped) {
      final gain = _activeProfile?.gainDb ?? 0.0;
      double shown(double db) {
        if (db <= -60) return -60;
        return (db + gain).clamp(-60.0, 0.0);
      }

      return _snapshot.copyWith(
        peakDb: shown(_monitorPeakDb),
        rmsDb: shown(_monitorRmsDb),
        peakHoldDb: shown(_monitorHoldDb),
      );
    }
    return _snapshot;
  }

  /// Borra el dispositivo guardado si ya no existe en el sistema.
  Future<void> _clearStaleDeviceSelection() async {
    final saved = _settings.lastDeviceId;
    if (saved.isEmpty || _devices.isEmpty) return;
    if (_devices.any((d) => d.id == saved)) return;

    DiagnosticLog.instance?.write(
      'audio',
      'el dispositivo guardado "$saved" no esta entre los detectados: '
          'se descarta para no intentar abrir uno inexistente',
    );
    setState(() => _settings.lastDeviceId = '');
    await _store.saveSettings(_settings);
  }

  /// Persiste la seleccion de emisora y los ajustes.
  ///
  /// No se vuelven a guardar todos los perfiles: `ProfilesScreen` ya guarda el
  /// que cambio. Reescribirlos todos obligaba a descifrar y volver a cifrar cada
  /// contrasena en cada cambio, y si alguna no se podia descifrar se borraba su
  /// archivo de secreto.
  Future<void> _saveProfiles() async {
    await _store.saveSettings(_settings);
  }

  Future<void> _saveSettings() async {
    await _store.saveSettings(_settings);
    final ffmpeg = await ProfileStore.findFfmpeg(_settings.ffmpegPath);
    final codecs = ffmpeg.isEmpty
        ? const {AudioCodec.mp3}
        : await FfmpegLocator(ffmpeg).availableCodecs();
    if (!mounted) return;
    setState(() {
      _ffmpegPath = ffmpeg;
      _availableCodecs = codecs;
    });
    await refreshDevices();
  }

  /// Entra al aire con el perfil activo.
  Future<void> _goLive() async {
    final profile = _activeProfile;
    if (profile == null) {
      _showMessage('Primero agrega y elegi una emisora');
      return;
    }
    final problems = profile.validate();
    if (problems.isNotEmpty) {
      _showMessage(problems.first);
      return;
    }
    if (_ffmpegPath.isEmpty) {
      _showMessage(
        'No se encontro FFmpeg. Indica la ruta del ejecutable en Ajustes.',
      );
      return;
    }
    if (!_availableCodecs.contains(profile.audio.codec)) {
      _showMessage(
        'El FFmpeg instalado no puede codificar ${profile.audio.codec.label}. '
        'Elegi otro codec en la emisora o instala una build con '
        '${profile.audio.codec.encoder}.',
        isError: true,
      );
      return;
    }

    // Cada intento de salir al aire puede volver a necesitar el aviso por falta
    // de dispositivo: si no se reinicia, solo se mostraria la primera vez.
    _deviceRecoveryShown = false;

    // Se suelta el monitor antes de abrir la captura de emision: en ALSA el
    // dispositivo es exclusivo y dos procesos no pueden abrirlo a la vez.
    await _stopInputMonitor(dispose: true);

    // Un intento anterior fallido pudo dejar el motor con sus canales abiertos.
    // Se libera antes de crear uno nuevo para no acumular escuchas ni sockets.
    final previous = _engine;
    if (previous != null &&
        (previous.snapshot.state == BroadcastState.live ||
            previous.snapshot.state == BroadcastState.starting ||
            previous.snapshot.state == BroadcastState.reconnecting)) {
      return; // Ya hay una emision en curso.
    }
    await _disposeEngine();

    // El dispositivo elegido puede haber desaparecido (microfono desconectado,
    // cascos cambiados). Si se pasa un nombre que ya no existe, FFmpeg falla y
    // el DJ veria "no captura audio" sin saber por que: mejor decirlo claro.
    // Orden de preferencia: el microfono asignado a esta emisora, luego el
    // elegido en Ajustes y, por ultimo, el primero disponible. Asi una radio
    // concreta puede usar su propio equipo sin cambiar el ajuste global.
    final chosen = profile.inputDeviceId.isNotEmpty
        ? profile.inputDeviceId
        : (_settings.lastDeviceId.isNotEmpty
              ? _settings.lastDeviceId
              : (_devices.isNotEmpty ? _devices.first.id : ''));

    if (_devices.isNotEmpty && chosen.isNotEmpty) {
      // Se repara por si quedo un nombre mal codificado de una version anterior.
      final fixed = repairDeviceName(chosen);
      final stillThere =
          _devices.any((d) => d.id == chosen) ||
          _devices.any((d) => d.id == fixed);
      if (!stillThere) {
        _showMessage(
          'El dispositivo de audio "$chosen" ya no esta disponible. '
          'Elegi otro en Ajustes o conectalo de nuevo.',
          isError: true,
        );
        return;
      }
    }

    final engine = BroadcastEngine(
      profile: profile,
      ffmpegPath: _ffmpegPath,
      // La ganancia viene del perfil: cada emisora puede usar otro microfono.
      gainDb: profile.gainDb,
      deviceName: repairDeviceName(chosen),
      captureBackend: _captureBackend,
      // La grabacion es un ajuste global de la app (Ajustes), no del perfil.
      recordLocally: _settings.recordLocally,
      recordDirectory: _settings.recordDirectory,
    );

    await _snapshotSub?.cancel();
    await _logSub?.cancel();
    _log.clear();

    _snapshotSub = engine.snapshots.listen((s) {
      if (!mounted) return;
      setState(() => _snapshot = s);
      _reactToCaptureFailure(s);
    });
    _logSub = engine.logs.listen((entry) {
      if (!mounted) return;
      setState(() {
        _log.insert(0, entry);
        if (_log.length > 300) _log.removeLast();
      });
    });

    setState(() => _engine = engine);

    final ok = await engine.goLive();
    if (ok) {
      // El "suena ahora" escrito antes de salir al aire se instala ahora.
      if (_pendingTrack.isNotEmpty) await engine.setTrack(_pendingTrack);
      if (!mounted) return;
      _startSignalMonitoring(profile);
      return;
    }

    // El mount ya tiene otro DJ. Antes de desplazarlo se pregunta: en una
    // emisora donde varios locutores comparten clave, entrar sin avisar deja
    // al otro fuera del aire sin enterarse.
    if (mounted &&
        BroadcastEngine.isMountOccupiedError(engine.lastConnectStatusCode)) {
      final confirmed = await _confirmDisplaceOtherDj(profile);
      if (confirmed) {
        final forced = await engine.goLive(force: true);
        if (forced) {
          if (_pendingTrack.isNotEmpty) await engine.setTrack(_pendingTrack);
          if (mounted) _startSignalMonitoring(profile);
          return;
        }
        if (mounted) {
          _showMessage(
            engine.snapshot.lastError ?? 'No se pudo entrar al aire',
            isError: true,
          );
        }
      }
    } else if (mounted) {
      // El motor ya dejo el motivo en el snapshot; se muestra destacado.
      final error = engine.snapshot.lastError;
      if (error != null) _showMessage(error, isError: true);
    }

    // Intento terminado sin emision: se libera el motor y su captura, y se
    // devuelve el vumetro al monitor de entrada.
    await _disposeEngine();
    await _startInputMonitor(force: true);
  }

  /// Cancela las escuchas y libera el motor actual.
  Future<void> _disposeEngine() async {
    final engine = _engine;
    _engine = null;
    await _snapshotSub?.cancel();
    _snapshotSub = null;
    await _logSub?.cancel();
    _logSub = null;
    await engine?.dispose();
  }

  /// Pregunta si se debe desplazar al DJ que ya ocupa el mount.
  ///
  /// Devuelve `true` solo si el DJ confirma explicitamente. El texto intenta ser
  /// concreto sobre la consecuencia, porque "forzar" no explica nada a quien no
  /// conoce Icecast.
  Future<bool> _confirmDisplaceOtherDj(ServerProfile profile) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: AppColors.warning),
            SizedBox(width: 10),
            Text('Ese mount ya esta ocupado'),
          ],
        ),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'El servidor rechazo la conexion porque ya hay una fuente '
                'transmitiendo en ${profile.normalizedMount}. '
                'Puede ser otro locutor de tu emisora.',
                style: const TextStyle(height: 1.45),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.onAirDark.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: AppColors.onAir.withValues(alpha: 0.5),
                  ),
                ),
                child: const Text(
                  'Si continuas, tu emision reemplaza a la que esta al aire: '
                  'el otro locutor sale sin aviso y sus oyentes pasan a '
                  'escucharte a vos. Coordina antes por telefono o WhatsApp.',
                  style: TextStyle(fontSize: 12.5, height: 1.45),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Mejor no, espero'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.onAir),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('SI, SALIR AL AIRE IGUAL'),
          ),
        ],
      ),
    );
    return result == true;
  }

  /// Arranca la comprobacion periodica de la senal publicada.
  void _startSignalMonitoring(ServerProfile profile) {
    _stopSignalMonitoring();
    _signalMonitor = StreamHealthMonitor(profile: profile);
    // Primera comprobacion en cuanto haya un momento: el servidor necesita unos
    // segundos para publicar la fuente recien conectada.
    _signalInitialCheck = Timer(const Duration(seconds: 3), _checkSignal);
    // Y despues cada 30 s, para detectar que el servidor deje de servir el
    // mount aunque nuestra conexion siga en pie.
    _signalTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _checkSignal();
    });
  }

  Future<void> _checkSignal() async {
    final monitor = _signalMonitor;
    if (monitor == null) return;
    final result = await monitor.check();
    if (!mounted) return;
    setState(() => _signalCheck = result);

    // Solo se avisa cuando el estado empeora, para no llenar el registro.
    if (result.status.isProblem) {
      _logSignal(result.message, 'warn');
    }
  }

  /// Anade una linea al registro de actividad.
  void _logSignal(String message, String level) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, LogEntry(level, message));
      if (_log.length > 300) _log.removeLast();
    });
  }

  void _stopSignalMonitoring() {
    _signalTimer?.cancel();
    _signalTimer = null;
    _signalInitialCheck?.cancel();
    _signalInitialCheck = null;
    _signalMonitor?.dispose();
    _signalMonitor = null;
  }

  /// Sale del aire.
  Future<void> _goOffAir() async {
    final engine = _engine;
    if (engine == null) return;
    _stopSignalMonitoring();
    await engine.goOffAir();
    // `goOffAir` deja el motor sin captura ni socket, pero sus canales siguen
    // abiertos: hay que cerrarlos para no dejar recursos vivos tras cada salida.
    await _disposeEngine();
    if (!mounted) return;
    setState(() => _signalCheck = null);
    await _startInputMonitor(force: true);
  }

  /// Reacciona cuando la captura se detiene por falta de dispositivo.
  ///
  /// Es el caso de la app abierta antes de conectar el microfono: la lista de
  /// dispositivos quedo vacia y el motor no puede abrir nada. En vez de dejar
  /// al DJ con un mensaje y sin salida, se vuelve a buscar dispositivos y se
  /// avisa que hay que elegir uno.
  void _reactToCaptureFailure(BroadcastSnapshot snapshot) {
    if (snapshot.state != BroadcastState.stopped) return;
    final error = snapshot.lastError ?? '';
    if (error.isEmpty) return;
    if (!error.contains('dispositivo')) return;
    if (_deviceRecoveryShown) return;

    _deviceRecoveryShown = true;
    unawaited(_recoverDevices());
  }

  bool _deviceRecoveryShown = false;

  /// Vuelve a buscar dispositivos de entrada y lo informa.
  Future<void> _recoverDevices() async {
    final before = _devices.length;
    await refreshDevices();
    if (!mounted) return;

    final after = _devices.length;
    if (after == 0) {
      _showMessage(
        'No se detecta ningun dispositivo de audio. Conecta un microfono y '
        'pulsa "Buscar de nuevo" en Ajustes.',
        isError: true,
      );
    } else if (after != before) {
      _showMessage(
        'Se encontraron $after dispositivos de audio. Elegi uno en Ajustes y '
        'volve a salir al aire.',
      );
      setState(() => _tabIndex = 2);
    } else {
      _showMessage(
        'El dispositivo de audio no esta disponible. Revisa Ajustes.',
        isError: true,
      );
      setState(() => _tabIndex = 2);
    }
  }

  /// Recuerda el "suena ahora" y lo envia si ya estamos al aire.
  Future<void> _setTrack(String track) async {
    _pendingTrack = track;
    final engine = _engine;
    if (engine == null) {
      _showMessage('El titulo se enviara al salir al aire');
      return;
    }
    final ok = await engine.setTrack(track);
    if (!mounted) return;
    if (ok) {
      _showMessage('Suena ahora actualizado');
    } else {
      _showMessage('El servidor no acepto el cambio de titulo', isError: true);
    }
  }

  /// Ajusta la ganancia de entrada y la guarda en el perfil activo.
  ///
  /// Si se esta al aire, el motor reinicia la captura para aplicar el filtro:
  /// FFmpeg no permite cambiar la cadena de filtros de un proceso en marcha.
  Future<void> _changeGain(double db) async {
    final profile = _activeProfile;
    if (profile == null) return;
    DiagnosticLog.instance?.write(
      'audio',
      'ganancia ajustada a ${db.toStringAsFixed(1)} dB',
    );

    profile.gainDb = db;
    await _store.save(profile);
    if (!mounted) return;

    final engine = _engine;
    if (engine != null && engine.isCapturing) {
      await engine.setGain(db);
      if (!mounted) return;
      _showMessage(
        'Ganancia ajustada a ${db >= 0 ? '+' : ''}'
        '${db.toStringAsFixed(1)} dB',
      );
    }
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? AppColors.onAirDark : null,
        duration: Duration(seconds: isError ? 6 : 3),
      ),
    );
  }

  @override
  void dispose() {
    _stopSignalMonitoring();
    _snapshotSub?.cancel();
    _logSub?.cancel();
    _engine?.dispose();
    _monitorLevelsSub?.cancel();
    _monitorErrorsSub?.cancel();
    _inputMonitor?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final isLive =
        _snapshot.isLive ||
        _snapshot.state == BroadcastState.starting ||
        _snapshot.state == BroadcastState.reconnecting;

    return Scaffold(
      body: Column(
        children: [
          _TopBar(
            profile: _activeProfile,
            snapshot: _viewSnapshot,
            ffmpegReady: _ffmpegPath.isNotEmpty,
          ),
          Expanded(
            child: Row(
              children: [
                _SideNav(
                  index: _tabIndex,
                  locked: isLive,
                  onSelect: (i) => setState(() => _tabIndex = i),
                ),
                Expanded(
                  child: IndexedStack(
                    index: _tabIndex,
                    children: [
                      BroadcastScreen(
                        profile: _activeProfile,
                        snapshot: _viewSnapshot,
                        log: _log,
                        devices: _devices,
                        ffmpegReady: _ffmpegPath.isNotEmpty,
                        signalCheck: _signalCheck,
                        onGoLive: _goLive,
                        onGoOffAir: _goOffAir,
                        onTrackChanged: _setTrack,
                        onGainChanged: _changeGain,
                        onOpenProfiles: () => setState(() => _tabIndex = 1),
                      ),
                      ProfilesScreen(
                        profiles: _profiles,
                        activeProfile: _activeProfile,
                        store: _store,
                        devices: _devices,
                        availableCodecs: _availableCodecs,
                        onChanged: (profiles, active) async {
                          setState(() {
                            _profiles = profiles;
                            _activeProfile = active;
                            _settings.lastProfileId = active?.id ?? '';
                          });
                          await _saveProfiles();
                          await _startInputMonitor(force: true);
                        },
                        onMessage: _showMessage,
                      ),
                      SettingsScreen(
                        settings: _settings,
                        devices: _devices,
                        captureBackend: _captureBackend,
                        ffmpegPath: _ffmpegPath,
                        onChanged: (s) async {
                          setState(() => _settings = s);
                          await _saveSettings();
                        },
                        onRefreshDevices: refreshDevices,
                        onMessage: _showMessage,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Barra superior con el estado siempre visible.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.profile,
    required this.snapshot,
    required this.ffmpegReady,
  });

  final ServerProfile? profile;
  final BroadcastSnapshot snapshot;
  final bool ffmpegReady;

  @override
  Widget build(BuildContext context) {
    final status = switch (snapshot.state) {
      BroadcastState.live => (AppColors.live, 'AL AIRE'),
      BroadcastState.starting => (AppColors.warning, 'PREPARANDO'),
      BroadcastState.reconnecting => (AppColors.warning, 'RECONECTANDO'),
      BroadcastState.stopped => (AppColors.onAir, 'DETENIDO'),
      BroadcastState.idle => (AppColors.textMuted, 'FUERA DEL AIRE'),
    };

    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: status.$1,
              shape: BoxShape.circle,
              boxShadow: snapshot.isLive
                  ? [
                      BoxShadow(
                        color: status.$1.withValues(alpha: 0.6),
                        blurRadius: 8,
                        spreadRadius: 2,
                      ),
                    ]
                  : null,
            ),
          ),
          const SizedBox(width: 12),
          const Text(
            'XTREME STUDIO',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              letterSpacing: 1.4,
              fontSize: 15,
            ),
          ),
          const SizedBox(width: 10),
          const Text(
            'Modo multi-emisora',
            style: TextStyle(color: AppColors.textMuted, fontSize: 12),
          ),
          const Spacer(),
          if (!ffmpegReady)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              margin: const EdgeInsets.only(right: 12),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: AppColors.warning.withValues(alpha: 0.4),
                ),
              ),
              child: const Text(
                'FFmpeg no detectado',
                style: TextStyle(color: AppColors.warning, fontSize: 12),
              ),
            ),
          if (profile != null)
            Text(
              profile!.name,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: status.$1.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: status.$1.withValues(alpha: 0.5)),
            ),
            child: Text(
              status.$2,
              style: TextStyle(
                color: status.$1,
                fontWeight: FontWeight.w700,
                fontSize: 12,
                letterSpacing: 0.8,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Navegacion lateral. Se bloquea cambiar de seccion mientras se transmite,
/// para que nadie desconfigure la emision por accidente.
class _SideNav extends StatelessWidget {
  const _SideNav({
    required this.index,
    required this.locked,
    required this.onSelect,
  });

  final int index;
  final bool locked;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final items = <(IconData, String)>[
      (Icons.podcasts, 'Emision'),
      (Icons.dns_outlined, 'Emisoras'),
      (Icons.settings_outlined, 'Ajustes'),
    ];

    return Container(
      width: 210,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          for (var i = 0; i < items.length; i++)
            _NavItem(
              icon: items[i].$1,
              label: items[i].$2,
              selected: index == i,
              enabled: !locked || i == 0,
              onTap: () => onSelect(i),
            ),
          const Spacer(),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'El audio va directo de tu PC a tu servidor. '
              'Xtreme Studio no lo reenvia ni lo almacena.',
              style: TextStyle(
                color: AppColors.textMuted,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.surfaceAlt : Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: selected ? AppColors.accent : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: !enabled
                    ? AppColors.textMuted.withValues(alpha: 0.4)
                    : selected
                    ? AppColors.accent
                    : AppColors.textSecondary,
              ),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(
                  color: !enabled
                      ? AppColors.textMuted.withValues(alpha: 0.4)
                      : selected
                      ? AppColors.textPrimary
                      : AppColors.textSecondary,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  fontSize: 13.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
