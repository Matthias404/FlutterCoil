import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart' hide PlayerState;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../media_confic.dart';
import '../../network/game_network_service.dart';
import '../../network/join_code.dart';
import '../../network/peer_directory.dart';
import '../../network/transport.dart';
import '../../network/udp_transport.dart';
import '../../screens/player/gun_settings_screen.dart';
import '../../screens/player/lobby_rules_help_screen.dart';
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
  late final AudioPlayer _gunSfxPlayer;
  String _gunShotAssetPath = MediaConfic.laserShot;
  String? _reloadSoundAssetPath;
  String? _modeSoundAssetPath;
  String? _hitSoundAssetPath;
  String? _recoilEnabledSoundAssetPath;
  String? _recoilDisabledSoundAssetPath;
  String? _connectSoundAssetPath;
  String? _disconnectSoundAssetPath;
  Timer? _gunSfxCutoffTimer;
  StreamSubscription<TeamVoiceMessage>? _teamVoiceSub;
  StreamSubscription<bool>? _gunConnectionSub;
  StreamSubscription<GunBatteryLevel>? _gunBatterySub;
  StreamSubscription<GunTelemetrySample>? _gunTelemetrySub;
  NetworkSnapshot? _snapshot;
  String _status = 'Enter your player name and select team.';
  String _voiceStatus = 'Team voice ready.';
  bool _gunConnected = false;
  bool _showGunDisconnectedAlert = false;
  bool _isRecordingVoice = false;
  bool _recoilEnabled = true;
  GunBatteryLevel? _gunBatteryLevel;
  int? _ammoRemaining;
  String _selectedTeam = 'Red';
  GunProfile? _savedGunProfile;
  int? _lastTriggerCounter;
  int? _lastReloadCounter;
  int? _lastStartCounter;
  int? _lastPowerCounter;
  int? _lastHitBy1Key;
  int? _lastHitBy2Key;

  IconData _batteryIconForLevel(GunBatteryLevel? level) {
    switch (level) {
      case GunBatteryLevel.empty:
        return Icons.battery_0_bar;
      case GunBatteryLevel.low:
        return Icons.battery_2_bar;
      case GunBatteryLevel.medium:
        return Icons.battery_5_bar;
      case GunBatteryLevel.full:
        return Icons.battery_full;
      case null:
        return Icons.battery_unknown;
    }
  }

  Color _batteryColorForLevel(GunBatteryLevel? level) {
    switch (level) {
      case GunBatteryLevel.empty:
        return Colors.redAccent;
      case GunBatteryLevel.low:
        return Colors.orangeAccent;
      case GunBatteryLevel.medium:
        return Colors.amber;
      case GunBatteryLevel.full:
        return Colors.lightGreenAccent;
      case null:
        return Colors.white54;
    }
  }

  String _batteryLabelForLevel(GunBatteryLevel? level) {
    if (!_gunConnected) {
      return 'Disconnected';
    }
    return level?.label ?? 'Reading...';
  }

  String _joinCodeNetworkHint() {
    try {
      final endpoint = JoinCodeCodec.decode(widget.joinCode);
      return buildNetworkHintForHost(endpoint.host);
    } on FormatException {
      return 'This join code is invalid.';
    }
  }

  void _showGunEventSnack(String message) {
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(milliseconds: 1200),
      ),
    );
  }

  Future<void> _playGunShotSound() async {
    try {
      await _playActionSound(
        _gunShotAssetPath,
        cutoff: const Duration(milliseconds: 640),
      );
    } catch (_) {
      // Ignore sound errors to keep gameplay responsive.
    }
  }

  Future<void> _playReloadSound() async {
    _reloadSoundAssetPath ??=
        await _resolveFirstExistingAsset(MediaConfic.reloadCandidates) ??
        MediaConfic.reload;
    await _playOptionalActionSound(_reloadSoundAssetPath);
  }

  Future<void> _playActionSound(String assetPath, {Duration? cutoff}) async {
    await _gunSfxPlayer.stop();
    await _gunSfxPlayer.play(AssetSource(assetPath), volume: 1.0);
    _gunSfxCutoffTimer?.cancel();
    if (cutoff != null) {
      _gunSfxCutoffTimer = Timer(cutoff, () {
        unawaited(_gunSfxPlayer.stop());
      });
    }
  }

  Future<void> _playOptionalActionSound(
    String? assetPath, {
    Duration? cutoff,
  }) async {
    if (assetPath == null) {
      return;
    }
    try {
      await _playActionSound(assetPath, cutoff: cutoff);
    } catch (_) {
      // Ignore sound errors to keep gameplay responsive.
    }
  }

  Future<String?> _resolveFirstExistingAsset(List<String> candidates) async {
    for (final candidate in candidates) {
      try {
        await rootBundle.load(MediaConfic.bundlePath(candidate));
        return candidate;
      } catch (_) {
        // Try next candidate.
      }
    }
    return null;
  }

  Future<void> _resolveGunActionAudioAssets() async {
    _gunShotAssetPath =
        await _resolveFirstExistingAsset(MediaConfic.gunShotCandidates) ??
        _gunShotAssetPath;
    _reloadSoundAssetPath = await _resolveFirstExistingAsset(
      MediaConfic.reloadCandidates,
    );
    _modeSoundAssetPath = await _resolveFirstExistingAsset(
      MediaConfic.modeCandidates,
    );
    _hitSoundAssetPath = await _resolveFirstExistingAsset(
      MediaConfic.hitCandidates,
    );
    _recoilEnabledSoundAssetPath = await _resolveFirstExistingAsset(
      MediaConfic.recoilEnabledCandidates,
    );
    _recoilDisabledSoundAssetPath = await _resolveFirstExistingAsset(
      MediaConfic.recoilDisabledCandidates,
    );
    _connectSoundAssetPath = await _resolveFirstExistingAsset(
      MediaConfic.connectCandidates,
    );
    _disconnectSoundAssetPath = await _resolveFirstExistingAsset(
      MediaConfic.disconnectCandidates,
    );
  }

  @override
  void initState() {
    super.initState();

    _nameController = TextEditingController();
    _peerDirectory = PeerDirectory();
    _voiceRecorder = AudioRecorder();
    _voicePlayer = AudioPlayer();
    _gunSfxPlayer = AudioPlayer();

    _service = GameNetworkService(
      transport: UdpNetworkTransport(localPort: _playerPort),
      localPlayerId: deviceId('player'),
      initialPlayerName: 'Player',
      initialPlayerGroup: _selectedTeam,
      peerDirectory: _peerDirectory,
    );

    unawaited(_resolveGunActionAudioAssets());
    _bootstrap();
    _loadSavedGunProfile();
  }

  Future<void> _loadSavedGunProfile() async {
    final profile = await GunProfileStorage.load();
    final gunConnected =
        profile != null &&
        BleGunController.isConnected(deviceId: profile.deviceId);
    if (!mounted) {
      return;
    }
    setState(() {
      _savedGunProfile = profile;
      _recoilEnabled = profile?.recoilEnabled ?? true;
      _gunConnected = gunConnected;
      _showGunDisconnectedAlert = false;
    });

    if (profile != null && gunConnected) {
      await _startGunConnectionMonitoring(profile);
      await _startBatteryMonitoring(profile);
      await _startTelemetryMonitoring(profile);
    }
  }

  Future<void> _startGunConnectionMonitoring(GunProfile profile) async {
    await _gunConnectionSub?.cancel();
    _gunConnectionSub =
        BleGunController.watchConnection(deviceId: profile.deviceId).listen((
          connected,
        ) {
          if (!mounted) {
            return;
          }

          if (connected) {
            if (!_gunConnected || _showGunDisconnectedAlert) {
              setState(() {
                _gunConnected = true;
                _showGunDisconnectedAlert = false;
                _status = 'Gun connected: ${profile.displayName}.';
              });
              unawaited(_playOptionalActionSound(_connectSoundAssetPath));
              unawaited(_startBatteryMonitoring(profile));
              unawaited(_startTelemetryMonitoring(profile));
              unawaited(_service.updateLocalProfile(gunConnected: true));
            }
            return;
          }

          if (_gunConnected || !_showGunDisconnectedAlert) {
            setState(() {
              _gunConnected = false;
              _showGunDisconnectedAlert = true;
              _gunBatteryLevel = null;
              _ammoRemaining = null;
              _lastTriggerCounter = null;
              _lastReloadCounter = null;
              _lastStartCounter = null;
              _lastPowerCounter = null;
              _status =
                  'Gun disconnected. Check Bluetooth range and tap Reconnect Gun.';
            });
            unawaited(_playOptionalActionSound(_disconnectSoundAssetPath));
            unawaited(_gunTelemetrySub?.cancel());
            unawaited(_service.updateLocalProfile(gunConnected: false));
          }
        });
  }

  Future<void> _startBatteryMonitoring(GunProfile profile) async {
    await _gunBatterySub?.cancel();
    _gunBatterySub =
        BleGunController.watchBatteryLevel(deviceId: profile.deviceId).listen(
          (level) {
            if (!mounted) {
              return;
            }
            setState(() {
              _gunBatteryLevel = level;
            });
          },
          onError: (_) {
            if (!mounted) {
              return;
            }
            setState(() {
              _gunBatteryLevel = null;
            });
          },
        );
  }

  Future<void> _startTelemetryMonitoring(GunProfile profile) async {
    await _gunTelemetrySub?.cancel();
    _lastTriggerCounter = null;
    _lastReloadCounter = null;
    _lastStartCounter = null;
    _lastPowerCounter = null;
    _lastHitBy1Key = null;
    _lastHitBy2Key = null;

    _gunTelemetrySub =
        BleGunController.watchTelemetry(deviceId: profile.deviceId).listen((
          sample,
        ) {
          if (!mounted) {
            return;
          }

          // Use first sample only for baseline to avoid false button presses.
          if (_lastTriggerCounter == null ||
              _lastReloadCounter == null ||
              _lastStartCounter == null ||
              _lastPowerCounter == null) {
            _lastTriggerCounter = sample.triggerCounter;
            _lastReloadCounter = sample.reloadCounter;
            _lastStartCounter = sample.thumbCounter;
            _lastPowerCounter = sample.powerCounter;
            _ammoRemaining = sample.shotsRemaining;
            return;
          }

          if (_ammoRemaining != sample.shotsRemaining) {
            setState(() {
              _ammoRemaining = sample.shotsRemaining;
            });
          }

          if (sample.triggerCounter != _lastTriggerCounter) {
            _lastTriggerCounter = sample.triggerCounter;
            const message = 'Trigger pressed: shoot signal received from gun.';
            setState(() {
              _status = message;
            });
            _showGunEventSnack(message);
            unawaited(_playGunShotSound());
            final profile = _savedGunProfile;
            if (_gunConnected && profile != null && profile.recoilEnabled) {
              unawaited(
                BleGunController.reinforceRecoilOnShot(
                  deviceId: profile.deviceId,
                ),
              );
            }
          }

          if (sample.reloadCounter != _lastReloadCounter) {
            _lastReloadCounter = sample.reloadCounter;
            const message =
                'Reload button pressed: reload signal received from gun.';
            setState(() {
              _status = message;
            });
            _showGunEventSnack(message);
            unawaited(_playReloadSound());
          }

          if (sample.thumbCounter != _lastStartCounter) {
            _lastStartCounter = sample.thumbCounter;
            unawaited(_playOptionalActionSound(_modeSoundAssetPath));
            unawaited(_cycleConfiguredFireMode());
          }

          if (sample.powerCounter != _lastPowerCounter) {
            _lastPowerCounter = sample.powerCounter;
            final enableRecoil =
                !(_savedGunProfile?.recoilEnabled ?? _recoilEnabled);
            unawaited(_setRecoilEnabled(enableRecoil));
            unawaited(
              _playOptionalActionSound(
                enableRecoil
                    ? _recoilEnabledSoundAssetPath
                    : _recoilDisabledSoundAssetPath,
              ),
            );
            _showGunEventSnack(
              enableRecoil
                  ? 'Power button pressed: recoil mode enabled.'
                  : 'Power button pressed: recoil mode disabled.',
            );
          }

          final hitBy1Key = (sample.hitBy1 << 3) | sample.hitBy1ShotId;
          if (sample.hitBy1 > 0 && hitBy1Key != _lastHitBy1Key) {
            _lastHitBy1Key = hitBy1Key;
            final message = 'Hit detected from player ${sample.hitBy1}.';
            setState(() {
              _status = message;
            });
            _showGunEventSnack(message);
            unawaited(_playOptionalActionSound(_hitSoundAssetPath));
          }

          final hitBy2Key = (sample.hitBy2 << 3) | sample.hitBy2ShotId;
          if (sample.hitBy2 > 0 && hitBy2Key != _lastHitBy2Key) {
            _lastHitBy2Key = hitBy2Key;
            final message = 'Hit detected from player ${sample.hitBy2}.';
            setState(() {
              _status = message;
            });
            _showGunEventSnack(message);
            unawaited(_playOptionalActionSound(_hitSoundAssetPath));
          }
        });
  }

  Future<void> _connectGunProfile(
    GunProfile profile, {
    required String loadingStatus,
    required String successStatus,
  }) async {
    if (!mounted) {
      return;
    }

    setState(() {
      _status = loadingStatus;
    });

    try {
      await BleGunController.connect(deviceId: profile.deviceId);
      if (!mounted) {
        return;
      }

      setState(() {
        _savedGunProfile = profile;
        _recoilEnabled = profile.recoilEnabled;
        _gunConnected = true;
        _showGunDisconnectedAlert = false;
        _status = successStatus;
      });

      await _startGunConnectionMonitoring(profile);
      await _startBatteryMonitoring(profile);
      await _startTelemetryMonitoring(profile);
      await _applyShotModeToGun(profile: profile);
      await _applyRecoilModeToGun(profile: profile);
      await _service.updateLocalProfile(gunConnected: true);
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _savedGunProfile = profile;
        _recoilEnabled = profile.recoilEnabled;
        _gunConnected = false;
        _showGunDisconnectedAlert = true;
        _status =
            'Could not connect to ${profile.displayName}. Check Bluetooth and try Reconnect Gun.';
      });
      await _service.updateLocalProfile(gunConnected: false);
    }
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

  Future<void> _applyShotModeToGun({required GunProfile profile}) async {
    try {
      await BleGunController.setShotMode(
        deviceId: profile.deviceId,
        mode: profile.selectedFireMode,
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status =
            'Gun connected, but fire mode command failed. Check Bluetooth range and try Reconnect Gun.';
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

  Future<void> _cycleConfiguredFireMode() async {
    final currentProfile = _savedGunProfile;
    if (currentProfile == null) {
      setState(() {
        _status = 'Open Gun Settings first to configure the gun profile.';
      });
      return;
    }

    final allowedModes = <FireMode>[];
    if (currentProfile.allowSingleShotMode) {
      allowedModes.add(FireMode.single);
    }
    if (currentProfile.allowBurst3ShotMode) {
      allowedModes.add(FireMode.burst3);
    }
    if (currentProfile.allowAutoShotMode) {
      allowedModes.add(FireMode.auto);
    }

    if (allowedModes.isEmpty) {
      setState(() {
        _status = 'No fire modes are enabled in the current gun profile.';
      });
      return;
    }

    final currentIndex = allowedModes.indexOf(currentProfile.selectedFireMode);
    final nextIndex = (currentIndex + 1) % allowedModes.length;
    final nextMode = allowedModes[nextIndex];
    final updatedProfile = currentProfile.copyWith(selectedFireMode: nextMode);
    await GunProfileStorage.save(updatedProfile);

    if (!mounted) {
      return;
    }

    setState(() {
      _savedGunProfile = updatedProfile;
      _status =
          'Fire mode switched to ${nextMode.label} via Thumb / Rear Button.';
    });
    _showGunEventSnack('Fire mode switched to ${nextMode.label}.');

    if (_gunConnected) {
      await _applyShotModeToGun(profile: updatedProfile);
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
    _gunConnectionSub?.cancel();
    _gunBatterySub?.cancel();
    _gunTelemetrySub?.cancel();
    _nameController.dispose();
    _service.stop();
    unawaited(_voiceRecorder.dispose());
    unawaited(_voicePlayer.dispose());
    _gunSfxCutoffTimer?.cancel();
    unawaited(_gunSfxPlayer.dispose());
    _peerDirectory.dispose();
    super.dispose();
  }

  Future<void> _toggleTeamVoice() async {
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
      _voiceStatus = 'Voice message sent to the whole lobby.';
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
    await _connectGunProfile(
      profile,
      loadingStatus: 'Connecting to ${profile.displayName}...',
      successStatus:
          'Connected to ${profile.displayName} (${profile.deviceId}).',
    );
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

    await _connectGunProfile(
      profile,
      loadingStatus: 'Reconnecting gun ${profile.displayName}...',
      successStatus:
          'Gun reconnected: ${profile.displayName} (${profile.deviceId}).',
    );
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

  Widget _buildGunDisconnectedOverlay(ButtonStyle searchButtonStyle) {
    final profile = _savedGunProfile;
    if (!_showGunDisconnectedAlert || profile == null) {
      return const SizedBox.shrink();
    }

    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.68),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Material(
                color: Colors.red.shade900.withValues(alpha: 0.94),
                borderRadius: BorderRadius.circular(18),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: Colors.amberAccent,
                        size: 40,
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Gun disconnected',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '${profile.displayName} is offline. Move closer to the gun, reconnect it, or search for another gun.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 18),
                      FilledButton.icon(
                        onPressed: _reconnectGun,
                        icon: const Icon(Icons.bluetooth_connected),
                        label: const Text('Reconnect Gun'),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        style: searchButtonStyle,
                        onPressed: _openGunSettings,
                        icon: const Icon(Icons.search),
                        label: const Text('Search Gun'),
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
    final overlaySearchButtonStyle = OutlinedButton.styleFrom(
      foregroundColor: Colors.white,
      side: const BorderSide(color: Colors.white70),
    );
    final localPlayer = snapshot?.players[_service.localPlayerId];
    final scheduledStartAt = snapshot?.scheduledGameStartAt;
    final isTeamLead = localPlayer?.playerClass == 'Team Lead';
    final isReady =
        snapshot?.readyTeamLeadIds.contains(_service.localPlayerId) ?? false;
    final canConfirmStart =
        isTeamLead &&
        snapshot?.gamePhase == GamePhase.setup &&
        scheduledStartAt != null &&
        !isReady;
    final localPlayerName = localPlayer?.name.isNotEmpty == true
        ? localPlayer!.name
        : _nameController.text.trim().isNotEmpty
        ? _nameController.text.trim()
        : 'Player';
    final localGunMode = _savedGunProfile == null
        ? 'No gun profile'
        : '${_savedGunProfile!.selectedFireMode.label} • Recoil ${_savedGunProfile!.recoilEnabled ? 'on' : 'off'}';
    final compactTextTheme = Theme.of(
      context,
    ).textTheme.apply(fontSizeFactor: 0.9);

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
      body: Stack(
        children: <Widget>[
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: teamColors,
              ),
            ),
            child: SafeArea(
              child: Theme(
                data: Theme.of(context).copyWith(textTheme: compactTextTheme),
                child: IconTheme.merge(
                  data: const IconThemeData(size: 18),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final compact = constraints.maxHeight < 720;
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
                                      'Lobby players (${players.length})',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleSmall,
                                    ),
                                    const SizedBox(height: 8),
                                    if (players.isEmpty)
                                      const Text('No players connected yet.')
                                    else
                                      ...players.map(
                                        (player) => Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 4,
                                          ),
                                          child: Row(
                                            children: <Widget>[
                                              player.isHost
                                                  ? const Icon(
                                                      Icons.shield,
                                                      size: 14,
                                                    )
                                                  : const SizedBox.shrink(),
                                              player.isHost
                                                  ? const SizedBox(width: 4)
                                                  : const SizedBox.shrink(),
                                              Expanded(
                                                child: Text(
                                                  '${player.name} • Team ${player.group} • ${player.playerClass == 'Team Lead' ? 'Team Lead' : 'Assault'}',
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
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
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: textPanelBg,
                                    border: Border.all(color: textPanelBorder),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Row(
                                    children: <Widget>[
                                      Expanded(
                                        child: Text(
                                          'Game Type: ${(snapshot?.lobbyRules.gameType ?? GameType.time).label}',
                                          style: TextStyle(
                                            color: panelTextColor,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: 'Game rules',
                                        onPressed: () {
                                          Navigator.of(context).push(
                                            MaterialPageRoute<void>(
                                              builder: (_) => LobbyRulesHelpScreen(
                                                rules:
                                                    snapshot?.lobbyRules ??
                                                    const LobbyRules.defaults(),
                                              ),
                                            ),
                                          );
                                        },
                                        icon: const Icon(Icons.help_outline),
                                      ),
                                    ],
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
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: textPanelBg,
                                    border: Border.all(color: textPanelBorder),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        'Player: $localPlayerName',
                                        style: TextStyle(
                                          color: panelTextColor,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Gun mode: $localGunMode',
                                        style: TextStyle(
                                          color: panelSecondaryTextColor,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 8),
                                SwitchListTile(
                                  value: _recoilEnabled,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  secondary: const Icon(
                                    Icons.sports_motorsports,
                                  ),
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
                                              (team) =>
                                                  DropdownMenuItem<String>(
                                                    value: team,
                                                    child: Row(
                                                      children: <Widget>[
                                                        _teamIcon(team),
                                                        const SizedBox(
                                                          width: 8,
                                                        ),
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
                                          _gunConnected
                                              ? 'Gun Ready'
                                              : 'Gun Settings',
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
                                        icon: const Icon(
                                          Icons.bluetooth_connected,
                                        ),
                                        label: const Text('Reconnect Gun'),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
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
                                          if (_savedGunProfile !=
                                              null) ...<Widget>[
                                            const SizedBox(height: 2),
                                            Row(
                                              children: <Widget>[
                                                Icon(
                                                  _batteryIconForLevel(
                                                    _gunBatteryLevel,
                                                  ),
                                                  size: 12,
                                                  color: _batteryColorForLevel(
                                                    _gunBatteryLevel,
                                                  ),
                                                ),
                                                const SizedBox(width: 4),
                                                Text(
                                                  'Battery: ${_batteryLabelForLevel(_gunBatteryLevel)}',
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    color:
                                                        panelSecondaryTextColor,
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              'Ammo: ${_ammoRemaining ?? '--'} • '
                                              '${_savedGunProfile!.deviceId} • '
                                              'Trigger: Shoot • '
                                              'Reload: Reload • '
                                              'Thumb/Rear: Fire Mode • '
                                              'Power: Recoil Toggle • '
                                              'Fire: ${_savedGunProfile!.selectedFireMode.label} • '
                                              'Recoil: ${_savedGunProfile!.recoilEnabled ? 'on' : 'off'}',
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: panelSecondaryTextColor,
                                              ),
                                            ),
                                          ],
                                          _buildGunDisconnectedOverlay(
                                            overlaySearchButtonStyle,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                OutlinedButton.icon(
                                  style: teamOutlinedButtonStyle,
                                  onPressed: _savedGunProfile == null
                                      ? null
                                      : () => unawaited(
                                          _cycleConfiguredFireMode(),
                                        ),
                                  icon: const Icon(Icons.sync_alt),
                                  label: Text(
                                    _savedGunProfile == null
                                        ? 'Cycle Fire Mode'
                                        : 'Cycle Fire Mode (Thumb / Rear Button)',
                                  ),
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
                                    style: TextStyle(
                                      color: panelSecondaryTextColor,
                                    ),
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
                                  icon: Icon(
                                    isReady ? Icons.check_circle : Icons.flag,
                                  ),
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
                                    _isRecordingVoice
                                        ? Icons.stop_circle_outlined
                                        : Icons.mic,
                                  ),
                                  label: Text(
                                    _isRecordingVoice
                                        ? 'Stop And Send Voice To Lobby'
                                        : 'Record Voice For Lobby',
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
                                    style: TextStyle(
                                      color: panelSecondaryTextColor,
                                    ),
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
            ),
          ),
        ],
      ),
    );
  }
}
