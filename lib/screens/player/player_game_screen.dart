import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart' hide PlayerState;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../media_confic.dart';
import '../../network/game_network_service.dart';
import '../../network/item_definitions.dart';
import '../../network/item_models.dart';
import '../../network/player_state.dart';
import '../../screens/player/gun_settings_screen.dart';
import '../../screens/player/player_results_screen.dart';
import '../../theme/team_colors.dart';
import '../../theme/theme_toggle_button.dart';
import '../../utils/ble_gun_controller.dart';
import '../../utils/gun_profile_storage.dart';
import '../../utils/helpers.dart'
    show ensureMicrophonePermission, teamBackgroundColors;
import '../../utils/offline_map_cache.dart';

class PlayerGameScreen extends StatefulWidget {
  const PlayerGameScreen({super.key, required this.service});

  final GameNetworkService service;

  @override
  State<PlayerGameScreen> createState() => _PlayerGameScreenState();
}

class _PlayerGameScreenState extends State<PlayerGameScreen> {
  static const int _startingAmmo = 15;
  static const Duration _reloadTelemetrySyncWindow = Duration(seconds: 2);
  static const int _burst3ShotsPerTriggerPress = 3;
  static const int _autoShotsPerTriggerPress = 1;
  static const Duration _burstShotInterval = Duration(milliseconds: 90);
  static const Duration _autoShotInterval = Duration(milliseconds: 70);
  static const Duration _autoReconnectCooldown = Duration(seconds: 2);
  static const int _recoilTriggerButtonBit = 0x01;
  static const double _radarRangeMeters = 80;

  Timer? _matchTimer;
  Timer? _reloadTimer;
  Timer? _autoFireTimer;
  Timer? _itemOverlayTimer;
  Timer? _autoReconnectTimer;
  int _timeRemaining = 0;
  int _livesLeft = 10;
  int _ammoLeft = _startingAmmo;
  bool _isGameRunning = true;
  bool _isReloading = false;
  bool _isFiringSequence = false;
  bool _isTriggerHeld = false;
  String _fireType = 'Burst';
  String _role = 'Assult';
  bool _shieldActive = false;
  bool _canUsePlayerHeal = false;
  DateTime? _shieldExpiresAt;
  DateTime? _noReloadExpiresAt;
  DateTime? _doubleDamageExpiresAt;
  DateTime? _invisibilityExpiresAt;
  _ItemPickupOverlay? _activePickupOverlay;
  _PendingAirStrike? _pendingAirStrike;
  Timer? _killOverlayTimer;
  String? _killOverlayMessage;
  String? _lastPickupNotificationId;
  double _radarSweepDegrees = 0;
  int _tick = 0;
  NetworkSnapshot? _snapshot;
  StreamSubscription<NetworkSnapshot>? _snapshotSub;
  StreamSubscription<KillEvent>? _killEventSub;
  StreamSubscription<TeamVoiceMessage>? _teamVoiceSub;
  late final AudioRecorder _teamVoiceRecorder;
  late final AudioPlayer _teamVoicePlayer;
  late final AudioPlayer _gunSfxPlayer;
  final List<AudioPlayer> _shotSfxPlayers = List<AudioPlayer>.generate(
    4,
    (_) => AudioPlayer(),
  );
  int _shotSfxPlayerIndex = 0;
  String _gunShotAssetPath = MediaConfic.laserShot;
  String? _reloadSoundAssetPath;
  String? _healSoundAssetPath;
  Timer? _gunSfxCutoffTimer;
  bool _isRecordingTeamVoice = false;
  String _teamVoiceStatus = 'Team voice ready.';
  final MapController _mapController = MapController();
  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<bool>? _gunConnectionSub;
  StreamSubscription<GunBatteryLevel>? _gunBatterySub;
  StreamSubscription<GunTelemetrySample>? _gunTelemetrySub;
  LatLng? _gpsPlayerPosition;
  String _gpsStatus = 'GPS: requesting location...';
  GunProfile? _savedGunProfile;
  GunBatteryLevel? _gunBatteryLevel;
  bool _gunConnected = false;
  bool _showGunDisconnectedAlert = false;
  bool _didNavigateToResults = false;
  int? _lastTriggerCounter;
  int? _lastReloadCounter;
  int? _lastStartCounter;
  int? _lastRecoilPlayerIdReported;
  int? _lastHitBy1Key;
  int? _lastHitBy2Key;

  void _navigateToResultsIfNeeded([NetworkSnapshot? snapshot]) {
    if (!mounted || _didNavigateToResults) {
      return;
    }

    final finalSnapshot = snapshot ?? _snapshot ?? widget.service.snapshot;
    final players = finalSnapshot.players.values.toList();
    if (players.isEmpty) {
      return;
    }

    _didNavigateToResults = true;
    _matchTimer?.cancel();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => PlayerResultsScreen(
            players: players,
            localPlayerId: widget.service.localPlayerId,
          ),
        ),
      );
    });
  }

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

  String _displayFireType(FireMode mode) {
    switch (mode) {
      case FireMode.single:
        return 'Single';
      case FireMode.burst3:
        return 'Burst 3';
      case FireMode.auto:
        return 'Auto';
    }
  }

  void _syncFireTypeFromProfile(GunProfile profile) {
    _fireType = _displayFireType(profile.selectedFireMode);
  }

  Future<void> _playGunShotSound() async {
    try {
      final player = _shotSfxPlayers[_shotSfxPlayerIndex];
      _shotSfxPlayerIndex = (_shotSfxPlayerIndex + 1) % _shotSfxPlayers.length;
      await player.stop();
      await player.play(AssetSource(_gunShotAssetPath), volume: 1.0);
    } catch (_) {
      // Keep gameplay running if audio fails.
    }
  }

  Future<void> _playItemUseSound(GameItemEffectType effectType) async {
    final sound = ItemRegistry.of(effectType)?.useSound;
    await _playOptionalActionSound(sound);
  }

  void _showKillOverlay(String message) {
    setState(() => _killOverlayMessage = message);
    _killOverlayTimer?.cancel();
    _killOverlayTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() => _killOverlayMessage = null);
      }
    });
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
      // Keep gameplay running if audio fails.
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
  }

  @override
  void initState() {
    super.initState();
    unawaited(WakelockPlus.enable());
    _teamVoiceRecorder = AudioRecorder();
    _teamVoicePlayer = AudioPlayer();
    _gunSfxPlayer = AudioPlayer();
    unawaited(_resolveGunActionAudioAssets());
    unawaited(_loadSavedGunProfile());
    unawaited(_initializeGpsTracking());

    // Initialise timer length from server rules.
    final rules = widget.service.snapshot.lobbyRules;
    _timeRemaining = rules.matchLengthMinutes * 60;
    _livesLeft = rules.maxLives;
    _snapshot = widget.service.snapshot;

    _snapshotSub = widget.service.updates.listen(_onSnapshotUpdate);
    _killEventSub = widget.service.killEvents.listen(_onKillEvent);
    _teamVoiceSub = widget.service.teamVoiceMessages.listen(
      _onTeamVoiceReceived,
    );

    _startTimer();
  }

  @override
  void dispose() {
    unawaited(WakelockPlus.disable());
    _matchTimer?.cancel();
    _reloadTimer?.cancel();
    _autoFireTimer?.cancel();
    _itemOverlayTimer?.cancel();
    _killOverlayTimer?.cancel();
    _autoReconnectTimer?.cancel();
    _snapshotSub?.cancel();
    _killEventSub?.cancel();
    _teamVoiceSub?.cancel();
    unawaited(_positionSubscription?.cancel());
    _gunConnectionSub?.cancel();
    _gunBatterySub?.cancel();
    _gunTelemetrySub?.cancel();
    _gunSfxCutoffTimer?.cancel();
    unawaited(_teamVoiceRecorder.dispose());
    unawaited(_teamVoicePlayer.dispose());
    unawaited(_gunSfxPlayer.dispose());
    for (final player in _shotSfxPlayers) {
      unawaited(player.dispose());
    }
    super.dispose();
  }

  Future<void> _loadSavedGunProfile() async {
    final profile = await GunProfileStorage.load();
    if (!mounted || profile == null) {
      return;
    }

    final gunConnected = BleGunController.isConnected(
      deviceId: profile.deviceId,
    );
    setState(() {
      _savedGunProfile = profile;
      _gunConnected = gunConnected;
      _showGunDisconnectedAlert = !gunConnected;
      _syncFireTypeFromProfile(profile);
    });

    await _startGunConnectionMonitoring(profile);
    if (gunConnected) {
      await _startBatteryMonitoring(profile);
      await _startTelemetryMonitoring(profile);
      await _applyShotModeToGun(profile);
      await _applyRecoilModeToGun(profile);
      await _armGunForMatch(profile);
    } else {
      _scheduleAutoReconnect();
    }
  }

  Future<void> _armGunForMatch(GunProfile profile) async {
    if (!_gunConnected) {
      return;
    }

    final recoilPlayerId =
        widget.service.localRecoilPlayerId ??
        widget.service.preferredRecoilPlayerId;
    try {
      await BleGunController.setPlayerId(
        deviceId: profile.deviceId,
        playerId: recoilPlayerId,
      );
      await BleGunController.reloadAmmo(
        deviceId: profile.deviceId,
        playerId: recoilPlayerId,
        shotCount: _startingAmmo,
      );
      await widget.service.updateLocalRecoilPlayerId(recoilPlayerId);
    } catch (_) {
      if (!mounted) {
        return;
      }
    }
  }

  void _onSnapshotUpdate(NetworkSnapshot snapshot) {
    if (!mounted) {
      return;
    }
    final local = snapshot.players[widget.service.localPlayerId];
    final rules = snapshot.lobbyRules;
    final maxLives = rules.maxLives;
    setState(() {
      _snapshot = snapshot;
      if (snapshot.gamePhase == GamePhase.running) {
        _isGameRunning = true;
      }
      if (local != null) {
        _livesLeft = (maxLives - local.hitsTaken).clamp(0, maxLives);
        if (_livesLeft == 0 && _isGameRunning) {
          _isGameRunning = false;
          _clearOnDeathEffects();
        }
      }
      if (snapshot.gamePhase == GamePhase.ended && _isGameRunning) {
        _isGameRunning = false;
      }
    });

    if (snapshot.gamePhase == GamePhase.ended) {
      _navigateToResultsIfNeeded(snapshot);
    }

    _syncPickupOverlay(snapshot);
    _syncAirStrikeWarningOverlay(snapshot);

    // Detect new active effects for local player and apply sound/state.
    if (local != null) {
      for (final effect in snapshot.activeEffects) {
        if (effect.playerId != widget.service.localPlayerId) {
          continue;
        }
        _applyNetworkEffect(effect);
      }
    }
  }

  void _applyNetworkEffect(ActiveGameEffect effect) {
    switch (effect.effectType) {
      case GameItemEffectType.playerShield:
      case GameItemEffectType.teamArmor:
        if (!_shieldActive) {
          _shieldActive = true;
          _shieldExpiresAt = effect.expiresAt;
        }
      case GameItemEffectType.playerHeal:
        _canUsePlayerHeal = true;
      case GameItemEffectType.teamAmmo:
      case GameItemEffectType.playerAmmo:
        if (_noReloadExpiresAt == null ||
            DateTime.now().isAfter(_noReloadExpiresAt!)) {
          _noReloadExpiresAt = effect.expiresAt;
          if (_noReloadExpiresAt != null) {
            _ammoLeft = _startingAmmo;
          }
        }
      case GameItemEffectType.doubleDamage:
        _doubleDamageExpiresAt = effect.expiresAt;
      case GameItemEffectType.invisibility:
        _invisibilityExpiresAt = effect.expiresAt;
      case GameItemEffectType.airStrike:
        // Resolved server-side.
        break;
      case GameItemEffectType.teamHeal:
        // Applied server-side; nothing local to update.
        break;
    }
  }

  void _onKillEvent(KillEvent kill) {
    if (!mounted) {
      return;
    }
    if (kill.victimPlayerId == widget.service.localPlayerId) {
      _showKillOverlay('Killed by ${kill.killerName}');
    } else if (kill.killerPlayerId == widget.service.localPlayerId) {
      _showKillOverlay('You eliminated ${kill.victimName}!');
    }
  }

  void _syncPickupOverlay(NetworkSnapshot snapshot) {
    final pickups = snapshot.recentItemPickups;
    if (pickups.isEmpty) {
      return;
    }
    final latest = pickups.last;
    if (latest.id == _lastPickupNotificationId) {
      return;
    }

    final definition = ItemRegistry.of(latest.effectType);
    _lastPickupNotificationId = latest.id;
    _itemOverlayTimer?.cancel();
    setState(() {
      _activePickupOverlay = _ItemPickupOverlay(
        collectorId: latest.playerName,
        category: latest.effectType.category,
        subcategoryLabel: definition?.name ?? latest.effectType.label,
        showUntil: DateTime.now().add(const Duration(seconds: 2)),
      );
    });

    _itemOverlayTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _activePickupOverlay = null;
      });
    });
  }

  void _syncAirStrikeWarningOverlay(NetworkSnapshot snapshot) {
    final strikeEffect = snapshot.activeEffects
        .where((effect) => effect.effectType == GameItemEffectType.airStrike)
        .cast<ActiveGameEffect?>()
        .firstWhere((_) => true, orElse: () => null);

    if (strikeEffect == null || strikeEffect.expiresAt == null) {
      if (_pendingAirStrike != null) {
        setState(() {
          _pendingAirStrike = null;
        });
      }
      return;
    }

    final targetName =
      snapshot.players[strikeEffect.playerId]?.name ?? 'Player';
    final next = _PendingAirStrike(
      targetId: targetName,
      resolveAt: strikeEffect.expiresAt!,
    );

    if (_pendingAirStrike?.targetId != next.targetId ||
        _pendingAirStrike?.resolveAt != next.resolveAt) {
      setState(() {
        _pendingAirStrike = next;
      });
    }
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
      await _teamVoicePlayer.play(BytesSource(audioBytes));
      if (mounted) {
        setState(() {
          _teamVoiceStatus =
              'Voice from ${message.senderName} (${message.team}) played.';
        });
      }
    } catch (_) {
      // Ignore playback errors.
    }
  }

  void _scheduleAutoReconnect() {
    final profile = _savedGunProfile;
    if (!mounted || profile == null || _gunConnected) {
      return;
    }
    if (_autoReconnectTimer?.isActive == true) {
      return;
    }

    _autoReconnectTimer = Timer(_autoReconnectCooldown, () {
      if (!mounted || _gunConnected) {
        return;
      }
      unawaited(_reconnectGun());
    });
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
            if (!_gunConnected) {
              setState(() {
                _gunConnected = true;
                _showGunDisconnectedAlert = false;
              });
              unawaited(_startBatteryMonitoring(profile));
              unawaited(_startTelemetryMonitoring(profile));
              unawaited(_applyShotModeToGun(profile));
              unawaited(_applyRecoilModeToGun(profile));
              unawaited(_armGunForMatch(profile));
            }
            return;
          }

          if (_gunConnected) {
            setState(() {
              _gunConnected = false;
              _showGunDisconnectedAlert = true;
              _gunBatteryLevel = null;
              _lastTriggerCounter = null;
              _lastReloadCounter = null;
              _lastStartCounter = null;
            });
            unawaited(_gunTelemetrySub?.cancel());
            _scheduleAutoReconnect();
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
    _lastRecoilPlayerIdReported = null;
    _lastHitBy1Key = null;
    _lastHitBy2Key = null;

    _gunTelemetrySub =
        BleGunController.watchTelemetry(deviceId: profile.deviceId).listen((
          sample,
        ) {
          if (!mounted) {
            return;
          }

          if (sample.recoilPlayerId > 0 &&
              sample.recoilPlayerId != _lastRecoilPlayerIdReported) {
            _lastRecoilPlayerIdReported = sample.recoilPlayerId;
            unawaited(
              widget.service.updateLocalRecoilPlayerId(sample.recoilPlayerId),
            );
          }

          final triggerHeldNow =
              (sample.buttons & _recoilTriggerButtonBit) != 0;
          if (triggerHeldNow != _isTriggerHeld) {
            _isTriggerHeld = triggerHeldNow;
            if (!_isTriggerHeld) {
              _stopAutoFireLoop();
            } else if (_savedGunProfile?.selectedFireMode == FireMode.auto) {
              _startAutoFireLoop();
            }
          }

          if (sample.triggerCounter != _lastTriggerCounter) {
            _lastTriggerCounter = sample.triggerCounter;
            unawaited(_handleGunButtonPress(GunButton.trigger));
          }

          if (sample.reloadCounter != _lastReloadCounter) {
            _lastReloadCounter = sample.reloadCounter;
            unawaited(_handleGunButtonPress(GunButton.reload));
          }

          if (sample.thumbCounter != _lastStartCounter) {
            _lastStartCounter = sample.thumbCounter;
            unawaited(_handleGunButtonPress(GunButton.thumb));
          }

          final hitBy1Key = (sample.hitBy1 << 3) | sample.hitBy1ShotId;
          if (sample.hitBy1 > 0 && hitBy1Key != _lastHitBy1Key) {
            _lastHitBy1Key = hitBy1Key;
            unawaited(_onHitFromGun(sample.hitBy1));
          }

          final hitBy2Key = (sample.hitBy2 << 3) | sample.hitBy2ShotId;
          if (sample.hitBy2 > 0 && hitBy2Key != _lastHitBy2Key) {
            _lastHitBy2Key = hitBy2Key;
            unawaited(_onHitFromGun(sample.hitBy2));
          }

          // Keep ammo accounting local in test mode so rounds are consumed only
          // when this screen confirms a shot event per selected fire mode.
        });
  }

  void _startAutoFireLoop() {
    if (_autoFireTimer != null && _autoFireTimer!.isActive) {
      return;
    }

    _autoFireTimer = Timer.periodic(_autoShotInterval, (_) {
      if (!mounted || !_isTriggerHeld || _isReloading) {
        _stopAutoFireLoop();
        return;
      }
      final profile = _savedGunProfile;
      if (profile == null || profile.selectedFireMode != FireMode.auto) {
        _stopAutoFireLoop();
        return;
      }
      unawaited(_fireByMode(FireMode.auto));
    });
  }

  void _stopAutoFireLoop() {
    _autoFireTimer?.cancel();
    _autoFireTimer = null;
  }

  bool _fireSingleShot() {
    final hasUnlimitedAmmo =
        _noReloadExpiresAt != null &&
        DateTime.now().isBefore(_noReloadExpiresAt!);
    if (_isReloading || (!hasUnlimitedAmmo && _ammoLeft <= 0)) {
      return false;
    }

    if (!hasUnlimitedAmmo) {
      _ammoLeft -= 1;
    }
    return true;
  }

  Future<void> _fireByMode(FireMode mode) async {
    if (!mounted || _isReloading) {
      return;
    }

    final hasUnlimitedAmmo =
        _noReloadExpiresAt != null &&
        DateTime.now().isBefore(_noReloadExpiresAt!);
    if (!hasUnlimitedAmmo && _ammoLeft <= 0) {
      return;
    }

    if (_isFiringSequence) {
      return;
    }

    int shotsToFire;
    Duration spacing;
    String modeLabel;
    switch (mode) {
      case FireMode.single:
        shotsToFire = 1;
        spacing = Duration.zero;
        modeLabel = 'Single';
      case FireMode.burst3:
        shotsToFire = _burst3ShotsPerTriggerPress;
        spacing = _burstShotInterval;
        modeLabel = 'Burst 3';
      case FireMode.auto:
        // SimpleCoil uses FE/01 for full-auto (continuous while held). In this
        // trigger-event test screen, a single press event maps to one auto shot.
        shotsToFire = _autoShotsPerTriggerPress;
        spacing = _autoShotInterval;
        modeLabel = 'Auto';
    }

    _isFiringSequence = true;
    var firedShots = 0;
    try {
      for (var i = 0; i < shotsToFire; i++) {
        if (!mounted || _isReloading) {
          break;
        }

        var shotFired = false;
        setState(() {
          shotFired = _fireSingleShot();
        });

        if (!shotFired) {
          break;
        }

        firedShots += 1;
        final profile = _savedGunProfile;
        if (profile != null && _gunConnected) {
          unawaited(BleGunController.pulseRecoil(deviceId: profile.deviceId));
        }
        unawaited(_playGunShotSound());
        if (i < shotsToFire - 1 && spacing > Duration.zero) {
          await Future<void>.delayed(spacing);
        }
      }
    } finally {
      _isFiringSequence = false;
    }

    if (!mounted) {
      return;
    }

  }

  Future<void> _onHitFromGun(int shooterId) async {
    if (!mounted) {
      return;
    }

    if (_shieldActive &&
        _shieldExpiresAt != null &&
        DateTime.now().isBefore(_shieldExpiresAt!)) {
      return;
    }

    final registered = await widget.service.registerTelemetryHit(shooterId);

    if (!mounted) {
      return;
    }

    setState(() {
      if (!registered) {
        return;
      }

      _shieldActive = false;
      _shieldExpiresAt = null;
    });
  }

  Future<void> _applyRecoilModeToGun(GunProfile profile) async {
    try {
      await BleGunController.setRecoilMode(
        deviceId: profile.deviceId,
        enabled: profile.recoilEnabled,
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
    }
  }

  Future<void> _applyShotModeToGun(GunProfile profile) async {
    try {
      await BleGunController.setShotMode(
        deviceId: profile.deviceId,
        mode: profile.selectedFireMode,
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
    }
  }

  Future<void> _reconnectGun() async {
    final profile = _savedGunProfile ?? await GunProfileStorage.load();
    if (!mounted || profile == null) {
      return;
    }

    _autoReconnectTimer?.cancel();

    try {
      await BleGunController.connect(deviceId: profile.deviceId);
      if (!mounted) {
        return;
      }

      setState(() {
        _savedGunProfile = profile;
        _gunConnected = true;
        _showGunDisconnectedAlert = false;
      });

      await _startGunConnectionMonitoring(profile);
      await _startBatteryMonitoring(profile);
      await _startTelemetryMonitoring(profile);
      await _applyShotModeToGun(profile);
      await _applyRecoilModeToGun(profile);
      await _armGunForMatch(profile);
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _savedGunProfile = profile;
        _gunConnected = false;
        _showGunDisconnectedAlert = true;
      });
      _scheduleAutoReconnect();
    }
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
                        '${profile.displayName} is offline. Reconnect the gun or search for another gun before you keep playing.',
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
    setState(() {
      _savedGunProfile = profile;
      _syncFireTypeFromProfile(profile);
    });
    await _reconnectGun();
  }

  Future<void> _toggleTeamVoiceRecording() async {
    if (_isRecordingTeamVoice) {
      await _stopAndPlayTeamVoice();
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
    await widget.service.sendTeamVoiceMessage(
      audioBase64: encoded,
      mimeType: 'audio/mp4',
      durationMs: 0,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _teamVoiceStatus = 'Voice message sent to the lobby.';
    });
  }

  Future<void> _initializeGpsTracking() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (!mounted) {
        return;
      }
      setState(() {
        _gpsStatus = 'GPS: location service disabled.';
      });
      return;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (!mounted) {
        return;
      }
      setState(() {
        _gpsStatus = 'GPS: location permission denied.';
      });
      return;
    }

    final current = await Geolocator.getCurrentPosition();
    if (mounted) {
      final livePosition = LatLng(current.latitude, current.longitude);
      setState(() {
        _gpsPlayerPosition = livePosition;
        _gpsStatus =
            'GPS: ${current.latitude.toStringAsFixed(5)}, ${current.longitude.toStringAsFixed(5)}';
      });
      _mapController.move(livePosition, 18);
      unawaited(
        widget.service.updateGpsPosition(current.latitude, current.longitude),
      );
    }

    _positionSubscription =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 2,
            timeLimit: Duration(milliseconds: 1500),
          ),
        ).listen((position) {
          if (!mounted) {
            return;
          }

          final livePosition = LatLng(position.latitude, position.longitude);
          setState(() {
            _gpsPlayerPosition = livePosition;
            _gpsStatus =
                'GPS: ${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)}';
          });
          _mapController.move(livePosition, 18);
          unawaited(
            widget.service.updateGpsPosition(
              position.latitude,
              position.longitude,
            ),
          );
        });
  }

  void _startTimer() {
    _matchTimer?.cancel();
    _matchTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      _tick += 1;
      _radarSweepDegrees = (_radarSweepDegrees + 18) % 360;
      _tickEffectTimers();

      // Stop the local countdown when the server ends the game.
      final serverPhase = _snapshot?.gamePhase;
      if (serverPhase == GamePhase.ended) {
        if (_isGameRunning) {
          setState(() {
            _timeRemaining = 0;
            _isGameRunning = false;
          });
        }
        _navigateToResultsIfNeeded();
        timer.cancel();
        return;
      }

      if (_timeRemaining <= 1) {
        setState(() {
          _timeRemaining = 0;
          _isGameRunning = false;
        });
        _navigateToResultsIfNeeded();
        timer.cancel();
        return;
      }

      setState(() {
        _timeRemaining -= 1;
      });
    });
  }

  void _tickEffectTimers() {
    final now = DateTime.now();
    if (_shieldExpiresAt != null && now.isAfter(_shieldExpiresAt!)) {
      _shieldExpiresAt = null;
      _shieldActive = false;
    }
    if (_noReloadExpiresAt != null && now.isAfter(_noReloadExpiresAt!)) {
      _noReloadExpiresAt = null;
    }
    if (_doubleDamageExpiresAt != null &&
        now.isAfter(_doubleDamageExpiresAt!)) {
      _doubleDamageExpiresAt = null;
    }
    if (_invisibilityExpiresAt != null &&
        now.isAfter(_invisibilityExpiresAt!)) {
      _invisibilityExpiresAt = null;
    }
  }

  void _clearOnDeathEffects() {
    _shieldActive = false;
    _shieldExpiresAt = null;
    _noReloadExpiresAt = null;
    _doubleDamageExpiresAt = null;
    _invisibilityExpiresAt = null;
    _canUsePlayerHeal = false;
  }

  void _toggleHealingBonus() {
    setState(() {
      if (_canUsePlayerHeal) {
        final maxLives = _snapshot?.lobbyRules.maxLives ?? 10;
        _livesLeft = maxLives;
        _canUsePlayerHeal = false;
        unawaited(_playItemUseSound(GameItemEffectType.playerHeal));
      }
    });
  }

  void _cycleFireType() {
    final profile = _savedGunProfile;
    if (profile == null) {
      return;
    }
    unawaited(_handleGunButtonPress(GunButton.thumb));
  }

  Future<void> _cycleConfiguredFireMode() async {
    final profile = _savedGunProfile;
    if (profile == null) {
      if (!mounted) {
        return;
      }
      return;
    }

    final allowedModes = <FireMode>[];
    if (profile.allowSingleShotMode) {
      allowedModes.add(FireMode.single);
    }
    if (profile.allowBurst3ShotMode) {
      allowedModes.add(FireMode.burst3);
    }
    if (profile.allowAutoShotMode) {
      allowedModes.add(FireMode.auto);
    }

    if (allowedModes.isEmpty) {
      if (!mounted) {
        return;
      }
      return;
    }

    final currentIndex = allowedModes.indexOf(profile.selectedFireMode);
    final nextIndex = (currentIndex + 1) % allowedModes.length;
    final nextMode = allowedModes[nextIndex];
    final updatedProfile = profile.copyWith(selectedFireMode: nextMode);
    await GunProfileStorage.save(updatedProfile);

    if (!mounted) {
      return;
    }

    setState(() {
      _savedGunProfile = updatedProfile;
      _syncFireTypeFromProfile(updatedProfile);
    });

    if (updatedProfile.selectedFireMode == FireMode.auto && _isTriggerHeld) {
      _startAutoFireLoop();
    } else {
      _stopAutoFireLoop();
    }

    if (_gunConnected) {
      await _applyShotModeToGun(updatedProfile);
    }
  }

  Future<void> _handleGunButtonPress(GunButton button) async {
    final profile = _savedGunProfile;
    if (profile == null) {
      if (!mounted) {
        return;
      }
      return;
    }

    if (button == GunButton.thumb) {
      await _cycleConfiguredFireMode();
      return;
    }

    if (button == GunButton.power) {
      await _toggleRecoilFromPowerButton();
      return;
    }

    if (!mounted) {
      return;
    }

    if (button == GunButton.trigger) {
      if (_isReloading) {
        return;
      }

      await _fireByMode(profile.selectedFireMode);
      return;
    }

    if (button == GunButton.reload) {
      if (_noReloadExpiresAt != null &&
          DateTime.now().isBefore(_noReloadExpiresAt!)) {
        setState(() {
          _ammoLeft = _startingAmmo;
        });
        return;
      }

      if (_isReloading) {
        return;
      }

      _stopAutoFireLoop();
      unawaited(_playReloadSound());

      setState(() {
        _isReloading = true;
      });

      _reloadTimer?.cancel();
      _reloadTimer = Timer(_reloadTelemetrySyncWindow, () {
        if (!mounted) {
          return;
        }
        setState(() {
          _ammoLeft = _startingAmmo;
          _isReloading = false;
        });
      });
      unawaited(_armGunForMatch(profile));
      return;
    }

  }

  Future<void> _toggleRecoilFromPowerButton() async {
    final profile = _savedGunProfile;
    if (profile == null) {
      if (!mounted) {
        return;
      }
      return;
    }

    final nextRecoilEnabled = !profile.recoilEnabled;
    final updatedProfile = profile.copyWith(recoilEnabled: nextRecoilEnabled);
    await GunProfileStorage.save(updatedProfile);

    if (!mounted) {
      return;
    }

    setState(() {
      _savedGunProfile = updatedProfile;
    });

    if (_gunConnected) {
      await _applyRecoilModeToGun(updatedProfile);
    }
  }

  void _cycleRole() {
    const roles = <String>['Assult', 'Team Lead'];
    final currentIndex = roles.indexOf(_role);
    final nextIndex = (currentIndex + 1) % roles.length;
    setState(() {
      _role = roles[nextIndex];
    });
  }

  Color _teamColor(String team) {
    return teamPaletteFor(team).accent;
  }

  LatLng _playerPosition() {
    return _gpsPlayerPosition ?? const LatLng(0, 0);
  }

  ({double xMeters, double yMeters}) _latLngToRelativeMeters(
    double lat,
    double lon,
  ) {
    final origin = _playerPosition();
    const metersPerDegreeLat = 111320.0;
    final metersPerDegreeLon =
        111320.0 * math.cos(origin.latitude * math.pi / 180);
    final xMeters = (lon - origin.longitude) * metersPerDegreeLon;
    final yMeters = -(lat - origin.latitude) * metersPerDegreeLat;
    return (xMeters: xMeters, yMeters: yMeters);
  }

  List<_RadarContact> _contactsFromSnapshot(NetworkSnapshot? snapshot) {
    if (snapshot == null) {
      return const <_RadarContact>[];
    }
    final result = <_RadarContact>[];
    for (final player in snapshot.players.values) {
      if (player.id == widget.service.localPlayerId) {
        continue;
      }
      final lat = player.latitude;
      final lon = player.longitude;
      if (lat == null || lon == null) {
        continue;
      }
      final rel = _latLngToRelativeMeters(lat, lon);
      result.add(
        _RadarContact(
          id: player.name.isNotEmpty ? player.name : player.id,
          team: player.group,
          xMeters: rel.xMeters,
          yMeters: rel.yMeters,
        ),
      );
    }
    return result;
  }

  LatLng _metersToLatLng(double xMeters, double yMeters) {
    final playerPosition = _playerPosition();
    final metersPerDegreeLat = 111320.0;
    final metersPerDegreeLon =
        111320.0 * math.cos(playerPosition.latitude * math.pi / 180);
    final latOffset = -yMeters / metersPerDegreeLat;
    final lonOffset = xMeters / metersPerDegreeLon;
    return LatLng(
      playerPosition.latitude + latOffset,
      playerPosition.longitude + lonOffset,
    );
  }

  Color _itemCategoryColor(GameItemCategory category) {
    switch (category) {
      case GameItemCategory.healing:
        return Colors.lightGreenAccent;
      case GameItemCategory.armor:
        return Colors.lightBlueAccent;
      case GameItemCategory.damage:
        return Colors.deepOrangeAccent;
      case GameItemCategory.special:
        return Colors.purpleAccent;
    }
  }

  String _itemCategoryLetter(GameItemCategory category) {
    switch (category) {
      case GameItemCategory.healing:
        return 'H';
      case GameItemCategory.armor:
        return 'A';
      case GameItemCategory.damage:
        return 'D';
      case GameItemCategory.special:
        return 'S';
    }
  }

  IconData _itemCategoryIcon(GameItemCategory category) {
    switch (category) {
      case GameItemCategory.healing:
        return Icons.healing;
      case GameItemCategory.armor:
        return Icons.shield;
      case GameItemCategory.damage:
        return Icons.bolt;
      case GameItemCategory.special:
        return Icons.warning_amber;
    }
  }

  double _distanceMeters(double x1, double y1, double x2, double y2) {
    final dx = x1 - x2;
    final dy = y1 - y2;
    return math.sqrt(dx * dx + dy * dy);
  }

  List<CircleMarker> _buildItemPickupCircles() {
    final items = _snapshot?.items ?? const <GameMapItem>[];
    final circles = items
        .map(
          (item) => CircleMarker(
            point: LatLng(item.latitude, item.longitude),
            radius: 1.5,
            useRadiusInMeter: true,
            color: _itemCategoryColor(item.category).withValues(alpha: 0.18),
            borderStrokeWidth: 1,
            borderColor: _itemCategoryColor(
              item.category,
            ).withValues(alpha: 0.95),
          ),
        )
        .toList();
    return circles;
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

    final otherPlayers = _snapshot?.players.values ?? const <PlayerState>[];
    for (final player in otherPlayers) {
      if (player.id == widget.service.localPlayerId) {
        continue;
      }
      final lat = player.latitude;
      final lon = player.longitude;
      if (lat == null || lon == null) {
        continue;
      }
      markers.add(
        Marker(
          point: LatLng(lat, lon),
          width: 26,
          height: 26,
          child: Icon(Icons.circle, color: _teamColor(player.group), size: 14),
        ),
      );
    }

    final items = _snapshot?.items ?? const <GameMapItem>[];
    for (final item in items) {
      markers.add(
        Marker(
          point: LatLng(item.latitude, item.longitude),
          width: 32,
          height: 32,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withValues(alpha: 0.7),
              border: Border.all(
                color: _itemCategoryColor(item.category),
                width: 2,
              ),
            ),
            alignment: Alignment.center,
            child: Text(
              _itemCategoryLetter(item.category),
              style: TextStyle(
                color: _itemCategoryColor(item.category),
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

  Widget _buildItemPickupOverlay() {
    final overlay = _activePickupOverlay;
    if (overlay == null || DateTime.now().isAfter(overlay.showUntil)) {
      return const SizedBox.shrink();
    }

    final color = _itemCategoryColor(overlay.category);
    return Positioned(
      top: 16,
      left: 16,
      right: 16,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.82),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color, width: 2),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: <Widget>[
                Icon(_itemCategoryIcon(overlay.category), color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${overlay.collectorId} picked ${overlay.category.label}: ${overlay.subcategoryLabel}',
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

  Widget _buildKillOverlay() {
    final message = _killOverlayMessage;
    if (message == null) {
      return const SizedBox.shrink();
    }
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

  Widget _buildAirStrikeWarningOverlay() {
    final strike = _pendingAirStrike;
    if (strike == null) {
      return const SizedBox.shrink();
    }

    final secondsLeft = strike.resolveAt
        .difference(DateTime.now())
        .inSeconds
        .clamp(0, 7);
    return Positioned(
      top: 74,
      left: 16,
      right: 16,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.red.shade800.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.amberAccent, width: 2),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: <Widget>[
                const Icon(Icons.sensors, color: Colors.amberAccent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'AIR STRIKE WARNING: ${strike.targetId} targeted. Impact in ${secondsLeft}s',
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

  Widget _statusIconTile({
    required IconData icon,
    required String title,
    required String value,
    required VoidCallback onTap,
    Color? activeColor,
  }) {
    final brightness = Theme.of(context).brightness;
    final localTeam = widget.service.localPlayer.group;
    final teamPalette = teamPaletteFor(localTeam);
    final tileBg = teamPalette.secondary.withValues(
      alpha: brightness == Brightness.dark ? 0.2 : 0.28,
    );
    final tileBorder = teamPalette.primary.withValues(
      alpha: brightness == Brightness.dark ? 0.45 : 0.28,
    );

    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          decoration: BoxDecoration(
            border: Border.all(color: tileBorder),
            borderRadius: BorderRadius.circular(12),
            color: tileBg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, color: activeColor ?? Colors.white70, size: 16),
              const SizedBox(height: 6),
              Text(title, style: const TextStyle(fontSize: 10)),
              const SizedBox(height: 2),
              Text(
                value,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
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

  Widget _buildMagazineBar() {
    const bulletIconLimit = 20;
    final maxAmmo = _startingAmmo.clamp(0, 9999);
    final ammoNow = _ammoLeft.clamp(0, maxAmmo);

    final shell = BoxDecoration(
      color: Colors.black.withValues(alpha: 0.28),
      border: Border.all(color: Colors.white24),
      borderRadius: BorderRadius.circular(6),
    );

    if (maxAmmo <= bulletIconLimit) {
      return Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 22),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: shell,
        child: ammoNow <= 0
            ? const Text(
                'Empty',
                style: TextStyle(color: Colors.white60, fontSize: 11),
              )
            : Wrap(
                spacing: 2,
                runSpacing: 2,
                children: List<Widget>.generate(ammoNow, (index) {
                  return const Icon(
                    Icons.adjust,
                    size: 9,
                    color: Colors.amberAccent,
                  );
                }),
              ),
      );
    }

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 22),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: shell,
      child: Row(
        children: <Widget>[
          const Icon(Icons.adjust, size: 10, color: Colors.amberAccent),
          const SizedBox(width: 6),
          Text(
            '$ammoNow / $maxAmmo',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
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
    final maxLives = _snapshot?.lobbyRules.maxLives ?? 10;
    final healthValue = maxLives > 0 ? _livesLeft / maxLives.toDouble() : 0.0;
    final brightness = Theme.of(context).brightness;
    final localTeam = widget.service.localPlayer.group;
    final teamPalette = teamPaletteFor(localTeam);
    final teamColors = teamBackgroundColors(localTeam, brightness: brightness);
    final panelBg = teamPalette.secondary.withValues(
      alpha: brightness == Brightness.dark ? 0.2 : 0.28,
    );
    final panelBgStrong = teamPalette.primary.withValues(
      alpha: brightness == Brightness.dark ? 0.38 : 0.22,
    );
    final panelBorder = teamPalette.primary.withValues(
      alpha: brightness == Brightness.dark ? 0.45 : 0.28,
    );
    final panelTextColor = teamPalette.foreground(brightness);
    final overlaySearchButtonStyle = OutlinedButton.styleFrom(
      foregroundColor: Colors.white,
      side: const BorderSide(color: Colors.white70),
    );

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        backgroundColor: teamPalette.primary.withValues(
          alpha: brightness == Brightness.dark ? 0.9 : 0.8,
        ),
        foregroundColor: teamPalette.foreground(brightness),
        title: const Text('Player Game'),
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
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxHeight < 760;
                    final hudPanelHeight = compact ? 280.0 : 340.0;
                    final radarPanelHeight = compact ? 260.0 : 320.0;

                    return SingleChildScrollView(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: constraints.maxHeight,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            SizedBox(
                              height: hudPanelHeight,
                              child: Card(
                                color: panelBgStrong,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  side: BorderSide(color: panelBorder),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(10),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Row(
                                        children: <Widget>[
                                          Expanded(
                                            child: Text(
                                              widget.service.localPlayer.name,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.bold,
                                                    color: Colors.white,
                                                  ),
                                            ),
                                          ),
                                          Text(
                                            localTeam,
                                            style: TextStyle(
                                              color: _teamColor(localTeam),
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
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
                                                _batteryLabelForLevel(
                                                  _gunBatteryLevel,
                                                ),
                                                style: const TextStyle(
                                                  color: Colors.white70,
                                                  fontSize: 10,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      const Text(
                                        'Health Bar',
                                        style: TextStyle(
                                          color: Colors.white70,
                                          fontSize: 11,
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
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                healthValue > 0.5
                                                    ? Colors.lightGreenAccent
                                                    : Colors.amberAccent,
                                              ),
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      const Text(
                                        'Magazine',
                                        style: TextStyle(
                                          color: Colors.white70,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      _buildMagazineBar(),
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
                                            onTap: () {},
                                            activeColor: _shieldActive
                                                ? Colors.lightBlueAccent
                                                : Colors.white54,
                                          ),
                                          const SizedBox(width: 6),
                                          _statusIconTile(
                                            icon: Icons.healing,
                                            title: 'Heal',
                                            value: _canUsePlayerHeal
                                                ? 'Ready'
                                                : 'None',
                                            onTap: _toggleHealingBonus,
                                            activeColor: _canUsePlayerHeal
                                                ? Colors.lightGreenAccent
                                                : Colors.white54,
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        _isGameRunning
                                            ? 'MATCH RUNNING'
                                            : 'MATCH STOPPED',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.copyWith(
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
                                                'Lives $_livesLeft/${_snapshot?.lobbyRules.maxLives ?? 10}',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 12,
                                                ),
                                                maxLines: 2,
                                              ),
                                            ),
                                            Expanded(
                                              child: Text(
                                                'Score ${widget.service.localPlayer.score}\n'
                                                'Shots ${widget.service.localPlayer.shotsFired}\n'
                                                'Hits ${widget.service.localPlayer.hitsTaken}\n'
                                                'Items ${_snapshot?.items.length ?? 0}\n'
                                                'AmmoBoost ${_noReloadExpiresAt != null && DateTime.now().isBefore(_noReloadExpiresAt!) ? 'On' : 'Off'}',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 12,
                                                ),
                                                maxLines: 5,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              height: radarPanelHeight,
                              child: Card(
                                color: panelBgStrong,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  side: BorderSide(color: panelBorder),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(10),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        'GPS Radar (${_radarRangeMeters.toInt()}m)',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall
                                            ?.copyWith(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                            ),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        _gpsStatus,
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 11,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Expanded(
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          child: Stack(
                                            fit: StackFit.expand,
                                            children: <Widget>[
                                              FlutterMap(
                                                mapController: _mapController,
                                                options: MapOptions(
                                                  initialCenter:
                                                      _playerPosition(),
                                                  initialZoom: 18,
                                                  interactionOptions:
                                                      const InteractionOptions(
                                                        flags: InteractiveFlag
                                                            .none,
                                                      ),
                                                ),
                                                children: <Widget>[
                                                  TileLayer(
                                                    urlTemplate:
                                                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                                    userAgentPackageName:
                                                        'lasertag_app',
                                                    tileProvider:
                                                        OfflineMapCache.localFirstTileProvider(),
                                                  ),
                                                  CircleLayer(
                                                    circles:
                                                        _buildItemPickupCircles(),
                                                  ),
                                                  MarkerLayer(
                                                    markers: _buildMapMarkers(),
                                                  ),
                                                ],
                                              ),
                                              CustomPaint(
                                                painter: _RadarPainter(
                                                  contacts:
                                                      _contactsFromSnapshot(
                                                        _snapshot,
                                                      ),
                                                  radarRangeMeters:
                                                      _radarRangeMeters,
                                                  sweepDegrees:
                                                      _radarSweepDegrees,
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
                                _isRecordingTeamVoice
                                    ? Icons.stop_circle_outlined
                                    : Icons.mic,
                                size: 18,
                              ),
                              label: Text(
                                _isRecordingTeamVoice
                                    ? 'Stop And Send Team Voice'
                                    : 'Team Voice',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _teamVoiceStatus,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          _buildItemPickupOverlay(),
          _buildAirStrikeWarningOverlay(),
          _buildKillOverlay(),
          _buildGunDisconnectedOverlay(overlaySearchButtonStyle),
        ],
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

class _ItemPickupOverlay {
  const _ItemPickupOverlay({
    required this.collectorId,
    required this.category,
    required this.subcategoryLabel,
    required this.showUntil,
  });

  final String collectorId;
  final GameItemCategory category;
  final String subcategoryLabel;
  final DateTime showUntil;
}

class _PendingAirStrike {
  const _PendingAirStrike({
    required this.targetId,
    required this.resolveAt,
  });

  final String targetId;
  final DateTime resolveAt;
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
