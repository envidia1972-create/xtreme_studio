import 'package:flutter/material.dart';

import '../core/audio/broadcast_engine.dart';
import '../core/audio/ffmpeg_capture.dart';
import '../core/net/stream_health.dart';
import '../core/server_profile.dart';
import 'theme.dart';
import 'widgets/vu_meter.dart';

/// Pantalla principal: entrar y salir del aire.
///
/// Todo lo importante esta a la vista sin desplazarse: estado, tiempo al aire,
/// vumetros, calidad y el campo de "suena ahora", que es lo que el DJ toca
/// mientras habla.
class BroadcastScreen extends StatefulWidget {
  const BroadcastScreen({
    super.key,
    required this.profile,
    required this.snapshot,
    required this.log,
    required this.devices,
    required this.ffmpegReady,
    required this.signalCheck,
    required this.onGoLive,
    required this.onGoOffAir,
    required this.onTrackChanged,
    required this.onGainChanged,
    required this.onOpenProfiles,
  });

  final ServerProfile? profile;
  final BroadcastSnapshot snapshot;
  final List<LogEntry> log;
  final List<InputDevice> devices;
  final bool ffmpegReady;

  /// Ultima comprobacion de la senal vista por un oyente (`null` = sin datos).
  final SignalCheck? signalCheck;

  final Future<void> Function() onGoLive;
  final Future<void> Function() onGoOffAir;
  final ValueChanged<String> onTrackChanged;

  /// Ajuste de ganancia de entrada. Se persiste en el perfil.
  final ValueChanged<double> onGainChanged;

  final VoidCallback onOpenProfiles;

  @override
  State<BroadcastScreen> createState() => _BroadcastScreenState();
}

class _BroadcastScreenState extends State<BroadcastScreen> {
  final TextEditingController _trackController = TextEditingController();
  bool _busy = false;

  @override
  void didUpdateWidget(covariant BroadcastScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Si el titulo cambio fuera de este campo (por ejemplo quedo instalado tras
    // reconectar), se refleja aqui, pero nunca se pisa lo que el DJ esta
    // escribiendo en ese momento.
    final track = widget.snapshot.currentTrack;
    if (track.isEmpty || _busy || _trackController.text == track) return;
    if (_trackController.text.isNotEmpty &&
        _trackController.text != oldWidget.snapshot.currentTrack) {
      return; // El DJ ya escribio algo distinto: se respeta.
    }
    _trackController.text = track;
  }

  @override
  void dispose() {
    _trackController.dispose();
    super.dispose();
  }

  Future<void> _toggleLive() async {
    setState(() => _busy = true);
    try {
      if (widget.snapshot.state == BroadcastState.idle ||
          widget.snapshot.state == BroadcastState.stopped) {
        await widget.onGoLive();
      } else {
        await widget.onGoOffAir();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    if (profile == null) {
      return _EmptyState(onOpenProfiles: widget.onOpenProfiles);
    }

    final s = widget.snapshot;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (s.lastError != null) ...[
            _ErrorBanner(message: s.lastError!),
            const SizedBox(height: 14),
          ],
          if (!widget.ffmpegReady) ...[
            const _ErrorBanner(
              message:
                  'No se encontro FFmpeg. Sin el no se puede capturar ni '
                  'codificar el audio: indica su ruta en Ajustes.',
            ),
            const SizedBox(height: 14),
          ],
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // En 1280x720 (portatiles y maquinas virtuales) el espacio
                // vertical es el recurso escaso. Por eso la distribucion es:
                //
                //   [ panel de emision ] [ "suena ahora"      ]
                //   [                   ] [ ganancia de entrada ]
                //   [ registro de actividad (solo si sobra)    ]
                //
                // Los dos controles que el DJ usa mientras esta al aire quedan
                // SIEMPRE visibles; el registro es lo unico que cede espacio.
                final compact = constraints.maxHeight < 620;

                final livePanel = _LivePanel(
                  snapshot: s,
                  profile: profile,
                  busy: _busy,
                  compact: compact,
                  onToggle: _toggleLive,
                );

                final sideControls = Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _TrackPanel(
                      controller: _trackController,
                      live: s.isLive,
                      currentTrack: s.currentTrack,
                      compact: compact,
                      onSend: (value) {
                        widget.onTrackChanged(value);
                        setState(() {});
                      },
                    ),
                    SizedBox(height: compact ? 10 : 14),
                    _GainPanel(
                      gainDb: profile.gainDb,
                      live: s.isLive,
                      compact: compact,
                      onChanged: widget.onGainChanged,
                    ),
                    SizedBox(height: compact ? 10 : 14),
                    _StatusCard(
                      snapshot: s,
                      profile: profile,
                      signalCheck: widget.signalCheck,
                      compact: true,
                    ),
                  ],
                );

                // Alto aproximado de lo que no puede desaparecer.
                final needed = compact ? 470.0 : 560.0;
                final logHeight = constraints.maxHeight - needed;
                final showLog = logHeight >= 110;

                final topRow = constraints.maxWidth < 880
                    // En ventanas angostas no hay dos columnas: se apila y se
                    // permite desplazar, porque los controles ocupan mas alto.
                    ? SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            livePanel,
                            const SizedBox(height: 12),
                            sideControls,
                          ],
                        ),
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 5,
                            child: SingleChildScrollView(child: livePanel),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            flex: 4,
                            child: SingleChildScrollView(child: sideControls),
                          ),
                        ],
                      );

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: SizedBox(
                        child: showLog
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(child: topRow),
                                  const SizedBox(height: 10),
                                  SizedBox(
                                    height: logHeight,
                                    child: _LogPanel(entries: widget.log),
                                  ),
                                ],
                              )
                            : topRow,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onOpenProfiles});

  final VoidCallback onOpenProfiles;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.dns_outlined, size: 56, color: AppColors.textMuted),
          const SizedBox(height: 18),
          const Text(
            'Todavia no hay ninguna emisora configurada',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const SizedBox(
            width: 460,
            child: Text(
              'Agrega los datos de tu servidor (Icecast, AzuraCast, Zeno.fm o '
              'Shoutcast) y podras salir al aire. Las credenciales se guardan '
              'cifradas en tu equipo.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, height: 1.5),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: onOpenProfiles,
            icon: const Icon(Icons.add),
            label: const Text('AGREGAR MI EMISORA'),
          ),
        ],
      ),
    );
  }
}

/// Panel central con el boton grande y los vumetros.
class _LivePanel extends StatelessWidget {
  const _LivePanel({
    required this.snapshot,
    required this.profile,
    required this.busy,
    required this.compact,
    required this.onToggle,
  });

  final BroadcastSnapshot snapshot;
  final ServerProfile profile;
  final bool busy;

  /// Reduce alturas y margenes cuando la pantalla es chica.
  final bool compact;

  final Future<void> Function() onToggle;

  @override
  Widget build(BuildContext context) {
    final isOnAir =
        snapshot.state == BroadcastState.live ||
        snapshot.state == BroadcastState.reconnecting ||
        snapshot.state == BroadcastState.starting;

    final statusColor = switch (snapshot.state) {
      BroadcastState.live => AppColors.live,
      BroadcastState.reconnecting => AppColors.warning,
      BroadcastState.starting => AppColors.accent,
      BroadcastState.stopped => AppColors.onAir,
      BroadcastState.idle => AppColors.textMuted,
    };

    return Container(
      padding: EdgeInsets.all(compact ? 14 : 22),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: snapshot.isLive
              ? AppColors.onAir.withValues(alpha: 0.55)
              : AppColors.border,
          width: snapshot.isLive ? 2 : 1,
        ),
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      snapshot.state.label,
                      style: TextStyle(
                        fontSize: compact ? 21 : 26,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.6,
                        color: statusColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      profile.summary,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                    if (snapshot.state == BroadcastState.reconnecting) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Reintento ${snapshot.reconnectAttempt} · la captura de '
                        'audio sigue activa',
                        style: const TextStyle(
                          color: AppColors.warning,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // Cronometro al aire.
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    formatDuration(snapshot.secondsOnAir),
                    style: AppTheme.mono.copyWith(
                      fontSize: compact ? 28 : 34,
                      fontWeight: FontWeight.w700,
                      color: snapshot.isLive
                          ? AppColors.textPrimary
                          : AppColors.textMuted,
                    ),
                  ),
                  Text(
                    snapshot.isLive
                        ? '${snapshot.measuredKbps.toStringAsFixed(0)} kbps reales'
                        : 'tiempo al aire',
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ],
          ),
          SizedBox(height: compact ? 12 : 20),
          // Vumetros.
          VuMeter(
            peakDb: snapshot.peakDb,
            holdDb: snapshot.peakHoldDb,
            rmsDb: snapshot.rmsDb,
          ),
          SizedBox(height: compact ? 12 : 20),
          SizedBox(
            width: double.infinity,
            height: compact ? 54 : 64,
            child: FilledButton(
              onPressed: busy ? null : () => onToggle(),
              style: FilledButton.styleFrom(
                // Verde para entrar al aire, rojo para salir. Al reves, un
                // boton rojo fuera del aire parece "detener" y el estado en
                // vivo queda menos visible de lo que debe estar en cabina.
                backgroundColor: isOnAir ? AppColors.onAir : AppColors.live,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: busy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    )
                  : Text(
                      isOnAir ? 'SALIR DEL AIRE' : 'ENTRAR AL AIRE',
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.6,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Campo "suena ahora".
class _TrackPanel extends StatelessWidget {
  const _TrackPanel({
    required this.controller,
    required this.live,
    required this.currentTrack,
    required this.compact,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool live;
  final String currentTrack;
  final bool compact;
  final ValueChanged<String> onSend;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(compact ? 13 : 18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'SUENA AHORA',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (v) {
                    if (v.trim().isNotEmpty) onSend(v.trim());
                  },
                  decoration: const InputDecoration(
                    hintText: 'Artista - Titulo de la cancion',
                    prefixIcon: Icon(Icons.music_note_outlined, size: 20),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 50,
                child: FilledButton.icon(
                  onPressed: () {
                    final v = controller.text.trim();
                    if (v.isNotEmpty) onSend(v);
                  },
                  icon: const Icon(Icons.publish, size: 18),
                  label: const Text('ACTUALIZAR'),
                ),
              ),
            ],
          ),
          if (currentTrack.isNotEmpty && live) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.check_circle, size: 15, color: AppColors.live),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Los oyentes ven: $currentTrack',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12.5,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (!live) ...[
            const SizedBox(height: 10),
            const Text(
              'Se enviara al servidor cuando estes al aire.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

/// Tarjeta con los detalles tecnicos de la conexion.
class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.snapshot,
    required this.profile,
    required this.signalCheck,
    this.compact = false,
  });

  final BroadcastSnapshot snapshot;
  final ServerProfile profile;
  final SignalCheck? signalCheck;

  /// Reduce margenes y oculta las filas menos importantes cuando falta altura.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(compact ? 13 : 18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'CONEXION',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 14),
          _Row('Servidor', profile.host),
          _Row('Puerto', '${profile.effectivePort}'),
          _Row('Mount', profile.normalizedMount),
          _Row('Protocolo', profile.protocol.shortLabel),
          _Row(
            'Calidad',
            '${profile.audio.bitrateKbps} kbps · '
                '${profile.audio.sampleRate / 1000} kHz · '
                '${profile.audio.channels == 1 ? "mono" : "estereo"}',
          ),
          const Divider(height: 26),
          _Row('Enviado', formatBytes(snapshot.bytesSent)),
          _Row(
            'Bitrate real',
            snapshot.isLive
                ? '${snapshot.measuredKbps.toStringAsFixed(0)} kbps'
                : '—',
          ),
          // Lo que ve un oyente. Es distinto de "conectado": nuestro socket
          // puede estar vivo mientras el mount no se sirve.
          if (snapshot.isLive) ...[
            const Divider(height: 26),
            const Text(
              'LOS OYENTES RECIBEN',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
                color: AppColors.textMuted,
              ),
            ),
            const SizedBox(height: 8),
            _SignalRow(check: signalCheck),
          ],
          if (snapshot.recordingPath != null &&
              snapshot.recordingPath!.isNotEmpty)
            _Row(
              'Grabando',
              snapshot.recordingPath!.split(RegExp(r'[\\/]')).last,
            ),
          if (profile.publicUrl.isNotEmpty) ...[
            const Divider(height: 26),
            const Text(
              'Tus oyentes escuchan en:',
              style: TextStyle(color: AppColors.textMuted, fontSize: 11.5),
            ),
            const SizedBox(height: 4),
            SelectableText(
              profile.publicUrl,
              style: const TextStyle(color: AppColors.accent, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

/// Fila que muestra si la senal esta publicada, con el detalle del ultimo
/// diagnostico.
class _SignalRow extends StatelessWidget {
  const _SignalRow({required this.check});

  final SignalCheck? check;

  @override
  Widget build(BuildContext context) {
    final status = check?.status ?? SignalStatus.unknown;

    final (color, icon) = switch (status) {
      SignalStatus.healthy => (AppColors.live, Icons.check_circle),
      SignalStatus.unknown => (AppColors.textMuted, Icons.hourglass_empty),
      SignalStatus.notConfigured => (AppColors.textMuted, Icons.help_outline),
      SignalStatus.noSource => (AppColors.onAir, Icons.error_outline),
      SignalStatus.unreachable => (AppColors.warning, Icons.cloud_off),
      SignalStatus.unexpected => (AppColors.warning, Icons.help_outline),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
            Text(
              status.label,
              style: TextStyle(
                color: color,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        // Un `if` con spread (`...[ ]`) es una expresion de lista y no admite
        // `else`: por eso el caso contrario se escribe como otro `if`.
        if (check != null) ...[
          const SizedBox(height: 4),
          Text(
            check!.message,
            style: const TextStyle(
              color: AppColors.textMuted,
              fontSize: 11,
              height: 1.35,
            ),
          ),
        ],
        if (check == null)
          const Text(
            'Comprobando que el mount se este sirviendo...',
            style: TextStyle(color: AppColors.textMuted, fontSize: 11),
          ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 12.5))),
        ],
      ),
    );
  }
}

/// Control de ganancia de entrada (nivel del microfono).
///
/// Es el ajuste que mas se usa en cabina: cada microfono y cada locutor tienen
/// un nivel distinto, y si entra demasiado bajo los oyentes escuchan poco, y si
/// entra alto el limitador recorta. Se guarda en el perfil para no repetirlo
/// cada vez.
class _GainPanel extends StatefulWidget {
  const _GainPanel({
    required this.gainDb,
    required this.live,
    required this.compact,
    required this.onChanged,
  });

  final double gainDb;
  final bool live;
  final bool compact;
  final ValueChanged<double> onChanged;

  @override
  State<_GainPanel> createState() => _GainPanelState();
}

class _GainPanelState extends State<_GainPanel> {
  late double _value = widget.gainDb;

  @override
  void didUpdateWidget(covariant _GainPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Si el perfil activo cambia, se refleja el valor del nuevo perfil.
    if (oldWidget.gainDb != widget.gainDb) _value = widget.gainDb;
  }

  /// Etiqueta del valor con su signo, para que +3.0 y -3.0 no se confundan.
  String get _label {
    final sign = _value >= 0 ? '+' : '';
    return '$sign${_value.toStringAsFixed(1)} dB';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(18, widget.compact ? 10 : 14, 18, 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'GANANCIA DE ENTRADA',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  color: AppColors.textSecondary,
                ),
              ),
              const Spacer(),
              Text(
                _label,
                style: AppTheme.mono.copyWith(
                  fontSize: 13,
                  color: _value.abs() < 0.05
                      ? AppColors.textMuted
                      : AppColors.accent,
                ),
              ),
            ],
          ),
          Slider(
            value: _value.clamp(-12.0, 12.0),
            min: -12,
            max: 12,
            divisions: 48,
            label: _label,
            activeColor: AppColors.accent,
            onChanged: (v) => setState(() => _value = v),
            onChangeEnd: widget.onChanged,
          ),
          const Text(
            'Ajusta el nivel del microfono: cada equipo y cada locutor necesitan '
            'uno distinto. Se guarda en el perfil.',
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 11,
              height: 1.35,
            ),
          ),
          if (widget.live)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                'Estas al aire: el cambio se aplica en vivo, sin cortar la '
                'emision.',
                style: TextStyle(color: AppColors.meterSafe, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }
}

/// Registro de actividad, lo mas nuevo arriba.
class _LogPanel extends StatelessWidget {
  const _LogPanel({required this.entries});

  final List<LogEntry> entries;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 16, 18, 10),
            child: Text(
              'ACTIVIDAD',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: entries.isEmpty
                ? const Center(
                    child: Text(
                      'Sin actividad todavia',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12.5,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 10,
                    ),
                    itemCount: entries.length,
                    itemBuilder: (context, i) {
                      final e = entries[i];
                      final color = switch (e.level) {
                        'ok' => AppColors.live,
                        'warn' => AppColors.warning,
                        'error' => AppColors.onAir,
                        _ => AppColors.textSecondary,
                      };
                      final icon = switch (e.level) {
                        'ok' => Icons.check_circle_outline,
                        'warn' => Icons.warning_amber_outlined,
                        'error' => Icons.error_outline,
                        _ => Icons.info_outline,
                      };
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              e.stamp,
                              style: AppTheme.mono.copyWith(
                                fontSize: 11.5,
                                color: AppColors.textMuted,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Icon(icon, size: 15, color: color),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                e.message,
                                style: TextStyle(fontSize: 12.5, color: color),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.onAirDark.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.onAir.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: AppColors.onAir, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
