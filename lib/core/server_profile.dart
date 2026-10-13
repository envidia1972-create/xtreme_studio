/// Perfiles de servidor de streaming: el corazon del "Modo B" (multi-emisora).
///
/// Cada usuario guarda aqui las credenciales de **su** servidor. La app no
/// depende de ningun backend propio: el audio sale de la PC del DJ directo al
/// servidor de su emisora.
library;

/// Protocolo de ingesta soportado.
///
/// - [icecast2]: HTTP `PUT` con autenticacion basica al mount (Icecast 2,
///   AzuraCast, Zeno.fm y casi todo hosting moderno).
/// - [shoutcast1]: handshake con la contrasena como usuario y `#1` como
///   password; los oyentes se redirigen a un puerto +1.
/// - [shoutcast2]: handshake v2 con usuario/password reales y `sid`.
enum ServerProtocol { icecast2, shoutcast1, shoutcast2 }

extension ServerProtocolInfo on ServerProtocol {
  String get id => switch (this) {
    ServerProtocol.icecast2 => 'icecast2',
    ServerProtocol.shoutcast1 => 'shoutcast1',
    ServerProtocol.shoutcast2 => 'shoutcast2',
  };

  String get label => switch (this) {
    ServerProtocol.icecast2 => 'Icecast 2 / AzuraCast / Zeno.fm',
    ServerProtocol.shoutcast1 => 'Shoutcast v1',
    ServerProtocol.shoutcast2 => 'Shoutcast v2',
  };

  String get shortLabel => switch (this) {
    ServerProtocol.icecast2 => 'Icecast 2',
    ServerProtocol.shoutcast1 => 'Shoutcast v1',
    ServerProtocol.shoutcast2 => 'Shoutcast v2',
  };

  static ServerProtocol fromId(String? value) {
    for (final p in ServerProtocol.values) {
      if (p.id == value) return p;
    }
    return ServerProtocol.icecast2;
  }
}

/// Configuracion de audio del perfil.
class AudioSettings {
  const AudioSettings({
    this.bitrateKbps = 128,
    this.sampleRate = 44100,
    this.channels = 2,
  });

  /// 64 / 96 / 128 / 160 / 192 kbps.
  final int bitrateKbps;
  final int sampleRate;

  /// 1 = mono, 2 = estereo.
  final int channels;

  static const List<int> bitrateOptions = [64, 96, 128, 160, 192];
  static const List<int> sampleRateOptions = [22050, 32000, 44100, 48000];

  AudioSettings copyWith({int? bitrateKbps, int? sampleRate, int? channels}) =>
      AudioSettings(
        bitrateKbps: bitrateKbps ?? this.bitrateKbps,
        sampleRate: sampleRate ?? this.sampleRate,
        channels: channels ?? this.channels,
      );

  Map<String, dynamic> toJson() => {
    'bitrateKbps': bitrateKbps,
    'sampleRate': sampleRate,
    'channels': channels,
  };

  factory AudioSettings.fromJson(Map<String, dynamic> json) => AudioSettings(
    bitrateKbps: (json['bitrateKbps'] as num?)?.toInt() ?? 128,
    sampleRate: (json['sampleRate'] as num?)?.toInt() ?? 44100,
    channels: (json['channels'] as num?)?.toInt() ?? 2,
  );
}

/// Un perfil de emisora: a donde y como se transmite.
///
/// La contrasena **no** se serializa aqui. Se guarda cifrada aparte y se
/// inyecta en [password] al cargar; ver `secret_store.dart`.
class ServerProfile {
  ServerProfile({
    required this.id,
    required this.name,
    required this.host,
    this.port = 8000,
    this.mount = '/stream',
    this.username = 'source',
    this.password = '',
    this.protocol = ServerProtocol.icecast2,
    this.useTls = false,
    this.publicUrl = '',
    this.stationName = '',
    this.genre = '',
    this.description = '',
    this.audio = const AudioSettings(),
    this.inputDeviceId = '',
    this.gainDb = 0.0,
    this.autoReconnect = true,
    this.recordLocally = false,
    this.recordDirectory = '',
    this.adminUsername = '',
    this.adminPassword = '',
  });

  /// Identificador estable del perfil. No cambia al editar.
  String id;
  String name;
  String host;
  int port;
  String mount;
  String username;
  String password;
  ServerProtocol protocol;
  bool useTls;

  /// URL publica de escucha, para el boton "abrir mi radio".
  String publicUrl;

  /// Metadatos que se anuncian al servidor al conectar.
  String stationName;
  String genre;
  String description;

  AudioSettings audio;

  /// Identificador del dispositivo de entrada (nombre dshow en Windows).
  /// Vacio = el primero disponible.
  String inputDeviceId;

  /// Ganancia de entrada en dB, para igualar el nivel del microfono.
  ///
  /// Se guarda por perfil porque cada emisora puede usar un equipo distinto:
  /// un locutor que sale desde su casa con otro microfono necesita otro ajuste.
  /// Rango util: -12 a +12 dB. Se aplica como filtro en FFmpeg, asi que un
  /// valor alto sube el ruido de fondo ademas de la voz.
  double gainDb;

  bool autoReconnect;
  bool recordLocally;
  String recordDirectory;

  /// Credenciales del panel de administracion (Icecast `admin`), opcionales.
  ///
  /// Todavia no se usan: estan previstas para la integracion con la API de
  /// administracion (expulsar a un DJ, consultar quien esta al aire). Se
  /// guardan desde ahora para no perderlas cuando esa fase se implemente.
  String adminUsername;
  String adminPassword;

  /// Puerto efectivo de ingesta. Shoutcast v1/v2 suelen usar el puerto base
  /// y el `+1` queda para los oyentes (lo maneja el servidor, no nosotros).
  int get effectivePort => port;

  /// Ruta de ingesta HTTP para Icecast: `/mount`.
  String get normalizedMount {
    var m = mount.trim();
    if (m.isEmpty) return '/stream';
    if (!m.startsWith('/')) m = '/$m';
    // Un mount no debe terminar en '/' salvo que sea la raiz.
    if (m.length > 1 && m.endsWith('/')) m = m.substring(0, m.length - 1);
    return m;
  }

  /// El usuario de Shoutcast v1 es siempre `source` y el password es el que
  /// el servidor espera como *contrasena*; el "usuario" real va en `#1`.
  bool get isShoutcast =>
      protocol == ServerProtocol.shoutcast1 ||
      protocol == ServerProtocol.shoutcast2;

  /// Descripcion corta para la lista de perfiles.
  String get summary {
    final tls = useTls ? 's' : '';
    return 'http$tls://$host:$port$normalizedMount';
  }

  ServerProfile duplicate({String? newId, String? newName}) {
    final copy = ServerProfile(
      id: newId ?? id,
      name: newName ?? '$name (copia)',
      host: host,
      port: port,
      mount: mount,
      username: username,
      password: password,
      protocol: protocol,
      useTls: useTls,
      publicUrl: publicUrl,
      stationName: stationName,
      genre: genre,
      description: description,
      audio: audio,
      inputDeviceId: inputDeviceId,
      gainDb: gainDb,
      autoReconnect: autoReconnect,
      recordLocally: recordLocally,
      recordDirectory: recordDirectory,
      adminUsername: adminUsername,
      adminPassword: adminPassword,
    );
    return copy;
  }

  /// Serializa **sin** secretos: las contrasenas van al almacen cifrado.
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'mount': mount,
    'username': username,
    'protocol': protocol.id,
    'useTls': useTls,
    'publicUrl': publicUrl,
    'stationName': stationName,
    'genre': genre,
    'description': description,
    'audio': audio.toJson(),
    'inputDeviceId': inputDeviceId,
    'gainDb': gainDb,
    'autoReconnect': autoReconnect,
    'recordLocally': recordLocally,
    'recordDirectory': recordDirectory,
    'adminUsername': adminUsername,
  };

  factory ServerProfile.fromJson(Map<String, dynamic> json) => ServerProfile(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? 'Emisora',
    host: json['host'] as String? ?? '',
    port: (json['port'] as num?)?.toInt() ?? 8000,
    mount: json['mount'] as String? ?? '/stream',
    username: json['username'] as String? ?? 'source',
    protocol: ServerProtocolInfo.fromId(json['protocol'] as String?),
    useTls: json['useTls'] as bool? ?? false,
    publicUrl: json['publicUrl'] as String? ?? '',
    stationName: json['stationName'] as String? ?? '',
    genre: json['genre'] as String? ?? '',
    description: json['description'] as String? ?? '',
    audio: AudioSettings.fromJson(
      (json['audio'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    inputDeviceId: json['inputDeviceId'] as String? ?? '',
    gainDb: (json['gainDb'] as num?)?.toDouble() ?? 0.0,
    autoReconnect: json['autoReconnect'] as bool? ?? true,
    recordLocally: json['recordLocally'] as bool? ?? false,
    recordDirectory: json['recordDirectory'] as String? ?? '',
    adminUsername: json['adminUsername'] as String? ?? '',
  );

  /// Validacion previa al guardado. Devuelve la lista de problemas; vacia = OK.
  List<String> validate() {
    final problems = <String>[];
    if (name.trim().isEmpty) problems.add('El nombre del perfil es obligatorio');
    if (host.trim().isEmpty) problems.add('El servidor (host) es obligatorio');
    if (port <= 0 || port > 65535) problems.add('El puerto debe estar entre 1 y 65535');
    if (username.trim().isEmpty) problems.add('El usuario es obligatorio');
    if (password.isEmpty) problems.add('La contrasena es obligatoria');
    if (audio.bitrateKbps < 32 || audio.bitrateKbps > 320) {
      problems.add('El bitrate debe estar entre 32 y 320 kbps');
    }
    if (gainDb < -24 || gainDb > 24) {
      problems.add(
        'La ganancia debe estar entre -24 y +24 dB '
        '(un valor mayor solo amplifica el ruido de fondo)',
      );
    }
    return problems;
  }
}
