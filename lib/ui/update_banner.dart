/// Aviso de actualizacion disponible.
library;

import 'package:flutter/material.dart';

import '../core/update/update_controller.dart';
import '../core/update/update_models.dart';
import 'theme.dart';

class UpdateBanner extends StatelessWidget {
  const UpdateBanner({
    super.key,
    required this.controller,
    required this.live,
    this.liveNow,
    required this.beforeRestart,
    required this.onMessage,
  });

  final UpdateController controller;
  final bool live;
  final bool Function()? liveNow;
  final Future<void> Function() beforeRestart;
  final void Function(String message, {bool isError}) onMessage;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (!controller.visible) return const SizedBox.shrink();
        final info = controller.info;
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.accent.withValues(alpha: 0.10),
            border: const Border(bottom: BorderSide(color: AppColors.border)),
          ),
          child: _content(context, info),
        );
      },
    );
  }

  Widget _content(BuildContext context, UpdateInfo? info) {
    switch (controller.phase) {
      case UpdatePhase.downloading:
      case UpdatePhase.installing:
        return _busy();
      case UpdatePhase.error:
        return _errorState(context);
      case UpdatePhase.available:
        return _available(context, info);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _available(BuildContext context, UpdateInfo? info) {
    final latest = info?.displayVersion ?? '';
    final current = info?.currentDisplayVersion ?? controller.currentVersion;
    final asset = info?.assetFor(UpdatePlatformInfo.current);
    final canInstall = asset != null && asset.hasChecksum;
    return Row(
      children: [
        const Icon(Icons.system_update_alt, color: AppColors.accent, size: 22),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Nueva version $latest disponible',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
              Text(
                live
                    ? 'Estas al aire. Salí del aire para actualizar.'
                    : 'Tenes la version $current. La actualizacion se descarga '
                          'y se verifica antes de instalarse.',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11.5,
                ),
              ),
            ],
          ),
        ),
        if (info?.notes.isNotEmpty == true)
          TextButton(
            onPressed: () => _showNotes(context, info!),
            child: const Text('Ver notas'),
          ),
        TextButton(onPressed: controller.dismiss, child: const Text('Despues')),
        const SizedBox(width: 6),
        FilledButton.icon(
          onPressed: live
              ? null
              : () => controller.install(
                  live: live,
                  liveNow: liveNow,
                  beforeRestart: beforeRestart,
                  onMessage: onMessage,
                ),
          icon: Icon(canInstall ? Icons.download : Icons.open_in_new, size: 17),
          label: Text(
            live
                ? 'Al aire'
                : canInstall
                ? 'Actualizar'
                : 'Abrir descarga',
          ),
        ),
      ],
    );
  }

  Widget _busy() {
    final installing = controller.phase == UpdatePhase.installing;
    final pct = (controller.progress * 100).round();
    return Row(
      children: [
        const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                installing
                    ? 'Instalando actualizacion...'
                    : 'Descargando actualizacion... $pct%',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 5),
              LinearProgressIndicator(
                value: installing ? null : controller.progress,
                minHeight: 3,
                backgroundColor: AppColors.surfaceAlt,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _errorState(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.error_outline, color: AppColors.warning, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            controller.error ?? 'No se pudo comprobar la actualizacion.',
            style: const TextStyle(color: AppColors.warning, fontSize: 12),
          ),
        ),
        TextButton(
          onPressed: () => controller.openPage(),
          child: const Text('Abrir descarga'),
        ),
        FilledButton(
          onPressed: () => controller.check(),
          child: const Text('Reintentar'),
        ),
      ],
    );
  }

  void _showNotes(BuildContext context, UpdateInfo info) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Novedades de la version ${info.displayVersion}'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Text(
              info.notes.isEmpty ? 'La release no incluye notas.' : info.notes,
              style: const TextStyle(fontSize: 12.5, height: 1.4),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }
}
