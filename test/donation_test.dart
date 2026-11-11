/// Pruebas de la invitacion y el enlace de donaciones.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtreme_studio/core/audio/ffmpeg_capture.dart';
import 'package:xtreme_studio/core/donation.dart';
import 'package:xtreme_studio/core/profile_store.dart';
import 'package:xtreme_studio/ui/settings_screen.dart';
import 'package:xtreme_studio/ui/theme.dart';

const _devices = [InputDevice(id: 'default', name: 'Microfono del equipo')];

void main() {
  test('el enlace es permanente y no expone el correo', () {
    expect(
      donationUrl,
      'https://www.paypal.com/donate/?hosted_button_id=URNUVG7CSFFFQ',
    );
    expect(donationUrl, isNot(contains('token=')));
    expect(donationUrl, isNot(contains('@')));
  });

  testWidgets('Ajustes muestra la invitacion y el boton de donar', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(960, 600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final dir = Directory.systemTemp.createTempSync('xtreme_donation_test_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(),
        home: Scaffold(
          backgroundColor: AppColors.background,
          body: SettingsScreen(
            settings: AppSettings(),
            devices: _devices,
            captureBackend: CaptureBackend.pulse,
            ffmpegPath: '',
            onChanged: (_) async {},
            onRefreshDevices: () async {},
            onMessage: (_, {bool isError = false}) {},
            onSupport: () {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Apoya el proyecto'), findsOneWidget);
    expect(find.text('Donar con PayPal'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
