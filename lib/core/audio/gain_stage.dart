/// Ganancia de entrada aplicada en Dart, antes de codificar.
///
/// Se hace aqui y no en FFmpeg a proposito: cambiar el filtro `volume` de un
/// proceso en marcha obliga a reiniciarlo, y reiniciar la captura corta el
/// audio que estan escuchando los oyentes. Con esta etapa la ganancia es solo
/// una multiplicacion sobre el PCM que ya esta fluyendo: se puede mover el
/// control en vivo sin tocar el microfono, el codificador ni el socket.
///
/// El PCM viaja en coma flotante (`f32le`). Asi una ganancia positiva puede
/// superar el fondo de escala sin recortar la onda antes de tiempo: el
/// limitador del codificador recibe la senal completa y decide cuanto recortar.
library;

import 'dart:math' as math;
import 'dart:typed_data';

class GainStage {
  GainStage({double gainDb = 0.0}) {
    this.gainDb = gainDb;
  }

  double _gainDb = 0;

  /// Ganancia en dB tal como la ve el DJ.
  double get gainDb => _gainDb;

  /// Ganancia lineal equivalente (`10^(dB/20)`).
  double get linearGain => _linear;
  double _linear = 1;

  set gainDb(double db) {
    _gainDb = db;
    _linear = math.pow(10, db / 20).toDouble();
  }

  /// Resto de un bloque anterior que no completo una muestra de 4 bytes.
  ///
  /// Los procesos entregan el PCM en bloques arbitrarios: si un bloque termina
  /// a mitad de un `float`, ese byte debe esperar al siguiente. Sin esto, cada
  /// bloque se desalinearia y el audio saldria como ruido.
  Uint8List _carry = Uint8List(0);

  /// Aplica la ganancia actual a un bloque de PCM `f32le`.
  ///
  /// Devuelve un bloque nuevo, alineado a 4 bytes, listo para el codificador.
  Uint8List process(Uint8List chunk) {
    Uint8List data;
    if (_carry.isEmpty) {
      data = chunk;
    } else {
      data = Uint8List(_carry.length + chunk.length)
        ..setAll(0, _carry)
        ..setAll(_carry.length, chunk);
    }

    final samples = data.length ~/ 4;
    final usableBytes = samples * 4;
    if (samples == 0) {
      _carry = data;
      return Uint8List(0);
    }

    final view = ByteData.sublistView(data, 0, usableBytes);
    final gain = _linear;
    final output = Uint8List(usableBytes);
    final outputView = ByteData.sublistView(output);
    for (var i = 0; i < samples; i++) {
      final offset = i * 4;
      final sample = view.getFloat32(offset, Endian.little);
      // Un valor no finito (driver defectuoso) envenenaria el codificador y
      // el vumetro; se trata como silencio.
      final amplified = sample.isFinite ? sample * gain : 0.0;
      outputView.setFloat32(offset, amplified, Endian.little);
    }

    _carry = usableBytes == data.length
        ? Uint8List(0)
        : Uint8List.fromList(data.sublist(usableBytes));

    // Se devuelve un bloque nuevo: el llamador puede quedarse con el anterior
    // (por ejemplo, para medirlo) sin que un ajuste posterior lo modifique.
    return output;
  }

  /// Descarta el resto pendiente al reiniciar una captura.
  void reset() {
    _carry = Uint8List(0);
  }
}
