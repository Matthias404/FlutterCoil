import 'dart:async';
import 'dart:math' as math;

import 'peer_directory.dart';
import 'player_state.dart';
import 'protocol.dart';
import 'transport.dart';

export 'player_state.dart';

enum GamePhase { setup, running, ended }

enum RespawnMode { onDeath, atTeamBase }

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

class LobbyRules {
  const LobbyRules({
    required this.maxLives,
    required this.matchLengthMinutes,
    required this.maxPlayers,
    required this.respawnDelaySeconds,
    required this.itemSpawnRateSeconds,
    this.respawnMode = RespawnMode.onDeath,
    this.baseRadiusMeters = 2.0,
    required this.friendlyFire,
    required this.allowMidGameJoin,
    required this.teamLeadVoiceOnly,
    this.showOtherPlayersOnMap = true,
  });

  const LobbyRules.defaults()
    : maxLives = 10,
      matchLengthMinutes = 10,
      maxPlayers = 8,
      respawnDelaySeconds = 3,
      itemSpawnRateSeconds = 30,
      respawnMode = RespawnMode.onDeath,
      baseRadiusMeters = 2.0,
      friendlyFire = false,
      allowMidGameJoin = true,
      teamLeadVoiceOnly = true,
      showOtherPlayersOnMap = true;

  final int maxLives;
  final int matchLengthMinutes;
  final int maxPlayers;
  final int respawnDelaySeconds;
  final int itemSpawnRateSeconds;
  final RespawnMode respawnMode;
  final double baseRadiusMeters;
  final bool friendlyFire;
  final bool allowMidGameJoin;
  final bool teamLeadVoiceOnly;
  final bool showOtherPlayersOnMap;

  LobbyRules copyWith({
    int? maxLives,
    int? matchLengthMinutes,
    int? maxPlayers,
    int? respawnDelaySeconds,
    int? itemSpawnRateSeconds,
    RespawnMode? respawnMode,
    double? baseRadiusMeters,
    bool? friendlyFire,
    bool? allowMidGameJoin,
    bool? teamLeadVoiceOnly,
    bool? showOtherPlayersOnMap,
  }) {
    return LobbyRules(
      maxLives: maxLives ?? this.maxLives,
      matchLengthMinutes: matchLengthMinutes ?? this.matchLengthMinutes,
      maxPlayers: maxPlayers ?? this.maxPlayers,
      respawnDelaySeconds: respawnDelaySeconds ?? this.respawnDelaySeconds,
      itemSpawnRateSeconds: itemSpawnRateSeconds ?? this.itemSpawnRateSeconds,
      respawnMode: respawnMode ?? this.respawnMode,
      baseRadiusMeters: baseRadiusMeters ?? this.baseRadiusMeters,
      friendlyFire: friendlyFire ?? this.friendlyFire,
      allowMidGameJoin: allowMidGameJoin ?? this.allowMidGameJoin,
      teamLeadVoiceOnly: teamLeadVoiceOnly ?? this.teamLeadVoiceOnly,
      showOtherPlayersOnMap:
          showOtherPlayersOnMap ?? this.showOtherPlayersOnMap,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'maxLives': maxLives,
      'matchLengthMinutes': matchLengthMinutes,
      'maxPlayers': maxPlayers,
      'respawnDelaySeconds': respawnDelaySeconds,
      'itemSpawnRateSeconds': itemSpawnRateSeconds,
      'respawnMode': respawnMode.name,
      'baseRadiusMeters': baseRadiusMeters,
      'friendlyFire': friendlyFire,
      'allowMidGameJoin': allowMidGameJoin,
      'teamLeadVoiceOnly': teamLeadVoiceOnly,
      'showOtherPlayersOnMap': showOtherPlayersOnMap,
    };
  }

  factory LobbyRules.fromJson(Map<String, dynamic> json) {
    return LobbyRules(
      maxLives: json['maxLives'] as int? ?? 10,
      matchLengthMinutes: json['matchLengthMinutes'] as int? ?? 10,
      maxPlayers: json['maxPlayers'] as int? ?? 8,
      respawnDelaySeconds: json['respawnDelaySeconds'] as int? ?? 3,
      itemSpawnRateSeconds: json['itemSpawnRateSeconds'] as int? ?? 30,
      respawnMode: _respawnModeFromString(
        json['respawnMode'] as String? ?? RespawnMode.onDeath.name,
      ),
      baseRadiusMeters: (json['baseRadiusMeters'] as num?)?.toDouble() ?? 2.0,
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
    required this.gamePhase,
    required this.serverPlayerId,
    required this.scheduledGameStartAt,
    required this.readyTeamLeadIds,
    required this.teamLeadCount,
  });

  final String localPlayerId;
  final Map<String, PlayerState> players;
  final LobbyRules lobbyRules;
  final GamePhase gamePhase;
  final String? serverPlayerId;
  final DateTime? scheduledGameStartAt;
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
  final math.Random _random = math.Random();
  final Map<String, PlayerState> _players = <String, PlayerState>{};
  StreamSubscription<DatagramEnvelope>? _sub;
  Timer? _scheduledStartTriggerTimer;
  Timer? _scheduledStartTimer;
  LobbyRules _lobbyRules = const LobbyRules.defaults();
  GamePhase _gamePhase = GamePhase.setup;
  String? _serverPlayerId;
  DateTime? _scheduledGameStartAt;
  Set<String> _readyTeamLeadIds = <String>{};

  Stream<NetworkSnapshot> get updates => _updates.stream;
  Stream<TeamVoiceMessage> get teamVoiceMessages => _teamVoiceMessages.stream;

  NetworkSnapshot get snapshot => NetworkSnapshot(
    localPlayerId: localPlayerId,
    players: Map.unmodifiable(_players),
    lobbyRules: _lobbyRules,
    gamePhase: _gamePhase,
    serverPlayerId: _serverPlayerId,
    scheduledGameStartAt: _scheduledGameStartAt,
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
      shotsFired: 0,
      hitsTaken: 0,
      gunConnected: isServer,
      isHost: isServer,
      lastSeen: DateTime.now(),
    );

    await transport.start();
    _sub = transport.incoming.listen(_onDatagram);
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
    _players[localPlayerId] = localPlayer.copyWith(
      name: name,
      group: group,
      playerClass: playerClass,
      gunConnected: gunConnected,
      lastSeen: DateTime.now(),
    );
    _emit();

    final packet = _buildProfilePacket(PacketType.join);
    for (final peer in peerDirectory.peers) {
      await transport.send(peer.host, peer.port, packet);
    }

    if (isServer) {
      _assignRandomTeamLeads();
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

  Future<void> startGame() async {
    if (!isServer) {
      return;
    }

    await queueGameStart();
  }

  Future<void> queueGameStart({
    Duration delay = const Duration(minutes: 1),
  }) async {
    if (!isServer) {
      return;
    }

    if (_gamePhase != GamePhase.setup) {
      return;
    }

    _scheduledStartTriggerTimer?.cancel();
    _scheduledStartTimer?.cancel();
    _readyTeamLeadIds = <String>{};
    _scheduledGameStartAt = DateTime.now().add(delay);

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
    _readyTeamLeadIds = <String>{};

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
    _readyTeamLeadIds = <String>{};

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
      },
    );

    for (final peer in peerDirectory.peers) {
      await transport.send(peer.host, peer.port, packet);
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
          _assignRandomTeamLeads();
          _broadcastState();
        }
        break;
      case PacketType.join:
        _upsertPlayer(packet);
        if (isServer) {
          _assignRandomTeamLeads();
          _broadcastState();
        }
        break;
      case PacketType.shot:
        _upsertPlayer(packet);
        if (packet.targetPlayerId == localPlayerId) {
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
        }
        break;
      case PacketType.hit:
        if (packet.playerId == localPlayerId) {
          _players[localPlayerId] = localPlayer.copyWith(
            score: localPlayer.score + 1,
            lastSeen: DateTime.now(),
          );
        }
        break;
      case PacketType.heartbeat:
        _upsertPlayer(packet);
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

        final messageTeam = packet.payload['group'] as String?;
        final localTeam = _players[localPlayerId]?.group;
        if (messageTeam == null ||
            localTeam == null ||
            messageTeam != localTeam) {
          break;
        }

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
    return _players.values
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
    final group = packet.payload['group'] as String? ?? existing?.group ?? 'A';
    final playerClass =
        packet.payload['playerClass'] as String? ??
        existing?.playerClass ??
        'Assult';
    final gunConnected =
        packet.payload['gunConnected'] as bool? ??
        existing?.gunConnected ??
        false;
    final isHost =
        packet.payload['isHost'] as bool? ?? existing?.isHost ?? false;

    if (existing == null) {
      _players[id] = PlayerState(
        id: id,
        name: packet.playerName ?? id,
        group: group,
        playerClass: playerClass,
        score: 0,
        shotsFired: 0,
        hitsTaken: 0,
        gunConnected: gunConnected,
        isHost: isHost,
        lastSeen: DateTime.now(),
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
    );
  }

  void _assignRandomTeamLeads() {
    final byTeam = <String, List<PlayerState>>{};
    for (final player in _players.values) {
      byTeam.putIfAbsent(player.group, () => <PlayerState>[]).add(player);
    }

    for (final teamPlayers in byTeam.values) {
      if (teamPlayers.isEmpty) {
        continue;
      }
      final existingLead = teamPlayers
          .where((player) => player.playerClass == 'Team Lead')
          .firstOrNull;
      final leader =
          existingLead ?? teamPlayers[_random.nextInt(teamPlayers.length)];
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
        'serverPlayerId': _serverPlayerId,
        'gamePhase': _gamePhase.name,
        'scheduledGameStartAt': _scheduledGameStartAt?.toIso8601String(),
        'readyTeamLeadIds': _readyTeamLeadIds.toList(),
        'rules': _lobbyRules.toJson(),
        'players': _players.values.map(_serializePlayer).toList(),
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
      },
    );
  }

  Map<String, dynamic> _serializePlayer(PlayerState player) {
    return <String, dynamic>{
      'id': player.id,
      'name': player.name,
      'group': player.group,
      'playerClass': player.playerClass,
      'score': player.score,
      'shotsFired': player.shotsFired,
      'hitsTaken': player.hitsTaken,
      'gunConnected': player.gunConnected,
      'isHost': player.isHost,
      'lastSeen': player.lastSeen.toIso8601String(),
    };
  }

  void _applyStatePacket(NetworkPacket packet) {
    _serverPlayerId = packet.payload['serverPlayerId'] as String?;
    _gamePhase = _phaseFromString(
      packet.payload['gamePhase'] as String? ?? 'setup',
    );
    _scheduledGameStartAt = DateTime.tryParse(
      packet.payload['scheduledGameStartAt'] as String? ?? '',
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

    final rawPlayers =
        packet.payload['players'] as List<dynamic>? ?? const <dynamic>[];
    final nextPlayers = <String, PlayerState>{};
    for (final rawPlayer in rawPlayers) {
      final player = (rawPlayer as Map).cast<String, dynamic>();
      final id = player['id'] as String? ?? 'unknown';
      nextPlayers[id] = PlayerState(
        id: id,
        name: player['name'] as String? ?? id,
        group: player['group'] as String? ?? 'A',
        playerClass: player['playerClass'] as String? ?? 'Assult',
        score: player['score'] as int? ?? 0,
        shotsFired: player['shotsFired'] as int? ?? 0,
        hitsTaken: player['hitsTaken'] as int? ?? 0,
        gunConnected: player['gunConnected'] as bool? ?? false,
        isHost: player['isHost'] as bool? ?? false,
        lastSeen:
            DateTime.tryParse(player['lastSeen'] as String? ?? '') ??
            DateTime.now(),
      );
    }

    if (nextPlayers.isNotEmpty) {
      _players
        ..clear()
        ..addAll(nextPlayers);
    }
  }

  void _emit() {
    if (_updates.isClosed) {
      return;
    }
    _updates.add(snapshot);
  }

  Future<void> stop() async {
    _scheduledStartTriggerTimer?.cancel();
    _scheduledStartTimer?.cancel();
    await _sub?.cancel();
    await transport.stop();
    await _teamVoiceMessages.close();
    await _updates.close();
  }
}
