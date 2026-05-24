import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart' hide PlayerState;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../media_confic.dart';
import '../../main.dart';
import '../../network/game_network_service.dart';
import '../../network/item_definitions.dart';
import '../../network/join_code.dart';
import '../../network/peer_directory.dart';
import '../../network/transport.dart';
import '../../network/udp_transport.dart';
import '../../screens/player/gun_settings_screen.dart';
import '../../screens/player/lobby_rules_help_screen.dart';
import '../../screens/player/player_lobby_screen.dart';
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

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    this.joinCode,
    this.initialPlayerName,
    this.initialTeam,
    this.autoJoinOnOpen = false,
  });

  final String? joinCode;
  final String? initialPlayerName;
  final String? initialTeam;
  final bool autoJoinOnOpen;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  static const int _playerPort = 7778;
  static const List<String> _teams = <String>['Red', 'Blue', 'Green', 'Yellow'];
  static const Duration _gunConnectTimeout = Duration(seconds: 8);
  static const String _playerNamePrefKey = 'player_name';
  static const String _selectedTeamPrefKey = 'selected_team';

  late final GameNetworkService _service;
  late final PeerDirectory _peerDirectory;
  late final TextEditingController _nameController;
  late final TextEditingController _joinCodeController;
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
  StreamSubscription<Position>? _gpsSub;
  late final Future<void> _bootstrapFuture;
  NetworkSnapshot? _snapshot;
  String _status = 'Fill in your player profile.';
  String _voiceStatus = 'Team voice ready.';
  bool _gunConnected = false;
  bool _showGunDisconnectedAlert = false;
  bool _showJoinCodeFallback = false;
  bool _hasJoinedLobby = false;
  bool _isJoiningLobby = false;
  bool _isConnectingGun = false;
  bool _isRecordingVoice = false;
  bool _recoilEnabled = true;
  GunBatteryLevel? _gunBatteryLevel;
  int? _ammoRemaining;
  String _selectedTeam = 'Red';
  GunProfile? _savedGunProfile;
  GameItemPickupNotification? _latestPickupNotification;
  final Set<String> _playedEffectIds = <String>{};
  final Set<String> _playedBombPickupIds = <String>{};
  Timer? _killOverlayTimer;
  String? _killOverlayMessage;
  int? _lastTriggerCounter;
  int? _lastReloadCounter;
  int? _lastStartCounter;
  int? _lastPowerCounter;
  int? _lastHitBy1Key;
  int? _lastHitBy2Key;

  bool get _showAdvancedPlayerPanels => false;

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

  Future<void> _openPlayerLobbyScreen() async {
    if (!mounted) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerLobbyScreen(
          service: _service,
          initialTeam: _selectedTeam,
        ),
      ),
    );
  }

  Future<void> _handleEnterLobbyTap() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() {
        _status = 'Enter your player name before entering lobby.';
      });
      return;
    }

    if (_hasJoinedLobby) {
      final isLobbyOpen = _snapshot?.lobbyOpen ?? false;
      if (!isLobbyOpen) {
        setState(() {
          _status =
              'Lobby is closed. Wait for the server to click Open Lobby.';
        });
        return;
      }
      await _openPlayerLobbyScreen();
      return;
    }

    if (!_showJoinCodeFallback) {
      setState(() {
        _showJoinCodeFallback = true;
        _status =
            'Paste a lobby join code, then tap Enter Lobby to connect.';
      });
      return;
    }

    await _joinLobby();

    if (!mounted) {
      return;
    }

    final isLobbyOpen = _snapshot?.lobbyOpen ?? false;
    if (!isLobbyOpen) {
      setState(() {
        _status =
            'Connected, but lobby is closed. Wait for server to open lobby.';
      });
      return;
    }

    await _openPlayerLobbyScreen();
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

  Future<void> _playItemUseSound(GameItemEffectType effectType) async {
    final sound = ItemRegistry.of(effectType)?.useSound;
    await _playOptionalActionSound(sound);
  }

  void _showKillOverlay(String message) {
    setState(() => _killOverlayMessage = message);
    _killOverlayTimer?.cancel();
    _killOverlayTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _killOverlayMessage = null);
    });
  }

  Future<void> _playActionSound(String assetPath, {Duration? cutoff}) async {
    await _gunSfxPlayer.play(AssetSource(assetPath), volume: 1.0);
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
    _joinCodeController = TextEditingController();
    final initialJoinCode = widget.joinCode?.trim();
    if (initialJoinCode != null && initialJoinCode.isNotEmpty) {
      _joinCodeController.text = initialJoinCode;
      _showJoinCodeFallback = true;
    }
    _peerDirectory = PeerDirectory();
    _voiceRecorder = AudioRecorder();
    _voicePlayer = AudioPlayer();
    _gunSfxPlayer = AudioPlayer();

    final initialPlayerName = widget.initialPlayerName?.trim();
    final resolvedInitialPlayerName =
      (initialPlayerName != null && initialPlayerName.isNotEmpty)
      ? initialPlayerName
      : 'Player';

    // Use initial values from widget if provided
    if (widget.initialTeam != null && _teams.contains(widget.initialTeam)) {
      _selectedTeam = widget.initialTeam!;
    }

    _service = GameNetworkService(
      transport: UdpNetworkTransport(localPort: _playerPort),
      localPlayerId: deviceId('player'),
      initialPlayerName: resolvedInitialPlayerName,
      initialPlayerGroup: _selectedTeam,
      peerDirectory: _peerDirectory,
    );

    unawaited(_resolveGunActionAudioAssets());
    unawaited(_loadSavedPlayerName());
    unawaited(_loadSavedTeamSelection());
    _bootstrapFuture = _bootstrapSafely();
    unawaited(_bootstrapFuture);
    unawaited(_loadSavedGunProfile());

    // Auto-join if join code and initial player name are provided
    if (widget.joinCode != null && widget.autoJoinOnOpen) {
      unawaited(_autoJoinLobby());
    }
  }

  Future<void> _bootstrapSafely() async {
    try {
      await _bootstrap();
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status =
            'Network startup failed. You can still configure your gun and retry.';
      });
    }
  }

  Future<void> _loadSavedPlayerName() async {
    final initialName = widget.initialPlayerName?.trim();
    if (initialName != null && initialName.isNotEmpty) {
      if (!mounted) {
        return;
      }
      _nameController.text = initialName;
      setState(() {});
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final savedName = prefs.getString(_playerNamePrefKey)?.trim() ?? '';
    if (!mounted || savedName.isEmpty) {
      return;
    }
    _nameController.text = savedName;
    setState(() {});
  }

  Future<void> _savePlayerName([String? value]) async {
    final normalized = (value ?? _nameController.text).trim();
    final prefs = await SharedPreferences.getInstance();
    if (normalized.isEmpty) {
      await prefs.remove(_playerNamePrefKey);
      return;
    }
    await prefs.setString(_playerNamePrefKey, normalized);
  }

  Future<void> _loadSavedTeamSelection() async {
    final prefs = await SharedPreferences.getInstance();
    final savedTeam = prefs.getString(_selectedTeamPrefKey);
    if (!mounted || savedTeam == null || !_teams.contains(savedTeam)) {
      return;
    }

    setState(() {
      _selectedTeam = savedTeam;
    });

    await _service.updateLocalProfile(group: savedTeam, gunConnected: _gunConnected);
  }

  Future<void> _saveSelectedTeam(String team) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectedTeamPrefKey, team);
  }

  Future<void> _loadSavedGunProfile() async {
    try {
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
        if (!gunConnected) {
          _status = 'Connect last gun or open Gun Settings to pair a gun.';
        }
      });

      if (profile != null && gunConnected) {
        await _startGunConnectionMonitoring(profile);
        await _startBatteryMonitoring(profile);
        await _startTelemetryMonitoring(profile);
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _savedGunProfile = null;
        _gunConnected = false;
        _showGunDisconnectedAlert = false;
        _status = 'Could not load saved gun profile. Open Gun Settings to pair.';
      });
    }
  }

  Future<void> _searchLanAndHandleFallback() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() {
        _status = 'Enter your player name before searching for games.';
      });
      return;
    }

    await _savePlayerName(name);
    if (!mounted) {
      return;
    }

    final useJoinCodeFallback = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => GameBrowserScreen(
          allowManualCodeFallback: true,
          playerName: name,
          selectedTeam: _selectedTeam,
        ),
      ),
    );

    if (!mounted) {
      return;
    }

    if (useJoinCodeFallback == true) {
      setState(() {
        _showJoinCodeFallback = true;
        _status =
            'No LAN lobbies found. Paste a lobby join code to connect manually.';
      });
      return;
    }

    // A selected game opens its own join flow; do not open lobby from here.
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
          }

          final hitBy1Key = (sample.hitBy1 << 3) | sample.hitBy1ShotId;
          if (sample.hitBy1 > 0 && hitBy1Key != _lastHitBy1Key) {
            _lastHitBy1Key = hitBy1Key;
            unawaited(_playOptionalActionSound(_hitSoundAssetPath));
          }

          final hitBy2Key = (sample.hitBy2 << 3) | sample.hitBy2ShotId;
          if (sample.hitBy2 > 0 && hitBy2Key != _lastHitBy2Key) {
            _lastHitBy2Key = hitBy2Key;
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

    if (_isConnectingGun) {
      return;
    }

    setState(() {
      _isConnectingGun = true;
      _status = loadingStatus;
    });

    try {
      await BleGunController.connect(
        deviceId: profile.deviceId,
      ).timeout(_gunConnectTimeout);
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
    } on TimeoutException {
      if (!mounted) {
        return;
      }

      setState(() {
        _savedGunProfile = profile;
        _recoilEnabled = profile.recoilEnabled;
        _gunConnected = false;
        _showGunDisconnectedAlert = true;
        _status =
            'Connection timed out for ${profile.displayName}. Check power/Bluetooth and try again.';
      });
      await _service.updateLocalProfile(gunConnected: false);
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
    } finally {
      if (mounted) {
        setState(() {
          _isConnectingGun = false;
        });
      }
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
      final useIndoorProfile =
          _snapshot?.lobbyRules.firingEnvironment == FiringEnvironment.indoor;
      await BleGunController.setShotMode(
        deviceId: profile.deviceId,
        mode: profile.selectedFireMode,
        useIndoorProfile: useIndoorProfile,
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

    if (_gunConnected) {
      await _applyShotModeToGun(profile: updatedProfile);
    }
  }

  Future<void> _bootstrap() async {
    await _service.start();
    final loadedName = _nameController.text.trim();
    if (loadedName.isNotEmpty && loadedName != _service.localPlayer.name) {
      await _service.updateLocalProfile(name: loadedName);
    }
    _teamVoiceSub = _service.teamVoiceMessages.listen(_onTeamVoiceReceived);
    _service.killEvents.listen((kill) {
      if (!mounted) return;
      if (kill.victimPlayerId == _service.localPlayerId) {
        _showKillOverlay('Killed by ${kill.killerName}');
      } else if (kill.killerPlayerId == _service.localPlayerId) {
        _showKillOverlay('You eliminated ${kill.victimName}!');
      }
    });
    _service.updates.listen((snapshot) {
      if (!mounted) {
        return;
      }

      setState(() {
        _snapshot = snapshot;
        _latestPickupNotification = snapshot.recentItemPickups.isEmpty
            ? null
            : snapshot.recentItemPickups.last;
      });

      // Bomb dropping sound for every air strike pickup, heard by all players.
      final newBombs = snapshot.recentItemPickups.where(
        (p) =>
            p.effectType == GameItemEffectType.airStrike &&
            _playedBombPickupIds.add(p.id),
      );
      if (newBombs.isNotEmpty) {
        unawaited(_playOptionalActionSound(MediaConfic.bombDropping));
        Future<void>.delayed(const Duration(seconds: 7)).then((_) {
          if (mounted) {
            unawaited(_playOptionalActionSound(MediaConfic.explosion));
          }
        });
      }

      final newEffects = snapshot.activeEffects.where(
        (effect) =>
            effect.playerId == snapshot.localPlayerId &&
            _playedEffectIds.add(effect.id),
      );
      for (final effect in newEffects) {
        unawaited(_playItemUseSound(effect.effectType));
      }
    });
    await _startGpsUpdates();
  }

  Future<void> _startGpsUpdates() async {
    await _gpsSub?.cancel();

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          setState(() {
            _status = 'Location service is off. Player map updates disabled.';
          });
        }
        return;
      }

      final permission = await Geolocator.checkPermission();
      final hasPermission =
          permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
      if (!hasPermission) {
        if (mounted) {
          setState(() {
            _status =
                'Location permission missing. Player map updates disabled.';
          });
        }
        return;
      }

      _gpsSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 5,
          timeLimit: Duration(milliseconds: 1500),
        ),
      ).listen(
        (position) {
          unawaited(
            _service.updateGpsPosition(position.latitude, position.longitude),
          );
        },
        onError: (_) {
          if (!mounted) {
            return;
          }
          setState(() {
            _status = 'Could not read location updates. Continuing without GPS.';
          });
        },
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status = 'GPS initialization failed. Continuing without location.';
      });
    }
  }

  @override
  void dispose() {
    _teamVoiceSub?.cancel();
    _gunConnectionSub?.cancel();
    _gunBatterySub?.cancel();
    _gunTelemetrySub?.cancel();
    _gpsSub?.cancel();
    _nameController.dispose();
    _joinCodeController.dispose();
    _killOverlayTimer?.cancel();
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
    if (_isJoiningLobby || _hasJoinedLobby) {
      return;
    }

    final name = _nameController.text.trim();
    final joinCode = _joinCodeController.text.trim();

    if (name.isEmpty) {
      setState(() {
        _status = 'Enter your player name before joining.';
      });
      return;
    }

    await _savePlayerName(name);

    PeerEndpoint serverEndpoint;
    try {
      serverEndpoint = JoinCodeCodec.decode(joinCode);
    } on FormatException catch (error) {
      setState(() {
        _status = error.message;
      });
      return;
    }

    setState(() {
      _isJoiningLobby = true;
    });

    try {
      _peerDirectory.replaceAll(<PeerEndpoint>[serverEndpoint]);

      await _bootstrapFuture;

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
        _hasJoinedLobby = true;
        _status =
            'Joined lobby at ${serverEndpoint.host}:${serverEndpoint.port}';
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status =
            'Could not connect to lobby. Check join code/network and try again.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isJoiningLobby = false;
        });
      }
    }
  }

  Future<void> _autoJoinLobby() async {
    final joinCode = widget.joinCode;
    if (joinCode == null) {
      return;
    }

    if (_isJoiningLobby || _hasJoinedLobby) {
      return;
    }

    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() {
        _status = 'Enter your player name before joining.';
      });
      return;
    }

    await _savePlayerName(name);

    PeerEndpoint serverEndpoint;
    try {
      serverEndpoint = JoinCodeCodec.decode(joinCode);
    } on FormatException catch (error) {
      setState(() {
        _status = 'Invalid join code: ${error.message}';
      });
      return;
    }

    setState(() {
      _isJoiningLobby = true;
    });

    try {
      _peerDirectory.replaceAll(<PeerEndpoint>[serverEndpoint]);

      await _bootstrapFuture;

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
        _hasJoinedLobby = true;
        _status =
            'Joined lobby at ${serverEndpoint.host}:${serverEndpoint.port}';
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _status =
            'Could not connect to lobby. Check join code/network and try again.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isJoiningLobby = false;
        });
      }
    }
  }

  Future<void> _handleTeamSelectionChanged(
    String team, {
    required bool hasJoinedLobby,
  }) async {
    if (_selectedTeam == team) {
      return;
    }

    setState(() {
      _selectedTeam = team;
    });
    await _saveSelectedTeam(team);

    if (!hasJoinedLobby) {
      return;
    }

    await _service.updateLocalProfile(group: team, gunConnected: _gunConnected);
    if (!mounted) {
      return;
    }
    setState(() {
      _status = 'Team changed to $team.';
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

  String _localActiveEffectsLabel(NetworkSnapshot? snapshot) {
    final localEffects =
        snapshot?.activeEffects
            .where((effect) => effect.playerId == _service.localPlayerId)
            .map((effect) => effect.effectType.label)
            .toList() ??
        const <String>[];
    if (localEffects.isEmpty) {
      return 'No active item effects';
    }
    return 'Active effects: ${localEffects.join(' • ')}';
  }

  Widget _buildKillOverlay() {
    final message = _killOverlayMessage;
    if (message == null) return const SizedBox.shrink();
    return Positioned(
      bottom: 120,
      left: 24,
      right: 24,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.redAccent, width: 2),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                const Icon(
                  Icons.local_fire_department,
                  color: Colors.redAccent,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildItemPickupOverlay() {
    final pickup = _latestPickupNotification;
    if (pickup == null) {
      return const SizedBox.shrink();
    }
    if (DateTime.now().difference(pickup.createdAt) >
        const Duration(seconds: 5)) {
      return const SizedBox.shrink();
    }

    final categoryColor = () {
      switch (pickup.effectType.category) {
        case GameItemCategory.healing:
          return Colors.lightGreenAccent;
        case GameItemCategory.armor:
          return Colors.lightBlueAccent;
        case GameItemCategory.damage:
          return Colors.orangeAccent;
        case GameItemCategory.special:
          return Colors.amberAccent;
      }
    }();

    return Positioned(
      top: 12,
      left: 12,
      right: 12,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.84),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: categoryColor, width: 2),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: <Widget>[
                Icon(Icons.inventory_2, color: categoryColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${pickup.playerName} picked ${pickup.effectType.category.label}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_gunConnected) {
      final hasSavedGun = _savedGunProfile != null;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Gun Connection'),
          actions: const <Widget>[ThemeToggleButton()],
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const Icon(Icons.bluetooth_searching, size: 44),
                    const SizedBox(height: 12),
                    const Text(
                      'Connect Gun',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _status,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _isConnectingGun || !hasSavedGun
                          ? null
                          : _reconnectGun,
                      icon: const Icon(Icons.bluetooth_connected, size: 18),
                      label: Text(
                        _isConnectingGun
                            ? 'Connecting...'
                            : hasSavedGun
                            ? 'Connect Last Gun'
                            : 'No Saved Gun',
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _isConnectingGun ? null : _openGunSettings,
                      icon: const Icon(Icons.manage_search, size: 18),
                      label: const Text('Find / Pair Gun'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final snapshot = _snapshot;
    final players = snapshot?.players.values.toList() ?? const <PlayerState>[];
    final activeEffectsLabel = _localActiveEffectsLabel(snapshot);
    final networkHint = _joinCodeNetworkHint(_joinCodeController.text);
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
    final teamSecondaryFilledButtonStyle = FilledButton.styleFrom(
      backgroundColor: teamPalette.secondary.withValues(
        alpha: brightness == Brightness.dark ? 0.72 : 0.82,
      ),
      foregroundColor: teamPalette.foreground(brightness),
      elevation: 5,
      shadowColor: teamPalette.secondary.withValues(alpha: 0.4),
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
    final hasJoinedLobby = _hasJoinedLobby;
    final isServerLobbyOpen = snapshot?.lobbyOpen ?? false;
    final isFreeForAll =
        (snapshot?.lobbyRules.gameType ?? GameType.time) == GameType.freeForAll;
    final countdownStarted =
        snapshot?.scheduledGameStartAt != null ||
        snapshot?.gamePhase == GamePhase.running ||
        snapshot?.gamePhase == GamePhase.ended;
    final canChangeTeam =
        !isFreeForAll && (!hasJoinedLobby || !countdownStarted);
    final lobbyPlayers = <PlayerState>[...players];
    if (localPlayer != null &&
        !lobbyPlayers.any((p) => p.id == _service.localPlayerId)) {
      lobbyPlayers.insert(0, localPlayer);
    }
    final teamBuckets = <String, List<PlayerState>>{};
    if (isFreeForAll) {
      teamBuckets['Players'] = lobbyPlayers;
    } else {
      for (final team in _teams) {
        teamBuckets[team] = <PlayerState>[];
      }
      for (final player in lobbyPlayers) {
        teamBuckets
            .putIfAbsent(player.group, () => <PlayerState>[])
            .add(player);
      }
    }
    final localPlayerName = localPlayer?.name.isNotEmpty == true
        ? localPlayer!.name
        : _nameController.text.trim().isNotEmpty
        ? _nameController.text.trim()
        : 'Player';
    final hasPlayerName = _nameController.text.trim().isNotEmpty;
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
                                      hasJoinedLobby
                                          ? 'Lobby (${lobbyPlayers.length} players)'
                                          : 'Lobby preview (${lobbyPlayers.length} players)',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleSmall,
                                    ),
                                    const SizedBox(height: 8),
                                    if (!isFreeForAll)
                                      DropdownButtonFormField<String>(
                                        initialValue: _selectedTeam,
                                        isDense: true,
                                        decoration: InputDecoration(
                                          labelText: countdownStarted
                                              ? 'Team (locked: countdown started)'
                                              : 'Team selection',
                                          border: const OutlineInputBorder(),
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
                                        onChanged: canChangeTeam
                                            ? (team) {
                                                if (team != null) {
                                                  unawaited(
                                                    _handleTeamSelectionChanged(
                                                      team,
                                                      hasJoinedLobby:
                                                          hasJoinedLobby,
                                                    ),
                                                  );
                                                }
                                              }
                                            : null,
                                      ),
                                    const SizedBox(height: 8),
                                    if (lobbyPlayers.isEmpty)
                                      const Text('No players connected yet.')
                                    else
                                      ...teamBuckets.entries
                                          .where(
                                            (entry) => entry.value.isNotEmpty,
                                          )
                                          .expand(
                                            (entry) => <Widget>[
                                              if (!isFreeForAll)
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        top: 6,
                                                        bottom: 4,
                                                      ),
                                                  child: Text(
                                                    'Team ${entry.key}',
                                                    style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                                  ),
                                                ),
                                              ...entry.value.map(
                                                (player) => Padding(
                                                  padding:
                                                      const EdgeInsets.only(
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
                                                          ? const SizedBox(
                                                              width: 4,
                                                            )
                                                          : const SizedBox.shrink(),
                                                      Expanded(
                                                        child: Text(
                                                          '${player.name} • ${player.playerClass == 'Team Lead' ? 'Team Lead' : 'Assault'}',
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ],
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
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        'Gun mode: $localGunMode',
                                        style: TextStyle(
                                          color: panelTextColor,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Row(
                                        children: <Widget>[
                                          Icon(
                                            _batteryIconForLevel(
                                              _gunBatteryLevel,
                                            ),
                                            size: 16,
                                            color: _batteryColorForLevel(
                                              _gunBatteryLevel,
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            'Battery: ${_batteryLabelForLevel(_gunBatteryLevel)}',
                                            style: TextStyle(
                                              color: panelSecondaryTextColor,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 8),
                                TextField(
                                  controller: _nameController,
                                  onChanged: (value) {
                                    setState(() {});
                                    unawaited(_savePlayerName(value));
                                  },
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
                                      child: OutlinedButton.icon(
                                        style: teamOutlinedButtonStyle,
                                        onPressed: _searchLanAndHandleFallback,
                                        icon: const Icon(Icons.wifi_find),
                                        label: const Text('Search LAN'),
                                      ),
                                    ),
                                    if (hasPlayerName) ...<Widget>[
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: FilledButton.icon(
                                          style: teamSecondaryFilledButtonStyle,
                                          onPressed: () {
                                            unawaited(_handleEnterLobbyTap());
                                          },
                                          icon: const Icon(Icons.login),
                                          label: const Text('Enter Lobby'),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 8),
                                DropdownButtonFormField<String>(
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
                                  onChanged: canChangeTeam
                                      ? (team) {
                                          if (team != null) {
                                            unawaited(
                                              _handleTeamSelectionChanged(
                                                team,
                                                hasJoinedLobby: hasJoinedLobby,
                                              ),
                                            );
                                          }
                                        }
                                      : null,
                                ),
                                if (hasJoinedLobby) ...<Widget>[
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
                                          'Game Rules',
                                          style: TextStyle(
                                            color: panelTextColor,
                                            fontWeight: FontWeight.w700,
                                            fontSize: 14,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          'Type: ${snapshot?.lobbyRules.gameType.label ?? "Unknown"}',
                                          style: TextStyle(
                                            color: panelSecondaryTextColor,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          'Duration: ${snapshot?.lobbyRules.matchLengthMinutes ?? 0} minutes',
                                          style: TextStyle(
                                            color: panelSecondaryTextColor,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        SizedBox(
                                          width: double.infinity,
                                          child: FilledButton.icon(
                                            style: teamSecondaryFilledButtonStyle,
                                            onPressed: () {
                                              Navigator.of(context).push(
                                                MaterialPageRoute<void>(
                                                  builder: (_) =>
                                                      LobbyRulesHelpScreen(
                                                        rules:
                                                            snapshot
                                                                    ?.lobbyRules ??
                                                            const LobbyRules
                                                                .defaults(),
                                                      ),
                                                ),
                                              );
                                            },
                                            icon: const Icon(Icons.info),
                                            label: const Text(
                                                'View Full Rules Explanation'),
                                          ),
                                        ),
                                      ],
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
                                          'Items Available',
                                          style: TextStyle(
                                            color: panelTextColor,
                                            fontWeight: FontWeight.w700,
                                            fontSize: 14,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        ...ItemRegistry.definitions.values
                                            .map(
                                              (item) => Padding(
                                                padding:
                                                    const EdgeInsets.only(
                                                      bottom: 6,
                                                    ),
                                                child: Row(
                                                  children: <Widget>[
                                                    Icon(
                                                      Icons.inventory_2,
                                                      size: 14,
                                                      color:
                                                          panelSecondaryTextColor,
                                                    ),
                                                    const SizedBox(width: 6),
                                                    Expanded(
                                                      child: Text(
                                                        item.name,
                                                        style: TextStyle(
                                                          color:
                                                              panelSecondaryTextColor,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  SizedBox(
                                    width: double.infinity,
                                    child: FilledButton.icon(
                                      style: teamSecondaryFilledButtonStyle,
                                      onPressed: isServerLobbyOpen
                                          ? () {
                                              unawaited(
                                                _openPlayerLobbyScreen(),
                                              );
                                            }
                                          : null,
                                      icon: const Icon(Icons.login),
                                      label: const Text('Enter Lobby'),
                                    ),
                                  ),
                                  if (!isServerLobbyOpen) ...<Widget>[
                                    const SizedBox(height: 6),
                                    Text(
                                      'Lobby is currently closed. Wait for server to click Open Lobby.',
                                      style: TextStyle(
                                        color: panelSecondaryTextColor,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ],
                                if (_showAdvancedPlayerPanels) ...<Widget>[
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
                                  child: Text(
                                    activeEffectsLabel,
                                    style: TextStyle(color: panelTextColor),
                                    maxLines: 2,
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
                                        hasJoinedLobby
                                            ? (countdownStarted
                                                  ? 'Lobby countdown active. Team changes are locked.'
                                                  : 'Lobby connected. You can still change your team.')
                                            : 'Enter name and connect to a lobby.',
                                        style: TextStyle(
                                          color: panelSecondaryTextColor,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 8),
                                DropdownButtonFormField<String>(
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
                                  onChanged: canChangeTeam
                                      ? (team) {
                                          if (team != null) {
                                            unawaited(
                                              _handleTeamSelectionChanged(
                                                team,
                                                hasJoinedLobby: hasJoinedLobby,
                                              ),
                                            );
                                          }
                                        }
                                      : null,
                                ),
                                const SizedBox(height: 8),
                                if (_showJoinCodeFallback) ...<Widget>[
                                  TextField(
                                    controller: _joinCodeController,
                                    decoration: InputDecoration(
                                      isDense: compact,
                                      labelText: 'Lobby join code',
                                      helperText: compact
                                          ? null
                                          : 'Paste the code shown on the host device.',
                                      border: const OutlineInputBorder(),
                                    ),
                                    maxLines: 1,
                                    onChanged: (_) {
                                      setState(() {});
                                    },
                                  ),
                                  const SizedBox(height: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: textPanelBg,
                                      border: Border.all(
                                        color: textPanelBorder,
                                      ),
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
                                    style: teamSecondaryFilledButtonStyle,
                                    onPressed: hasPlayerName
                                        ? () {
                                            unawaited(_handleEnterLobbyTap());
                                          }
                                        : null,
                                    icon: const Icon(Icons.login),
                                    label: const Text('Enter Lobby'),
                                  ),
                                  const SizedBox(height: 8),
                                ],
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
          _buildItemPickupOverlay(),
          _buildGunDisconnectedOverlay(overlaySearchButtonStyle),
          _buildKillOverlay(),
        ],
      ),
    );
  }
}
