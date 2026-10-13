import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/audio/ffmpeg_capture.dart';
import '../core/diagnostic_log.dart';
import '../core/profile_store.dart';
import 'theme.dart';

/// Ajustes: FFmpeg, dispositivo de entrada y grabacion local.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.devices,
    required this.ffmpegPath,
    required this.onChanged,
    required this.onRefreshDevices,
    required this.onMessage,
  });

  final AppSettings settings;
  final List<InputDevice> devices;
  final String ffmpegPath;
  final Future<void> Function(AppSettings settings) onChanged;
  final Future<void> Function() onRefreshDevices;
  final void Function(String message, {bool isError}) onMessage;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _ffmpegController;
  late TextEditingController _recordDirController;
  String _ffmpegVersion = '';
  bool _probing = false;

  @override
  void initState() {
    super.initState();
    _ffmpegController = TextEditingController(
      text: widget.settings.ffmpegPath,
    );
    _recordDirController = TextEditingController(
      text: widget.settings.recordDirectory,
    );
    _readVersion();
  }

  @override
  void dispose() {
    _ffmpegController.dispose();
    _recordDirController.dispose();
    super.dispose();
  }

  Future<void> _readVersion() async {
    if (widget.ffmpegPath.isEmpty) return;
    final v = await FfmpegLocator(widget.ffmpegPath).version();
    if (!mounted) return;
    setState(() => _ffmpegVersion = v);
  }

  /// Prueba una ruta concreta de FFmpeg antes de guardarla, para no dejar la
  /// app en un estado donde no puede emitir.
  Future<void> _useFfmpegPath(String path) async {
    setState(() => _probing = true);
    final locator = FfmpegLocator(path);
    final available = locator.isAvailable;
    final version = available ? await locator.version() : '';
    if (!mounted) return;
    setState(() {
      _probing = false;
      _ffmpegVersion = version;
    });

    if (!available) {
      widget.onMessage('No se encontro un ejecutable en esa ruta', isError: true);
      return;
    }

    final settings = widget.settings..ffmpegPath = path;
    await widget.onChanged(settings);
    await widget.onRefreshDevices();
    widget.onMessage('FFmpeg listo');
  }

  Future<void> _autodetect() async {
    final found = await ProfileStore.findFfmpeg('');
    if (!mounted) return;
    if (found.isEmpty) {
      widget.onMessage(
        'No se encontro FFmpeg automaticamente. Descargalo y pega la ruta '
        'completa a ffmpeg.exe.',
        isError: true,
      );
      return;
    }
    _ffmpegController.text = found;
    await _useFfmpegPath(found);
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Ajustes',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 18),

          // --- FFmpeg ---
          _card(
            title: 'Motor de audio (FFmpeg)',
            subtitle:
                'Xtreme Studio usa FFmpeg para capturar el audio del equipo y '
                'codificarlo en MP3. Es la unica pieza externa que necesita.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _ffmpegController,
                        decoration: const InputDecoration(
                          labelText: 'Ruta a ffmpeg.exe',
                          hintText: r'C:\ffmpeg\bin\ffmpeg.exe',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton(
                      onPressed: _probing
                          ? null
                          : () => _useFfmpegPath(_ffmpegController.text.trim()),
                      child: _probing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Comprobar'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _autodetect,
                      child: const Text('Autodetectar'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (widget.ffmpegPath.isEmpty)
                  const _StatusLine(
                    ok: false,
                    text: 'Sin FFmpeg no se puede emitir. '
                        'Descargalo de ffmpeg.org y pega la ruta completa.',
                  )
                else
                  _StatusLine(
                    ok: true,
                    text: _ffmpegVersion.isEmpty
                        ? 'Detectado en ${widget.ffmpegPath}'
                        : _ffmpegVersion,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // --- Dispositivo de entrada ---
          _card(
            title: 'Entrada de audio',
            subtitle:
                'Elegi el microfono, la consola o el dispositivo de captura que '
                'usaras para salir al aire.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: widget.devices.isEmpty
                          ? const Text(
                              'No se detectaron dispositivos de entrada. '
                              'Verifica FFmpeg y que el microfono este conectado.',
                              style: TextStyle(
                                color: AppColors.textMuted,
                                fontSize: 12.5,
                              ),
                            )
                          : const Text(
                              'Estos son los dispositivos que reporta Windows '
                              '(incluye microfonos y capturas del sistema como '
                              'Stereo Mix o CABLE Output):',
                              style: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 12.5,
                                height: 1.4,
                              ),
                            ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: widget.onRefreshDevices,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Buscar de nuevo'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                for (final d in widget.devices)
                  RadioListTile<String>(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: d.id,
                    groupValue: _selectedDeviceId(),
                    activeColor: AppColors.accent,
                    title: Text(d.name, style: const TextStyle(fontSize: 13)),
                    onChanged: (_) => _selectDevice(d),
                  ),
                if (widget.devices.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _CommandPreview(deviceName: _selectedDeviceId()),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),

          // --- Grabacion ---
          _card(
            title: 'Grabacion local',
            subtitle:
                'Guarda una copia de tu emision en tu equipo. Se graba '
                'exactamente el mismo audio que reciben los oyentes.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: settings.recordLocally,
                  activeColor: AppColors.accent,
                  title: const Text(
                    'Grabar mis emisiones',
                    style: TextStyle(fontSize: 13.5),
                  ),
                  onChanged: (v) async {
                    settings.recordLocally = v;
                    await widget.onChanged(settings);
                    if (mounted) setState(() {});
                  },
                ),
                if (settings.recordLocally) ...[
                  const SizedBox(height: 6),
                  TextField(
                    controller: _recordDirController,
                    decoration: const InputDecoration(
                      labelText: 'Carpeta de grabaciones',
                      hintText: r'C:\Users\TuUsuario\Music\XtremeStudio',
                    ),
                    onSubmitted: (v) async {
                      settings.recordDirectory = v.trim();
                      await widget.onChanged(settings);
                    },
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      OutlinedButton(
                        onPressed: () async {
                          settings.recordDirectory =
                              _recordDirController.text.trim();
                          await widget.onChanged(settings);
                          widget.onMessage('Carpeta guardada');
                        },
                        child: const Text('Guardar carpeta'),
                      ),
                      const SizedBox(width: 12),
                      if (settings.recordDirectory.isNotEmpty)
                        Expanded(
                          child: Text(
                            Directory(settings.recordDirectory).existsSync()
                                ? 'Carpeta valida'
                                : 'La carpeta no existe: se creara al emitir',
                            style: TextStyle(
                              fontSize: 12,
                              color: Directory(settings.recordDirectory)
                                      .existsSync()
                                  ? AppColors.live
                                  : AppColors.warning,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),

          // --- Registro de diagnostico ---
          _card(
            title: 'Registro de diagnostico',
            subtitle:
                'Si algo no funciona, este archivo tiene el detalle de lo que '
                'intento hacer la app: que dispositivo abrio, con que argumentos '
                'y que respondio el servidor. No contiene contrasenas.',
            child: Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () async {
                    final path = DiagnosticLog.instance?.file?.path;
                    if (path == null || !File(path).existsSync()) {
                      widget.onMessage(
                        'Todavia no hay registro. Intenta salir al aire una vez '
                        'y volve a mirar.',
                        isError: true,
                      );
                      return;
                    }
                    // Se abre el Explorador con el archivo seleccionado.
                    await Process.run('explorer.exe', ['/select,', path]);
                  },
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Abrir el registro'),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: SelectableText(
                    DiagnosticLog.instance?.file?.path ?? '(sin registro)',
                    style: AppTheme.mono.copyWith(
                      fontSize: 11,
                      color: AppColors.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // --- Informacion ---
          _card(
            title: 'Privacidad y seguridad',
            subtitle: '',
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Bullet('El audio va directo de tu equipo al servidor de tu '
                    'emisora. No pasa por ningun servidor intermedio ni se '
                    'almacena en la nube.'),
                _Bullet('Las contrasenas se cifran con la proteccion de tu '
                    'usuario de Windows (DPAPI). Copiar el archivo a otra PC '
                    'no revela nada.'),
                _Bullet('Al compartir un perfil, la contrasena nunca se '
                    'incluye: solo los datos del servidor.'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _selectedDeviceId() {
    for (final d in widget.devices) {
      if (d.id == widget.settings.lastDeviceId) return d.id;
    }
    return widget.devices.isNotEmpty ? widget.devices.first.id : '';
  }

  Future<void> _selectDevice(InputDevice device) async {
    widget.settings.lastDeviceId = device.id;
    await widget.onChanged(widget.settings);
    if (mounted) setState(() {});
  }

  Widget _card({
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
          ],
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

/// Muestra el comando exacto que la app le pasa a FFmpeg, para diagnostico.
///
/// Usa los valores tipicos de emision (128 kbps, 44.1 kHz, estereo) porque la
/// forma del comando es identica para cualquier calidad: lo que interesa es ver
/// el dispositivo, el capturador y las tuberias.
class _CommandPreview extends StatefulWidget {
  const _CommandPreview({required this.deviceName});

  final String deviceName;

  @override
  State<_CommandPreview> createState() => _CommandPreviewState();
}

class _CommandPreviewState extends State<_CommandPreview> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final args = CaptureArgs(
      deviceName: widget.deviceName,
      bitrateKbps: 128,
      sampleRate: 44100,
      channels: 2,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton.icon(
          onPressed: () => setState(() => _open = !_open),
          icon: Icon(
            _open ? Icons.expand_less : Icons.expand_more,
            size: 18,
          ),
          label: const Text('Ver el comando de FFmpeg (para diagnosticar)'),
        ),
        if (_open) ...[
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border),
            ),
            child: SelectableText(
              args.preview(),
              style: AppTheme.mono.copyWith(
                fontSize: 11,
                height: 1.4,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: args.preview()));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Comando copiado')),
                  );
                },
                icon: const Icon(Icons.copy_outlined, size: 18),
                label: const Text('Copiar comando'),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Pegalo en una consola para ver el error exacto si no captura '
                  'audio.',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 11.5),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.ok, required this.text});

  final bool ok;
  final String text;

  @override
  Widget build(BuildContext context) {
    final color = ok ? AppColors.live : AppColors.warning;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(ok ? Icons.check_circle_outline : Icons.warning_amber_outlined,
            size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: color, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 5, right: 8),
            child: Icon(Icons.circle, size: 6, color: AppColors.textMuted),
          ),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
