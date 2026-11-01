/// Mantiene la sesion despierta mientras la app esta al aire.
///
/// Por que existe: en Linux, cuando el protector de pantalla bloquea la sesion,
/// el bloqueador cambia a una sesion de greeter (otra VT). La sesion del DJ
/// pasa a "inactiva" y el grafo de audio de PipeWire se reconfigura: la captura
/// de FFmpeg queda apuntando a un nodo que ya no entrega audio y la emision se
/// queda muda aunque la app siga mostrando "AL AIRE".
///
/// La solucion es la misma que usan los reproductores de video: pedirle al
/// protector de pantalla que no se active mientras hay una emision en curso, y
/// bloquear la suspension por inactividad con `systemd-inhibit`.
///
/// **Detalle que importa:** la inhibicion de D-Bus esta atada a la conexion que
/// la pide. Si se hace un `gdbus call ... Inhibit` y el proceso termina, el
/// escritorio elimina la inhibicion en el acto. Por eso se usan los comandos
/// que se quedan vivos mientras dura la emision
/// (`light-locker-command --inhibit`, `xfce4-screensaver-command --inhibit`,
/// `gnome-session-inhibit ... sleep infinity`, `kde-inhibit ...`). El `gdbus`
/// queda solo como ultimo recurso.
///
/// Todo es opcional: si el escritorio no lo soporta o los comandos no estan
/// instalados, la app sigue funcionando igual (solo se pierde la proteccion).
library;

import 'dart:async';
import 'dart:io';

import 'diagnostic_log.dart';

class ScreenGuard {
  ScreenGuard({this.enabled = true});

  /// Si es `false` no se hace nada (ajuste "Evitar el bloqueo de pantalla").
  ///
  /// Se puede cambiar en caliente: el motor lo actualiza cuando el DJ toca el
  /// interruptor en Ajustes, incluso con la emision en curso.
  bool enabled;

  Process? _idleInhibitor;
  Process? _screenHold;
  int? _cookie;
  String? _screenMechanism;
  bool _running = false;

  /// Cambia cada vez que se arranca o se para, para que una peticion de
  /// inhibicion que llegue tarde no deje la pantalla bloqueada para siempre.
  int _generation = 0;

  /// `true` mientras hay una inhibicion activa.
  bool get isRunning => _running;

  /// Extrae el cookie que devuelve `Inhibit`.
  ///
  /// `gdbus` responde `(uint32 42, )` y `dbus-send` responde
  /// `method return ... uint32 42`. En los dos casos el numero es el cookie que
  /// hay que devolver en `UnInhibit`.
  static int? parseCookie(String output) {
    final match = RegExp(r'uint32\s+(\d+)').firstMatch(output);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  /// Pide al escritorio que no bloquee la pantalla ni suspenda el equipo.
  ///
  /// Nunca lanza: un fallo aqui no puede impedir salir al aire.
  Future<void> start() async {
    if (!enabled || _running || !Platform.isLinux) return;
    _running = true;
    final generation = ++_generation;

    final hold = await _holdScreensaver();
    if (generation != _generation) {
      // Se salio del aire mientras se pedia la inhibicion: se suelta ya, o la
      // pantalla quedaria bloqueada sin que nadie la libere.
      hold.process?.kill();
      return;
    }
    _screenHold = hold.process;
    _screenMechanism = hold.mechanism;

    if (hold.process == null) {
      // Ultimo recurso: una llamada suelta. En muchos escritorios se pierde al
      // cerrarse la conexion, pero en otros si vale.
      final cookie = await _inhibitScreenSaverOnce();
      if (generation != _generation) {
        if (cookie != null) await _releaseScreenSaver(cookie);
        return;
      }
      _cookie = cookie;
      if (cookie != null) _screenMechanism = 'D-Bus';
    }

    final idle = await _inhibitIdle();
    if (generation != _generation) {
      idle?.kill();
      return;
    }
    _idleInhibitor = idle;

    DiagnosticLog.instance?.write(
      'sesion',
      'pantalla: ${_screenMechanism == null ? "sin inhibicion" : "bloqueo inhibido ($_screenMechanism)"}'
          '; suspension: ${idle != null ? "inhibida" : "sin inhibir"}',
    );
  }

  /// Suelta las inhibiciones. Se llama al salir del aire.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _generation++;

    final hold = _screenHold;
    _screenHold = null;
    _screenMechanism = null;
    if (hold != null) _kill(hold);

    final cookie = _cookie;
    _cookie = null;
    if (cookie != null) await _releaseScreenSaver(cookie);

    final idle = _idleInhibitor;
    _idleInhibitor = null;
    if (idle != null) _kill(idle);
  }

  /// Comandos que inhiben el protector **mientras el proceso siga vivo**.
  ///
  /// El orden importa: primero los de escritorios concretos (que dejan el
  /// proceso colgado) y despues el generico de GNOME. Si el ejecutable no esta
  /// instalado o falla, se prueba el siguiente.
  static const List<(String, List<String>)> _holdCommands = [
    (
      'light-locker-command',
      ['--inhibit', '-n', 'Xtreme Studio', '-r', 'Emision al aire'],
    ),
    ('xfce4-screensaver-command', ['--inhibit']),
    ('kde-inhibit', ['--screenSaver', '--power', 'sleep', 'infinity']),
    (
      'gnome-session-inhibit',
      ['--inhibit', 'idle', '--reason', 'Emision al aire', 'sleep', 'infinity'],
    ),
  ];

  Future<({Process? process, String? mechanism})> _holdScreensaver() async {
    for (final (executable, arguments) in _holdCommands) {
      final process = await _startHold(executable, arguments);
      if (process != null) return (process: process, mechanism: executable);
    }
    return (process: null, mechanism: null);
  }

  /// Arranca un inhibidor y comprueba que siga vivo.
  ///
  /// Si el comando no logra inhibir (por ejemplo, no encuentra el servicio
  /// D-Bus), termina enseguida; medio segundo alcanza para distinguirlo de uno
  /// que se queda sosteniendo la inhibicion.
  Future<Process?> _startHold(String executable, List<String> arguments) async {
    Process process;
    try {
      process = await Process.start(executable, arguments);
    } on ProcessException {
      return null;
    }
    // Se drena la salida: si el proceso escribiera y nadie la leyera, el
    // buffer del pipe podria llenarse y bloquearlo.
    process.stdout.listen((_) {}, onError: (_) {});
    process.stderr.listen((_) {}, onError: (_) {});

    final exited = await Future.any<int?>([
      process.exitCode,
      Future<int?>.delayed(const Duration(milliseconds: 500)),
    ]);
    return exited == null ? process : null;
  }

  /// Inhibicion por D-Bus en una sola llamada (ultimo recurso).
  Future<int?> _inhibitScreenSaverOnce() async {
    const app = 'Xtreme Studio';
    const reason = 'Emision al aire';

    final viaGdbus = await _run('gdbus', [
      'call',
      '--session',
      '--dest',
      'org.freedesktop.ScreenSaver',
      '--object-path',
      '/org/freedesktop/ScreenSaver',
      '--method',
      'org.freedesktop.ScreenSaver.Inhibit',
      app,
      reason,
    ]);
    final cookie = viaGdbus == null ? null : parseCookie(viaGdbus);
    if (cookie != null) return cookie;

    // dbus-send existe en cualquier sistema con D-Bus, aunque falte glib.
    final viaDbusSend = await _run('dbus-send', [
      '--session',
      '--print-reply',
      '--dest=org.freedesktop.ScreenSaver',
      '/org/freedesktop/ScreenSaver',
      'org.freedesktop.ScreenSaver.Inhibit',
      'string:$app',
      'string:$reason',
    ]);
    return viaDbusSend == null ? null : parseCookie(viaDbusSend);
  }

  Future<void> _releaseScreenSaver(int cookie) async {
    final viaGdbus = await _run('gdbus', [
      'call',
      '--session',
      '--dest',
      'org.freedesktop.ScreenSaver',
      '--object-path',
      '/org/freedesktop/ScreenSaver',
      '--method',
      'org.freedesktop.ScreenSaver.UnInhibit',
      '$cookie',
    ]);
    if (viaGdbus != null) return;

    await _run('dbus-send', [
      '--session',
      '--print-reply',
      '--dest=org.freedesktop.ScreenSaver',
      '/org/freedesktop/ScreenSaver',
      'org.freedesktop.ScreenSaver.UnInhibit',
      'uint32:$cookie',
    ]);
  }

  /// Bloquea la suspension por inactividad.
  ///
  /// `systemd-inhibit` mantiene la inhibicion mientras viva el proceso, por eso
  /// se deja un `sleep infinity` colgando y se mata al salir del aire.
  Future<Process?> _inhibitIdle() async {
    try {
      final process = await Process.start('systemd-inhibit', [
        '--what=idle:sleep',
        '--who=Xtreme Studio',
        '--why=Emision al aire',
        '--mode=block',
        'sleep',
        'infinity',
      ]);
      process.stdout.listen((_) {}, onError: (_) {});
      process.stderr.listen((_) {}, onError: (_) {});
      return process;
    } on ProcessException catch (e) {
      DiagnosticLog.instance?.write(
        'sesion',
        'no se pudo inhibir la suspension: ${e.message}',
      );
      return null;
    }
  }

  /// Mata un proceso sin que un fallo afecte a la app.
  void _kill(Process process) {
    try {
      process.kill();
    } catch (_) {
      // Si ya murio no hay nada que hacer.
    }
  }

  /// Ejecuta una herramienta y devuelve su salida, o `null` si falla.
  Future<String?> _run(String executable, List<String> arguments) async {
    try {
      final result = await Process.run(
        executable,
        arguments,
      ).timeout(const Duration(seconds: 3));
      if (result.exitCode != 0) return null;
      return '${result.stdout}${result.stderr}';
    } catch (_) {
      return null;
    }
  }
}
