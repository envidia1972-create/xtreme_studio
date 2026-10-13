/// Paleta e identidad visual de Xtreme Studio.
///
/// Pensada para cabina: fondo oscuro (menos fatiga y menos reflejo), un rojo
/// inconfundible para "AL AIRE" y un verde claro para "conectado". Los estados
/// nunca dependen solo del color: siempre llevan texto, porque en una consola
/// de radio hay que entender el estado de un vistazo.
library;

import 'package:flutter/material.dart';

class AppColors {
  static const background = Color(0xFF0D0F14);
  static const surface = Color(0xFF161A22);
  static const surfaceAlt = Color(0xFF1E2430);
  static const border = Color(0xFF2A3242);

  static const textPrimary = Color(0xFFE8ECF4);
  static const textSecondary = Color(0xFF97A2B8);
  static const textMuted = Color(0xFF64708A);

  /// Rojo "AL AIRE".
  static const onAir = Color(0xFFE53935);
  static const onAirDark = Color(0xFF8E1F1D);

  /// Verde de conexion establecida.
  static const live = Color(0xFF35D07F);

  /// Ambar de advertencia / reconectando.
  static const warning = Color(0xFFF0A93B);

  static const accent = Color(0xFF4A8CFF);

  /// Zona segura del vumetro (por debajo de -12 dBFS).
  static const meterSafe = Color(0xFF35D07F);
  /// Zona de atencion (-12 a -3 dBFS).
  static const meterWarn = Color(0xFFF0C93B);
  /// Zona de saturacion (por encima de -3 dBFS).
  static const meterHot = Color(0xFFE53935);
}

class AppTheme {
  static ThemeData build() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: AppColors.background,
      colorScheme: base.colorScheme.copyWith(
        surface: AppColors.surface,
        primary: AppColors.accent,
        error: AppColors.onAir,
      ),
      cardTheme: const CardThemeData(
        color: AppColors.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.border,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceAlt,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.accent, width: 2),
        ),
        labelStyle: const TextStyle(color: AppColors.textSecondary),
        hintStyle: const TextStyle(color: AppColors.textMuted),
      ),
      textTheme: base.textTheme.apply(
        bodyColor: AppColors.textPrimary,
        displayColor: AppColors.textPrimary,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          side: const BorderSide(color: AppColors.border),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      tooltipTheme: const TooltipThemeData(
        decoration: BoxDecoration(
          color: AppColors.surfaceAlt,
          borderRadius: BorderRadius.all(Radius.circular(6)),
        ),
        textStyle: TextStyle(color: AppColors.textPrimary, fontSize: 12),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: AppColors.surfaceAlt,
        contentTextStyle: TextStyle(color: AppColors.textPrimary),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Estilo de texto monoespaciado para tiempos y datos tecnicos.
  static const mono = TextStyle(
    fontFamily: 'monospace',
    fontFeatures: [FontFeature.tabularFigures()],
  );
}

/// Formatea segundos como HH:MM:SS (o MM:SS si es menos de una hora).
String formatDuration(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  if (h > 0) return '${two(h)}:${two(m)}:${two(s)}';
  return '${two(m)}:${two(s)}';
}

/// Formatea un tamano en bytes de manera legible.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
