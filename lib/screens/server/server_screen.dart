import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../network/game_network_service.dart';
import '../../network/join_code.dart';
import '../../network/local_network.dart';
import '../../network/peer_directory.dart';
import '../../network/transport.dart';
import '../../network/udp_transport.dart';
import '../../theme/team_colors.dart';
import '../../theme/theme_toggle_button.dart';
import '../../utils/helpers.dart';

class ServerScreen extends StatefulWidget {
  const ServerScreen({super.key});

  @override
  State<ServerScreen> createState() => _ServerScreenState();
}

enum _GameModePreset { time, lives, teamLives, kingOfTheHill, freeForAll }

class _ServerScreenState extends State<ServerScreen> {
  static const int _serverPort = 7777;
  static const String _lanMode = 'LAN';
  static const String _onlineMode = 'Online';
  static const double _itemSpawnDisabledSeconds = 0;
  static const double _itemSpawnMinSeconds = 30;
  static const double _itemSpawnMaxSeconds = 300;
  static const double _itemSpawnStepSeconds = 15;

  late final GameNetworkService _service;
  late final PeerDirectory _peerDirectory;
  late final TextEditingController _serverNameController;
  late final TextEditingController _advertisedHostController;
  NetworkSnapshot? _snapshot;
  String _status = 'Starting server...';
  String _networkMode = _lanMode;
  double _maxLives = 10;
  double _magazineSize = 15;
  double _reloadTimeSeconds = 2;
  double _matchLength = 10;
  double _respawnDelaySeconds = 3;
  double _itemSpawnRateSeconds = _itemSpawnMinSeconds;
  double _hillRadiusMeters = 2.0;
  _GameModePreset _selectedPreset = _GameModePreset.time;
  RespawnMode _respawnMode = RespawnMode.onDeath;
  bool _friendlyFire = false;
  bool _allowMidGameJoin = true;
  bool _teamLeadVoiceOnly = true;
  bool _showOtherPlayersOnMap = true;

  GameType _gameTypeForPreset(_GameModePreset preset) {
    switch (preset) {
      case _GameModePreset.time:
        return GameType.time;
      case _GameModePreset.lives:
        return GameType.lives;
      case _GameModePreset.teamLives:
        return GameType.teamLives;
      case _GameModePreset.kingOfTheHill:
        return GameType.kingOfTheHill;
      case _GameModePreset.freeForAll:
        return GameType.freeForAll;
    }
  }

  _GameModePreset _presetForGameType(GameType gameType) {
    switch (gameType) {
      case GameType.time:
        return _GameModePreset.time;
      case GameType.lives:
        return _GameModePreset.lives;
      case GameType.teamLives:
        return _GameModePreset.teamLives;
      case GameType.kingOfTheHill:
        return _GameModePreset.kingOfTheHill;
      case GameType.freeForAll:
        return _GameModePreset.freeForAll;
    }
  }

  String _formatCountdown(Duration duration) {
    final totalSeconds = duration.inSeconds.clamp(0, 3599);
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  double _normalizeItemSpawnRate(double value) {
    if (value <= _itemSpawnDisabledSeconds) {
      return _itemSpawnDisabledSeconds;
    }

    final clamped = value.clamp(_itemSpawnMinSeconds, _itemSpawnMaxSeconds);
    final snapped =
        ((clamped - _itemSpawnMinSeconds) / _itemSpawnStepSeconds).round() *
            _itemSpawnStepSeconds +
        _itemSpawnMinSeconds;
    return snapped.toDouble();
  }

  bool get _itemSpawnDisabled =>
      _itemSpawnRateSeconds <= _itemSpawnDisabledSeconds;

  @override
  void initState() {
    super.initState();

    _serverNameController = TextEditingController(text: 'Server Control');
    _advertisedHostController = TextEditingController(text: '127.0.0.1');
    _peerDirectory = PeerDirectory();

    _detectAndSetLocalIp();

    _service = GameNetworkService(
      transport: UdpNetworkTransport(localPort: _serverPort),
      localPlayerId: deviceId('server'),
      initialPlayerName: 'Server Control',
      initialPlayerGroup: 'Host',
      peerDirectory: _peerDirectory,
      isServer: true,
    );

    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _service.start();
    _service.updates.listen((snapshot) {
      if (!mounted) {
        return;
      }

      setState(() {
        _selectedPreset = _presetForGameType(snapshot.lobbyRules.gameType);
        _snapshot = snapshot;
        _maxLives = snapshot.lobbyRules.maxLives.toDouble();
        _magazineSize = snapshot.lobbyRules.magazineSize.toDouble();
        _reloadTimeSeconds = snapshot.lobbyRules.reloadTimeSeconds.toDouble();
        _matchLength = snapshot.lobbyRules.matchLengthMinutes.toDouble();
        _respawnDelaySeconds = snapshot.lobbyRules.respawnDelaySeconds
            .toDouble();
        _itemSpawnRateSeconds = _normalizeItemSpawnRate(
          snapshot.lobbyRules.itemSpawnRateSeconds.toDouble(),
        );
        _hillRadiusMeters = snapshot.lobbyRules.hillRadiusMeters;
        _respawnMode = snapshot.lobbyRules.respawnMode;
        _friendlyFire = snapshot.lobbyRules.friendlyFire;
        _allowMidGameJoin = snapshot.lobbyRules.allowMidGameJoin;
        _teamLeadVoiceOnly = snapshot.lobbyRules.teamLeadVoiceOnly;
        _showOtherPlayersOnMap = snapshot.lobbyRules.showOtherPlayersOnMap;
      });
    });
    if (!mounted) {
      return;
    }

    setState(() {
      _status = 'Server listening on UDP 7777.';
    });
  }

  @override
  void dispose() {
    _serverNameController.dispose();
    _advertisedHostController.dispose();
    _service.stop();
    _peerDirectory.dispose();
    super.dispose();
  }

  Future<void> _detectAndSetLocalIp() async {
    if (_networkMode != _lanMode) {
      return;
    }
    final ip = await getLocalIpAddress();
    if (ip != null && mounted) {
      setState(() {
        _advertisedHostController.text = ip;
      });
      return;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _status =
          'Could not auto-detect LAN IP. You can still enter it manually.';
    });
  }

  void _setNetworkMode(String mode) {
    if (_networkMode == mode) {
      return;
    }

    setState(() {
      _networkMode = mode;
      _status = mode == _lanMode
          ? 'LAN mode selected. Players can join only on the same network.'
          : 'Online mode selected. Enter your public host/IP for remote players.';
    });

    if (mode == _lanMode) {
      _detectAndSetLocalIp();
    }
  }

  void _applyPreset(_GameModePreset preset) {
    setState(() {
      _selectedPreset = preset;
      switch (preset) {
        case _GameModePreset.time:
          _matchLength = 15;
          _maxLives = 10;
          _respawnDelaySeconds = 3;
          _itemSpawnRateSeconds = 60;
          _friendlyFire = false;
        case _GameModePreset.lives:
          _matchLength = 10;
          _maxLives = 3;
          _respawnDelaySeconds = 0;
          _itemSpawnRateSeconds = 45;
          _friendlyFire = false;
        case _GameModePreset.teamLives:
          _matchLength = 10;
          _maxLives = 15;
          _respawnDelaySeconds = 0;
          _itemSpawnRateSeconds = 45;
          _friendlyFire = false;
        case _GameModePreset.kingOfTheHill:
          _matchLength = 12;
          _maxLives = 0;
          _respawnDelaySeconds = 2;
          _itemSpawnRateSeconds = 30;
          _hillRadiusMeters = 2.0;
          _friendlyFire = false;
        case _GameModePreset.freeForAll:
          _matchLength = 10;
          _maxLives = 8;
          _respawnDelaySeconds = 2;
          _itemSpawnRateSeconds = 45;
          _friendlyFire = false;
      }

      _itemSpawnRateSeconds = _normalizeItemSpawnRate(_itemSpawnRateSeconds);
      _status = '${_gameModePresetLabel(preset)} preset selected. Save rules to apply.';
    });
  }

  String _gameModePresetLabel(_GameModePreset preset) {
    switch (preset) {
      case _GameModePreset.time:
        return 'Time';
      case _GameModePreset.lives:
        return 'Lives';
      case _GameModePreset.teamLives:
        return 'Team Lives';
      case _GameModePreset.kingOfTheHill:
        return 'King of the Hill';
      case _GameModePreset.freeForAll:
        return 'Free for All';
    }
  }

  Future<void> _applyServerRules() async {
    await _service.updateLocalProfile(name: _serverNameController.text.trim());
    await _service.updateLobbyRules(
      LobbyRules(
        gameType: _gameTypeForPreset(_selectedPreset),
        magazineSize: _magazineSize.round(),
        reloadTimeSeconds: _reloadTimeSeconds.round(),
        maxLives: _maxLives.round(),
        matchLengthMinutes: _matchLength.round(),
        maxPlayers: _snapshot?.lobbyRules.maxPlayers ?? 8,
        respawnDelaySeconds: _respawnDelaySeconds.round(),
        itemSpawnRateSeconds: _itemSpawnDisabled
            ? _itemSpawnDisabledSeconds.round()
            : _normalizeItemSpawnRate(_itemSpawnRateSeconds).round(),
        respawnMode: _respawnMode,
        baseRadiusMeters: 2.0,
        hillRadiusMeters: _hillRadiusMeters,
        friendlyFire: _friendlyFire,
        allowMidGameJoin: _allowMidGameJoin,
        teamLeadVoiceOnly: _teamLeadVoiceOnly,
        showOtherPlayersOnMap: _showOtherPlayersOnMap,
      ),
    );
    if (!mounted) {
      return;
    }

    setState(() {
      _status = 'Server settings updated.';
    });
  }

  Future<void> _queueGameStart() async {
    await _service.queueGameStart();
    if (!mounted) {
      return;
    }

    setState(() {
      _status =
          'Game start queued. Match starts in 60s or when all Team Leads are ready.';
    });
  }

  Future<void> _openLobby() async {
    await _applyServerRules();
    if (!mounted) {
      return;
    }

    setState(() {
      _status = 'Lobby is open. Players can now join using the join code.';
    });
  }

  Widget _buildModeDescription(_GameModePreset preset) {
    final String text;
    switch (preset) {
      case _GameModePreset.time:
        text =
            'Each kill earns a point. The team with the most points when time runs out wins.';
      case _GameModePreset.lives:
        text =
            'Each player has a limited number of lives. No respawn once lives reach zero. The team with the last living player wins. On timeout, the team with the most lives per player wins.';
      case _GameModePreset.teamLives:
        text =
            'All lives are pooled per team. Every player kill reduces the team pool. The last team with lives remaining wins. On timeout, the team with the most lives wins.';
      case _GameModePreset.kingOfTheHill:
        text =
            'Unlimited lives. The hill is placed at the center of all starting GPS positions. Every 3 seconds a team member is inside the hill, that team scores a point. Highest score when time runs out wins.';
      case _GameModePreset.freeForAll:
        text =
            'Every player for themselves — no friendly fire. The player with the most points when time runs out (or the last one alive) wins.';
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final serverPalette = teamPaletteFor('Red');
    final serverBgColors = serverPalette.background(brightness);
    final rulesPanelColor = serverPalette.secondary.withValues(
      alpha: brightness == Brightness.dark ? 0.2 : 0.18,
    );
    final rulesPanelBorder = serverPalette.primary.withValues(
      alpha: brightness == Brightness.dark ? 0.4 : 0.25,
    );
    final snapshot = _snapshot;
    final players = snapshot?.players.values.toList() ?? const <PlayerState>[];
    final joinEndpoint = PeerEndpoint(
      host: _advertisedHostController.text.trim().isEmpty
          ? '127.0.0.1'
          : _advertisedHostController.text.trim(),
      port: _serverPort,
    );
    final joinCode = JoinCodeCodec.encode(joinEndpoint);
    final scheduledStartAt = snapshot?.scheduledGameStartAt;
    final countdown = scheduledStartAt?.difference(DateTime.now());
    final countdownLabel = countdown == null
        ? null
        : _formatCountdown(countdown);
    final readyTeamLeadCount = snapshot?.readyTeamLeadIds.length ?? 0;
    final teamLeadCount = snapshot?.teamLeadCount ?? 0;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: serverPalette.primary.withValues(
          alpha: brightness == Brightness.dark ? 0.9 : 0.8,
        ),
        foregroundColor: serverPalette.foreground(brightness),
        title: const Text('Server Console'),
        actions: const <Widget>[ThemeToggleButton()],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: serverBgColors,
          ),
        ),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Text('Status: $_status'),
            const SizedBox(height: 8),
            Text(
              'Game phase: ${snapshot?.gamePhase.name ?? GamePhase.setup.name}',
            ),
            if (countdownLabel != null)
              Text(
                'Start countdown: $countdownLabel • Team Leads ready: $readyTeamLeadCount/$teamLeadCount',
              ),
            const Divider(height: 24),
            TextField(
              controller: _serverNameController,
              decoration: const InputDecoration(
                labelText: 'Server display name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Network mode',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: <Widget>[
                ChoiceChip(
                  label: const Text(_lanMode),
                  avatar: const Icon(Icons.wifi),
                  selected: _networkMode == _lanMode,
                  onSelected: (_) => _setNetworkMode(_lanMode),
                ),
                ChoiceChip(
                  label: const Text(_onlineMode),
                  avatar: const Icon(Icons.public),
                  selected: _networkMode == _onlineMode,
                  onSelected: (_) => _setNetworkMode(_onlineMode),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _networkMode == _lanMode
                  ? 'LAN: players must be on the same local network.'
                  : 'Online: players can join from outside your network using your public host/IP.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _advertisedHostController,
              readOnly: _networkMode == _lanMode,
              decoration: InputDecoration(
                labelText: _networkMode == _lanMode
                    ? 'Advertised LAN IP'
                    : 'Advertised public host / IP',
                helperText: _networkMode == _lanMode
                    ? 'Auto-detected for players on the same network.'
                    : 'Use your public IP/domain and forward UDP port 7777.',
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) {
                setState(() {});
              },
            ),
            if (_networkMode == _lanMode) ...<Widget>[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _detectAndSetLocalIp,
                  icon: const Icon(Icons.sync),
                  label: const Text('Detect LAN IP Again'),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Card(
              color: serverPalette.secondary.withValues(
                alpha: brightness == Brightness.dark ? 0.18 : 0.24,
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Lobby join code',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      joinCode,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Players can paste this code instead of entering an IP address.',
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: joinCode));
                        if (!mounted) {
                          return;
                        }
                        setState(() {
                          _status = 'Join code copied to clipboard.';
                        });
                      },
                      icon: const Icon(Icons.copy),
                      label: const Text('Copy Join Code'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: rulesPanelColor,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: rulesPanelBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Server rules',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      ChoiceChip(
                        label: const Text('Time'),
                        selected: _selectedPreset == _GameModePreset.time,
                        onSelected: (_) => _applyPreset(_GameModePreset.time),
                      ),
                      ChoiceChip(
                        label: const Text('Lives'),
                        selected: _selectedPreset == _GameModePreset.lives,
                        onSelected: (_) => _applyPreset(_GameModePreset.lives),
                      ),
                      ChoiceChip(
                        label: const Text('Team Lives'),
                        selected: _selectedPreset == _GameModePreset.teamLives,
                        onSelected: (_) =>
                            _applyPreset(_GameModePreset.teamLives),
                      ),
                      ChoiceChip(
                        label: const Text('King of the Hill'),
                        selected:
                            _selectedPreset == _GameModePreset.kingOfTheHill,
                        onSelected: (_) =>
                            _applyPreset(_GameModePreset.kingOfTheHill),
                      ),
                      ChoiceChip(
                        label: const Text('Free for All'),
                        selected: _selectedPreset == _GameModePreset.freeForAll,
                        onSelected: (_) =>
                            _applyPreset(_GameModePreset.freeForAll),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  _buildModeDescription(_selectedPreset),
                  const SizedBox(height: 8),
                  if (_selectedPreset != _GameModePreset.kingOfTheHill) ...<Widget>[
                    Text(
                      _selectedPreset == _GameModePreset.teamLives
                          ? 'Team lives pool: ${_maxLives.round()}'
                          : 'Max lives: ${_maxLives.round()}',
                    ),
                    Slider(
                      value: _maxLives,
                      min: 1,
                      max: 20,
                      divisions: 19,
                      label: _maxLives.round().toString(),
                      onChanged: (value) {
                        setState(() {
                          _maxLives = value;
                        });
                      },
                    ),
                  ],
                  if (_selectedPreset == _GameModePreset.kingOfTheHill) ...<Widget>[
                    Text(
                      'Hill radius: ${_hillRadiusMeters.toStringAsFixed(1)} m',
                    ),
                    Slider(
                      value: _hillRadiusMeters,
                      min: 0.5,
                      max: 5.0,
                      divisions: 9,
                      label: '${_hillRadiusMeters.toStringAsFixed(1)} m',
                      onChanged: (value) {
                        setState(() {
                          _hillRadiusMeters =
                              (value / 0.5).round() * 0.5;
                        });
                      },
                    ),
                  ],
                  Text('Magazine size: ${_magazineSize.round()}'),
                  Slider(
                    value: _magazineSize,
                    min: 1,
                    max: 60,
                    divisions: 59,
                    label: _magazineSize.round().toString(),
                    onChanged: (value) {
                      setState(() {
                        _magazineSize = value;
                      });
                    },
                  ),
                  Text('Reload time: ${_reloadTimeSeconds.round()} seconds'),
                  Slider(
                    value: _reloadTimeSeconds,
                    min: 0,
                    max: 10,
                    divisions: 10,
                    label: _reloadTimeSeconds.round().toString(),
                    onChanged: (value) {
                      setState(() {
                        _reloadTimeSeconds = value;
                      });
                    },
                  ),
                  Text('Match length: ${_matchLength.round()} minutes'),
                  Slider(
                    value: _matchLength,
                    min: 5,
                    max: 30,
                    divisions: 25,
                    label: _matchLength.round().toString(),
                    onChanged: (value) {
                      setState(() {
                        _matchLength = value;
                      });
                    },
                  ),
                  Text(
                    'Respawn delay: ${_respawnDelaySeconds.round()} seconds',
                  ),
                  Slider(
                    value: _respawnDelaySeconds,
                    min: 0,
                    max: 15,
                    divisions: 15,
                    label: _respawnDelaySeconds.round().toString(),
                    onChanged: (value) {
                      setState(() {
                        _respawnDelaySeconds = value;
                      });
                    },
                  ),
                  Text(
                    'Respawn mode: ${_respawnMode == RespawnMode.onDeath ? 'Start timer on death' : 'Start timer at team base'}',
                  ),
                  SegmentedButton<RespawnMode>(
                    segments: const <ButtonSegment<RespawnMode>>[
                      ButtonSegment<RespawnMode>(
                        value: RespawnMode.onDeath,
                        icon: Icon(Icons.timer),
                        label: Text('On Death'),
                      ),
                      ButtonSegment<RespawnMode>(
                        value: RespawnMode.atTeamBase,
                        icon: Icon(Icons.home_work),
                        label: Text('At Team Base'),
                      ),
                    ],
                    selected: <RespawnMode>{_respawnMode},
                    onSelectionChanged: (selection) {
                      setState(() {
                        _respawnMode = selection.first;
                      });
                    },
                  ),
                  if (_respawnMode == RespawnMode.atTeamBase)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        'Team base is a 2m radius around the Team Lead GPS position captured at game start.',
                      ),
                    ),
                  Text(
                    _itemSpawnDisabled
                        ? 'Item spawn rate: never'
                        : 'Item spawn rate: ${_itemSpawnRateSeconds.round()} seconds',
                  ),
                  Slider(
                    value: _itemSpawnDisabled
                        ? _itemSpawnMinSeconds
                        : _itemSpawnRateSeconds,
                    min: _itemSpawnMinSeconds,
                    max: _itemSpawnMaxSeconds,
                    divisions:
                        ((_itemSpawnMaxSeconds - _itemSpawnMinSeconds) ~/
                        _itemSpawnStepSeconds),
                    label: _itemSpawnDisabled
                        ? 'never'
                        : _itemSpawnRateSeconds.round().toString(),
                    onChanged: (value) {
                      setState(() {
                        _itemSpawnRateSeconds = _normalizeItemSpawnRate(value);
                      });
                    },
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: _itemSpawnDisabled
                          ? null
                          : () {
                              setState(() {
                                _itemSpawnRateSeconds =
                                    _itemSpawnDisabledSeconds;
                              });
                            },
                      icon: const Icon(Icons.block),
                      label: const Text('No Item Spawn'),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Friendly fire'),
                    value: _friendlyFire,
                    onChanged: (value) {
                      setState(() {
                        _friendlyFire = value;
                      });
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Allow joining after game start'),
                    subtitle: const Text(
                      'Players can join while match is running',
                    ),
                    value: _allowMidGameJoin,
                    onChanged: (value) {
                      setState(() {
                        _allowMidGameJoin = value;
                      });
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Only Team Leads can send team voice'),
                    subtitle: const Text('Default: on'),
                    value: _teamLeadVoiceOnly,
                    onChanged: (value) {
                      setState(() {
                        _teamLeadVoiceOnly = value;
                      });
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show other players on map'),
                    subtitle: const Text(
                      'If off, players only see teammates on the map.',
                    ),
                    value: _showOtherPlayersOnMap,
                    onChanged: (value) {
                      setState(() {
                        _showOtherPlayersOnMap = value;
                      });
                    },
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        setState(() {
                          _teamLeadVoiceOnly = false;
                        });
                      },
                      icon: const Icon(Icons.record_voice_over),
                      label: const Text('Allow All Players To Talk'),
                    ),
                  ),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: <Widget>[
                      FilledButton.icon(
                        onPressed: _openLobby,
                        icon: const Icon(Icons.door_front_door),
                        label: const Text('Open Lobby'),
                      ),
                      FilledButton(
                        onPressed: _applyServerRules,
                        child: const Text('Save Rules'),
                      ),
                      FilledButton(
                        onPressed: _queueGameStart,
                        child: Text(
                          scheduledStartAt == null
                              ? 'Start In 60s'
                              : 'Restart 60s Timer',
                        ),
                      ),
                      OutlinedButton(
                        onPressed: _service.endGame,
                        child: const Text('End Game'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(height: 24),
            Text('Players (${players.length})'),
            const SizedBox(height: 8),
            ...players.map(
              (player) => ListTile(
                title: Text(player.name),
                subtitle: Text(
                  'group=${player.group} gun=${player.gunConnected ? 'connected' : 'not connected'} '
                  'role=${player.playerClass == 'Team Lead' ? 'Team Lead' : 'Assult'} score=${player.score} lives hit=${player.hitsTaken}',
                ),
                trailing: player.isHost ? const Icon(Icons.shield) : null,
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
