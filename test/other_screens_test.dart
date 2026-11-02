/// Pruebas de widgets para Ajustes y el gestor de emisoras.
///
/// Se renderizan de verdad a los tamanos de ventana reales para detectar
/// desbordes que el analisis estatico no puede ver.
///
/// Uso: flutter test test/other_screens_test.dart
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtreme_studio/core/audio/ffmpeg_capture.dart';
import 'package:xtreme_studio/core/profile_store.dart';
import 'package:xtreme_studio/core/server_profile.dart';
import 'package:xtreme_studio/core/soundboard_controller.dart';
import 'package:xtreme_studio/core/soundboard_store.dart';
import 'package:xtreme_studio/ui/profiles_screen.dart';
import 'package:xtreme_studio/ui/settings_screen.dart';
import 'package:xtreme_studio/ui/soundboard_screen.dart';
import 'package:xtreme_studio/ui/theme.dart';

const _devices = [
  InputDevice(id: 'default', name: 'Microfono del equipo'),
  InputDevice(
    id: 'alsa_output.pci.monitor',
    name: 'Monitor del altavoz (lo que suena)',
    isMonitor: true,
  ),
];

ServerProfile _profile(String id, String name) => ServerProfile(
  id: id,
  name: name,
  host: 'radio-$id.example.com',
  port: 8000,
  mount: '/directo',
  username: 'source',
  password: 'secreta',
  stationName: name,
  audio: const AudioSettings(bitrateKbps: 128, sampleRate: 44100, channels: 2),
);

Widget _wrap(Widget child) => MaterialApp(
  theme: AppTheme.build(),
  home: Scaffold(backgroundColor: AppColors.background, body: child),
);

Future<void> _setSize(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

ProfileStore _store(WidgetTester tester) {
  final dir = Directory.systemTemp.createTempSync('xtreme_widget_test_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return ProfileStore(baseDirectory: dir);
}

void main() {
  group('Emisoras', () {
    testWidgets('el listado no desborda en 1280x687', (tester) async {
      await _setSize(tester, const Size(1280, 687));
      await tester.pumpWidget(
        _wrap(
          ProfilesScreen(
            profiles: [
              _profile('uno', 'Radio Uno'),
              _profile('dos', 'Radio Dos'),
            ],
            activeProfile: null,
            store: _store(tester),
            devices: _devices,
            onChanged: (_, __) async {},
            onMessage: (_, {bool isError = false}) {},
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Mis emisoras'), findsOneWidget);
      expect(find.text('AGREGAR EMISORA'), findsOneWidget);
      expect(find.text('Radio Uno'), findsOneWidget);
      expect(find.text('Radio Dos'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('el listado no desborda en el minimo 960x600', (tester) async {
      await _setSize(tester, const Size(960, 600));
      await tester.pumpWidget(
        _wrap(
          ProfilesScreen(
            profiles: [
              _profile('uno', 'Radio Uno'),
              _profile('dos', 'Radio Dos'),
            ],
            activeProfile: null,
            store: _store(tester),
            devices: _devices,
            onChanged: (_, __) async {},
            onMessage: (_, {bool isError = false}) {},
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('la pantalla vacia invita a crear la primera', (tester) async {
      await _setSize(tester, const Size(960, 600));
      await tester.pumpWidget(
        _wrap(
          ProfilesScreen(
            profiles: const [],
            activeProfile: null,
            store: _store(tester),
            devices: _devices,
            onChanged: (_, __) async {},
            onMessage: (_, {bool isError = false}) {},
          ),
        ),
      );
      await tester.pump();

      expect(find.text('AGREGAR EMISORA'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  test('la etiqueta del tipo Icecast es solo Icecast2', () {
    expect(ServerProtocol.icecast2.label, 'Icecast2');
    expect(ServerProtocol.icecast2.shortLabel, 'Icecast2');
  });

  group('Soundboard', () {
    for (final size in const [Size(1280, 687), Size(960, 600)]) {
      testWidgets(
        'no desborda en ${size.width.toInt()}x${size.height.toInt()}',
        (tester) async {
          await _setSize(tester, size);
          final store = SoundboardStore(_store(tester).base);
          final controller = SoundboardController(store: store);
          addTearDown(controller.dispose);
          await controller.init();
          await tester.pumpWidget(
            _wrap(
              SoundboardScreen(
                controller: controller,
                live: false,
                onMessage: (_, {bool isError = false}) {},
              ),
            ),
          );
          await tester.pump();

          expect(find.text('Soundboard'), findsOneWidget);
          expect(find.text('Pad libre'), findsNWidgets(8));
          expect(find.text('DETENER TODO'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  });

  group('Ajustes', () {
    testWidgets('por defecto queda marcada la entrada del sistema', (
      tester,
    ) async {
      await _setSize(tester, const Size(1280, 687));
      await tester.pumpWidget(
        _wrap(
          SettingsScreen(
            settings: AppSettings(),
            devices: _devices,
            captureBackend: CaptureBackend.pulse,
            ffmpegPath: '',
            onChanged: (_) async {},
            onRefreshDevices: () async {},
            onMessage: (_, {bool isError = false}) {},
          ),
        ),
      );
      await tester.pump();

      final group = tester.widget<RadioGroup<String>>(
        find.byType(RadioGroup<String>),
      );
      expect(group.groupValue, 'default');
      expect(tester.takeException(), isNull);
    });
    for (final size in const [Size(1280, 687), Size(960, 600)]) {
      testWidgets(
        'no desborda en ${size.width.toInt()}x${size.height.toInt()}',
        (tester) async {
          await _setSize(tester, size);
          await tester.pumpWidget(
            _wrap(
              SettingsScreen(
                settings: AppSettings(),
                devices: _devices,
                captureBackend: CaptureBackend.pulse,
                ffmpegPath: '',
                onChanged: (_) async {},
                onRefreshDevices: () async {},
                onMessage: (_, {bool isError = false}) {},
              ),
            ),
          );
          await tester.pump();

          expect(find.text('Ajustes'), findsOneWidget);
          expect(find.text('Motor de audio (FFmpeg)'), findsOneWidget);
          expect(find.text('Entrada de audio'), findsOneWidget);
          expect(
            find.text('Monitor del altavoz (lo que suena)'),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  });
}
