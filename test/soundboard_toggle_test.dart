/// El segundo toque de un pad debe detenerlo sin afectar a los demas.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xtreme_studio/core/audio/soundboard.dart';
import 'package:xtreme_studio/core/soundboard_controller.dart';
import 'package:xtreme_studio/core/soundboard_store.dart';

void main() {
  test('un pad activo se detiene al accionarlo de nuevo', () async {
    final dir = Directory.systemTemp.createTempSync('xtreme_toggle_test_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final controller = SoundboardController(store: SoundboardStore(dir));
    addTearDown(controller.dispose);
    await controller.init();

    final first = controller.pads[0]..fileName = 'uno.mp3';
    final second = controller.pads[1]..fileName = 'dos.mp3';
    final clip = JingleClip(
      samples: Float32List(48000 * 2),
      sampleRate: 44100,
      channels: 2,
    );

    controller.mixer.trigger(first, clip);
    controller.mixer.trigger(second, clip);
    expect(controller.isPlaying(first.id), isTrue);
    expect(controller.isPlaying(second.id), isTrue);

    expect(await controller.togglePad(first), isTrue);
    // El mixer aplica un fade de 50 ms; se simula un bloque de audio para que
    // termine de retirar la voz detenida.
    controller.mixer.mix(Uint8List(4800 * 2 * 4));
    expect(controller.isPlaying(first.id), isFalse);
    expect(controller.isPlaying(second.id), isTrue);
  });

  test('un pad sin jingle no se puede accionar', () async {
    final dir = Directory.systemTemp.createTempSync('xtreme_toggle_test_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final controller = SoundboardController(store: SoundboardStore(dir));
    addTearDown(controller.dispose);
    await controller.init();

    expect(await controller.togglePad(controller.pads.first), isFalse);
    expect(controller.lastError, isNotNull);
  });
}
