import 'dart:async';
import 'dart:math' as math;

import 'item_definitions.dart';
import 'item_models.dart';
import 'peer_directory.dart';
import 'player_state.dart';
import 'protocol.dart';
import 'transport.dart';

export 'item_models.dart';
export 'player_state.dart';

enum GamePhase { setup, running, ended }

enum RespawnMode { onDeath, atTeamBase }

enum GameType { time, lives, teamLives, kingOfTheHill, freeForAll }

enum FiringEnvironment { outdoor, indoor }

RespawnMode _respawnModeFromString(String value) {
  return RespawnMode.values.firstWhere(
    (mode) => mode.name == value,
    orElse: () => RespawnMode.onDeath,
  );
}

GamePhase _phaseFromString(String value) {
  return GamePhase.values.firstWhere(
    (phase) => phase.name == value,
    orElse: () => GamePhase.setup,
  );
}

GameType _gameTypeFromString(String value) {
  final normalized = value.trim().toLowerCase();
  switch (normalized) {
    case 'time':
      return GameType.time;
    case 'lives':
      return GameType.lives;
    case 'teamlives':
    case 'team_lives':
    case 'team lives':
      return GameType.teamLives;
    // backward-compat aliases
    case 'timelife':
    case 'time_life':
    case 'time life':
    case 'team battle':
      return GameType.time;
    case 'kingofthehill':
    case 'king_of_the_hill':
    case 'king of the hill':
      return GameType.kingOfTheHill;
    case 'freeforall':
    case 'free_for_all':
    case 'free for all':
      return GameType.freeForAll;
    default:
      return GameType.time;
  }
}

FiringEnvironment _firingEnvironmentFromString(String value) {
  final normalized = value.trim().toLowerCase();
  switch (normalized) {
    case 'indoor':
      return FiringEnvironment.indoor;
    case 'outdoor':
    default:
      return FiringEnvironment.outdoor;
  }
}

extension GameTypeLabel on GameType {
  String get label {
    switch (this) {
      case GameType.time:
        return 'Time';
      case GameType.lives:
        return 'Lives';
      case GameType.teamLives:
        return 'Team Lives';
      case GameType.kingOfTheHill:
        return 'King of the Hill';
      case GameType.freeForAll:
        return 'Free for All';
    }
  }
}

extension FiringEnvironmentLabel on FiringEnvironment {
  String get label {
    switch (this) {
      case FiringEnvironment.outdoor:
        return 'Outdoor';
      case FiringEnvironment.indoor:
        return 'Indoor';
    }
  }
}

class LobbyRules {
  const LobbyRules({
    required this.gameType,
    this.firingEnvironment = FiringEnvironment.outdoor,
    this.magazineSize = 15,
    this.reloadTimeSeconds = 2,
    required this.maxLives,
    required this.matchLengthMinutes,
    required this.maxPlayers,
    required this.respawnDelaySeconds,
    required this.itemSpawnRateSeconds,
    this.respawnMode = RespawnMode.onDeath,
    this.baseRadiusMeters = 2.0,
    this.hillRadiusMeters = 2.0,
    required this.friendlyFire,
    required this.allowMidGameJoin,
    required this.teamLeadVoiceOnly,
    this.showOtherPlayersOnMap = true,
  });

  const LobbyRules.defaults()
    : gameType = GameType.time,
      firingEnvironment = FiringEnvironment.outdoor,
      magazineSize = 15,
      reloadTimeSeconds = 2,
      maxLives = 10,
      matchLengthMinutes = 10,
      maxPlayers = 6,
      respawnDelaySeconds = 3,
      itemSpawnRateSeconds = 30,
      respawnMode = RespawnMode.onDeath,
      baseRadiusMeters = 2.0,
      hillRadiusMeters = 2.0,
      friendlyFire = false,
      allowMidGameJoin = true,
      teamLeadVoiceOnly = true,
      showOtherPlayersOnMap = true;

  final GameType gameType;
  final FiringEnvironment firingEnvironment;
  final int magazineSize;
  final int reloadTimeSeconds;
  final int maxLives;
  final int matchLengthMinutes;
  final int maxPlayers;
  final int respawnDelaySeconds;
  final int itemSpawnRateSeconds;
  final RespawnMode respawnMode;
  final double baseRadiusMeters;
  final double hillRadiusMeters;
  final bool friendlyFire;
  final bool allowMidGameJoin;
  final bool teamLeadVoiceOnly;
  final bool showOtherPlayersOnMap;

  LobbyRules copyWith({
    GameType? gameType,
    FiringEnvironment? firingEnvironment,
    int? magazineSize,
    int? reloadTimeSeconds,
    int? maxLives,
    int? matchLengthMinutes,
    int? maxPlayers,
    int? respawnDelaySeconds,
    int? itemSpawnRateSeconds,
    RespawnMode? respawnMode,
    double? baseRadiusMeters,
    double? hillRadiusMeters,
    bool? friendlyFire,
    bool? allowMidGameJoin,
    bool? teamLeadVoiceOnly,
    bool? showOtherPlayersOnMap,
  }) {
    return LobbyRules(
      gameType: gameType ?? this.gameType,
      firingEnvironment: firingEnvironment ?? this.firingEnvironment,
      magazineSize: magazineSize ?? this.magazineSize,
      reloadTimeSeconds: reloadTimeSeconds ?? this.reloadTimeSeconds,
      maxLives: maxLives ?? this.maxLives,
      matchLengthMinutes: matchLengthMinutes ?? this.matchLengthMinutes,
      maxPlayers: maxPlayers ?? this.maxPlayers,
      respawnDelaySeconds: respawnDelaySeconds ?? this.respawnDelaySeconds,
      itemSpawnRateSeconds: itemSpawnRateSeconds ?? this.itemSpawnRateSeconds,
      respawnMode: respawnMode ?? this.respawnMode,
      baseRadiusMeters: baseRadiusMeters ?? this.baseRadiusMeters,
      hillRadiusMeters: hillRadiusMeters ?? this.hillRadiusMeters,
      friendlyFire: friendlyFire ?? this.friendlyFire,
      allowMidGameJoin: allowMidGameJoin ?? this.allowMidGameJoin,
      teamLeadVoiceOnly: teamLeadVoiceOnly ?? this.teamLeadVoiceOnly,
      showOtherPlayersOnMap:
          showOtherPlayersOnMap ?? this.showOtherPlayersOnMap,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'gameType': gameType.name,
      'firingEnvironment': firingEnvironment.name,
      'magazineSize': magazineSize,
      'reloadTimeSeconds': reloadTimeSeconds,
      'maxLives': maxLives,
      'matchLengthMinutes': matchLengthMinutes,
      'maxPlayers': maxPlayers,
      'respawnDelaySeconds': respawnDelaySeconds,
      'itemSpawnRateSeconds': itemSpawnRateSeconds,
      'respawnMode': respawnMode.name,
      'baseRadiusMeters': baseRadiusMeters,
      'hillRadiusMeters': hillRadiusMeters,
      'friendlyFire': friendlyFire,
      'allowMidGameJoin': allowMidGameJoin,
      'teamLeadVoiceOnly': teamLeadVoiceOnly,
      'showOtherPlayersOnMap': showOtherPlayersOnMap,
    };
  }

  factory LobbyRules.fromJson(Map<String, dynamic> json) {
    return LobbyRules(
      gameType: _gameTypeFromString(json['gameType'] as String? ?? ''),
      firingEnvironment: _firingEnvironmentFromString(
        json['firingEnvironment'] as String? ?? '',
      ),
      magazineSize: json['magazineSize'] as int? ?? 15,
      reloadTimeSeconds: json['reloadTimeSeconds'] as int? ?? 2,
      maxLives: json['maxLives'] as int? ?? 10,
      matchLengthMinutes: json['matchLengthMinutes'] as int? ?? 10,
      maxPlayers: json['maxPlayers'] as int? ?? 6,
      respawnDelaySeconds: json['respawnDelaySeconds'] as int? ?? 3,
      itemSpawnRateSeconds: json['itemSpawnRateSeconds'] as int? ?? 30,
      respawnMode: _respawnModeFromString(
        json['respawnMode'] as String? ?? RespawnMode.onDeath.name,
      ),
      baseRadiusMeters: (json['baseRadiusMeters'] as num?)?.toDouble() ?? 2.0,
      hillRadiusMeters: (json['hillRadiusMeters'] as num?)?.toDouble() ?? 2.0,
      friendlyFire: json['friendlyFire'] as bool? ?? false,
      allowMidGameJoin: json['allowMidGameJoin'] as bool? ?? true,
      teamLeadVoiceOnly: json['teamLeadVoiceOnly'] as bool? ?? true,
      showOtherPlayersOnMap: json['showOtherPlayersOnMap'] as bool? ?? true,
    );
  }
}

class NetworkSnapshot {
  const NetworkSnapshot({
    required this.localPlayerId,
    required this.players,
    required this.lobbyRules,
    required this.lobbyOpen,
    required this.items,
    required this.activeEffects,
    required this.recentItemPickups,
    required this.gamePhase,
    required this.serverPlayerId,
    required this.scheduledGameStartAt,
    required this.gameStartedAt,
    required this.readyTeamLeadIds,
    required this.teamLeadCount,
  });

  final String localPlayerId;
  final Map<String, PlayerState> players;
  final LobbyRules lobbyRules;
  final bool lobbyOpen;
  final List<GameMapItem> items;
  final List<ActiveGameEffect> activeEffects;
  final List<GameItemPickupNotification> recentItemPickups;
  final GamePhase gamePhase;
  final String? serverPlayerId;
  final DateTime? scheduledGameStartAt;
  final DateTime? gameStartedAt;
  final Set<String> readyTeamLeadIds;
  final int teamLeadCount;
}

class TeamVoiceMessage {
  const TeamVoiceMessage({
    required this.senderPlayerId,
    required this.senderName,
    required this.team,
    required this.audioBase64,
    required this.mimeType,
    required this.durationMs,
    required this.sentAt,
  });

  final String senderPlayerId;
  final String senderName;
  final String team;
  final String audioBase64;
  final String mimeType;
  final int durationMs;
  final DateTime sentAt;
}

class _PreservedPlayerStats {
  const _PreservedPlayerStats({
    required this.score,
    required this.kills,
    required this.hitsLanded,
    required this.shotsFired,
    required this.hitsTaken,
  });

  final int score;
  final int kills;
  final int hitsLanded;
  final int shotsFired;
  final int hitsTaken;
}

class GameNetworkService {
  GameNetworkService({
    required this.transport,
    required this.localPlayerId,
    required this.initialPlayerName,
    required this.initialPlayerGroup,
    required this.peerDirectory,
    this.isServer = false,
  }) : _updates = StreamController<NetworkSnapshot>.broadcast();

  final NetworkTransport transport;
  final String localPlayerId;
  final String initialPlayerName;
  final String initialPlayerGroup;
  final PeerDirectory peerDirectory;
  final bool isServer;

  final StreamController<NetworkSnapshot> _updates;
  final StreamController<TeamVoiceMessage> _teamVoiceMessages =
      StreamController<TeamVoiceMessage>.broadcast();
  final StreamController<KillEvent> _killEvents =
      StreamController<KillEvent>.broadcast();
  final math.Random _random = math.Random();
  final Map<String, PlayerState> _players = <String, PlayerState>{};
  final Map<String, int> _recoilIdByPlayerId = <String, int>{};
  final List<GameMapItem> _items = <GameMapItem>[];
  final List<ActiveGameEffect> _activeEffects = <ActiveGameEffect>[];
  final List<GameItemPickupNotification> _recentItemPickups =
      <GameItemPickupNotification>[];
  final Map<String, Timer> _disconnectionGracePeriodTimers = <String, Timer>{};
  final Map<String, Timer> _respawnTimers = <String, Timer>{};
    final Map<String, _PreservedPlayerStats> _preservedStatsByPlayerId =
      <String, _PreservedPlayerStats>{};
  StreamSubscription<DatagramEnvelope>? _sub;
  Timer? _scheduledStartTriggerTimer;
  Timer? _scheduledStartTimer;
  Timer? _connectionCheckTimer;
  Timer? _serverItemTickTimer;
  static const Duration _disconnectionGracePeriod = Duration(seconds: 30);
  static const Duration _connectionCheckInterval = Duration(seconds: 5);
  static const Duration _itemTickInterval = Duration(seconds: 1);
  static const Duration _pickupNotificationTtl = Duration(seconds: 5);
  static const double _itemPickupRadiusMeters = 1.5;
  LobbyRules _lobbyRules = const LobbyRules.defaults();
  GamePhase _gamePhase = GamePhase.setup;
  bool _lobbyOpen = false;
  String? _serverPlayerId;
  int? _localRecoilPlayerId;
  DateTime? _scheduledGameStartAt;
  DateTime? _gameStartedAt;
  Duration _serverClockOffset = Duration.zero;
  Set<String> _readyTeamLeadIds = <String>{};
  DateTime? _lastGpsBroadcast;
  DateTime? _lastItemSpawnAt;

  Stream<NetworkSnapshot> get updates => _updates.stream;
  Stream<TeamVoiceMessage> get teamVoiceMessages => _teamVoiceMessages.stream;
  Stream<KillEvent> get killEvents => _killEvents.stream;

  DateTime get synchronizedNow {
    if (isServer) {
      return DateTime.now().toUtc();
    }
    return DateTime.now().toUtc().add(_serverClockOffset);
  }

  int? get localRecoilPlayerId => _localRecoilPlayerId;

  int get preferredRecoilPlayerId {
    final hash = localPlayerId.codeUnits.fold<int>(
      0,
      (acc, code) => ((acc * 31) + code) & 0x7fffffff,
    );
    return (hash % 16) + 1;
  }

  int _decodeRecoilPlayerId(int rawHitPlayerId) {
    if (rawHitPlayerId <= 0) {
      return 0;
    }
    return rawHitPlayerId >> 2;
  }

  String? resolveNetworkPlayerIdFromRecoilRawHit(int rawHitPlayerId) {
    final recoilPlayerId = _decodeRecoilPlayerId(rawHitPlayerId);
    if (recoilPlayerId <= 0) {
      return null;
    }

    for (final entry in _recoilIdByPlayerId.entries) {
      if (entry.value == recoilPlayerId) {
        return entry.key;
      }
    }
    return null;
  }

  Future<void> updateLocalRecoilPlayerId(int recoilPlayerId) async {
    if (recoilPlayerId <= 0) {
      return;
    }
    if (_localRecoilPlayerId == recoilPlayerId) {
      return;
    }

    _localRecoilPlayerId = recoilPlayerId;
    _recoilIdByPlayerId[localPlayerId] = recoilPlayerId;

    final packet = _buildProfilePacket(PacketType.join);
    for (final peer in peerDirectory.peers) {
      await transport.send(peer.host, peer.port, packet);
    }

    if (isServer) {
      await _broadcastState();
    }
  }

  Future<bool> registerTelemetryHit(int rawShooterHitPlayerId) async {
    final shooterPlayerId = resolveNetworkPlayerIdFromRecoilRawHit(
      rawShooterHitPlayerId,
    );
    if (shooterPlayerId == null) {
      return false;
    }
    if (!_canRegisterDamageFrom(shooterPlayerId, localPlayerId)) {
      return false;
    }

    final hitPacket = NetworkPacket(
      type: PacketType.hit,
      playerId: shooterPlayerId,
      targetPlayerId: localPlayerId,
    );
    for (final peer in peerDirectory.peers) {
      unawaited(transport.send(peer.host, peer.port, hitPacket));
    }

    return true;
  }

  NetworkSnapshot get snapshot => NetworkSnapshot(
    localPlayerId: localPlayerId,
    players: Map.unmodifiable(
      isServer ? (Map.of(_players)..remove(localPlayerId)) : _players,
    ),
    lobbyRules: _lobbyRules,
    lobbyOpen: _lobbyOpen,
    items: List.unmodifiable(_items),
    activeEffects: List.unmodifiable(_activeEffects),
    recentItemPickups: List.unmodifiable(_recentItemPickups),
    gamePhase: _gamePhase,
    serverPlayerId: _serverPlayerId,
    scheduledGameStartAt: _scheduledGameStartAt,
    gameStartedAt: _gameStartedAt,
    readyTeamLeadIds: Set.unmodifiable(_readyTeamLeadIds),
    teamLeadCount: _teamLeadIds().length,
  );

  PlayerState get localPlayer => _players[localPlayerId]!;

  Future<void> start() async {
    if (isServer) {
      _serverPlayerId = localPlayerId;
    }

    _players[localPlayerId] = PlayerState(
      id: localPlayerId,
      name: initialPlayerName,
      group: initialPlayerGroup,
      playerClass: 'Assult',
      score: 0,
      kills: 0,
      hitsLanded: 0,
      shotsFired: 0,
      hitsTaken: 0,
      gunConnected: isServer,
      isHost: isServer,
      lastSeen: DateTime.now(),
    );
    _localRecoilPlayerId ??= preferredRecoilPlayerId;
    if (_localRecoilPlayerId != null) {
      _recoilIdByPlayerId[localPlayerId] = _localRecoilPlayerId!;
    }

    await transport.start();
    _sub = transport.incoming.listen(_onDatagram);

    // Start periodic connection check for servers to detect and handle disconnections
    if (isServer) {
      _connectionCheckTimer = Timer.periodic(
        _connectionCheckInterval,
        (_) => _checkPlayerConnections(),
      );
      _serverItemTickTimer = Timer.periodic(
        _itemTickInterval,
        (_) => _tickServerOwnedItems(),
      );
    }

    _emit();
  }

  Future<void> connect() async {
    final hello = _buildProfilePacket(PacketType.hello);

    for (final peer in peerDirectory.peers) {
      await transport.send(peer.host, peer.port, hello);
    }
  }

  Future<void> updateLocalProfile({
    String? name,
    String? group,
    String? playerClass,
    bool? gunConnected,
  }) async {
    final forceFreeForAll = _lobbyRules.gameType == GameType.freeForAll;
    _players[localPlayerId] = localPlayer.copyWith(
      name: name,
      group: forceFreeForAll ? 'FFA' : group,
      playerClass: forceFreeForAll ? 'Assult' : playerClass,
      gunConnected: gunConnected,
      lastSeen: DateTime.now(),
    );
    _emit();

    final packet = _buildProfilePacket(PacketType.join);
    for (final peer in peerDirectory.peers) {
      await transport.send(peer.host, peer.port, packet);
    }

    if (isServer) {
      _checkForItemPickups();
      await _broadcastState();
    }
  }

  Future<void> updateGpsPosition(double latitude, double longitude) async {
    _players[localPlayerId] = localPlayer.copyWith(
      latitude: latitude,
      longitude: longitude,
      lastSeen: DateTime.now(),
    );
    _emit();

    final now = DateTime.now();
    final last = _lastGpsBroadcast;
    if (last != null && now.difference(last) < const Duration(seconds: 3)) {
      return;
    }
    _lastGpsBroadcast = now;

    final packet = NetworkPacket(
      type: PacketType.heartbeat,
      playerId: localPlayerId,
      playerName: localPlayer.name,
      payload: <String, dynamic>{
        'group': localPlayer.group,
        'playerClass': localPlayer.playerClass,
        'gunConnected': localPlayer.gunConnected,
        'isHost': localPlayer.isHost,
        if (_localRecoilPlayerId != null)
          'recoilPlayerId': _localRecoilPlayerId,
        'latitude': latitude,
        'longitude': longitude,
      },
    );

    for (final peer in peerDirectory.peers) {
      await transport.send(peer.host, peer.port, packet);
    }

    if (isServer) {
      _checkForItemPickups();
      await _broadcastState();
    }
  }

  Future<void> updateLobbyRules(LobbyRules rules) async {
    if (!isServer) {
      return;
    }

    _lobbyRules = rules;
    _emit();
    await _broadcastState();
  }

  Future<void> setLobbyOpen(bool open) async {
    if (!isServer) {
      return;
    }
    if (_lobbyOpen == open) {
      return;
    }

    _lobbyOpen = open;
    _emit();
    await _broadcastState();
  }

  Future<void> startGame() async {
    if (!isServer) {
      return;
    }

    await queueGameStart();
  }

  Future<void> queueGameStart({
    Duration delay = const Duration(seconds: 20),
  }) async {
    if (!isServer) {
      return;
    }

    if (_gamePhase != GamePhase.setup) {
      return;
    }

    _scheduledStartTriggerTimer?.cancel();
    _scheduledStartTimer?.cancel();
    _assignRoundRoles();
    _readyTeamLeadIds = <String>{};
    _gameStartedAt = null;
    _scheduledGameStartAt = DateTime.now().toUtc().add(delay);

    _scheduledStartTriggerTimer = Timer(delay, () {
      unawaited(_startGameNow());
    });

    _scheduledStartTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_scheduledGameStartAt == null || _gamePhase != GamePhase.setup) {
        timer.cancel();
        return;
      }

      _emit();
      unawaited(_broadcastState());
    });

    _emit();
    await _broadcastState();
  }

  Future<void> confirmTeamLeadReadyStart() async {
    if (_gamePhase != GamePhase.setup) {
      return;
    }
    if (_lobbyRules.gameType == GameType.freeForAll) {
      return;
    }

    final packet = NetworkPacket(
      type: PacketType.ready,
      playerId: localPlayerId,
      playerName: localPlayer.name,
      payload: <String, dynamic>{
        'group': localPlayer.group,
        'playerClass': localPlayer.playerClass,
        'gunConnected': localPlayer.gunConnected,
        'isHost': localPlayer.isHost,
      },
    );

    for (final peer in peerDirectory.peers) {
      await transport.send(peer.host, peer.port, packet);
    }

    if (isServer) {
      await _handleTeamLeadReady(localPlayerId);
    }
  }

  Future<void> _startGameNow() async {
    if (_gamePhase != GamePhase.setup) {
      return;
    }

    _scheduledStartTriggerTimer?.cancel();
    _scheduledStartTriggerTimer = null;
    _scheduledStartTimer?.cancel();
    _scheduledStartTimer = null;
    _scheduledGameStartAt = null;
    _gameStartedAt = DateTime.now().toUtc();
    _readyTeamLeadIds = <String>{};
    _items.clear();
    _activeEffects.clear();
    _recentItemPickups.clear();
    _lastItemSpawnAt = null;

    _gamePhase = GamePhase.running;
    _emit();
    await _broadcastState();
  }

  Future<void> endGame() async {
    if (!isServer) {
      return;
    }

    _scheduledStartTriggerTimer?.cancel();
    _scheduledStartTriggerTimer = null;
    _scheduledStartTimer?.cancel();
    _scheduledStartTimer = null;
    _scheduledGameStartAt = null;
    _gameStartedAt = null;
    _readyTeamLeadIds = <String>{};
    _items.clear();
    _activeEffects.clear();
    _recentItemPickups.clear();
    _lastItemSpawnAt = null;

    _gamePhase = GamePhase.ended;
    _emit();
    await _broadcastState();
  }

  Future<void> sendShot(String targetPlayerId) async {
    if (_gamePhase != GamePhase.running) {
      return;
    }

    _players[localPlayerId] = localPlayer.copyWith(
      shotsFired: localPlayer.shotsFired + 1,
      lastSeen: DateTime.now(),
    );
    _emit();

    final packet = NetworkPacket(
      type: PacketType.shot,
      playerId: localPlayerId,
      targetPlayerId: targetPlayerId,
      playerName: localPlayer.name,
      payload: <String, dynamic>{
        'group': localPlayer.group,
        'gunConnected': localPlayer.gunConnected,
        'isHost': localPlayer.isHost,
        if (_localRecoilPlayerId != null)
          'recoilPlayerId': _localRecoilPlayerId,
      },
    );

    for (final peer in peerDirectory.peers) {
      unawaited(transport.send(peer.host, peer.port, packet));
    }
  }

  Future<void> sendTeamVoiceMessage({
    required String audioBase64,
    required String mimeType,
    required int durationMs,
  }) async {
    if (audioBase64.isEmpty) {
      return;
    }

    final packet = NetworkPacket(
      type: PacketType.voice,
      playerId: localPlayerId,
      playerName: localPlayer.name,
      payload: <String, dynamic>{
        'group': localPlayer.group,
        if (_localRecoilPlayerId != null)
          'recoilPlayerId': _localRecoilPlayerId,
        'audioBase64': audioBase64,
        'mimeType': mimeType,
        'durationMs': durationMs,
        'sentAt': DateTime.now().toIso8601String(),
      },
    );

    for (final peer in peerDirectory.peers) {
      await transport.send(peer.host, peer.port, packet);
    }
  }

  bool _canRegisterDamageFrom(String shooterPlayerId, String victimPlayerId) {
    if (_lobbyRules.gameType == GameType.freeForAll ||
        _lobbyRules.friendlyFire) {
      return true;
    }

    final shooter = _players[shooterPlayerId];
    final victim = _players[victimPlayerId];
    if (shooter == null || victim == null) {
      // If one side is missing, fail open to avoid dropping valid hits.
      return true;
    }

    return shooter.group != victim.group;
  }

  void _onDatagram(DatagramEnvelope envelope) {
    final packet = envelope.packet;
    peerDirectory.add(PeerEndpoint(host: envelope.host, port: envelope.port));

    switch (packet.type) {
      case PacketType.hello:
        _upsertPlayer(packet);
        transport.send(
          envelope.host,
          envelope.port,
          _buildProfilePacket(PacketType.join),
        );
        if (isServer) {
          _broadcastState();
        }
        break;
      case PacketType.join:
        _upsertPlayer(packet);
        if (isServer) {
          _broadcastState();
        }
        break;
      case PacketType.shot:
        _upsertPlayer(packet);
        if (packet.targetPlayerId == localPlayerId &&
            _canRegisterDamageFrom(packet.playerId, localPlayerId)) {
          _players[localPlayerId] = localPlayer.copyWith(
            hitsTaken: localPlayer.hitsTaken + 1,
            lastSeen: DateTime.now(),
          );
          transport.send(
            envelope.host,
            envelope.port,
            NetworkPacket(
              type: PacketType.hit,
              playerId: packet.playerId,
              targetPlayerId: localPlayerId,
            ),
          );
          // Notify victim's screen
          if (!_killEvents.isClosed) {
            _killEvents.add(
              KillEvent(
                id: 'kill_${DateTime.now().microsecondsSinceEpoch}',
                killerPlayerId: packet.playerId,
                killerName: packet.playerName ?? packet.playerId,
                victimPlayerId: localPlayerId,
                victimName: localPlayer.name,
                weapon: 'gun',
                createdAt: DateTime.now(),
              ),
            );
          }
        }
        break;
      case PacketType.hit:
        if (isServer && packet.targetPlayerId != null) {
          final targetPlayerId = packet.targetPlayerId!;
          if (_gamePhase == GamePhase.running &&
              _canRegisterDamageFrom(packet.playerId, targetPlayerId)) {
            final target = _players[targetPlayerId];
            if (target != null) {
              _players[targetPlayerId] = target.copyWith(
                hitsTaken: target.hitsTaken + 1,
                lastSeen: DateTime.now(),
              );
              final shooter = _players[packet.playerId];
              if (shooter != null) {
                _players[packet.playerId] = shooter.copyWith(
                  score: shooter.score + 1,
                  kills: shooter.kills + 1,
                  hitsLanded: shooter.hitsLanded + 1,
                  lastSeen: DateTime.now(),
                );
              }
              _scheduleRespawnIfNeeded(targetPlayerId);
              _emit();
              unawaited(_broadcastState());
            }
          }
        }

        if (packet.playerId == localPlayerId) {
          // Notify shooter's screen
          final victimId = packet.targetPlayerId;
          if (victimId != null && !_killEvents.isClosed) {
            final victimName = _players[victimId]?.name ?? 'Player';
            _killEvents.add(
              KillEvent(
                id: 'kill_${DateTime.now().microsecondsSinceEpoch}',
                killerPlayerId: localPlayerId,
                killerName: localPlayer.name,
                victimPlayerId: victimId,
                victimName: victimName,
                weapon: 'gun',
                createdAt: DateTime.now(),
              ),
            );
          }
        }
        break;
      case PacketType.heartbeat:
        _upsertPlayer(packet);
        if (isServer) {
          // UDP packets can be dropped; rebroadcasting on heartbeat keeps
          // all clients eventually consistent with player joins/updates.
          unawaited(_broadcastState());
        }
        break;
      case PacketType.state:
        _applyStatePacket(packet);
        break;
      case PacketType.voice:
        _upsertPlayer(packet);

        if (isServer) {
          final sender = _players[packet.playerId];
          final senderCanBroadcast =
              !_lobbyRules.teamLeadVoiceOnly ||
              sender?.playerClass == 'Team Lead';
          if (senderCanBroadcast) {
            _relayPacketExcept(
              sourceHost: envelope.host,
              sourcePort: envelope.port,
              packet: packet,
            );
          }
        }

        final messageTeam = packet.payload['group'] as String? ?? 'Unknown';

        final audioBase64 = packet.payload['audioBase64'] as String? ?? '';
        if (audioBase64.isEmpty) {
          break;
        }

        if (!_teamVoiceMessages.isClosed) {
          _teamVoiceMessages.add(
            TeamVoiceMessage(
              senderPlayerId: packet.playerId,
              senderName: packet.playerName ?? packet.playerId,
              team: messageTeam,
              audioBase64: audioBase64,
              mimeType: packet.payload['mimeType'] as String? ?? 'audio/m4a',
              durationMs: packet.payload['durationMs'] as int? ?? 0,
              sentAt:
                  DateTime.tryParse(
                    packet.payload['sentAt'] as String? ?? '',
                  ) ??
                  DateTime.now(),
            ),
          );
        }
        break;
      case PacketType.ready:
        _upsertPlayer(packet);
        if (isServer) {
          unawaited(_handleTeamLeadReady(packet.playerId));
        }
        break;
    }

    _emit();
  }

  Set<String> _teamLeadIds() {
    if (_lobbyRules.gameType == GameType.freeForAll) {
      return <String>{};
    }
    return _players.values
      .where((player) => !player.isHost)
        .where((player) => player.playerClass == 'Team Lead')
        .map((player) => player.id)
        .toSet();
  }

  void _trimReadyTeamLeads() {
    final leads = _teamLeadIds();
    _readyTeamLeadIds = _readyTeamLeadIds.where(leads.contains).toSet();
  }

  bool _allTeamLeadsReady() {
    final leads = _teamLeadIds();
    if (leads.isEmpty) {
      return false;
    }
    return leads.every(_readyTeamLeadIds.contains);
  }

  Future<void> _handleTeamLeadReady(String playerId) async {
    if (!isServer || _gamePhase != GamePhase.setup) {
      return;
    }
    if (_scheduledGameStartAt == null) {
      return;
    }

    final player = _players[playerId];
    if (player?.playerClass != 'Team Lead') {
      return;
    }

    _readyTeamLeadIds.add(playerId);
    _trimReadyTeamLeads();

    if (_allTeamLeadsReady()) {
      await _startGameNow();
      return;
    }

    _emit();
    await _broadcastState();
  }

  void _upsertPlayer(NetworkPacket packet) {
    final id = packet.playerId;
    final existing = _players[id];
    final incomingRecoilPlayerId = (packet.payload['recoilPlayerId'] as num?)
        ?.toInt();
    if (incomingRecoilPlayerId != null && incomingRecoilPlayerId > 0) {
      _recoilIdByPlayerId[id] = incomingRecoilPlayerId;
    }
    final forceFreeForAll = _lobbyRules.gameType == GameType.freeForAll;
    final incomingGroup =
        packet.payload['group'] as String? ?? existing?.group ?? 'A';
    final group = forceFreeForAll ? 'FFA' : incomingGroup;
    final incomingPlayerClass =
        packet.payload['playerClass'] as String? ??
        existing?.playerClass ??
        'Assult';
    final playerClass = forceFreeForAll ? 'Assult' : incomingPlayerClass;
    final gunConnected =
        packet.payload['gunConnected'] as bool? ??
        existing?.gunConnected ??
        false;
    final isHost =
        packet.payload['isHost'] as bool? ?? existing?.isHost ?? false;
    final latitude =
        (packet.payload['latitude'] as num?)?.toDouble() ?? existing?.latitude;
    final longitude =
        (packet.payload['longitude'] as num?)?.toDouble() ??
        existing?.longitude;

    if (!isServer && isHost) {
      // Host device is controller-only and should not appear as a player.
      return;
    }

    if (isServer && existing == null && !isHost) {
      // New players may only join after server explicitly opens the lobby.
      if (!_lobbyOpen) {
        return;
      }

      // Enforce lobby capacity for non-host players.
      final activePlayerCount = _players.values
          .where((player) => !player.isHost)
          .length;
      if (activePlayerCount >= _lobbyRules.maxPlayers) {
        return;
      }
      // Block new joins while a running/ended match disallows mid-game join.
      if ((_gamePhase == GamePhase.running || _gamePhase == GamePhase.ended) &&
          !_lobbyRules.allowMidGameJoin) {
        return;
      }
    }

    if (existing == null) {
      final preservedStats = _preservedStatsByPlayerId[id];
      _players[id] = PlayerState(
        id: id,
        name: packet.playerName ?? id,
        group: group,
        playerClass: playerClass,
        score: preservedStats?.score ?? 0,
        kills: preservedStats?.kills ?? 0,
        hitsLanded: preservedStats?.hitsLanded ?? 0,
        shotsFired: preservedStats?.shotsFired ?? 0,
        hitsTaken: preservedStats?.hitsTaken ?? 0,
        gunConnected: gunConnected,
        isHost: isHost,
        lastSeen: DateTime.now(),
        latitude: latitude,
        longitude: longitude,
      );
      return;
    }

    _players[id] = existing.copyWith(
      name: packet.playerName ?? existing.name,
      group: group,
      playerClass: playerClass,
      gunConnected: gunConnected,
      isHost: isHost,
      lastSeen: DateTime.now(),
      latitude: latitude,
      longitude: longitude,
    );

    // Handle player rejoin if they were offline
    if (isServer && !existing.isNetworkConnected) {
      _handlePlayerRejoin(id);
    }
  }

  void _assignRoundRoles() {
    if (_lobbyRules.gameType == GameType.freeForAll) {
      for (final player in _players.values) {
        if (player.isHost) {
          continue;
        }
        _players[player.id] = player.copyWith(
          playerClass: 'Assult',
          group: 'FFA',
          lastSeen: DateTime.now(),
        );
      }
      _trimReadyTeamLeads();
      return;
    }

    final byTeam = <String, List<PlayerState>>{};
    for (final player in _players.values.where((p) => !p.isHost)) {
      byTeam.putIfAbsent(player.group, () => <PlayerState>[]).add(player);
    }

    for (final teamPlayers in byTeam.values) {
      if (teamPlayers.isEmpty) {
        continue;
      }
      final leader = teamPlayers[_random.nextInt(teamPlayers.length)];
      for (final player in teamPlayers) {
        _players[player.id] = player.copyWith(
          playerClass: player.id == leader.id ? 'Team Lead' : 'Assult',
          lastSeen: DateTime.now(),
        );
      }
    }

    _trimReadyTeamLeads();
  }

  Future<void> _broadcastState() async {
    final packet = NetworkPacket(
      type: PacketType.state,
      playerId: localPlayerId,
      playerName: localPlayer.name,
      payload: <String, dynamic>{
        'lobbyOpen': _lobbyOpen,
        'serverPlayerId': _serverPlayerId,
        'serverNow': DateTime.now().toUtc().toIso8601String(),
        'gamePhase': _gamePhase.name,
        'scheduledGameStartAt': _scheduledGameStartAt
            ?.toUtc()
            .toIso8601String(),
        'gameStartedAt': _gameStartedAt?.toUtc().toIso8601String(),
        'readyTeamLeadIds': _readyTeamLeadIds.toList(),
        'rules': _lobbyRules.toJson(),
        'items': _items.map((item) => item.toJson()).toList(),
        'activeEffects': _activeEffects
            .map((effect) => effect.toJson())
            .toList(),
        'recentItemPickups': _recentItemPickups
            .map((pickup) => pickup.toJson())
            .toList(),
        'players': _players.values
            .where((p) => p.id != localPlayerId)
            .map(_serializePlayer)
            .toList(),
      },
    );

    for (final peer in peerDirectory.peers) {
      await transport.send(peer.host, peer.port, packet);
    }
  }

  void _relayPacketExcept({
    required String sourceHost,
    required int sourcePort,
    required NetworkPacket packet,
  }) {
    for (final peer in peerDirectory.peers) {
      if (peer.host == sourceHost && peer.port == sourcePort) {
        continue;
      }
      transport.send(peer.host, peer.port, packet);
    }
  }

  NetworkPacket _buildProfilePacket(PacketType type) {
    return NetworkPacket(
      type: type,
      playerId: localPlayerId,
      playerName: localPlayer.name,
      payload: <String, dynamic>{
        'group': localPlayer.group,
        'playerClass': localPlayer.playerClass,
        'gunConnected': localPlayer.gunConnected,
        'isHost': localPlayer.isHost,
        if (_localRecoilPlayerId != null)
          'recoilPlayerId': _localRecoilPlayerId,
      },
    );
  }

  void _tickServerOwnedItems() {
    if (!isServer) {
      return;
    }

    final effectCountBefore = _activeEffects.length;
    final pickupCountBefore = _recentItemPickups.length;
    _pruneExpiredEffects();
    _pruneExpiredPickupNotifications();
    final stateChanged =
        effectCountBefore != _activeEffects.length ||
        pickupCountBefore != _recentItemPickups.length;
    if (stateChanged) {
      _emit();
      unawaited(_broadcastState());
    }

    if (_gamePhase != GamePhase.running) {
      return;
    }

    if (_lobbyRules.itemSpawnRateSeconds > 0) {
      final now = DateTime.now();
      final lastSpawnAt = _lastItemSpawnAt;
      if (lastSpawnAt == null ||
          now.difference(lastSpawnAt).inSeconds >=
              _lobbyRules.itemSpawnRateSeconds) {
        if (_spawnServerOwnedItem()) {
          _lastItemSpawnAt = now;
        }
      }
    }

    _checkForItemPickups();
  }

  bool _spawnServerOwnedItem() {
    final positionedPlayers = _players.values
        .where((player) => player.id != localPlayerId)
        .where((player) => player.latitude != null && player.longitude != null)
        .toList();

    if (positionedPlayers.isEmpty) {
      return false;
    }

    final anchor = positionedPlayers[_random.nextInt(positionedPlayers.length)];
    final angle = _random.nextDouble() * math.pi * 2;
    final distanceMeters = 8 + _random.nextDouble() * 12;
    final spawned = _offsetLatLng(
      anchor.latitude!,
      anchor.longitude!,
      distanceMeters,
      angle,
    );

    final effectType = _pickSpawnEffectType();
    _items.add(
      GameMapItem(
        id: 'item_${DateTime.now().microsecondsSinceEpoch}_${_random.nextInt(1 << 20)}',
        effectType: effectType,
        latitude: spawned.$1,
        longitude: spawned.$2,
      ),
    );
    unawaited(_broadcastState());
    return true;
  }

  GameItemEffectType _pickSpawnEffectType() {
    return ItemRegistry.pickEffectType(
      freeForAll: _lobbyRules.gameType == GameType.freeForAll,
      random: _random,
    );
  }

  void _checkForItemPickups() {
    if (!isServer || _items.isEmpty) {
      return;
    }

    final positionedPlayers = _players.values
        .where((player) => !player.isHost)
        .where((player) => player.latitude != null && player.longitude != null)
        .toList();
    if (positionedPlayers.isEmpty) {
      return;
    }

    final remainingItems = <GameMapItem>[];
    var changed = false;
    for (final item in _items) {
      PlayerState? collector;
      var nearestDistance = double.infinity;
      for (final player in positionedPlayers) {
        final distance = _distanceMetersBetweenLatLng(
          item.latitude,
          item.longitude,
          player.latitude!,
          player.longitude!,
        );
        if (distance <= _itemPickupRadiusMeters && distance < nearestDistance) {
          collector = player;
          nearestDistance = distance;
        }
      }

      if (collector == null) {
        remainingItems.add(item);
        continue;
      }

      changed = true;
      _applyItemEffectToGame(item, collector);
    }

    if (!changed) {
      return;
    }

    _items
      ..clear()
      ..addAll(remainingItems);
    _emit();
    unawaited(_broadcastState());
  }

  void _applyItemEffectToGame(GameMapItem item, PlayerState collector) {
    final recipients = item.effectType.isTeamEffect
        ? _recipientIdsForTeamEffect(collector)
        : <String>[collector.id];
    if (recipients.isEmpty) {
      return;
    }

    final now = DateTime.now();
    final expiresAt = _effectExpiryFor(item.effectType, now);
    for (final playerId in recipients) {
      _activeEffects.removeWhere(
        (effect) =>
            effect.playerId == playerId && effect.effectType == item.effectType,
      );
      _activeEffects.add(
        ActiveGameEffect(
          id: 'effect_${item.id}_$playerId',
          playerId: playerId,
          effectType: item.effectType,
          createdAt: now,
          expiresAt: expiresAt,
        ),
      );
    }

    _recentItemPickups.add(
      GameItemPickupNotification(
        id: 'pickup_${item.id}_${collector.id}',
        itemId: item.id,
        playerId: collector.id,
        playerName: collector.name,
        effectType: item.effectType,
        createdAt: now,
      ),
    );
  }

  List<String> _recipientIdsForTeamEffect(PlayerState collector) {
    if (_lobbyRules.gameType == GameType.freeForAll) {
      return <String>[collector.id];
    }

    return _players.values
        .where((player) => player.group == collector.group)
        .where((player) => !player.isHost)
        .map((player) => player.id)
        .toList();
  }

  DateTime? _effectExpiryFor(GameItemEffectType effectType, DateTime now) {
    switch (effectType) {
      case GameItemEffectType.teamHeal:
      case GameItemEffectType.playerHeal:
        return null;
      case GameItemEffectType.teamArmor:
        return now.add(const Duration(seconds: 12));
      case GameItemEffectType.playerShield:
        return now.add(const Duration(seconds: 20));
      case GameItemEffectType.teamAmmo:
        return now.add(const Duration(seconds: 30));
      case GameItemEffectType.playerAmmo:
        return now.add(const Duration(seconds: 45));
      case GameItemEffectType.doubleDamage:
        return now.add(const Duration(minutes: 1));
      case GameItemEffectType.airStrike:
        return now.add(const Duration(seconds: 7));
      case GameItemEffectType.invisibility:
        return now.add(const Duration(minutes: 2));
    }
  }

  void _pruneExpiredEffects() {
    final now = DateTime.now();
    _activeEffects.removeWhere(
      (effect) => effect.expiresAt != null && now.isAfter(effect.expiresAt!),
    );
  }

  void _pruneExpiredPickupNotifications() {
    final now = DateTime.now();
    _recentItemPickups.removeWhere(
      (pickup) => now.difference(pickup.createdAt) > _pickupNotificationTtl,
    );
  }

  double _distanceMetersBetweenLatLng(
    double latitudeA,
    double longitudeA,
    double latitudeB,
    double longitudeB,
  ) {
    const earthRadiusMeters = 6371000.0;
    final lat1 = latitudeA * math.pi / 180.0;
    final lat2 = latitudeB * math.pi / 180.0;
    final deltaLat = (latitudeB - latitudeA) * math.pi / 180.0;
    final deltaLon = (longitudeB - longitudeA) * math.pi / 180.0;

    final haversine =
        math.sin(deltaLat / 2) * math.sin(deltaLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(deltaLon / 2) *
            math.sin(deltaLon / 2);
    final arc = 2 * math.atan2(math.sqrt(haversine), math.sqrt(1 - haversine));
    return earthRadiusMeters * arc;
  }

  (double, double) _offsetLatLng(
    double latitude,
    double longitude,
    double distanceMeters,
    double angleRadians,
  ) {
    const metersPerDegreeLatitude = 111320.0;
    final metersPerDegreeLongitude =
        111320.0 * math.cos(latitude * math.pi / 180.0);
    final latitudeOffset =
        math.cos(angleRadians) * distanceMeters / metersPerDegreeLatitude;
    final longitudeOffset =
        math.sin(angleRadians) * distanceMeters / metersPerDegreeLongitude;
    return (latitude + latitudeOffset, longitude + longitudeOffset);
  }

  Map<String, dynamic> _serializePlayer(PlayerState player) {
    return <String, dynamic>{
      'id': player.id,
      'name': player.name,
      'group': player.group,
      'playerClass': player.playerClass,
      'score': player.score,
      'kills': player.kills,
      'hitsLanded': player.hitsLanded,
      'shotsFired': player.shotsFired,
      'hitsTaken': player.hitsTaken,
      'gunConnected': player.gunConnected,
      'isHost': player.isHost,
      'lastSeen': player.lastSeen.toIso8601String(),
      if (player.latitude != null) 'latitude': player.latitude,
      if (player.longitude != null) 'longitude': player.longitude,
      if (_recoilIdByPlayerId[player.id] != null)
        'recoilPlayerId': _recoilIdByPlayerId[player.id],
      'isNetworkConnected': player.isNetworkConnected,
    };
  }

  void _applyStatePacket(NetworkPacket packet) {
    final receivedAtUtc = DateTime.now().toUtc();
    final serverNowUtc = DateTime.tryParse(
      packet.payload['serverNow'] as String? ?? '',
    );
    if (serverNowUtc != null) {
      final measuredOffset = serverNowUtc.difference(receivedAtUtc);
      // Smooth per-packet jitter so countdown/timers don't visually jump.
      final smoothedMilliseconds =
          ((_serverClockOffset.inMilliseconds * 3) +
              measuredOffset.inMilliseconds) ~/
          4;
      _serverClockOffset = Duration(milliseconds: smoothedMilliseconds);
    }

    _lobbyOpen = packet.payload['lobbyOpen'] as bool? ?? false;
    _serverPlayerId = packet.payload['serverPlayerId'] as String?;
    _gamePhase = _phaseFromString(
      packet.payload['gamePhase'] as String? ?? 'setup',
    );
    _scheduledGameStartAt = DateTime.tryParse(
      packet.payload['scheduledGameStartAt'] as String? ?? '',
    );
    _gameStartedAt = DateTime.tryParse(
      packet.payload['gameStartedAt'] as String? ?? '',
    );
    _readyTeamLeadIds =
        (packet.payload['readyTeamLeadIds'] as List<dynamic>? ??
                const <dynamic>[])
            .whereType<String>()
            .toSet();
    final rules = (packet.payload['rules'] as Map?)?.cast<String, dynamic>();
    if (rules != null) {
      _lobbyRules = LobbyRules.fromJson(rules);
    }

    final rawItems =
        packet.payload['items'] as List<dynamic>? ?? const <dynamic>[];
    _items
      ..clear()
      ..addAll(
        rawItems.whereType<Map>().map(
          (rawItem) => GameMapItem.fromJson(rawItem.cast<String, dynamic>()),
        ),
      );

    final rawEffects =
        packet.payload['activeEffects'] as List<dynamic>? ?? const <dynamic>[];
    _activeEffects
      ..clear()
      ..addAll(
        rawEffects.whereType<Map>().map(
          (rawEffect) =>
              ActiveGameEffect.fromJson(rawEffect.cast<String, dynamic>()),
        ),
      );

    final rawPickups =
        packet.payload['recentItemPickups'] as List<dynamic>? ??
        const <dynamic>[];
    _recentItemPickups
      ..clear()
      ..addAll(
        rawPickups.whereType<Map>().map(
          (rawPickup) => GameItemPickupNotification.fromJson(
            rawPickup.cast<String, dynamic>(),
          ),
        ),
      );

    final rawPlayers =
        packet.payload['players'] as List<dynamic>? ?? const <dynamic>[];
    final nextPlayers = <String, PlayerState>{};
    final nextRecoilIdByPlayerId = <String, int>{};
    for (final rawPlayer in rawPlayers) {
      final player = (rawPlayer as Map).cast<String, dynamic>();
      final id = player['id'] as String? ?? 'unknown';
      final recoilPlayerId = (player['recoilPlayerId'] as num?)?.toInt();
      if (recoilPlayerId != null && recoilPlayerId > 0) {
        nextRecoilIdByPlayerId[id] = recoilPlayerId;
      }
      nextPlayers[id] = PlayerState(
        id: id,
        name: player['name'] as String? ?? id,
        group: player['group'] as String? ?? 'A',
        playerClass: player['playerClass'] as String? ?? 'Assult',
        score: player['score'] as int? ?? 0,
        kills: player['kills'] as int? ?? 0,
        hitsLanded: player['hitsLanded'] as int? ?? 0,
        shotsFired: player['shotsFired'] as int? ?? 0,
        hitsTaken: player['hitsTaken'] as int? ?? 0,
        gunConnected: player['gunConnected'] as bool? ?? false,
        isHost: player['isHost'] as bool? ?? false,
        lastSeen:
            DateTime.tryParse(player['lastSeen'] as String? ?? '') ??
            DateTime.now(),
        latitude: (player['latitude'] as num?)?.toDouble(),
        longitude: (player['longitude'] as num?)?.toDouble(),
        isNetworkConnected: player['isNetworkConnected'] as bool? ?? true,
      );
    }

    // Preserve the local player's own entry in case the server broadcast
    // arrived before our hello was registered on the server side.
    final selfState = _players[localPlayerId];
    final selfRecoilPlayerId = _recoilIdByPlayerId[localPlayerId];
    _players
      ..clear()
      ..addAll(nextPlayers);
    if (selfState != null && !_players.containsKey(localPlayerId)) {
      _players[localPlayerId] = selfState;
    }

    _recoilIdByPlayerId
      ..removeWhere((playerId, _) => playerId != localPlayerId)
      ..addAll(nextRecoilIdByPlayerId);
    if (selfRecoilPlayerId != null &&
        !_recoilIdByPlayerId.containsKey(localPlayerId)) {
      _recoilIdByPlayerId[localPlayerId] = selfRecoilPlayerId;
    }
  }

  void _emit() {
    if (_updates.isClosed) {
      return;
    }
    _updates.add(snapshot);
  }

  /// Periodic server check for player disconnections.
  /// Marks players offline if they haven't sent anything in 15 seconds.
  /// Removes them permanently if they've been offline for the grace period.
  void _checkPlayerConnections() {
    if (!isServer) {
      return;
    }

    final now = DateTime.now();
    final disconnectionThreshold = now.subtract(const Duration(seconds: 15));
    final playersToCheck = _players.values
        .where((p) => p.id != localPlayerId)
        .where((p) => p.isNetworkConnected)
        .toList();

    for (final player in playersToCheck) {
      if (player.lastSeen.isBefore(disconnectionThreshold)) {
        // Player hasn't sent anything in 15 seconds, mark as offline
        _startDisconnectionGracePeriod(player.id);
      }
    }

    // Keep clients in sync even if an earlier UDP state packet was dropped.
    unawaited(_broadcastState());
  }

  /// Starts the grace period for a disconnected player.
  /// During this time, the player can rejoin without losing their state.
  void _startDisconnectionGracePeriod(String playerId) {
    final player = _players[playerId];
    if (player == null || !player.isNetworkConnected) {
      return;
    }

    // Mark player as offline
    _players[playerId] = player.copyWith(isNetworkConnected: false);

    // Cancel any existing grace period timer for this player
    _disconnectionGracePeriodTimers[playerId]?.cancel();

    // Start a new grace period timer
    _disconnectionGracePeriodTimers[playerId] = Timer(
      _disconnectionGracePeriod,
      () => _endDisconnectionGracePeriod(playerId),
    );

    _emit();
    unawaited(_broadcastState());
  }

  /// Ends the grace period for a disconnected player and removes them from the game.
  void _endDisconnectionGracePeriod(String playerId) {
    final removed = _players[playerId];
    if (removed != null && !removed.isHost) {
      _preservedStatsByPlayerId[playerId] = _PreservedPlayerStats(
        score: removed.score,
        kills: removed.kills,
        hitsLanded: removed.hitsLanded,
        shotsFired: removed.shotsFired,
        hitsTaken: removed.hitsTaken,
      );
    }
    _respawnTimers.remove(playerId)?.cancel();
    _disconnectionGracePeriodTimers.remove(playerId);
    _players.remove(playerId);
    _recoilIdByPlayerId.remove(playerId);
    _readyTeamLeadIds.remove(playerId);
    _emit();
    unawaited(_broadcastState());
  }

  void _scheduleRespawnIfNeeded(String playerId) {
    if (!isServer || _gamePhase != GamePhase.running) {
      return;
    }

    final player = _players[playerId];
    if (player == null || player.isHost) {
      return;
    }

    if (player.hitsTaken < _lobbyRules.maxLives) {
      return;
    }

    if (_respawnTimers[playerId]?.isActive == true) {
      return;
    }

    final delay = Duration(seconds: _lobbyRules.respawnDelaySeconds);
    _respawnTimers[playerId] = Timer(delay, () {
      _respawnTimers.remove(playerId);
      final latest = _players[playerId];
      if (latest == null || _gamePhase != GamePhase.running) {
        return;
      }

      // Respawn restores health; position handling can be extended per mode.
      _players[playerId] = latest.copyWith(
        hitsTaken: 0,
        lastSeen: DateTime.now(),
      );
      _emit();
      unawaited(_broadcastState());
    });
  }

  /// Called when a player successfully rejoins after being disconnected.
  void _handlePlayerRejoin(String playerId) {
    final player = _players[playerId];
    if (player == null) {
      return;
    }

    // Cancel grace period if it's still active
    _disconnectionGracePeriodTimers[playerId]?.cancel();
    _disconnectionGracePeriodTimers.remove(playerId);

    // Mark player as back online
    _players[playerId] = player.copyWith(
      isNetworkConnected: true,
      lastSeen: DateTime.now(),
    );

    _emit();
    unawaited(_broadcastState());
  }

  Future<void> stop() async {
    _scheduledStartTriggerTimer?.cancel();
    _scheduledStartTimer?.cancel();
    _connectionCheckTimer?.cancel();
    _serverItemTickTimer?.cancel();
    for (final timer in _respawnTimers.values) {
      timer.cancel();
    }
    _respawnTimers.clear();
    for (final timer in _disconnectionGracePeriodTimers.values) {
      timer.cancel();
    }
    _disconnectionGracePeriodTimers.clear();
    await _sub?.cancel();
    await transport.stop();
    await _teamVoiceMessages.close();
    await _killEvents.close();
    await _updates.close();
  }
}
