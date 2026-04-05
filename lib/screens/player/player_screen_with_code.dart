import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart' hide PlayerState;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../network/game_network_service.dart';
import '../../network/join_code.dart';
import '../../network/peer_directory.dart';
import '../../network/transport.dart';
import '../../network/udp_transport.dart';
import '../../screens/player/gun_settings_screen.dart';
import '../../theme/team_colors.dart';
import '../../theme/theme_toggle_button.dart';
import '../../utils/ble_gun_controller.dart';
import '../../utils/gun_profile_storage.dart';
import '../../utils/helpers.dart'
    show
        deviceId,
        buildNetworkHintForHost,
        ensureMicrophonePermission,
        teamBackgroundColors;

class PlayerScreenWithCode extends StatefulWidget {
  const PlayerScreenWithCode({super.key, required this.joinCode});

  final String joinCode;

  @override
  State<PlayerScreenWithCode> createState() => _PlayerScreenWithCodeState();
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
  bool _recoilEnabled = true;
  String _selectedTeam = 'Red';
  GunProfile? _savedGunProfile;

  String _formatCountdown(Duration duration) {
    final totalSeconds = duration.inSeconds.clamp(0, 3599);
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

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
    _loadSavedGunProfile();
  }

  Future<void> _loadSavedGunProfile() async {
    final profile = await GunProfileStorage.load();
    if (!mounted) {
      return;
    }
    setState(() {
      _savedGunProfile = profile;
      _recoilEnabled = profile?.recoilEnabled ?? true;
    });
  }

  Future<void> _applyRecoilModeToGun({required GunProfile profile}) async {
    try {
      await BleGunController.setRecoilMode(
        deviceId: profile.deviceId,
        enabled: profile.recoilEnabled,
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status =
            'Gun connected, but recoil command failed. Check Bluetooth range and try Reconnect Gun.';
      });
    }
  }

  Future<void> _setRecoilEnabled(bool enabled) async {
    final currentProfile = _savedGunProfile;
    if (currentProfile == null) {
      setState(() {
        _recoilEnabled = enabled;
        _status = 'Open Gun Settings first to select a Bluetooth gun.';
      });
      return;
    }

    final updatedProfile = currentProfile.copyWith(recoilEnabled: enabled);
    await GunProfileStorage.save(updatedProfile);

    if (!mounted) {
      return;
    }

    setState(() {
      _savedGunProfile = updatedProfile;
      _recoilEnabled = enabled;
      _status = enabled
          ? 'Recoil mode enabled. Applying to gun...'
          : 'Recoil mode disabled. Applying to gun...';
    });

    if (_gunConnected) {
      await _applyRecoilModeToGun(profile: updatedProfile);
    }
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
    final hasPermission = await ensureMicrophonePermission();
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

  Future<void> _openGunSettings() async {
    final profile = await Navigator.of(context).push<GunProfile>(
      MaterialPageRoute<GunProfile>(
        builder: (_) => GunSettingsScreen(initialProfile: _savedGunProfile),
      ),
    );
    if (!mounted || profile == null) {
      return;
    }

    await GunProfileStorage.save(profile);
    if (!mounted) {
      return;
    }

    setState(() {
      _savedGunProfile = profile;
      _recoilEnabled = profile.recoilEnabled;
      _gunConnected = true;
      _status = 'Connected to ${profile.displayName} (${profile.deviceId}).';
    });
    await _applyRecoilModeToGun(profile: profile);
    await _service.updateLocalProfile(gunConnected: true);
  }

  Future<void> _reconnectGun() async {
    final profile = _savedGunProfile ?? await GunProfileStorage.load();
    if (!mounted) {
      return;
    }

    if (profile == null) {
      setState(() {
        _status = 'No saved gun profile found. Open Gun Settings first.';
      });
      return;
    }

    setState(() {
      _status = 'Reconnecting gun ${profile.displayName}...';
    });

    await Future<void>.delayed(const Duration(milliseconds: 350));

    if (!mounted) {
      return;
    }

    setState(() {
      _savedGunProfile = profile;
      _recoilEnabled = profile.recoilEnabled;
      _gunConnected = true;
      _status =
          'Gun reconnected: ${profile.displayName} (${profile.deviceId}).';
    });
    await _applyRecoilModeToGun(profile: profile);
    await _service.updateLocalProfile(gunConnected: true);
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
      _status =
          'Joining lobby at ${serverEndpoint.host}:${serverEndpoint.port}';
    });
  }

  Future<void> _teamLeadReadyStart() async {
    await _service.confirmTeamLeadReadyStart();
    if (!mounted) {
      return;
    }
    setState(() {
      _status = 'Ready signal sent. Waiting for other Team Leads...';
    });
  }

  Widget _teamIcon(String team) {
    return Icon(Icons.circle, color: teamPaletteFor(team).accent);
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final players = snapshot?.players.values.toList() ?? const <PlayerState>[];
    final networkHint = _joinCodeNetworkHint();
    final brightness = Theme.of(context).brightness;
    final teamPalette = teamPaletteFor(_selectedTeam);
    final teamColors = teamBackgroundColors(
      _selectedTeam,
      brightness: brightness,
    );
    final textPanelBg = teamPalette.secondary.withValues(
      alpha: brightness == Brightness.dark ? 0.22 : 0.34,
    );
    final textPanelBorder = teamPalette.primary.withValues(
      alpha: brightness == Brightness.dark ? 0.45 : 0.25,
    );
    final panelTextColor = teamPalette.foreground(brightness);
    final panelSecondaryTextColor = panelTextColor.withValues(alpha: 0.82);
    final teamFilledButtonStyle = FilledButton.styleFrom(
      backgroundColor: teamPalette.primary.withValues(
        alpha: brightness == Brightness.dark ? 0.88 : 0.9,
      ),
      foregroundColor: teamPalette.foreground(brightness),
    );
    final teamSecondaryFilledButtonStyle = FilledButton.styleFrom(
      backgroundColor: teamPalette.secondary.withValues(
        alpha: brightness == Brightness.dark ? 0.72 : 0.82,
      ),
      foregroundColor: teamPalette.foreground(brightness),
    );
    final teamOutlinedButtonStyle = OutlinedButton.styleFrom(
      foregroundColor: teamPalette.foreground(brightness),
      side: BorderSide(color: textPanelBorder),
    );
    final localPlayer = snapshot?.players[_service.localPlayerId];
    final scheduledStartAt = snapshot?.scheduledGameStartAt;
    final countdown = scheduledStartAt?.difference(DateTime.now());
    final countdownLabel = countdown == null
        ? null
        : _formatCountdown(countdown);
    final isTeamLead = localPlayer?.playerClass == 'Team Lead';
    final isReady =
        snapshot?.readyTeamLeadIds.contains(_service.localPlayerId) ?? false;
    final canConfirmStart =
        isTeamLead &&
        snapshot?.gamePhase == GamePhase.setup &&
        scheduledStartAt != null &&
        !isReady;
    final readyCount = snapshot?.readyTeamLeadIds.length ?? 0;
    final teamLeadCount = snapshot?.teamLeadCount ?? 0;
    final teamLeadVoiceOnly = snapshot?.lobbyRules.teamLeadVoiceOnly ?? true;
    final voiceLocked =
        teamLeadVoiceOnly && localPlayer?.playerClass != 'Team Lead';

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        backgroundColor: teamPalette.primary.withValues(
          alpha: brightness == Brightness.dark ? 0.9 : 0.8,
        ),
        foregroundColor: teamPalette.foreground(brightness),
        title: const Text('Player Setup'),
        actions: <Widget>[
          ThemeToggleButton(color: teamPalette.foreground(brightness)),
        ],
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

                final infoPanels = Column(
                  children: <Widget>[
                    Card(
                      margin: EdgeInsets.zero,
                      color: textPanelBg,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: textPanelBorder),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              'Server rules',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Phase: ${snapshot?.gamePhase.name ?? GamePhase.setup.name}',
                            ),
                            Text(
                              'Max lives: ${snapshot?.lobbyRules.maxLives ?? 10}',
                            ),
                            Text(
                              'Length: ${snapshot?.lobbyRules.matchLengthMinutes ?? 10} min',
                            ),
                            Text(
                              'Item spawn: ${((snapshot?.lobbyRules.itemSpawnRateSeconds ?? 30) <= 0) ? 'never' : '${snapshot?.lobbyRules.itemSpawnRateSeconds ?? 30} sec'}',
                            ),
                            Text(
                              'Friendly fire: ${snapshot?.lobbyRules.friendlyFire == true ? 'on' : 'off'}',
                            ),
                            Text(
                              'Respawn: ${snapshot?.lobbyRules.respawnMode == RespawnMode.atTeamBase ? 'at team base (2m)' : 'timer starts on death'}',
                            ),
                            Text(
                              'Voice: ${snapshot?.lobbyRules.teamLeadVoiceOnly == false ? 'all players' : 'team leads only'}',
                            ),
                            Text(
                              'Map visibility: ${snapshot?.lobbyRules.showOtherPlayersOnMap == false ? 'teammates only' : 'all players'}',
                            ),
                            if (countdownLabel != null)
                              Text(
                                'Match starts in: $countdownLabel • Leads ready: $readyCount/$teamLeadCount',
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Card(
                      margin: EdgeInsets.zero,
                      color: textPanelBg,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: textPanelBorder),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              'Lobby players (${players.length})',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 8),
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
                              Text(
                                '+${players.length - previewPlayers.length} more players',
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );

                return SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: textPanelBg,
                            border: Border.all(color: textPanelBorder),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            'Status: $_status',
                            style: TextStyle(color: panelTextColor),
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
                        SwitchListTile(
                          value: _recoilEnabled,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                          ),
                          secondary: const Icon(Icons.sports_motorsports),
                          title: const Text('Recoil Mode'),
                          subtitle: Text(
                            _recoilEnabled
                                ? 'On: gun kick/recoil enabled'
                                : 'Off: gun kick/recoil disabled',
                          ),
                          onChanged: (value) {
                            unawaited(_setRecoilEnabled(value));
                          },
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
                                    .map(
                                      (team) => DropdownMenuItem<String>(
                                        value: team,
                                        child: Row(
                                          children: <Widget>[
                                            _teamIcon(team),
                                            const SizedBox(width: 8),
                                            Text(team),
                                          ],
                                        ),
                                      ),
                                    )
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
                                style: teamSecondaryFilledButtonStyle,
                                onPressed: _openGunSettings,
                                icon: Icon(
                                  _gunConnected
                                      ? Icons.bluetooth_connected
                                      : Icons.bluetooth_searching,
                                ),
                                label: Text(
                                  _gunConnected ? 'Gun Ready' : 'Gun Settings',
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: OutlinedButton.icon(
                                style: teamOutlinedButtonStyle,
                                onPressed: _reconnectGun,
                                icon: const Icon(Icons.bluetooth_connected),
                                label: const Text('Reconnect Gun'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    _savedGunProfile == null
                                        ? 'No saved gun profile'
                                        : _savedGunProfile!.displayName,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: panelSecondaryTextColor,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  if (_savedGunProfile != null) ...<Widget>[
                                    const SizedBox(height: 2),
                                    Text(
                                      '${_savedGunProfile!.deviceId} • '
                                      'Ammo: ${_savedGunProfile!.ammo} • '
                                      'HP: ${_savedGunProfile!.health} • '
                                      'Recoil: ${_savedGunProfile!.recoilEnabled ? 'on' : 'off'}',
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: panelSecondaryTextColor,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: TextEditingController(
                            text: widget.joinCode,
                          ),
                          readOnly: true,
                          maxLines: 1,
                          decoration: InputDecoration(
                            isDense: compact,
                            labelText: 'Lobby join code',
                            border: const OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: textPanelBg,
                            border: Border.all(color: textPanelBorder),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            networkHint,
                            style: TextStyle(color: panelSecondaryTextColor),
                            maxLines: compact ? 2 : 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          style: teamFilledButtonStyle,
                          onPressed: _joinLobby,
                          icon: const Icon(Icons.login),
                          label: const Text('Join Lobby'),
                        ),
                        const SizedBox(height: 6),
                        OutlinedButton.icon(
                          style: teamOutlinedButtonStyle,
                          onPressed: canConfirmStart
                              ? _teamLeadReadyStart
                              : null,
                          icon: Icon(isReady ? Icons.check_circle : Icons.flag),
                          label: Text(
                            isReady
                                ? 'Ready For Start Sent'
                                : 'Team Lead Ready To Start',
                          ),
                        ),
                        const SizedBox(height: 6),
                        OutlinedButton.icon(
                          style: teamOutlinedButtonStyle,
                          onPressed: _toggleTeamVoice,
                          icon: Icon(
                            voiceLocked
                                ? Icons.lock
                                : (_isRecordingVoice
                                      ? Icons.stop_circle_outlined
                                      : Icons.mic),
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
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: textPanelBg,
                            border: Border.all(color: textPanelBorder),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            _voiceStatus,
                            style: TextStyle(color: panelSecondaryTextColor),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(height: 8),
                        infoPanels,
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
