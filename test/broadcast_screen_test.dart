/// Pruebas de widgets de la pantalla principal.
///
/// A diferencia de `tool/verify_ui.dart` (que solo revisa el codigo fuente),
/// estas pruebas montan la interfaz de verdad en un motor Flutter, la
/// renderizan a los tamanos reales de cabina y fallan si algo desborda,
/// desaparece o muestra el estado equivocado.
///
/// Uso: flutter test test/broadcast_screen_test.dart
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtreme_studio/core/audio/broadcast_engine.dart';
import 'package:xtreme_studio/core/audio/ffmpeg_capture.dart';
import 'package:xtreme_studio/core/net/stream_health.dart';
import 'package:xtreme_studio/core/server_profile.dart';
import 'package:xtreme_studio/ui/broadcast_screen.dart';
import 'package:xtreme_studio/ui/theme.dart';

ServerProfile _profile() => ServerProfile(
  id: 'perfil-de-prueba',
  name: 'Radio de prueba',
  host: '127.0.0.1',
  port: 8000,
  mount: '/directo',
  username: 'source',
  password: 'no-se-usa',
  stationName: 'Xtreme Studio',
);

BroadcastSnapshot _snapshot({
  BroadcastState state = BroadcastState.idle,
  String? lastError,
  int secondsOnAir = 0,
  String currentTrack = '',
}) => BroadcastSnapshot(
  state: state,
  peakDb: state == BroadcastState.live ? -9.5 : -60,
  rmsDb: state == BroadcastState.live ? -14.2 : -60,
  peakHoldDb: state == BroadcastState.live ? -9.5 : -60,
  secondsOnAir: secondsOnAir,
  bytesSent: state == BroadcastState.live ? 16000 * 8 * secondsOnAir : 0,
  reconnectAttempt: 0,
  currentTrack: currentTrack,
  lastError: lastError,
);

const _devices = [
  InputDevice(id: 'default', name: 'Microfono del equipo'),
  InputDevice(id: 'monitor', name: 'Monitor del altavoz', isMonitor: true),
];

Widget _app({
  ServerProfile? profile,
  BroadcastSnapshot? snapshot,
  bool ffmpegReady = true,
  List<LogEntry> log = const [],
  SignalCheck? signalCheck,
  Future<void> Function()? onGoLive,
  Future<void> Function()? onGoOffAir,
}) {
  return MaterialApp(
    theme: AppTheme.build(),
    home: Scaffold(
      backgroundColor: AppColors.background,
      body: BroadcastScreen(
        profile: profile,
        snapshot: snapshot ?? _snapshot(),
        log: log,
        devices: _devices,
        ffmpegReady: ffmpegReady,
        signalCheck: signalCheck,
        onGoLive: onGoLive ?? () async {},
        onGoOffAir: onGoOffAir ?? () async {},
        onTrackChanged: (_) {},
        onGainChanged: (_) {},
        onOpenProfiles: () {},
      ),
    ),
  );
}

Future<void> _setSize(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Color? _buttonColor(WidgetTester tester, String label) {
  final button = tester.widget<FilledButton>(
    find.widgetWithText(FilledButton, label),
  );
  return button.style?.backgroundColor?.resolve(<WidgetState>{});
}

void main() {
  group('Estado fuera del aire', () {
    testWidgets('ofrece entrar al aire y no salir', (tester) async {
      await _setSize(tester, const Size(1280, 687));
      await tester.pumpWidget(_app(profile: _profile()));
      await tester.pump();

      expect(find.text('ENTRAR AL AIRE'), findsOneWidget);
      expect(find.text('SALIR AL AIRE'), findsNothing);
      expect(find.text('SALIR DEL AIRE'), findsNothing);
      expect(find.text('FUERA DEL AIRE'), findsOneWidget);
      expect(_buttonColor(tester, 'ENTRAR AL AIRE'), AppColors.live);
      expect(tester.takeException(), isNull);
    });

    testWidgets('el boton verde dispara la entrada al aire', (tester) async {
      await _setSize(tester, const Size(1280, 687));
      var goLive = 0;
      var goOffAir = 0;
      await tester.pumpWidget(
        _app(
          profile: _profile(),
          onGoLive: () async => goLive++,
          onGoOffAir: () async => goOffAir++,
        ),
      );
      await tester.pump();

      await tester.tap(find.text('ENTRAR AL AIRE'));
      await tester.pumpAndSettle();

      expect(goLive, 1);
      expect(goOffAir, 0);
    });
  });

  group('Estado al aire', () {
    testWidgets('ofrece salir del aire en rojo y muestra el cronometro', (
      tester,
    ) async {
      await _setSize(tester, const Size(1280, 687));
      await tester.pumpWidget(
        _app(
          profile: _profile(),
          snapshot: _snapshot(
            state: BroadcastState.live,
            secondsOnAir: 367,
            currentTrack: 'Artista - Tema',
          ),
        ),
      );
      await tester.pump();

      expect(find.text('SALIR DEL AIRE'), findsOneWidget);
      expect(find.text('ENTRAR AL AIRE'), findsNothing);
      expect(find.text('06:07'), findsOneWidget);
      expect(_buttonColor(tester, 'SALIR DEL AIRE'), AppColors.onAir);
      expect(tester.takeException(), isNull);
    });

    testWidgets('el boton rojo dispara la salida del aire', (tester) async {
      await _setSize(tester, const Size(1280, 687));
      var goLive = 0;
      var goOffAir = 0;
      await tester.pumpWidget(
        _app(
          profile: _profile(),
          snapshot: _snapshot(state: BroadcastState.live),
          onGoLive: () async => goLive++,
          onGoOffAir: () async => goOffAir++,
        ),
      );
      await tester.pump();

      await tester.tap(find.text('SALIR DEL AIRE'));
      await tester.pumpAndSettle();

      expect(goOffAir, 1);
      expect(goLive, 0);
    });
  });

  group('Tamano de ventana', () {
    for (final size in const [
      Size(1280, 700), // 1366x768 con barra de tareas
      Size(1280, 687), // alto real en esta laptop
      Size(1000, 620), // minimo de la ventana en Linux
      Size(960, 600), // limite duro de GTK
      Size(900, 600), // si el gestor ignora el minimo
    ]) {
      testWidgets(
        'no desborda en ${size.width.toInt()}x${size.height.toInt()}',
        (tester) async {
          await _setSize(tester, size);
          await tester.pumpWidget(
            _app(
              profile: _profile(),
              snapshot: _snapshot(state: BroadcastState.live, secondsOnAir: 59),
            ),
          );
          await tester.pump();

          expect(tester.takeException(), isNull);
          expect(find.text('SALIR DEL AIRE'), findsOneWidget);
        },
      );
    }

    testWidgets('el aviso de FFmpeg no desborda en ventana pequena', (
      tester,
    ) async {
      await _setSize(tester, const Size(960, 600));
      await tester.pumpWidget(
        _app(
          profile: _profile(),
          ffmpegReady: false,
          snapshot: _snapshot(
            lastError:
                'No se pudo conectar con el servidor: la conexion fue '
                'rechazada despues de varios intentos.',
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('No se encontro FFmpeg'), findsOneWidget);
      expect(find.textContaining('No se pudo conectar'), findsOneWidget);
    });
  });

  group('Sin emisoras', () {
    testWidgets('invita a agregar la primera emisora', (tester) async {
      await _setSize(tester, const Size(1280, 687));
      await tester.pumpWidget(_app());
      await tester.pump();

      expect(find.text('AGREGAR MI EMISORA'), findsOneWidget);
      expect(find.textContaining('Todavia no hay'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
