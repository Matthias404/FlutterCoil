import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart' hide PlayerState;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import 'network/game_network_service.dart';
import 'network/join_code.dart';
import 'network/peer_directory.dart';
import 'network/transport.dart';
import 'network/udp_transport.dart';
import 'screens/player/player_game_test_screen.dart';
import 'screens/player/player_screen.dart';
import 'screens/player/player_screen_with_code.dart';
import 'screens/server/server_screen.dart';
import 'utils/helpers.dart';

void main() {
  runApp(const LaserTagApp());
}

class LaserTagApp extends StatelessWidget {
  const LaserTagApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LaserTag Lobby',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.red),
      ),
      home: const StartScreen(),
    );
  }
}

class StartScreen extends StatelessWidget {
  const StartScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              Colors.red.shade900,
              Colors.orange.shade700,
              Colors.black,
            ],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                    Text(
                      'LaserTag Lobby',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.displaySmall?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Choose whether this device controls the match or joins it as a player.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: Colors.white70,
                          ),
                    ),
                    const SizedBox(height: 32),
                    FilledButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const ServerScreen(),
                          ),
                        );
                      },
                      icon: const Icon(Icons.settings_input_antenna),
                      label: const Text('Run As Server'),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white54),
                      ),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const GameBrowserScreen(),
                          ),
                        );
                      },
                      icon: const Icon(Icons.list),
                      label: const Text('Browse Available Games'),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white54),
                      ),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const PlayerScreen(),
                          ),
                        );
                      },
                      icon: const Icon(Icons.sports_esports),
                      label: const Text('Join As Player'),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white54),
                      ),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const PlayerGameTestScreen(),
                          ),
                        );
                      },
                      icon: const Icon(Icons.videogame_asset),
                      label: const Text('Test Player Screen (No Real Game)'),
                    ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class GameBrowserScreen extends StatefulWidget {
  const GameBrowserScreen({super.key});

  @override
  State<GameBrowserScreen> createState() => _GameBrowserScreenState();
}

class _GameBrowserScreenState extends State<GameBrowserScreen> {
  List<AdvertisedGame> _discoveredGames = <AdvertisedGame>[];
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    _searchForGames();
  }

  Future<void> _searchForGames() async {
    setState(() {
      _isSearching = true;
    });

    await Future<void>.delayed(const Duration(seconds: 2));

    if (!mounted) {
      return;
    }

    setState(() {
      _discoveredGames = <AdvertisedGame>[
        AdvertisedGame(
          name: 'Alice\'s Game',
          host: '192.168.1.100',
          port: 7777,
          playerCount: 3,
          maxPlayers: 8,
        ),
        AdvertisedGame(
          name: 'Quick Match',
          host: '192.168.1.105',
          port: 7777,
          playerCount: 1,
          maxPlayers: 4,
        ),
      ];
      _isSearching = false;
    });
  }

  Future<void> _joinGame(AdvertisedGame game) async {
    final endpoint = PeerEndpoint(host: game.host, port: game.port);
    final code = JoinCodeCodec.encode(endpoint);

    if (!mounted) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Game Found'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Server: ${game.name}'),
            Text('Players: ${game.playerCount}/${game.maxPlayers}'),
            const SizedBox(height: 12),
            const Text('Join code:'),
            SelectableText(code),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PlayerScreenWithCode(joinCode: code),
                ),
              );
            },
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Browse Games'),
      ),
      body: _isSearching
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Searching for available games...'),
                ],
              ),
            )
          : _discoveredGames.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      const Text('No games found.'),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _searchForGames,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Search Again'),
                      ),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: _discoveredGames
                      .map(
                        (game) => Card(
                          child: ListTile(
                            title: Text(game.name),
                            subtitle: Text(
                              '${game.playerCount}/${game.maxPlayers} players • ${game.host}:${game.port}',
                            ),
                            trailing: FilledButton(
                              onPressed: () => _joinGame(game),
                              child: const Text('Join'),
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _searchForGames,
        tooltip: 'Refresh',
        child: const Icon(Icons.refresh),
      ),
    );
  }
}

class AdvertisedGame {
  const AdvertisedGame({
    required this.name,
    required this.host,
    required this.port,
    required this.playerCount,
    required this.maxPlayers,
  });

  final String name;
  final String host;
  final int port;
  final int playerCount;
  final int maxPlayers;
}



class _PlayerScreenWithCodeState extends State<PlayerScreenWithCode> {
  static const int _playerPort = 7778;
  static const List<String> _teams = <String>['Red', 'Blue', 'Green', 'Yellow'];

  late final GameNetworkService _service;
  late final PeerDirectory _peerDirectory;
  late final TextEditingController _nameController;
  late final AudioRecorder _voiceRecorder;
  late final AudioPlayer _voicePlayer;
  StreamSubscription<TeamVoiceMessage>? _teamVoiceSub;
  NetworkSnapshot? _snapshot;
  String _status = 'Enter your player name and select team.';
  String _voiceStatus = 'Team voice ready.';
  bool _gunConnected = false;
  bool _isRecordingVoice = false;
  String _selectedTeam = 'Red';

  String _joinCodeNetworkHint() {
    try {
      final endpoint = JoinCodeCodec.decode(widget.joinCode);
      return buildNetworkHintForHost(endpoint.host);
    } on FormatException {
      return 'This join code is invalid.';
    }
  }

  @override
  void initState() {
    super.initState();

    _nameController = TextEditingController();
    _peerDirectory = PeerDirectory();
    _voiceRecorder = AudioRecorder();
    _voicePlayer = AudioPlayer();

    _service = GameNetworkService(
      transport: UdpNetworkTransport(localPort: _playerPort),
      localPlayerId: deviceId('player'),
      initialPlayerName: 'Player',
      initialPlayerGroup: _selectedTeam,
      peerDirectory: _peerDirectory,
    );

    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _service.start();
    _teamVoiceSub = _service.teamVoiceMessages.listen(_onTeamVoiceReceived);
    _service.updates.listen((snapshot) {
      if (!mounted) {
        return;
      }

      setState(() {
        _snapshot = snapshot;
      });
    });
  }

  @override
  void dispose() {
    _teamVoiceSub?.cancel();
    _nameController.dispose();
    _service.stop();
    unawaited(_voiceRecorder.dispose());
    unawaited(_voicePlayer.dispose());
    _peerDirectory.dispose();
    super.dispose();
  }

  Future<void> _toggleTeamVoice() async {
    final localPlayer = _snapshot?.players[_service.localPlayerId];
    final voiceOnlyTeamLead = _snapshot?.lobbyRules.teamLeadVoiceOnly ?? true;
    if (voiceOnlyTeamLead && localPlayer?.playerClass != 'Team Lead') {
      setState(() {
        _voiceStatus = 'Only Team Leads can send team voice right now.';
      });
      return;
    }

    if (_isRecordingVoice) {
      await _stopAndSendTeamVoice();
      return;
    }
    await _startTeamVoiceRecording();
  }

  Future<void> _startTeamVoiceRecording() async {
    final hasPermission = await _ensureMicrophonePermission();
    if (!hasPermission) {
      if (!mounted) {
        return;
      }
      setState(() {
        _voiceStatus = 'Microphone permission denied.';
      });
      return;
    }

    final cacheDir = await getTemporaryDirectory();
    final outputPath =
        '${cacheDir.path}/team_voice_${DateTime.now().microsecondsSinceEpoch}.m4a';

    await _voiceRecorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 64000,
        sampleRate: 16000,
      ),
      path: outputPath,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _isRecordingVoice = true;
      _voiceStatus = 'Recording team voice... tap again to send.';
    });
  }

  Future<void> _stopAndSendTeamVoice() async {
    final outputPath = await _voiceRecorder.stop();

    if (!mounted) {
      return;
    }

    setState(() {
      _isRecordingVoice = false;
    });

    if (outputPath == null) {
      setState(() {
        _voiceStatus = 'No voice clip captured.';
      });
      return;
    }

    final bytes = await File(outputPath).readAsBytes();
    if (bytes.isEmpty) {
      setState(() {
        _voiceStatus = 'Voice clip is empty.';
      });
      return;
    }

    final base64Audio = base64Encode(bytes);
    await _service.sendTeamVoiceMessage(
      audioBase64: base64Audio,
      mimeType: 'audio/mp4',
      durationMs: 0,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _voiceStatus = 'Voice message sent to $_selectedTeam team.';
    });
  }

  Future<void> _onTeamVoiceReceived(TeamVoiceMessage message) async {
    if (!mounted) {
      return;
    }

    try {
      final audioBytes = base64Decode(message.audioBase64);
      if (audioBytes.isEmpty) {
        return;
      }

      await _voicePlayer.play(BytesSource(audioBytes));

      if (!mounted) {
        return;
      }

      setState(() {
        _voiceStatus =
            'Voice from ${message.senderName} (${message.team}) played.';
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _voiceStatus = 'Could not play incoming team voice message.';
      });
    }
  }

  Future<void> _toggleGunConnection() async {
    final next = !_gunConnected;
    setState(() {
      _gunConnected = next;
      _status = next
          ? 'Gun linked in simulation mode. You can join the lobby now.'
          : 'Gun disconnected.';
    });
    await _service.updateLocalProfile(gunConnected: next);
  }

  Future<void> _joinLobby() async {
    final name = _nameController.text.trim();

    if (name.isEmpty) {
      setState(() {
        _status = 'Enter your player name before joining.';
      });
      return;
    }

    if (!_gunConnected) {
      setState(() {
        _status = 'Connect the Bluetooth gun before joining the game.';
      });
      return;
    }

    PeerEndpoint serverEndpoint;
    try {
      serverEndpoint = JoinCodeCodec.decode(widget.joinCode);
    } on FormatException catch (error) {
      setState(() {
        _status = error.message;
      });
      return;
    }

    _peerDirectory.replaceAll(<PeerEndpoint>[serverEndpoint]);

    await _service.updateLocalProfile(
      name: name,
      group: _selectedTeam,
      gunConnected: _gunConnected,
    );
    await _service.connect();

    if (!mounted) {
      return;
    }

    setState(() {
      _status = 'Joining lobby at ${serverEndpoint.host}:${serverEndpoint.port}';
    });
  }

  Widget _teamIcon(String team) {
    switch (team) {
      case 'Red':
        return const Icon(Icons.circle, color: Colors.red);
      case 'Blue':
        return const Icon(Icons.circle, color: Colors.blue);
      case 'Green':
        return const Icon(Icons.circle, color: Colors.green);
      case 'Yellow':
        return const Icon(Icons.circle, color: Colors.yellow);
      default:
        return const Icon(Icons.circle);
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final players = snapshot?.players.values.toList() ?? const <PlayerState>[];
    final networkHint = _joinCodeNetworkHint();
    final teamColors = _teamBackgroundColors(_selectedTeam);
    final localPlayer = snapshot?.players[_service.localPlayerId];
    final teamLeadVoiceOnly = snapshot?.lobbyRules.teamLeadVoiceOnly ?? true;
    final voiceLocked = teamLeadVoiceOnly && localPlayer?.playerClass != 'Team Lead';

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: teamColors.first.withValues(alpha: 0.9),
        foregroundColor: Colors.white,
        title: const Text('Player Setup'),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: teamColors,
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: LayoutBuilder(
              builder: (context, constraints) {
              final compact = constraints.maxHeight < 720;
              final previewCount = compact ? 2 : 4;
              final previewPlayers = players.take(previewCount).toList();

              final infoPanels = constraints.maxWidth < 420
                  ? Column(
                      children: <Widget>[
                        Expanded(
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text('Server rules', style: Theme.of(context).textTheme.titleSmall),
                                  const SizedBox(height: 6),
                                  Text('Phase: ${snapshot?.gamePhase.name ?? GamePhase.setup.name}'),
                                  Text('Max lives: ${snapshot?.lobbyRules.maxLives ?? 10}'),
                                  Text('Length: ${snapshot?.lobbyRules.matchLengthMinutes ?? 10} min'),
                                  Text('Friendly fire: ${snapshot?.lobbyRules.friendlyFire == true ? 'on' : 'off'}'),
                                  Text('Voice: ${snapshot?.lobbyRules.teamLeadVoiceOnly == false ? 'all players' : 'team leads only'}'),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text('Lobby players (${players.length})', style: Theme.of(context).textTheme.titleSmall),
                                  const SizedBox(height: 6),
                                  if (previewPlayers.isEmpty)
                                    const Text('No players connected yet.')
                                  else
                                    ...previewPlayers.map(
                                      (player) => Padding(
                                        padding: const EdgeInsets.only(bottom: 4),
                                        child: Row(
                                          children: <Widget>[
                                            (player as PlayerState?)?.isHost == true
                                              ? const Icon(Icons.shield, size: 14)
                                              : const SizedBox.shrink(),
                                            (player).isHost
                                              ? const SizedBox(width: 4)
                                              : const SizedBox.shrink(),
                                            Expanded(
                                              child: Text(
                                                '${player.name} • ${player.group} • ${player.playerClass == 'Team Lead' ? 'Team Lead' : 'Assult'} • ${player.gunConnected ? 'gun on' : 'gun off'}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  if (players.length > previewPlayers.length)
                                    Text('+${players.length - previewPlayers.length} more players'),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  : Row(
                      children: <Widget>[
                        Expanded(
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text('Server rules', style: Theme.of(context).textTheme.titleSmall),
                                  const SizedBox(height: 6),
                                  Text('Phase: ${snapshot?.gamePhase.name ?? GamePhase.setup.name}'),
                                  Text('Max lives: ${snapshot?.lobbyRules.maxLives ?? 10}'),
                                  Text('Length: ${snapshot?.lobbyRules.matchLengthMinutes ?? 10} min'),
                                  Text('Friendly fire: ${snapshot?.lobbyRules.friendlyFire == true ? 'on' : 'off'}'),
                                  Text('Voice: ${snapshot?.lobbyRules.teamLeadVoiceOnly == false ? 'all players' : 'team leads only'}'),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text('Lobby players (${players.length})', style: Theme.of(context).textTheme.titleSmall),
                                  const SizedBox(height: 6),
                                  if (previewPlayers.isEmpty)
                                    const Text('No players connected yet.')
                                  else
                                    ...previewPlayers.map(
                                      (player) => Padding(
                                        padding: const EdgeInsets.only(bottom: 4),
                                        child: Row(
                                          children: <Widget>[
                                            (player).isHost
                                              ? const Icon(Icons.shield, size: 14)
                                              : const SizedBox.shrink(),
                                            (player).isHost
                                              ? const SizedBox(width: 4)
                                              : const SizedBox.shrink(),
                                            Expanded(
                                              child: Text(
                                                '${player.name} • ${player.group} • ${player.playerClass == 'Team Lead' ? 'Team Lead' : 'Assult'} • ${player.gunConnected ? 'gun on' : 'gun off'}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  if (players.length > previewPlayers.length)
                                    Text('+${players.length - previewPlayers.length} more players'),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    );

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      'Status: $_status',
                      style: const TextStyle(color: Colors.white),
                      maxLines: compact ? 2 : 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      isDense: compact,
                      labelText: 'Player name',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _selectedTeam,
                          isDense: compact,
                          decoration: const InputDecoration(
                            labelText: 'Team',
                            border: OutlineInputBorder(),
                          ),
                          items: _teams
                              .map((team) => DropdownMenuItem<String>(
                                    value: team,
                                    child: Row(
                                      children: <Widget>[
                                        _teamIcon(team),
                                        const SizedBox(width: 8),
                                        Text(team),
                                      ],
                                    ),
                                  ))
                              .toList(),
                          onChanged: (team) {
                            if (team != null) {
                              setState(() {
                                _selectedTeam = team;
                              });
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _toggleGunConnection,
                          icon: Icon(_gunConnected ? Icons.bluetooth_connected : Icons.bluetooth),
                          label: Text(_gunConnected ? 'Gun On' : 'Connect Gun'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: TextEditingController(text: widget.joinCode),
                    readOnly: true,
                    maxLines: 1,
                    decoration: InputDecoration(
                      isDense: compact,
                      labelText: 'Lobby join code',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    networkHint,
                    maxLines: compact ? 2 : 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _joinLobby,
                    icon: const Icon(Icons.login),
                    label: const Text('Join Lobby'),
                  ),
                  const SizedBox(height: 6),
                  OutlinedButton.icon(
                    onPressed: _toggleTeamVoice,
                    icon: Icon(
                      voiceLocked
                          ? Icons.lock
                          : (_isRecordingVoice ? Icons.stop_circle_outlined : Icons.mic),
                    ),
                    label: Text(
                      voiceLocked
                          ? 'Team Voice Locked (Lead Only)'
                          : (_isRecordingVoice
                                ? 'Stop And Send Team Voice'
                                : 'Record Team Voice'),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _voiceStatus,
                    style: const TextStyle(color: Colors.white70),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Expanded(child: infoPanels),
                ],
              );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  static const int _playerPort = 7778;
  static const List<String> _teams = <String>['Red', 'Blue', 'Green', 'Yellow'];

  late final GameNetworkService _service;
  late final PeerDirectory _peerDirectory;
  late final TextEditingController _nameController;
  late final TextEditingController _joinCodeController;
  late final AudioRecorder _voiceRecorder;
  late final AudioPlayer _voicePlayer;
  StreamSubscription<TeamVoiceMessage>? _teamVoiceSub;
  NetworkSnapshot? _snapshot;
  String _status = 'Fill in your player profile.';
  String _voiceStatus = 'Team voice ready.';
  bool _gunConnected = false;
  bool _isRecordingVoice = false;
  String _selectedTeam = 'Red';

  String _joinCodeNetworkHint(String joinCode) {
    if (joinCode.trim().isEmpty) {
      return 'Paste a join code to see whether this game is LAN or online.';
    }

    try {
      final endpoint = JoinCodeCodec.decode(joinCode);
      return buildNetworkHintForHost(endpoint.host);
    } on FormatException {
      return 'Join code format looks invalid.';
    }
  }

  @override
  void initState() {
    super.initState();

    _nameController = TextEditingController();
    _joinCodeController = TextEditingController();
    _peerDirectory = PeerDirectory();
    _voiceRecorder = AudioRecorder();
    _voicePlayer = AudioPlayer();

    _service = GameNetworkService(
      transport: UdpNetworkTransport(localPort: _playerPort),
      localPlayerId: deviceId('player'),
      initialPlayerName: 'Player',
      initialPlayerGroup: _selectedTeam,
      peerDirectory: _peerDirectory,
    );

    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _service.start();
    _teamVoiceSub = _service.teamVoiceMessages.listen(_onTeamVoiceReceived);
    _service.updates.listen((snapshot) {
      if (!mounted) {
        return;
      }

      setState(() {
        _snapshot = snapshot;
      });
    });
  }

  @override
  void dispose() {
    _teamVoiceSub?.cancel();
    _nameController.dispose();
    _joinCodeController.dispose();
    _service.stop();
    unawaited(_voiceRecorder.dispose());
    unawaited(_voicePlayer.dispose());
    _peerDirectory.dispose();
    super.dispose();
  }

  Future<void> _toggleTeamVoice() async {
    final localPlayer = _snapshot?.players[_service.localPlayerId];
    final voiceOnlyTeamLead = _snapshot?.lobbyRules.teamLeadVoiceOnly ?? true;
    if (voiceOnlyTeamLead && localPlayer?.playerClass != 'Team Lead') {
      setState(() {
        _voiceStatus = 'Only Team Leads can send team voice right now.';
      });
      return;
    }

    if (_isRecordingVoice) {
      await _stopAndSendTeamVoice();
      return;
    }
    await _startTeamVoiceRecording();
  }

  Future<void> _startTeamVoiceRecording() async {
    final hasPermission = await _ensureMicrophonePermission();
    if (!hasPermission) {
      if (!mounted) {
        return;
      }
      setState(() {
        _voiceStatus = 'Microphone permission denied.';
      });
      return;
    }

    final cacheDir = await getTemporaryDirectory();
    final outputPath =
        '${cacheDir.path}/team_voice_${DateTime.now().microsecondsSinceEpoch}.m4a';

    await _voiceRecorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 64000,
        sampleRate: 16000,
      ),
      path: outputPath,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _isRecordingVoice = true;
      _voiceStatus = 'Recording team voice... tap again to send.';
    });
  }

  Future<void> _stopAndSendTeamVoice() async {
    final outputPath = await _voiceRecorder.stop();

    if (!mounted) {
      return;
    }

    setState(() {
      _isRecordingVoice = false;
    });

    if (outputPath == null) {
      setState(() {
        _voiceStatus = 'No voice clip captured.';
      });
      return;
    }

    final bytes = await File(outputPath).readAsBytes();
    if (bytes.isEmpty) {
      setState(() {
        _voiceStatus = 'Voice clip is empty.';
      });
      return;
    }

    final base64Audio = base64Encode(bytes);
    await _service.sendTeamVoiceMessage(
      audioBase64: base64Audio,
      mimeType: 'audio/mp4',
      durationMs: 0,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _voiceStatus = 'Voice message sent to $_selectedTeam team.';
    });
  }

  Future<void> _onTeamVoiceReceived(TeamVoiceMessage message) async {
    if (!mounted) {
      return;
    }

    try {
      final audioBytes = base64Decode(message.audioBase64);
      if (audioBytes.isEmpty) {
        return;
      }

      await _voicePlayer.play(BytesSource(audioBytes));

      if (!mounted) {
        return;
      }

      setState(() {
        _voiceStatus =
            'Voice from ${message.senderName} (${message.team}) played.';
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _voiceStatus = 'Could not play incoming team voice message.';
      });
    }
  }

  Future<void> _toggleGunConnection() async {
    final next = !_gunConnected;
    setState(() {
      _gunConnected = next;
      _status = next
          ? 'Gun linked in simulation mode. You can join the lobby now.'
          : 'Gun disconnected.';
    });
    await _service.updateLocalProfile(gunConnected: next);
  }

  Future<void> _joinLobby() async {
    final name = _nameController.text.trim();
    final joinCode = _joinCodeController.text.trim();

    if (name.isEmpty) {
      setState(() {
        _status = 'Enter your player name before joining.';
      });
      return;
    }

    if (!_gunConnected) {
      setState(() {
        _status = 'Connect the Bluetooth gun before joining the game.';
      });
      return;
    }

    PeerEndpoint serverEndpoint;
    try {
      serverEndpoint = JoinCodeCodec.decode(joinCode);
    } on FormatException catch (error) {
      setState(() {
        _status = error.message;
      });
      return;
    }

    _peerDirectory.replaceAll(<PeerEndpoint>[serverEndpoint]);

    await _service.updateLocalProfile(
      name: name,
      group: _selectedTeam,
      gunConnected: _gunConnected,
    );
    await _service.connect();

    if (!mounted) {
      return;
    }

    setState(() {
      _status = 'Joining lobby at ${serverEndpoint.host}:${serverEndpoint.port}';
    });
  }

  Widget _teamIcon(String team) {
    switch (team) {
      case 'Red':
        return const Icon(Icons.circle, color: Colors.red);
      case 'Blue':
        return const Icon(Icons.circle, color: Colors.blue);
      case 'Green':
        return const Icon(Icons.circle, color: Colors.green);
      case 'Yellow':
        return const Icon(Icons.circle, color: Colors.yellow);
      default:
        return const Icon(Icons.circle);
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final players = snapshot?.players.values.toList() ?? const <PlayerState>[];
    final networkHint = _joinCodeNetworkHint(_joinCodeController.text);
    final teamColors = _teamBackgroundColors(_selectedTeam);
    final localPlayer = snapshot?.players[_service.localPlayerId];
    final teamLeadVoiceOnly = snapshot?.lobbyRules.teamLeadVoiceOnly ?? true;
    final voiceLocked = teamLeadVoiceOnly && localPlayer?.playerClass != 'Team Lead';

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: teamColors.first.withValues(alpha: 0.9),
        foregroundColor: Colors.white,
        title: const Text('Player Setup'),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: teamColors,
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: LayoutBuilder(
              builder: (context, constraints) {
              final compact = constraints.maxHeight < 720;
              final previewCount = compact ? 2 : 4;
              final previewPlayers = players.take(previewCount).toList();

              final infoPanels = constraints.maxWidth < 420
                  ? Column(
                      children: <Widget>[
                        Expanded(
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text('Server rules', style: Theme.of(context).textTheme.titleSmall),
                                  const SizedBox(height: 6),
                                  Text('Phase: ${snapshot?.gamePhase.name ?? GamePhase.setup.name}'),
                                  Text('Max lives: ${snapshot?.lobbyRules.maxLives ?? 10}'),
                                  Text('Length: ${snapshot?.lobbyRules.matchLengthMinutes ?? 10} min'),
                                  Text('Friendly fire: ${snapshot?.lobbyRules.friendlyFire == true ? 'on' : 'off'}'),
                                  Text('Voice: ${snapshot?.lobbyRules.teamLeadVoiceOnly == false ? 'all players' : 'team leads only'}'),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text('Lobby players (${players.length})', style: Theme.of(context).textTheme.titleSmall),
                                  const SizedBox(height: 6),
                                  if (previewPlayers.isEmpty)
                                    const Text('No players connected yet.')
                                  else
                                    ...previewPlayers.map(
                                      (player) => Padding(
                                        padding: const EdgeInsets.only(bottom: 4),
                                        child: Row(
                                          children: <Widget>[
                                            player.isHost
                                              ? const Icon(Icons.shield, size: 14)
                                              : const SizedBox.shrink(),
                                            player.isHost
                                              ? const SizedBox(width: 4)
                                              : const SizedBox.shrink(),
                                            Expanded(
                                              child: Text(
                                                '${player.name} • ${player.group} • ${player.playerClass == 'Team Lead' ? 'Team Lead' : 'Assult'} • ${player.gunConnected ? 'gun on' : 'gun off'}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  if (players.length > previewPlayers.length)
                                    Text('+${players.length - previewPlayers.length} more players'),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  : Row(
                      children: <Widget>[
                        Expanded(
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text('Server rules', style: Theme.of(context).textTheme.titleSmall),
                                  const SizedBox(height: 6),
                                  Text('Phase: ${snapshot?.gamePhase.name ?? GamePhase.setup.name}'),
                                  Text('Max lives: ${snapshot?.lobbyRules.maxLives ?? 10}'),
                                  Text('Length: ${snapshot?.lobbyRules.matchLengthMinutes ?? 10} min'),
                                  Text('Friendly fire: ${snapshot?.lobbyRules.friendlyFire == true ? 'on' : 'off'}'),
                                  Text('Voice: ${snapshot?.lobbyRules.teamLeadVoiceOnly == false ? 'all players' : 'team leads only'}'),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text('Lobby players (${players.length})', style: Theme.of(context).textTheme.titleSmall),
                                  const SizedBox(height: 6),
                                  if (previewPlayers.isEmpty)
                                    const Text('No players connected yet.')
                                  else
                                    ...previewPlayers.map(
                                      (player) => Padding(
                                        padding: const EdgeInsets.only(bottom: 4),
                                        child: Row(
                                          children: <Widget>[
                                            player.isHost
                                              ? const Icon(Icons.shield, size: 14)
                                              : const SizedBox.shrink(),
                                            player.isHost
                                              ? const SizedBox(width: 4)
                                              : const SizedBox.shrink(),
                                            Expanded(
                                              child: Text(
                                                '${player.name} • ${player.group} • ${player.playerClass == 'Team Lead' ? 'Team Lead' : 'Assult'} • ${player.gunConnected ? 'gun on' : 'gun off'}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  if (players.length > previewPlayers.length)
                                    Text('+${players.length - previewPlayers.length} more players'),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    );

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      'Status: $_status',
                      style: const TextStyle(color: Colors.white),
                      maxLines: compact ? 2 : 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      isDense: compact,
                      labelText: 'Player name',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _selectedTeam,
                          isDense: compact,
                          decoration: const InputDecoration(
                            labelText: 'Team',
                            border: OutlineInputBorder(),
                          ),
                          items: _teams
                              .map((team) => DropdownMenuItem<String>(
                                    value: team,
                                    child: Row(
                                      children: <Widget>[
                                        _teamIcon(team),
                                        const SizedBox(width: 8),
                                        Text(team),
                                      ],
                                    ),
                                  ))
                              .toList(),
                          onChanged: (team) {
                            if (team != null) {
                              setState(() {
                                _selectedTeam = team;
                              });
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _toggleGunConnection,
                          icon: Icon(_gunConnected ? Icons.bluetooth_connected : Icons.bluetooth),
                          label: Text(_gunConnected ? 'Gun On' : 'Connect Gun'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _joinCodeController,
                    decoration: InputDecoration(
                      isDense: compact,
                      labelText: 'Lobby join code',
                      helperText: compact ? null : 'Paste the code shown on the server device.',
                      border: const OutlineInputBorder(),
                    ),
                    maxLines: 1,
                    onChanged: (_) {
                      setState(() {});
                    },
                  ),
                  const SizedBox(height: 6),
                  Text(
                    networkHint,
                    maxLines: compact ? 2 : 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const GameBrowserScreen(),
                              ),
                            );
                          },
                          icon: const Icon(Icons.wifi_find),
                          label: const Text('Search LAN'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _joinLobby,
                          icon: const Icon(Icons.login),
                          label: const Text('Join Lobby'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  OutlinedButton.icon(
                    onPressed: _toggleTeamVoice,
                    icon: Icon(
                      voiceLocked
                          ? Icons.lock
                          : (_isRecordingVoice ? Icons.stop_circle_outlined : Icons.mic),
                    ),
                    label: Text(
                      voiceLocked
                          ? 'Team Voice Locked (Lead Only)'
                          : (_isRecordingVoice
                                ? 'Stop And Send Team Voice'
                                : 'Record Team Voice'),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _voiceStatus,
                    style: const TextStyle(color: Colors.white70),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Expanded(child: infoPanels),
                ],
              );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class PlayerGameTestScreen extends StatefulWidget {
  const PlayerGameTestScreen({super.key});

  @override
  State<PlayerGameTestScreen> createState() => _PlayerGameTestScreenState();
}

class _PlayerGameTestScreenState extends State<PlayerGameTestScreen> {
  static const int _maxLives = 10;
  static const int _startingAmmo = 30;
  static const int _matchLengthSeconds = 300;
  static const double _radarRangeMeters = 80;
  static const double _itemPickupRadiusMeters = 1;
  static const double _itemMinPairDistanceMeters = 10;
  static const double _itemFallbackSpawnDistanceMeters = 10;
  static const int _maxSpawnedItems = 8;
  static const int _itemSpawnIntervalSeconds = 6;
  static const double _playerLatitude = 48.137154;
  static const double _playerLongitude = 11.576124;

  Timer? _matchTimer;
  int _timeRemaining = _matchLengthSeconds;
  int _livesLeft = _maxLives;
  int _ammoLeft = _startingAmmo;
  int _score = 0;
  int _hitsTaken = 0;
  int _shotsFired = 0;
  bool _isGameRunning = true;
  String _eventText = 'Match started. Good luck, player!';
  final String _playerName = 'Player One';
  final String _team = 'Red Team';
  String _fireType = 'Burst';
  String _role = 'Assult';
  bool _shieldActive = false;
  bool _healingBoostActive = false;
  double _radarSweepDegrees = 0;
  int _tick = 0;
  final math.Random _random = math.Random();
  List<_RadarContact> _contacts = <_RadarContact>[
    const _RadarContact(id: 'P2', team: 'Blue Team', xMeters: 24, yMeters: -10),
    const _RadarContact(id: 'P3', team: 'Green Team', xMeters: -18, yMeters: 32),
    const _RadarContact(id: 'P4', team: 'Yellow Team', xMeters: 45, yMeters: 8),
    const _RadarContact(id: 'P5', team: 'Red Team', xMeters: -35, yMeters: -22),
  ];
  List<_MapItem> _items = <_MapItem>[];
  late final AudioRecorder _teamVoiceRecorder;
  late final AudioPlayer _teamVoicePlayer;
  bool _isRecordingTeamVoice = false;
  String _teamVoiceStatus = 'Team voice ready.';

  @override
  void initState() {
    super.initState();
    _teamVoiceRecorder = AudioRecorder();
    _teamVoicePlayer = AudioPlayer();
    _startTimer();
  }

  @override
  void dispose() {
    _matchTimer?.cancel();
    unawaited(_teamVoiceRecorder.dispose());
    unawaited(_teamVoicePlayer.dispose());
    super.dispose();
  }

  Future<void> _toggleTeamVoiceRecording() async {
    if (_isRecordingTeamVoice) {
      await _stopAndPlayTeamVoice();
      return;
    }
    await _startTeamVoiceRecording();
  }

  Future<void> _startTeamVoiceRecording() async {
    final hasPermission = await _ensureMicrophonePermission();
    if (!hasPermission) {
      if (!mounted) {
        return;
      }
      setState(() {
        _teamVoiceStatus = 'Microphone permission denied.';
      });
      return;
    }

    final cacheDir = await getTemporaryDirectory();
    final outputPath =
        '${cacheDir.path}/team_voice_test_${DateTime.now().microsecondsSinceEpoch}.m4a';

    await _teamVoiceRecorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 64000,
        sampleRate: 16000,
      ),
      path: outputPath,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _isRecordingTeamVoice = true;
      _teamVoiceStatus = 'Recording... tap again to send to team.';
    });
  }

  Future<void> _stopAndPlayTeamVoice() async {
    final outputPath = await _teamVoiceRecorder.stop();
    if (!mounted) {
      return;
    }

    setState(() {
      _isRecordingTeamVoice = false;
    });

    if (outputPath == null) {
      setState(() {
        _teamVoiceStatus = 'No voice clip captured.';
      });
      return;
    }

    final bytes = await File(outputPath).readAsBytes();
    if (bytes.isEmpty) {
      setState(() {
        _teamVoiceStatus = 'Voice clip is empty.';
      });
      return;
    }

    final encoded = base64Encode(bytes);
    await _teamVoicePlayer.play(BytesSource(base64Decode(encoded)));

    if (!mounted) {
      return;
    }

    setState(() {
      _teamVoiceStatus = 'Team voice clip sent and played back (simulation).';
    });
  }

  void _startTimer() {
    _matchTimer?.cancel();
    _matchTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      if (!_isGameRunning) {
        return;
      }

      _tick += 1;
      _radarSweepDegrees = (_radarSweepDegrees + 18) % 360;
      _animateContacts();
      _spawnRandomItemIfNeeded();
      _collectNearbyItems();

      if (_timeRemaining <= 1) {
        setState(() {
          _timeRemaining = 0;
          _isGameRunning = false;
          _eventText = 'Match ended. Time is up!';
        });
        timer.cancel();
        return;
      }

      setState(() {
        _timeRemaining -= 1;
      });
    });
  }

  void _animateContacts() {
    _contacts = _contacts.asMap().entries.map((entry) {
      final index = entry.key;
      final contact = entry.value;
      final driftX = math.sin((_tick + index * 11) / 4) * 1.8;
      final driftY = math.cos((_tick + index * 7) / 4) * 1.8;
      final nextX = (contact.xMeters + driftX).clamp(-_radarRangeMeters, _radarRangeMeters);
      final nextY = (contact.yMeters + driftY).clamp(-_radarRangeMeters, _radarRangeMeters);
      return _RadarContact(
        id: contact.id,
        team: contact.team,
        xMeters: nextX,
        yMeters: nextY,
      );
    }).toList();
  }

  void _fireShot() {
    if (!_isGameRunning) {
      setState(() {
        _eventText = 'Cannot fire. Match is not running.';
      });
      return;
    }

    if (_ammoLeft <= 0) {
      setState(() {
        _eventText = 'Out of ammo. Reload first.';
      });
      return;
    }

    setState(() {
      _ammoLeft -= 1;
      _shotsFired += 1;
      _eventText = 'Shot fired.';
    });
  }

  void _registerHit() {
    if (!_isGameRunning) {
      setState(() {
        _eventText = 'Hit ignored. Match is not running.';
      });
      return;
    }

    setState(() {
      _hitsTaken += 1;
      _livesLeft = (_livesLeft - 1).clamp(0, _maxLives);
      _eventText = 'You got hit!';
      if (_livesLeft == 0) {
        _isGameRunning = false;
        _eventText = 'You are out. Match over for this player.';
      }
    });
  }

  void _registerTag() {
    if (!_isGameRunning) {
      setState(() {
        _eventText = 'Tag ignored. Match is not running.';
      });
      return;
    }

    setState(() {
      _score += 100;
      _eventText = 'Tag confirmed! +100 points';
    });
  }

  void _spawnRandomItemIfNeeded() {
    if (!_isGameRunning) {
      return;
    }
    if (_tick % _itemSpawnIntervalSeconds != 0) {
      return;
    }
    if (_items.length >= _maxSpawnedItems) {
      return;
    }

    final players = _allSimulatedPlayers();
    if (players.isEmpty) {
      return;
    }

    final pair = _randomPlayerPairAtLeastDistance(
      players,
      _itemMinPairDistanceMeters,
    );

    late final double spawnX;
    late final double spawnY;

    if (pair != null) {
      spawnX = (pair.$1.xMeters + pair.$2.xMeters) / 2;
      spawnY = (pair.$1.yMeters + pair.$2.yMeters) / 2;
    } else {
      final anchor = players[_random.nextInt(players.length)];
      final angle = _random.nextDouble() * 2 * math.pi;
      spawnX = anchor.xMeters + math.cos(angle) * _itemFallbackSpawnDistanceMeters;
      spawnY = anchor.yMeters + math.sin(angle) * _itemFallbackSpawnDistanceMeters;
    }

    final category =
        _ItemCategory.values[_random.nextInt(_ItemCategory.values.length)];

    _items = <_MapItem>[
      ..._items,
      _MapItem(
        id: 'item_${_tick}_${_random.nextInt(1 << 20)}',
        category: category,
        xMeters: spawnX.clamp(-_radarRangeMeters, _radarRangeMeters),
        yMeters: spawnY.clamp(-_radarRangeMeters, _radarRangeMeters),
      ),
    ];
    _eventText = 'Spawned ${_itemCategoryLabel(category)} item.';
  }

  void _collectNearbyItems() {
    if (_items.isEmpty) {
      return;
    }

    final players = _allSimulatedPlayers();
    final remaining = <_MapItem>[];
    String? latestPickupText;

    for (final item in _items) {
      final collector = _nearestCollectorWithinRadius(item, players);
      if (collector == null) {
        remaining.add(item);
        continue;
      }

      if (collector.id == _playerName) {
        _applyItemToLocalPlayer(item.category);
      }

      latestPickupText =
          '${collector.id} picked ${_itemCategoryLabel(item.category)} item.';
    }

    _items = remaining;
    if (latestPickupText != null) {
      _eventText = latestPickupText;
    }
  }

  void _applyItemToLocalPlayer(_ItemCategory category) {
    switch (category) {
      case _ItemCategory.healing:
        _livesLeft = (_livesLeft + 2).clamp(0, _maxLives);
      case _ItemCategory.armor:
        _shieldActive = true;
      case _ItemCategory.damage:
        _ammoLeft = (_ammoLeft + 8).clamp(0, _startingAmmo);
        _score += 25;
      case _ItemCategory.special:
        _score += 150;
        _healingBoostActive = true;
    }
  }

  _SimulatedPlayer? _nearestCollectorWithinRadius(
    _MapItem item,
    List<_SimulatedPlayer> players,
  ) {
    _SimulatedPlayer? nearest;
    var nearestDistance = double.infinity;

    for (final player in players) {
      final distance = _distanceMeters(
        item.xMeters,
        item.yMeters,
        player.xMeters,
        player.yMeters,
      );
      if (distance <= _itemPickupRadiusMeters && distance < nearestDistance) {
        nearest = player;
        nearestDistance = distance;
      }
    }

    return nearest;
  }

  List<_SimulatedPlayer> _allSimulatedPlayers() {
    return <_SimulatedPlayer>[
      const _SimulatedPlayer(id: 'Player One', team: 'Red Team', xMeters: 0, yMeters: 0),
      ..._contacts.map(
        (contact) => _SimulatedPlayer(
          id: contact.id,
          team: contact.team,
          xMeters: contact.xMeters,
          yMeters: contact.yMeters,
        ),
      ),
    ];
  }

  (_SimulatedPlayer, _SimulatedPlayer)? _randomPlayerPairAtLeastDistance(
    List<_SimulatedPlayer> players,
    double minDistance,
  ) {
    if (players.length < 2) {
      return null;
    }

    final validPairs = <(_SimulatedPlayer, _SimulatedPlayer)>[];
    for (var i = 0; i < players.length - 1; i++) {
      for (var j = i + 1; j < players.length; j++) {
        final first = players[i];
        final second = players[j];
        final distance = _distanceMeters(
          first.xMeters,
          first.yMeters,
          second.xMeters,
          second.yMeters,
        );
        if (distance >= minDistance) {
          validPairs.add((first, second));
        }
      }
    }

    if (validPairs.isEmpty) {
      return null;
    }
    return validPairs[_random.nextInt(validPairs.length)];
  }

  void _reload() {
    if (!_isGameRunning) {
      setState(() {
        _eventText = 'Cannot reload. Match is not running.';
      });
      return;
    }

    setState(() {
      _ammoLeft = _startingAmmo;
      _eventText = 'Reload complete.';
    });
  }

  void _toggleShieldBonus() {
    setState(() {
      _shieldActive = !_shieldActive;
      _eventText = _shieldActive ? 'Shield bonus enabled.' : 'Shield bonus disabled.';
    });
  }

  void _toggleHealingBonus() {
    setState(() {
      _healingBoostActive = !_healingBoostActive;
      _eventText = _healingBoostActive ? 'Healing bonus enabled.' : 'Healing bonus disabled.';
    });
  }

  void _cycleFireType() {
    const types = <String>['Single', 'Burst', 'Auto'];
    final currentIndex = types.indexOf(_fireType);
    final nextIndex = (currentIndex + 1) % types.length;
    setState(() {
      _fireType = types[nextIndex];
      _eventText = 'Fire type switched to $_fireType.';
    });
  }

  void _cycleRole() {
    const roles = <String>['Assult', 'Team Lead'];
    final currentIndex = roles.indexOf(_role);
    final nextIndex = (currentIndex + 1) % roles.length;
    setState(() {
      _role = roles[nextIndex];
      _eventText = 'Role switched to $_role.';
    });
  }

  void _respawn() {
    setState(() {
      _livesLeft = _maxLives;
      _ammoLeft = _startingAmmo;
      _isGameRunning = true;
      _eventText = 'Player respawned. Back in game.';
    });

    if (_timeRemaining > 0) {
      _startTimer();
    }
  }

  void _restartMatch() {
    setState(() {
      _timeRemaining = _matchLengthSeconds;
      _livesLeft = _maxLives;
      _ammoLeft = _startingAmmo;
      _score = 0;
      _hitsTaken = 0;
      _shotsFired = 0;
      _isGameRunning = true;
      _items = <_MapItem>[];
      _eventText = 'New match started.';
    });
    _startTimer();
  }

  Color _teamColor(String team) {
    if (team.toLowerCase().contains('red')) {
      return Colors.redAccent;
    }
    if (team.toLowerCase().contains('blue')) {
      return Colors.lightBlueAccent;
    }
    if (team.toLowerCase().contains('green')) {
      return Colors.greenAccent;
    }
    if (team.toLowerCase().contains('yellow')) {
      return Colors.amberAccent;
    }
    return Colors.white;
  }

  LatLng _playerPosition() {
    return const LatLng(_playerLatitude, _playerLongitude);
  }

  LatLng _contactToLatLng(_RadarContact contact) {
    return _metersToLatLng(contact.xMeters, contact.yMeters);
  }

  LatLng _metersToLatLng(double xMeters, double yMeters) {
    final metersPerDegreeLat = 111320.0;
    final metersPerDegreeLon = 111320.0 * math.cos(_playerLatitude * math.pi / 180);
    final latOffset = -yMeters / metersPerDegreeLat;
    final lonOffset = xMeters / metersPerDegreeLon;
    return LatLng(_playerLatitude + latOffset, _playerLongitude + lonOffset);
  }

  Color _itemColor(_ItemCategory category) {
    switch (category) {
      case _ItemCategory.healing:
        return Colors.lightGreenAccent;
      case _ItemCategory.armor:
        return Colors.lightBlueAccent;
      case _ItemCategory.damage:
        return Colors.deepOrangeAccent;
      case _ItemCategory.special:
        return Colors.purpleAccent;
    }
  }

  String _itemCategoryLabel(_ItemCategory category) {
    switch (category) {
      case _ItemCategory.healing:
        return 'Healing';
      case _ItemCategory.armor:
        return 'Armor';
      case _ItemCategory.damage:
        return 'Damage';
      case _ItemCategory.special:
        return 'Special';
    }
  }

  String _itemCategoryLetter(_ItemCategory category) {
    switch (category) {
      case _ItemCategory.healing:
        return 'H';
      case _ItemCategory.armor:
        return 'A';
      case _ItemCategory.damage:
        return 'D';
      case _ItemCategory.special:
        return 'S';
    }
  }

  double _distanceMeters(double x1, double y1, double x2, double y2) {
    final dx = x1 - x2;
    final dy = y1 - y2;
    return math.sqrt(dx * dx + dy * dy);
  }

  List<CircleMarker> _buildItemPickupCircles() {
    return _items
        .map(
          (item) => CircleMarker(
            point: _metersToLatLng(item.xMeters, item.yMeters),
            radius: _itemPickupRadiusMeters,
            useRadiusInMeter: true,
            color: _itemColor(item.category).withValues(alpha: 0.18),
            borderStrokeWidth: 1,
            borderColor: _itemColor(item.category).withValues(alpha: 0.95),
          ),
        )
        .toList();
  }

  List<Marker> _buildMapMarkers() {
    final markers = <Marker>[
      Marker(
        point: _playerPosition(),
        width: 24,
        height: 24,
        child: const Icon(Icons.my_location, color: Colors.white, size: 22),
      ),
    ];

    for (final contact in _contacts) {
      markers.add(
        Marker(
          point: _contactToLatLng(contact),
          width: 26,
          height: 26,
          child: Icon(
            Icons.circle,
            color: _teamColor(contact.team),
            size: 14,
          ),
        ),
      );
    }

    for (final item in _items) {
      markers.add(
        Marker(
          point: _metersToLatLng(item.xMeters, item.yMeters),
          width: 32,
          height: 32,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withValues(alpha: 0.7),
              border: Border.all(
                color: _itemColor(item.category),
                width: 2,
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              _itemCategoryLetter(item.category),
              style: TextStyle(
                color: _itemColor(item.category),
                fontWeight: FontWeight.w900,
                fontSize: 14,
              ),
            ),
          ),
        ),
      );
    }
    return markers;
  }

  Widget _statusIconTile({
    required IconData icon,
    required String title,
    required String value,
    required VoidCallback onTap,
    Color? activeColor,
  }) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white24),
            borderRadius: BorderRadius.circular(12),
            color: Colors.black.withValues(alpha: 0.2),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, color: activeColor ?? Colors.white70),
              const SizedBox(height: 6),
              Text(
                title,
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: activeColor ?? Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(int seconds) {
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    final remainingSeconds = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$remainingSeconds';
  }

  @override
  Widget build(BuildContext context) {
    final statusColor = _isGameRunning ? Colors.greenAccent : Colors.redAccent;
    final healthValue = _livesLeft / _maxLives;
    final teamColors = _teamBackgroundColors(_team);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: teamColors.first.withValues(alpha: 0.9),
        foregroundColor: Colors.white,
        title: const Text('Player Screen Test (Simulation)'),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: teamColors,
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: LayoutBuilder(
              builder: (context, constraints) {
              final compact = constraints.maxHeight < 760;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      'Simulation mode: no server required. Live HUD and radar test.',
                      style: const TextStyle(color: Colors.white),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    flex: compact ? 4 : 5,
                    child: Card(
                      color: Colors.black87,
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text(
                                    _playerName,
                                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white,
                                        ),
                                  ),
                                ),
                                Text(
                                  _team,
                                  style: TextStyle(
                                    color: _teamColor(_team),
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Health Bar',
                              style: TextStyle(
                                color: Colors.white70,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: LinearProgressIndicator(
                                minHeight: 18,
                                value: healthValue,
                                backgroundColor: Colors.red.shade900,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  healthValue > 0.5 ? Colors.lightGreenAccent : Colors.amberAccent,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: <Widget>[
                                _statusIconTile(
                                  icon: Icons.flash_on,
                                  title: 'Fire',
                                  value: _fireType,
                                  onTap: _cycleFireType,
                                  activeColor: Colors.orangeAccent,
                                ),
                                const SizedBox(width: 6),
                                _statusIconTile(
                                  icon: Icons.badge,
                                  title: 'Role',
                                  value: _role,
                                  onTap: _cycleRole,
                                  activeColor: Colors.cyanAccent,
                                ),
                                const SizedBox(width: 6),
                                _statusIconTile(
                                  icon: Icons.shield,
                                  title: 'Shield',
                                  value: _shieldActive ? 'On' : 'Off',
                                  onTap: _toggleShieldBonus,
                                  activeColor: _shieldActive ? Colors.lightBlueAccent : Colors.white54,
                                ),
                                const SizedBox(width: 6),
                                _statusIconTile(
                                  icon: Icons.healing,
                                  title: 'Heal',
                                  value: _healingBoostActive ? 'On' : 'Off',
                                  onTap: _toggleHealingBonus,
                                  activeColor: _healingBoostActive ? Colors.lightGreenAccent : Colors.white54,
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _isGameRunning ? 'MATCH RUNNING' : 'MATCH STOPPED',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    color: statusColor,
                                    fontWeight: FontWeight.bold,
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Expanded(
                              child: Row(
                                children: <Widget>[
                                  Expanded(
                                    child: Text(
                                      'Time ${_formatTime(_timeRemaining)}\n'
                                      'Lives $_livesLeft/$_maxLives\n'
                                      'Ammo $_ammoLeft/$_startingAmmo',
                                      style: const TextStyle(color: Colors.white),
                                      maxLines: 3,
                                    ),
                                  ),
                                  Expanded(
                                    child: Text(
                                      'Score $_score\n'
                                      'Shots $_shotsFired\n'
                                      'Hits $_hitsTaken\n'
                                      'Items ${_items.length}',
                                      style: const TextStyle(color: Colors.white),
                                      maxLines: 4,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              'Event: $_eventText',
                              style: const TextStyle(color: Colors.white70),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    flex: compact ? 4 : 5,
                    child: Card(
                      color: Colors.black,
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              'GPS Radar (${_radarRangeMeters.toInt()}m)',
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                            ),
                            const SizedBox(height: 8),
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: <Widget>[
                                    FlutterMap(
                                      options: MapOptions(
                                        initialCenter: _playerPosition(),
                                        initialZoom: 18,
                                        interactionOptions: const InteractionOptions(
                                          flags: InteractiveFlag.none,
                                        ),
                                      ),
                                      children: <Widget>[
                                        TileLayer(
                                          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                          userAgentPackageName: 'lasertag_app',
                                        ),
                                        CircleLayer(circles: _buildItemPickupCircles()),
                                        MarkerLayer(markers: _buildMapMarkers()),
                                      ],
                                    ),
                                    CustomPaint(
                                      painter: _RadarPainter(
                                        contacts: _contacts,
                                        radarRangeMeters: _radarRangeMeters,
                                        sweepDegrees: _radarSweepDegrees,
                                        teamColorResolver: _teamColor,
                                      ),
                                      child: const SizedBox.expand(),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _toggleTeamVoiceRecording,
                    icon: Icon(
                      _isRecordingTeamVoice ? Icons.stop_circle_outlined : Icons.mic,
                    ),
                    label: Text(
                      _isRecordingTeamVoice
                          ? 'Stop And Send Team Voice'
                          : 'Team Voice',
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _teamVoiceStatus,
                    style: const TextStyle(color: Colors.white70),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _RadarContact {
  const _RadarContact({
    required this.id,
    required this.team,
    required this.xMeters,
    required this.yMeters,
  });

  final String id;
  final String team;
  final double xMeters;
  final double yMeters;
}

enum _ItemCategory {
  healing,
  armor,
  damage,
  special,
}

class _MapItem {
  const _MapItem({
    required this.id,
    required this.category,
    required this.xMeters,
    required this.yMeters,
  });

  final String id;
  final _ItemCategory category;
  final double xMeters;
  final double yMeters;
}

class _SimulatedPlayer {
  const _SimulatedPlayer({
    required this.id,
    required this.team,
    required this.xMeters,
    required this.yMeters,
  });

  final String id;
  final String team;
  final double xMeters;
  final double yMeters;
}

class _RadarPainter extends CustomPainter {
  _RadarPainter({
    required this.contacts,
    required this.radarRangeMeters,
    required this.sweepDegrees,
    required this.teamColorResolver,
  });

  final List<_RadarContact> contacts;
  final double radarRangeMeters;
  final double sweepDegrees;
  final Color Function(String team) teamColorResolver;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radarRadius = math.min(size.width, size.height) / 2;

    final bgPaint = Paint()..color = const Color(0x22021607);
    canvas.drawRect(Offset.zero & size, bgPaint);

    final gridPaint = Paint()
      ..color = Colors.greenAccent.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    for (final ringFactor in <double>[1.0, 0.75, 0.5, 0.25]) {
      canvas.drawCircle(center, radarRadius * ringFactor, gridPaint);
    }

    canvas.drawLine(
      Offset(center.dx - radarRadius, center.dy),
      Offset(center.dx + radarRadius, center.dy),
      gridPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - radarRadius),
      Offset(center.dx, center.dy + radarRadius),
      gridPaint,
    );

    final sweepRadians = sweepDegrees * math.pi / 180.0;
    final sweepEnd = Offset(
      center.dx + math.cos(sweepRadians) * radarRadius,
      center.dy + math.sin(sweepRadians) * radarRadius,
    );
    final sweepPaint = Paint()
      ..color = Colors.lightGreenAccent.withValues(alpha: 0.6)
      ..strokeWidth = 2;
    canvas.drawLine(center, sweepEnd, sweepPaint);

    final meterToPixel = radarRadius / radarRangeMeters;
    for (final contact in contacts) {
      final distance = math.sqrt(
        contact.xMeters * contact.xMeters + contact.yMeters * contact.yMeters,
      );
      if (distance > radarRangeMeters) {
        continue;
      }

      final contactOffset = Offset(
        center.dx + contact.xMeters * meterToPixel,
        center.dy + contact.yMeters * meterToPixel,
      );

      final dotPaint = Paint()..color = teamColorResolver(contact.team);
      canvas.drawCircle(contactOffset, 5, dotPaint);

      final textPainter = TextPainter(
        text: TextSpan(
          text: contact.id,
          style: const TextStyle(color: Colors.white, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(canvas, contactOffset + const Offset(6, -6));
    }

    final playerPaint = Paint()..color = Colors.white;
    canvas.drawCircle(center, 7, playerPaint);
    canvas.drawCircle(
      center,
      10,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _RadarPainter oldDelegate) {
    return oldDelegate.contacts != contacts ||
        oldDelegate.sweepDegrees != sweepDegrees ||
        oldDelegate.radarRangeMeters != radarRangeMeters;
  }
}

String _deviceId(String prefix) {
  return '$prefix-${DateTime.now().microsecondsSinceEpoch}';
}

String _buildNetworkHintForHost(String host) {
  final normalized = host.trim().toLowerCase();
  if (normalized.isEmpty) {
    return 'Host is empty in this code.';
  }

  if (normalized == 'localhost') {
    return 'This code points to localhost and only works on the same device.';
  }

  final parsed = Uri.tryParse('http://$normalized')?.host ?? normalized;
  final parts = parsed.split('.');
  if (parts.length == 4) {
    final octets = parts.map(int.tryParse).toList();
    final isIpv4 = octets.every((value) => value != null && value >= 0 && value <= 255);
    if (isIpv4) {
      final first = octets[0]!;
      final second = octets[1]!;
      final isPrivate = first == 10 ||
          first == 127 ||
          (first == 172 && second >= 16 && second <= 31) ||
          (first == 192 && second == 168) ||
          (first == 169 && second == 254);
      if (isPrivate) {
        return 'LAN game detected: you must be on the same local network as the server.';
      }
      return 'Online host detected: this can work over the internet if server port forwarding is configured.';
    }
  }

  // Domain names and non-private hosts are treated as online targets.
  return 'Online host detected: this can work over the internet if server port forwarding is configured.';
}

List<Color> _teamBackgroundColors(String team) {
  final normalized = team.toLowerCase();
  if (normalized.contains('red')) {
    return <Color>[Colors.red.shade900, Colors.red.shade600, Colors.black];
  }
  if (normalized.contains('blue')) {
    return <Color>[Colors.indigo.shade900, Colors.blue.shade700, Colors.black];
  }
  if (normalized.contains('green')) {
    return <Color>[Colors.green.shade900, Colors.teal.shade700, Colors.black];
  }
  if (normalized.contains('yellow')) {
    return <Color>[Colors.orange.shade900, Colors.amber.shade700, Colors.black];
  }
  return <Color>[Colors.grey.shade900, Colors.blueGrey.shade700, Colors.black];
}

Future<bool> _ensureMicrophonePermission() async {
  final status = await Permission.microphone.request();
  return status.isGranted;
}
