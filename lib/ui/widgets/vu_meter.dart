import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Vumetro de barras segmentadas con pico y RMS.
///
/// Se dibuja a mano (en vez de usar un widget de progreso) porque en cabina
/// importa ver la escala real en dBFS y donde esta el limite de saturacion:
/// el verde indica margen, el amarillo atencion y el rojo recorte inminente.
class VuMeter extends StatelessWidget {
  const VuMeter({
    super.key,
    required this.peakDb,
    required this.rmsDb,
    this.holdDb,
  });

  /// Pico instantaneo en dBFS (-60 a 0).
  final double peakDb;

  /// Nivel promedio percibido.
  final double rmsDb;

  /// Pico retenido para la lectura numerica. Si es `null`, se usa [peakDb].
  final double? holdDb;

  /// Rango visible del vumetro.
  static const double floorDb = -48;
  static const double ceilDb = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'NIVEL DE ENTRADA',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 8),
        // Sin `const` a proposito: el painter recibe los niveles actuales, que
        // cambian en cada fotograma. Hacerlo constante congelaria el vumetro.
        SizedBox(
          height: 34,
          child: CustomPaint(
            painter: _MeterPainter(peakDb: peakDb, rmsDb: rmsDb),
            size: Size.infinite,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Builder(
              builder: (context) {
                final shown = holdDb ?? peakDb;
                return Text(
                  '${shown <= floorDb ? "-∞" : shown.toStringAsFixed(1)} dBFS pico',
                  style: AppTheme.mono.copyWith(
                    fontSize: 11,
                    color: _colorFor(shown),
                  ),
                );
              },
            ),
            Text(
              'RMS ${rmsDb <= floorDb ? "-∞" : rmsDb.toStringAsFixed(1)}',
              style: AppTheme.mono.copyWith(
                fontSize: 11,
                color: AppColors.textMuted,
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Color segun el nivel: verde con margen, ambar cerca del limite, rojo
  /// cuando ya hay riesgo de recorte.
  static Color _colorFor(double db) {
    if (db >= -3) return AppColors.meterHot;
    if (db >= -12) return AppColors.meterWarn;
    return AppColors.meterSafe;
  }
}

class _MeterPainter extends CustomPainter {
  _MeterPainter({required this.peakDb, required this.rmsDb});

  final double peakDb;
  final double rmsDb;

  /// Numero de segmentos del vumetro.
  static const int segments = 32;

  @override
  void paint(Canvas canvas, Size size) {
    const gap = 2.0;
    final segWidth = (size.width - gap * (segments - 1)) / segments;
    final radius = Radius.circular(math.min(3, segWidth / 2));

    // Posicion normalizada de 0 a 1 para un nivel en dBFS.
    double norm(double db) {
      final clamped = db.clamp(VuMeter.floorDb, VuMeter.ceilDb);
      return (clamped - VuMeter.floorDb) / (VuMeter.ceilDb - VuMeter.floorDb);
    }

    final peakNorm = norm(peakDb);
    final rmsNorm = norm(rmsDb);

    for (var i = 0; i < segments; i++) {
      final segNorm = (i + 1) / segments;
      final dbAtSegment =
          VuMeter.floorDb + segNorm * (VuMeter.ceilDb - VuMeter.floorDb);

      final active = segNorm <= peakNorm;
      // El RMS se pinta mas brillante para distinguirlo del pico.
      final isRms = segNorm <= rmsNorm;

      Color color;
      if (active) {
        color = VuMeter._colorFor(dbAtSegment);
        if (isRms) color = color.withValues(alpha: 1.0);
      } else {
        // Segmento apagado: se ve la escala pero sin llamar la atencion.
        color = AppColors.surfaceAlt;
      }

      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(i * (segWidth + gap), 0, segWidth, size.height),
        radius,
      );
      canvas.drawRRect(rect, Paint()..color = color);

      // Marca de referencia en -12 y -3 dBFS.
      if (dbAtSegment.abs() < 2.5 || (dbAtSegment + 12).abs() < 1.0) {
        canvas.drawLine(
          Offset(rect.left, size.height),
          Offset(rect.right, size.height),
          Paint()
            ..color = AppColors.background.withValues(alpha: 0.8)
            ..strokeWidth = 2,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MeterPainter old) =>
      old.peakDb != peakDb || old.rmsDb != rmsDb;
}
