import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/net/broadcaster.dart';
import '../core/net/server_detect.dart';
import '../core/profile_store.dart';
import '../core/server_profile.dart';
import 'theme.dart';

/// Gestor de emisoras: crear, editar, duplicar, probar y compartir perfiles.
///
/// Es el corazon del modo multi-emisora: cada DJ guarda aqui las credenciales
/// de **su** servidor, sea el de esta radio o el de cualquier otra emisora.
class ProfilesScreen extends StatefulWidget {
  const ProfilesScreen({
    super.key,
    required this.profiles,
    required this.activeProfile,
    required this.store,
    required this.onChanged,
    required this.onMessage,
  });

  final List<ServerProfile> profiles;
  final ServerProfile? activeProfile;
  final ProfileStore store;
  final Future<void> Function(List<ServerProfile> profiles, ServerProfile? active)
      onChanged;
  final void Function(String message, {bool isError}) onMessage;

  @override
  State<ProfilesScreen> createState() => _ProfilesScreenState();
}

class _ProfilesScreenState extends State<ProfilesScreen> {
  String? _testingId;
  ConnectionTestResult? _lastTest;

  Future<void> _saveProfile(ServerProfile profile) async {
    final problems = profile.validate();
    if (problems.isNotEmpty) {
      widget.onMessage(problems.first, isError: true);
      return;
    }
    try {
      await widget.store.save(profile);
    } catch (e) {
      widget.onMessage('No se pudo guardar: $e', isError: true);
      return;
    }

    final list = [...widget.profiles];
    final index = list.indexWhere((p) => p.id == profile.id);
    if (index >= 0) {
      list[index] = profile;
    } else {
      list.add(profile);
    }
    final active = widget.activeProfile ?? profile;
    await widget.onChanged(list, active);
    widget.onMessage('Emisora guardada');
  }

  Future<void> _delete(ServerProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Eliminar emisora'),
        content: Text(
          'Se borrara "${profile.name}" y su contrasena guardada. '
          'Esta accion no se puede deshacer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.onAir),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await widget.store.delete(profile.id);
    final list = widget.profiles.where((p) => p.id != profile.id).toList();
    final active = widget.activeProfile?.id == profile.id
        ? (list.isNotEmpty ? list.first : null)
        : widget.activeProfile;
    await widget.onChanged(list, active);
    widget.onMessage('Emisora eliminada');
  }

  Future<void> _duplicate(ServerProfile profile) async {
    final copy = profile.duplicate(
      newId: ProfileStore.newId(),
      newName: '${profile.name} (copia)',
    );
    await _saveProfile(copy);
  }

  Future<void> _test(ServerProfile profile) async {
    setState(() {
      _testingId = profile.id;
      _lastTest = null;
    });
    final result = await testConnection(profile);
    if (!mounted) return;
    setState(() {
      _testingId = null;
      _lastTest = result;
    });
    widget.onMessage(
      result.message,
      isError: !result.ok,
    );
  }

  Future<void> _export(ServerProfile profile) async {
    final content = widget.store.exportProfile(profile);
    await Clipboard.setData(ClipboardData(text: content));
    if (!mounted) return;
    widget.onMessage(
      'Perfil copiado al portapapeles (sin la contrasena). '
      'Pegalo en un archivo o mensaje para compartirlo.',
    );
  }

  Future<void> _import() async {
    final controller = TextEditingController();
    final content = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Importar emisora'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Pega el contenido de un perfil exportado. Por seguridad, la '
                'contrasena NO viaja en la exportacion: tendras que '
                'escribirla despues.',
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12.5,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 8,
                decoration: const InputDecoration(
                  hintText: '{ "name": "Mi radio", "host": "...", ... }',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Importar'),
          ),
        ],
      ),
    );

    if (content == null || content.trim().isEmpty) return;
    try {
      final profile = await widget.store.importProfile(content);
      profile.id = ProfileStore.newId();
      await _saveProfile(profile);
      widget.onMessage(
        'Emisora importada. No olvides escribir su contrasena.',
      );
    } catch (e) {
      widget.onMessage('El contenido no es un perfil valido: $e', isError: true);
    }
  }

  Future<void> _openEditor({ServerProfile? existing}) async {
    final result = await showDialog<ServerProfile>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ProfileEditorDialog(existing: existing, store: widget.store),
    );
    if (result != null) {
      await _saveProfile(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Mis emisoras',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Servidores donde podes transmitir. Las contrasenas se '
                    'guardan cifradas en este equipo.',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
                  ),
                ],
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: _import,
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('Importar'),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: () => _openEditor(),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('AGREGAR EMISORA'),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (_lastTest != null) ...[
            _TestResultCard(result: _lastTest!),
            const SizedBox(height: 14),
          ],
          Expanded(
            child: widget.profiles.isEmpty
                ? const _NoProfiles()
                : ListView.separated(
                    itemCount: widget.profiles.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, i) {
                      final p = widget.profiles[i];
                      return _ProfileTile(
                        profile: p,
                        isActive: widget.activeProfile?.id == p.id,
                        testing: _testingId == p.id,
                        onActivate: () =>
                            widget.onChanged(widget.profiles, p),
                        onEdit: () => _openEditor(existing: p),
                        onDuplicate: () => _duplicate(p),
                        onTest: () => _test(p),
                        onExport: () => _export(p),
                        onDelete: () => _delete(p),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _NoProfiles extends StatelessWidget {
  const _NoProfiles();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'Sin emisoras. Usa "AGREGAR EMISORA" para cargar los datos de tu '
        'servidor.',
        style: TextStyle(color: AppColors.textMuted),
      ),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.profile,
    required this.isActive,
    required this.testing,
    required this.onActivate,
    required this.onEdit,
    required this.onDuplicate,
    required this.onTest,
    required this.onExport,
    required this.onDelete,
  });

  final ServerProfile profile;
  final bool isActive;
  final bool testing;
  final VoidCallback onActivate;
  final VoidCallback onEdit;
  final VoidCallback onDuplicate;
  final VoidCallback onTest;
  final VoidCallback onExport;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isActive ? AppColors.surfaceAlt : AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive ? AppColors.accent : AppColors.border,
          width: isActive ? 1.6 : 1,
        ),
      ),
      child: Row(
        children: [
          Icon(
            isActive ? Icons.radio_button_checked : Icons.radio_button_off,
            color: isActive ? AppColors.accent : AppColors.textMuted,
            size: 20,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      profile.name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14.5,
                      ),
                    ),
                    const SizedBox(width: 10),
                    _Chip(text: profile.protocol.shortLabel),
                    if (isActive) ...[
                      const SizedBox(width: 6),
                      const _Chip(text: 'EN USO', highlight: true),
                    ],
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  profile.summary,
                  style: AppTheme.mono.copyWith(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${profile.audio.bitrateKbps} kbps · '
                  '${profile.audio.sampleRate / 1000} kHz · '
                  '${profile.audio.channels == 1 ? "mono" : "estereo"} · '
                  'usuario: ${profile.username}',
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          if (!isActive)
            OutlinedButton(
              onPressed: onActivate,
              child: const Text('Usar'),
            ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Probar conexion',
            onPressed: testing ? null : onTest,
            icon: testing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.wifi_tethering, size: 20),
          ),
          IconButton(
            tooltip: 'Editar',
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined, size: 20),
          ),
          IconButton(
            tooltip: 'Duplicar',
            onPressed: onDuplicate,
            icon: const Icon(Icons.copy_outlined, size: 20),
          ),
          IconButton(
            tooltip: 'Copiar perfil sin contrasena',
            onPressed: onExport,
            icon: const Icon(Icons.share_outlined, size: 20),
          ),
          IconButton(
            tooltip: 'Eliminar',
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline, size: 20),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, this.highlight = false});

  final String text;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final color = highlight ? AppColors.accent : AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// Resultado del boton "Probar conexion".
class _TestResultCard extends StatelessWidget {
  const _TestResultCard({required this.result});

  final ConnectionTestResult result;

  @override
  Widget build(BuildContext context) {
    final color = result.ok ? AppColors.live : AppColors.onAir;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                result.ok ? Icons.check_circle : Icons.error_outline,
                color: color,
                size: 19,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  result.message,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
            ],
          ),
          if (result.details.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final d in result.details)
              Padding(
                padding: const EdgeInsets.only(left: 29, top: 2),
                child: Text(
                  '· $d',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11.5,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Formulario de alta y edicion de una emisora.
class _ProfileEditorDialog extends StatefulWidget {
  const _ProfileEditorDialog({required this.existing, required this.store});

  final ServerProfile? existing;
  final ProfileStore store;

  @override
  State<_ProfileEditorDialog> createState() => _ProfileEditorDialogState();
}

class _ProfileEditorDialogState extends State<_ProfileEditorDialog> {
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _name;
  late TextEditingController _host;
  late TextEditingController _port;
  late TextEditingController _mount;
  late TextEditingController _username;
  late TextEditingController _password;
  late TextEditingController _publicUrl;
  late TextEditingController _stationName;
  late TextEditingController _genre;

  late ServerProtocol _protocol;
  late int _bitrate;
  late int _sampleRate;
  late int _channels;
  bool _useTls = false;
  bool _showPassword = false;

  /// `true` mientras se consulta al servidor que tipo es.
  bool _detecting = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _host = TextEditingController(text: e?.host ?? '');
    _port = TextEditingController(text: '${e?.port ?? 8000}');
    _mount = TextEditingController(text: e?.mount ?? '/stream');
    _username = TextEditingController(text: e?.username ?? 'source');
    _password = TextEditingController(text: e?.password ?? '');
    _publicUrl = TextEditingController(text: e?.publicUrl ?? '');
    _stationName = TextEditingController(text: e?.stationName ?? '');
    _genre = TextEditingController(text: e?.genre ?? '');
    _protocol = e?.protocol ?? ServerProtocol.icecast2;
    _bitrate = e?.audio.bitrateKbps ?? 128;
    _sampleRate = e?.audio.sampleRate ?? 44100;
    _channels = e?.audio.channels ?? 2;
    _useTls = e?.useTls ?? false;
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _host,
      _port,
      _mount,
      _username,
      _password,
      _publicUrl,
      _stationName,
      _genre,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Ajusta los valores tipicos segun el protocolo elegido, para que el DJ no
  /// tenga que saberse los convenios de cada servidor.
  void _applyProtocolDefaults(ServerProtocol protocol) {
    setState(() {
      _protocol = protocol;
      if (protocol == ServerProtocol.icecast2) {
        if (_username.text.isEmpty || _username.text == 'source') {
          _username.text = 'source';
        }
        if (_mount.text.isEmpty) _mount.text = '/stream';
      } else {
        // En Shoutcast el usuario real es el DJ o "source"; el password es el
        // que da el hosting.
        if (_username.text == 'source') _username.text = 'source';
        if (_mount.text.isEmpty) _mount.text = '/';
      }
    });
  }

  ServerProfile _build() {
    final existing = widget.existing;
    return ServerProfile(
      id: existing?.id ?? ProfileStore.newId(),
      name: _name.text.trim(),
      host: _host.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? 8000,
      mount: _mount.text.trim(),
      username: _username.text.trim(),
      password: _password.text,
      protocol: _protocol,
      useTls: _useTls,
      publicUrl: _publicUrl.text.trim(),
      stationName: _stationName.text.trim(),
      genre: _genre.text.trim(),
      description: existing?.description ?? '',
      audio: AudioSettings(
        bitrateKbps: _bitrate,
        sampleRate: _sampleRate,
        channels: _channels,
      ),
      inputDeviceId: existing?.inputDeviceId ?? '',
      autoReconnect: existing?.autoReconnect ?? true,
      recordLocally: existing?.recordLocally ?? false,
      recordDirectory: existing?.recordDirectory ?? '',
      adminUsername: existing?.adminUsername ?? '',
      adminPassword: existing?.adminPassword ?? '',
    );
  }

  Future<void> _test() async {
    final profile = _build();
    final result = await testConnection(profile);
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(result.ok ? 'Conexion correcta' : 'No se pudo conectar'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(result.message),
            const SizedBox(height: 12),
            for (final d in result.details)
              Text(
                '· $d',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;

    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(isNew ? 'Nueva emisora' : 'Editar emisora'),
      content: SizedBox(
        width: 620,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionTitle('Datos del servidor'),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: _field(
                        _name,
                        'Nombre del perfil',
                        hint: 'Radio Latina, Mi emisora...',
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Ponele un nombre'
                            : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: DropdownButtonFormField<ServerProtocol>(
                        initialValue: _protocol,
                        decoration: const InputDecoration(labelText: 'Tipo de servidor'),
                        dropdownColor: AppColors.surfaceAlt,
                        items: [
                          for (final p in ServerProtocol.values)
                            DropdownMenuItem(value: p, child: Text(p.label)),
                        ],
                        onChanged: (v) {
                          if (v != null) _applyProtocolDefaults(v);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: _field(
                        _host,
                        _protocol == ServerProtocol.icecast2
                            ? 'Servidor (host)'
                            : 'IP o dominio del servidor',
                        hint: 'stream.miradio.com',
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Falta el servidor'
                            : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _field(
                        _port,
                        'Puerto',
                        keyboardType: TextInputType.number,
                        validator: (v) {
                          final n = int.tryParse(v?.trim() ?? '');
                          if (n == null || n < 1 || n > 65535) {
                            return 'Puerto invalido';
                          }
                          return null;
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_protocol == ServerProtocol.icecast2)
                  _field(
                    _mount,
                    'Mount / punto de montaje',
                    hint: '/stream o /miradio',
                    helper: 'Es la ruta que aparece en la URL de escucha.',
                  )
                else
                  _field(
                    _mount,
                    'Mount (opcional en Shoutcast)',
                    hint: '/',
                    helper: 'En Shoutcast suele dejarse "/".',
                  ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _field(
                        _username,
                        'Usuario',
                        hint: 'source',
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Falta el usuario'
                            : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _password,
                        obscureText: !_showPassword,
                        decoration: InputDecoration(
                          labelText: 'Contrasena',
                          suffixIcon: IconButton(
                            icon: Icon(
                              _showPassword
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                              size: 20,
                            ),
                            onPressed: () =>
                                setState(() => _showPassword = !_showPassword),
                          ),
                        ),
                        validator: (v) =>
                            (v == null || v.isEmpty) ? 'Falta la contrasena' : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Row(
                  children: [
                    Icon(Icons.lock_outline, size: 14, color: AppColors.textMuted),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Se guarda cifrada con la proteccion de tu usuario de '
                        'Windows: otro equipo no puede leerla.',
                        style: TextStyle(color: AppColors.textMuted, fontSize: 11.5),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _sectionTitle('Calidad de audio'),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _bitrate,
                        decoration: const InputDecoration(labelText: 'Bitrate'),
                        dropdownColor: AppColors.surfaceAlt,
                        items: [
                          for (final b in AudioSettings.bitrateOptions)
                            DropdownMenuItem(
                              value: b,
                              child: Text('$b kbps'),
                            ),
                        ],
                        onChanged: (v) => setState(() => _bitrate = v ?? 128),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _sampleRate,
                        decoration: const InputDecoration(labelText: 'Frecuencia'),
                        dropdownColor: AppColors.surfaceAlt,
                        items: [
                          for (final r in AudioSettings.sampleRateOptions)
                            DropdownMenuItem(
                              value: r,
                              child: Text('${r / 1000} kHz'),
                            ),
                        ],
                        onChanged: (v) => setState(() => _sampleRate = v ?? 44100),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _channels,
                        decoration: const InputDecoration(labelText: 'Canales'),
                        dropdownColor: AppColors.surfaceAlt,
                        items: const [
                          DropdownMenuItem(value: 2, child: Text('Estereo')),
                          DropdownMenuItem(value: 1, child: Text('Mono')),
                        ],
                        onChanged: (v) => setState(() => _channels = v ?? 2),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _sectionTitle('Para tus oyentes (opcional)'),
                _field(
                  _publicUrl,
                  'URL de escucha',
                  hint: 'https://miradio.com/en-vivo',
                  helper: 'Se muestra en la pantalla de emision para compartirla.',
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _field(
                        _stationName,
                        'Nombre que vera el oyente',
                        hint: 'Radio Latina 104.5',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _field(_genre, 'Genero', hint: 'Variado'),
                    ),
                  ],
                ),
                if (_protocol == ServerProtocol.icecast2) ...[
                  const SizedBox(height: 10),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _useTls,
                    onChanged: (v) => setState(() => _useTls = v),
                    title: const Text(
                      'Usar HTTPS (puerto seguro)',
                      style: TextStyle(fontSize: 13),
                    ),
                    subtitle: const Text(
                      'Solo si tu hosting lo pide expresamente.',
                      style: TextStyle(fontSize: 11.5, color: AppColors.textMuted),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        TextButton.icon(
          onPressed: _detecting ? null : _detectProtocol,
          icon: _detecting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.search, size: 18),
          label: const Text('Detectar tipo'),
        ),
        OutlinedButton.icon(
          onPressed: _test,
          icon: const Icon(Icons.wifi_tethering, size: 18),
          label: const Text('Probar conexion'),
        ),
        FilledButton(
          onPressed: () {
            if (_formKey.currentState?.validate() ?? false) {
              Navigator.pop(context, _build());
            }
          },
          child: const Text('Guardar'),
        ),
      ],
    );
  }

  /// Consulta al servidor que tipo es y ajusta el desplegable.
  ///
  /// Es el boton que evita el error mas confuso de todos: un mismo hosting puede
  /// tener Icecast en un puerto y SHOUTcast en otro. Si el tipo no coincide, el
  /// servidor responde "contrasena incorrecta" y el DJ busca el problema en el
  /// lugar equivocado.
  Future<void> _detectProtocol() async {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim()) ?? 0;
    if (host.isEmpty || port <= 0) {
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('Faltan datos'),
          content: const Text(
            'Completa el servidor y el puerto para poder consultarlo.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cerrar'),
            ),
          ],
        ),
      );
      return;
    }

    setState(() => _detecting = true);
    final detected = await detectServer(
      host: host,
      port: port,
      expected: _protocol,
      useTls: _useTls,
    );
    if (!mounted) return;
    setState(() => _detecting = false);

    // Si la deteccion es concluyente, se ajusta el tipo sin preguntar: es
    // justamente lo que el DJ vino a averiguar.
    if (detected.isCertain && detected.protocol != _protocol) {
      setState(() => _protocol = detected.protocol);
    }

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(
          detected.isCertain
              ? 'Servidor identificado'
              : 'No se pudo identificar',
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (detected.serverSoftware != null)
                Text(
                  detected.serverSoftware!,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
              const SizedBox(height: 8),
              Text(detected.evidence),
              if (detected.isCertain) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.live.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: AppColors.live.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(
                    'Tipo ajustado a ${detected.protocol.label}.',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.1,
            color: AppColors.textSecondary,
          ),
        ),
      );

  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    String? helper,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      validator: validator,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        helperMaxLines: 2,
      ),
    );
  }
}
