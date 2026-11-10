/// Estado de la actualizacion y acciones de la interfaz.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../diagnostic_log.dart';
import 'app_version.dart';
import 'update_installer.dart';
import 'update_models.dart';
import 'update_service.dart';

enum UpdatePhase {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  installing,
  error,
}

class UpdateController extends ChangeNotifier {
  UpdateController({UpdateService? service})
    : _service = service ?? UpdateService(currentVersion: appVersion);

  final UpdateService _service;
  UpdatePhase _phase = UpdatePhase.idle;
  UpdateInfo? _info;
  String? _error;
  double _progress = 0;
  String? _dismissedVersion;
  bool _silentError = true;
  Timer? _initialTimer;
  Timer? _timer;
  bool _checking = false;

  UpdatePhase get phase => _phase;
  UpdateInfo? get info => _info;
  String? get error => _error;
  double get progress => _progress;
  String get currentVersion => appVersion;
  bool get isBusy =>
      _phase == UpdatePhase.downloading || _phase == UpdatePhase.installing;

  bool get visible =>
      _phase == UpdatePhase.available ||
      _phase == UpdatePhase.downloading ||
      _phase == UpdatePhase.installing ||
      (_phase == UpdatePhase.error && !_silentError);

  bool get installable {
    final asset = _info?.assetFor(UpdatePlatformInfo.current);
    return asset != null && asset.hasChecksum;
  }

  /// Arranca la comprobacion automatica: una a los pocos segundos y luego cada
  /// seis horas. No bloquea el arranque de la app.
  void startAutoCheck({
    Duration initialDelay = const Duration(seconds: 4),
    Duration interval = const Duration(hours: 6),
  }) {
    _initialTimer?.cancel();
    _timer?.cancel();
    _initialTimer = Timer(initialDelay, () => check(silent: true));
    _timer = Timer.periodic(interval, (_) => check(silent: true));
  }

  Future<void> check({bool silent = false}) async {
    if (_checking || isBusy) return;
    _checking = true;
    if (!silent) {
      _phase = UpdatePhase.checking;
      _silentError = false;
      notifyListeners();
    }
    try {
      final latest = await _service.check();
      if (latest == null) {
        _phase = UpdatePhase.upToDate;
        _info = null;
        _error = null;
        _silentError = silent;
        notifyListeners();
        return;
      }
      _info = latest;
      _error = null;
      _silentError = silent;
      if (latest.isNewer && latest.latestVersion != _dismissedVersion) {
        _phase = UpdatePhase.available;
      } else {
        _phase = UpdatePhase.upToDate;
      }
      notifyListeners();
    } catch (e) {
      final message = e is UpdateException ? e.message : e.toString();
      DiagnosticLog.instance?.write(
        'update',
        'fallo la comprobacion: $message',
      );
      _phase = silent ? UpdatePhase.idle : UpdatePhase.error;
      _error = message;
      _silentError = silent;
      notifyListeners();
    } finally {
      _checking = false;
    }
  }

  void dismiss() {
    _dismissedVersion = _info?.latestVersion;
    _phase = UpdatePhase.idle;
    notifyListeners();
  }

  Future<void> install({
    required bool live,
    bool Function()? liveNow,
    required Future<void> Function() beforeRestart,
    void Function(String message, {bool isError})? onMessage,
  }) async {
    if (live) {
      onMessage?.call(
        'Salí del aire antes de actualizar. La app no se actualiza mientras '
        'esta emitiendo.',
        isError: true,
      );
      return;
    }
    final latest = _info;
    if (latest == null) return;
    if (!UpdateInstaller.supportsCurrentPlatform) {
      await openPage();
      onMessage?.call(
        'La actualizacion automatica estara disponible primero en Windows. '
        'Se abrio la pagina de descarga.',
      );
      return;
    }
    if (!installable) {
      await openPage();
      onMessage?.call(
        'La release no tiene un paquete verificable para esta plataforma. '
        'Se abrio la pagina de descarga.',
      );
      return;
    }

    _phase = UpdatePhase.downloading;
    _progress = 0;
    _error = null;
    _silentError = false;
    notifyListeners();
    try {
      final archive = await _service.download(
        latest,
        onProgress: (received, total) {
          _progress = total > 0 ? (received / total).clamp(0.0, 1.0) : 0;
          notifyListeners();
        },
      );
      if (liveNow?.call() ?? live) {
        throw UpdateException(
          'Saliste al aire durante la descarga. La app no se actualiza '
          'mientras esta emitiendo.',
        );
      }
      _phase = UpdatePhase.installing;
      _progress = 1;
      notifyListeners();
      await beforeRestart();
      await UpdateInstaller.launchWindowsUpdater(
        archive: archive,
        info: latest,
        processId: pid,
      );
      // El actualizador espera este PID. Cerrar ahora libera el .exe y los DLL.
      exit(0);
    } catch (e) {
      final message = e is UpdateException ? e.message : e.toString();
      _phase = UpdatePhase.error;
      _error = message;
      _silentError = false;
      DiagnosticLog.instance?.write(
        'update',
        'fallo la actualizacion: $message',
      );
      notifyListeners();
      onMessage?.call('No se pudo actualizar: $message', isError: true);
    }
  }

  Future<void> openPage() async {
    final url = _info?.pageUrl?.toString() ?? updateReleasePage;
    try {
      if (Platform.isWindows) {
        await Process.start('cmd', [
          '/c',
          'start',
          '',
          url,
        ], mode: ProcessStartMode.detached);
      } else if (Platform.isMacOS) {
        await Process.start('open', [url], mode: ProcessStartMode.detached);
      } else {
        await Process.start('xdg-open', [url], mode: ProcessStartMode.detached);
      }
    } catch (e) {
      DiagnosticLog.instance?.write('update', 'no se pudo abrir $url: $e');
    }
  }

  @override
  void dispose() {
    _initialTimer?.cancel();
    _timer?.cancel();
    unawaited(_service.dispose());
    super.dispose();
  }
}
