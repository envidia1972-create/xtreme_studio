/// Pantalla del soundboard: pads, mezcla y cue local.
library;

import 'package:flutter/material.dart';

import '../core/audio/soundboard.dart';
import '../core/soundboard_controller.dart';
import 'theme.dart';

class SoundboardScreen extends StatefulWidget {
  const SoundboardScreen({
    super.key,
    required this.controller,
    required this.live,
    required this.onMessage,
  });

  final SoundboardController controller;
  final bool live;
  final void Function(String message, {bool isError}) onMessage;

  @override
  State<SoundboardScreen> createState() => _SoundboardScreenState();
}

class _SoundboardScreenState extends State<SoundboardScreen> {
  SoundboardController get c => widget.controller;

  void _error(String message) => widget.onMessage(message, isError: true);

  Future<void> _play(SoundboardPad pad) async {
    if (!pad.assigned) {
      await _edit(pad);
      return;
    }
    final ok = widget.live ? await c.triggerPad(pad) : await c.cuePad(pad);
    if (!ok && c.lastError != null) _error(c.lastError!);
  }

  Future<void> _cue(SoundboardPad pad) async {
    if (!pad.assigned) return;
    final ok = await c.cuePad(pad);
    if (!ok && c.lastError != null) _error(c.lastError!);
  }

  Future<void> _stop(SoundboardPad pad) async {
    await c.stopPad(pad);
  }

  Future<void> _edit(SoundboardPad pad) async {
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PadEditor(controller: c, pad: pad, live: widget.live),
    );
    if (changed == true && mounted) setState(() {});
  }

  Future<void> _refreshFolder() async {
    final added = await c.refreshFolder();
    if (!mounted) return;
    if (added > 0) {
      widget.onMessage('$added jingle(s) incorporado(s) desde la carpeta.');
    } else {
      widget.onMessage(
        'No hay archivos nuevos en la carpeta. Copia tus jingles alli y '
        'vuelve a pulsar Recargar.',
      );
    }
  }

  Future<void> _openFolder() async {
    await c.openFolder();
    if (!mounted) return;
    widget.onMessage('Carpeta del soundboard: ${c.directoryPath}');
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        if (c.loading) {
          return const Center(child: CircularProgressIndicator());
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              const SizedBox(height: 16),
              _controls(),
              const SizedBox(height: 14),
              _banner(),
              const SizedBox(height: 18),
              _grid(),
              const SizedBox(height: 14),
              const Text(
                'Teclas: 1-8 o F1-F8 con la app enfocada. El boton de '
                'auriculares reproduce solo en este equipo (cue).',
                style: TextStyle(color: AppColors.textMuted, fontSize: 11.5),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _header() {
    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: AppColors.accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.library_music, color: AppColors.accent),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Soundboard',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
              ),
              Text(
                'Jingles para el aire y cue local para escucharlos antes.',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
        ),
        FilledButton.icon(
          onPressed: c.mixer.isActive || c.pads.any((p) => c.isCueing(p.id))
              ? c.stopAll
              : null,
          icon: const Icon(Icons.stop_circle_outlined, size: 18),
          label: const Text('DETENER TODO'),
        ),
      ],
    );
  }

  Widget _controls() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Wrap(
        spacing: 18,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _slider(
            label: 'Master',
            value: c.masterVolume,
            display: '${(c.masterVolume * 100).round()}%',
            onChanged: c.setMasterVolume,
          ),
          _slider(
            label: 'Ducking',
            value: ((c.duckingDb + 40) / 40).clamp(0.0, 1.0),
            display: '${c.duckingDb.round()} dB',
            onChanged: (v) => c.setDuckingDb(v * 40 - 40),
          ),
          SizedBox(
            width: 250,
            child: Material(
              type: MaterialType.transparency,
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text(
                  'Cue tambien al aire',
                  style: TextStyle(fontSize: 12.5),
                ),
                subtitle: const Text(
                  'Puede realimentar si el microfono capta los altavoces.',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 10.5),
                ),
                value: c.cueWhileLive,
                activeThumbColor: AppColors.accent,
                onChanged: c.setCueWhileLive,
              ),
            ),
          ),
          OutlinedButton.icon(
            onPressed: _openFolder,
            icon: const Icon(Icons.folder_open, size: 17),
            label: const Text('Abrir carpeta'),
          ),
          OutlinedButton.icon(
            onPressed: _refreshFolder,
            icon: const Icon(Icons.refresh, size: 17),
            label: const Text('Recargar'),
          ),
          OutlinedButton.icon(
            onPressed: () async {
              final empty = c.pads.where((p) => !p.assigned).firstOrNull;
              if (empty == null) {
                _error('Los ocho pads ya tienen un jingle. Vacia uno primero.');
                return;
              }
              await _edit(empty);
            },
            icon: const Icon(Icons.add, size: 17),
            label: const Text('Agregar'),
          ),
        ],
      ),
    );
  }

  Widget _slider({
    required String label,
    required double value,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    return SizedBox(
      width: 230,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label, style: const TextStyle(fontSize: 12)),
              const Spacer(),
              Text(
                display,
                style: const TextStyle(
                  color: AppColors.accent,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          Slider(
            value: value.clamp(0.0, 1.0),
            onChanged: onChanged,
            activeColor: AppColors.accent,
          ),
        ],
      ),
    );
  }

  Widget _banner() {
    final live = widget.live;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: live
            ? AppColors.onAir.withValues(alpha: 0.10)
            : AppColors.surfaceAlt,
        border: Border.all(
          color: live
              ? AppColors.onAir.withValues(alpha: 0.45)
              : AppColors.border,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            live ? Icons.podcasts : Icons.headphones,
            size: 18,
            color: live ? AppColors.onAir : AppColors.textSecondary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              live
                  ? 'AL AIRE: los pads se mezclan con el microfono y salen al '
                        'stream. Los auriculares hacen cue local.'
                  : 'FUERA DEL AIRE: tocar un pad lo reproduce por cue local; '
                        'no se envia al servidor.',
              style: TextStyle(
                color: live ? AppColors.onAir : AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _grid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1000 ? 4 : 2;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: c.pads.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: columns == 4 ? 1.55 : 2.1,
          ),
          itemBuilder: (context, index) {
            final pad = c.pads[index];
            return _padCard(pad);
          },
        );
      },
    );
  }

  Widget _padCard(SoundboardPad pad) {
    final active = c.isPlaying(pad.id);
    final cueing = c.isCueing(pad.id);
    final error = c.errorFor(pad.id);
    final progress = c.progressFor(pad.id);
    final borderColor = active
        ? AppColors.live
        : cueing
        ? AppColors.accent
        : AppColors.border;
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: borderColor, width: active || cueing ? 2 : 1),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _play(pad),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: active
                          ? AppColors.live.withValues(alpha: 0.18)
                          : AppColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      pad.keyLabel.isEmpty ? '--' : pad.keyLabel,
                      style: TextStyle(
                        color: active ? AppColors.live : AppColors.textMuted,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      pad.assigned ? pad.name : 'Pad libre',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: pad.assigned
                            ? AppColors.textPrimary
                            : AppColors.textMuted,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Editar pad',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _edit(pad),
                    icon: const Icon(Icons.edit_outlined, size: 16),
                  ),
                ],
              ),
              const Spacer(),
              if (!pad.assigned)
                const Text(
                  'Sin jingle asignado',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 11),
                )
              else ...[
                Text(
                  error ?? pad.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: error != null
                        ? AppColors.onAir
                        : AppColors.textMuted,
                    fontSize: 10.5,
                  ),
                ),
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: progress,
                  minHeight: 3,
                  backgroundColor: AppColors.surfaceAlt,
                  valueColor: AlwaysStoppedAnimation(
                    active ? AppColors.live : AppColors.border,
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: active ? () => _stop(pad) : () => _play(pad),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        minimumSize: const Size(0, 30),
                        foregroundColor: active
                            ? AppColors.live
                            : AppColors.textPrimary,
                        textStyle: const TextStyle(fontSize: 11),
                      ),
                      icon: Icon(
                        active ? Icons.stop : Icons.play_arrow,
                        size: 17,
                      ),
                      label: Text(active ? 'Stop' : 'Play'),
                    ),
                    TextButton.icon(
                      onPressed: () => _cue(pad),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        minimumSize: const Size(0, 30),
                        foregroundColor: cueing
                            ? AppColors.accent
                            : AppColors.textSecondary,
                        textStyle: const TextStyle(fontSize: 11),
                      ),
                      icon: const Icon(Icons.headphones, size: 15),
                      label: const Text('Cue'),
                    ),
                    const Spacer(),
                    Text(
                      '${(pad.volume * 100).round()}%',
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PadEditor extends StatefulWidget {
  const _PadEditor({
    required this.controller,
    required this.pad,
    required this.live,
  });

  final SoundboardController controller;
  final SoundboardPad pad;
  final bool live;

  @override
  State<_PadEditor> createState() => _PadEditorState();
}

class _PadEditorState extends State<_PadEditor> {
  late final TextEditingController _name;
  late final TextEditingController _path;
  late String _key;
  late double _volume;
  late bool _loop;
  late bool _ducking;
  bool _saving = false;
  String? _error;

  static const _keys = [
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
    'F1',
    'F2',
    'F3',
    'F4',
    'F5',
    'F6',
    'F7',
    'F8',
  ];

  @override
  void initState() {
    super.initState();
    final pad = widget.pad;
    _name = TextEditingController(text: pad.name);
    _path = TextEditingController();
    _key = pad.keyLabel.isEmpty ? '1' : pad.keyLabel;
    _volume = pad.volume;
    _loop = pad.loop;
    _ducking = pad.ducking;
  }

  @override
  void dispose() {
    _name.dispose();
    _path.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Ponle un nombre al pad.');
      return;
    }
    final used = widget.controller.pads
        .where((p) => p.id != widget.pad.id && p.keyLabel == _key)
        .toList();
    if (used.isNotEmpty) {
      setState(() => _error = 'La tecla $_key ya la usa otro pad.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final path = _path.text.trim();
    if (!widget.pad.assigned && path.isEmpty) {
      setState(() {
        _saving = false;
        _error =
            'Indica la ruta del archivo o copialo a la carpeta y usa '
            'Recargar.';
      });
      return;
    }
    if (path.isNotEmpty) {
      final ok = await widget.controller.assignFile(
        widget.pad,
        path,
        name: name,
      );
      if (!ok) {
        if (!mounted) return;
        setState(() {
          _saving = false;
          _error =
              widget.controller.errorFor(widget.pad.id) ??
              widget.controller.lastError ??
              'No se pudo importar el archivo.';
        });
        return;
      }
    }
    await widget.controller.updatePad(
      widget.pad,
      name: name,
      keyLabel: _key,
      volume: _volume,
      loop: _loop,
      ducking: _ducking,
    );
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  Future<void> _clear() async {
    setState(() => _saving = true);
    await widget.controller.clearPad(widget.pad);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final currentFile = widget.pad.fileName;
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(widget.pad.assigned ? 'Editar pad' : 'Asignar jingle'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Nombre'),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              if (currentFile.isNotEmpty)
                Text(
                  'Archivo actual: $currentFile',
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11,
                  ),
                ),
              const SizedBox(height: 8),
              TextField(
                controller: _path,
                decoration: InputDecoration(
                  labelText: currentFile.isEmpty
                      ? 'Ruta del archivo (MP3, WAV, OGG...)'
                      : 'Reemplazar por otra ruta (opcional)',
                  helperText:
                      'Tambien podes copiarlo a la carpeta del '
                      'soundboard y usar Recargar.',
                  helperStyle: const TextStyle(fontSize: 10.5),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _key,
                decoration: const InputDecoration(labelText: 'Tecla rapida'),
                items: [
                  for (final key in _keys)
                    DropdownMenuItem(value: key, child: Text(key)),
                ],
                onChanged: (v) => setState(() => _key = v ?? _key),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  const Text('Volumen', style: TextStyle(fontSize: 12)),
                  Expanded(
                    child: Slider(
                      value: _volume,
                      onChanged: (v) => setState(() => _volume = v),
                      activeColor: AppColors.accent,
                    ),
                  ),
                  Text(
                    '${(_volume * 100).round()}%',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text(
                  'Repetir en loop',
                  style: TextStyle(fontSize: 13),
                ),
                value: _loop,
                activeThumbColor: AppColors.accent,
                onChanged: (v) => setState(() => _loop = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text(
                  'Bajar el microfono mientras suena (ducking)',
                  style: TextStyle(fontSize: 13),
                ),
                value: _ducking,
                activeThumbColor: AppColors.accent,
                onChanged: (v) => setState(() => _ducking = v),
              ),
              if (!widget.live)
                const Text(
                  'Fuera del aire este pad se reproduce por cue local.',
                  style: TextStyle(color: AppColors.textMuted, fontSize: 11),
                ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: const TextStyle(color: AppColors.onAir, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (widget.pad.assigned)
          TextButton(
            onPressed: _saving ? null : _clear,
            child: const Text(
              'Vaciar pad',
              style: TextStyle(color: AppColors.onAir),
            ),
          ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Guardar'),
        ),
      ],
    );
  }
}
