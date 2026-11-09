/// Prueba de layout del aviso de actualizacion.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xtreme_studio/core/update/update_controller.dart';
import 'package:xtreme_studio/core/update/update_models.dart';
import 'package:xtreme_studio/core/update/update_service.dart';
import 'package:xtreme_studio/ui/theme.dart';
import 'package:xtreme_studio/ui/update_banner.dart';

class _FakeUpdateService extends UpdateService {
  _FakeUpdateService()
    : super(
        manifestUrl: Uri.parse('https://example.com/latest.json'),
        currentVersion: '0.1.0',
        platform: UpdatePlatform.windows,
      );

  @override
  Future<UpdateInfo?> check() async => UpdateInfo(
    latestVersion: '0.2.0',
    currentVersion: '0.1.0',
    notes: 'Mejoras de prueba',
    pageUrl: Uri.parse('https://example.com/download'),
    assets: [
      UpdateAsset(
        name: 'XtremeStudio-0.2.0-windows-x64.zip',
        url: Uri.parse('https://example.com/asset.zip'),
        sha256: 'a' * 64,
        size: 100,
      ),
      UpdateAsset(
        name: 'XtremeStudio-0.2.0-linux-x64.tar.gz',
        url: Uri.parse('https://example.com/asset.tar.gz'),
        sha256: 'b' * 64,
        size: 100,
      ),
    ],
  );
}

void main() {
  testWidgets('el aviso no desborda en ventana minima', (tester) async {
    final controller = UpdateController(service: _FakeUpdateService());
    addTearDown(controller.dispose);
    await controller.check();

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(960, 600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(),
        home: Scaffold(
          backgroundColor: AppColors.background,
          body: UpdateBanner(
            controller: controller,
            live: false,
            beforeRestart: () async {},
            onMessage: (_, {bool isError = false}) {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Nueva version 0.2.0 disponible'), findsOneWidget);
    expect(find.text('Actualizar'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
