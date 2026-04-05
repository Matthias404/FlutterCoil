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

enum _GameModePreset { time, life, kingOfTheHill, freeForAll }

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
  double _matchLength = 10;
  double _maxPlayers = 8;
  double _respawnDelaySeconds = 3;
  double _itemSpawnRateSeconds = _itemSpawnMinSeconds;
  _GameModePreset _selectedPreset = _GameModePreset.time;
  RespawnMode _respawnMode = RespawnMode.onDeath;
  bool _friendlyFire = false;
  bool _allowMidGameJoin = true;
  bool _teamLeadVoiceOnly = true;
  bool _showOtherPlayersOnMap = true;

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
        _snapshot = snapshot;
        _maxLives = snapshot.lobbyRules.maxLives.toDouble();
        _matchLength = snapshot.lobbyRules.matchLengthMinutes.toDouble();
        _maxPlayers = snapshot.lobbyRules.maxPlayers.toDouble();
        _respawnDelaySeconds = snapshot.lobbyRules.respawnDelaySeconds
            .toDouble();
        _itemSpawnRateSeconds = _normalizeItemSpawnRate(
          snapshot.lobbyRules.itemSpawnRateSeconds.toDouble(),
        );
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
        case _GameModePreset.life:
          _matchLength = 10;
          _maxLives = 3;
          _respawnDelaySeconds = 0;
          _itemSpawnRateSeconds = 45;
          _friendlyFire = false;
        case _GameModePreset.kingOfTheHill:
          _matchLength = 12;
          _maxLives = 15;
          _respawnDelaySeconds = 2;
          _itemSpawnRateSeconds = 30;
          _friendlyFire = false;
        case _GameModePreset.freeForAll:
          _matchLength = 10;
          _maxLives = 8;
          _respawnDelaySeconds = 2;
          _itemSpawnRateSeconds = 45;
          _friendlyFire = true;
      }

      _itemSpawnRateSeconds = _normalizeItemSpawnRate(_itemSpawnRateSeconds);
      _status =
          '${preset == _GameModePreset.time
              ? 'Time'
              : preset == _GameModePreset.life
              ? 'Life'
              : preset == _GameModePreset.kingOfTheHill
              ? 'King of the Hill'
              : 'Free for All'} preset selected. Save rules to apply.';
    });
  }

  Future<void> _applyServerRules() async {
    await _service.updateLocalProfile(name: _serverNameController.text.trim());
    await _service.updateLobbyRules(
      LobbyRules(
        maxLives: _maxLives.round(),
        matchLengthMinutes: _matchLength.round(),
        maxPlayers: _maxPlayers.round(),
        respawnDelaySeconds: _respawnDelaySeconds.round(),
        itemSpawnRateSeconds: _itemSpawnDisabled
            ? _itemSpawnDisabledSeconds.round()
            : _normalizeItemSpawnRate(_itemSpawnRateSeconds).round(),
        respawnMode: _respawnMode,
        baseRadiusMeters: 2.0,
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
                        label: const Text('Life'),
                        selected: _selectedPreset == _GameModePreset.life,
                        onSelected: (_) => _applyPreset(_GameModePreset.life),
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
                  const SizedBox(height: 8),
                  Text('Max lives: ${_maxLives.round()}'),
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
                  Text('Max players: ${_maxPlayers.round()}'),
                  Slider(
                    value: _maxPlayers,
                    min: 2,
                    max: 20,
                    divisions: 18,
                    label: _maxPlayers.round().toString(),
                    onChanged: (value) {
                      setState(() {
                        _maxPlayers = value;
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
