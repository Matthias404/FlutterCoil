import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../media_confic.dart';
import '../../screens/player/gun_settings_screen.dart';
import '../../theme/team_colors.dart';
import '../../theme/theme_toggle_button.dart';
import '../../utils/ble_gun_controller.dart';
import '../../utils/gun_profile_storage.dart';
import '../../utils/helpers.dart'
    show ensureMicrophonePermission, teamBackgroundColors;
import '../../utils/offline_map_cache.dart';

class PlayerGameTestScreen extends StatefulWidget {
  const PlayerGameTestScreen({super.key});

  @override
  State<PlayerGameTestScreen> createState() => _PlayerGameTestScreenState();
}

class _PlayerGameTestScreenState extends State<PlayerGameTestScreen> {
  static const int _maxLives = 10;
  static const int _startingAmmo = 15;
  static const Duration _reloadTelemetrySyncWindow = Duration(seconds: 2);
  static const int _burst3ShotsPerTriggerPress = 3;
  static const int _autoShotsPerTriggerPress = 1;
  static const Duration _burstShotInterval = Duration(milliseconds: 90);
  static const Duration _autoShotInterval = Duration(milliseconds: 70);
  static const int _recoilTriggerButtonBit = 0x01;
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
  Timer? _reloadTimer;
  Timer? _autoFireTimer;
  int _timeRemaining = _matchLengthSeconds;
  int _livesLeft = _maxLives;
  int _ammoLeft = _startingAmmo;
  int _score = 0;
  int _hitsTaken = 0;
  int _shotsFired = 0;
  bool _isGameRunning = true;
  bool _isReloading = false;
  bool _isFiringSequence = false;
  bool _isTriggerHeld = false;
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
    const _RadarContact(
      id: 'P3',
      team: 'Green Team',
      xMeters: -18,
      yMeters: 32,
    ),
    const _RadarContact(id: 'P4', team: 'Yellow Team', xMeters: 45, yMeters: 8),
    const _RadarContact(id: 'P5', team: 'Red Team', xMeters: -35, yMeters: -22),
  ];
  List<_MapItem> _items = <_MapItem>[];
  late final AudioRecorder _teamVoiceRecorder;
  late final AudioPlayer _teamVoicePlayer;
  late final AudioPlayer _gunSfxPlayer;
  String _gunShotAssetPath = MediaConfic.laserShot;
  String? _reloadSoundAssetPath;
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
  int? _lastTriggerCounter;
  int? _lastReloadCounter;
  int? _lastStartCounter;
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
      await _playActionSound(
        _gunShotAssetPath,
        cutoff: const Duration(milliseconds: 640),
      );
    } catch (_) {
      // Keep gameplay running if audio fails.
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
    _teamVoiceRecorder = AudioRecorder();
    _teamVoicePlayer = AudioPlayer();
    _gunSfxPlayer = AudioPlayer();
    unawaited(_resolveGunActionAudioAssets());
    unawaited(_loadSavedGunProfile());
    unawaited(_initializeGpsTracking());
    _startTimer();
  }

  @override
  void dispose() {
    _matchTimer?.cancel();
    _reloadTimer?.cancel();
    _autoFireTimer?.cancel();
    unawaited(_positionSubscription?.cancel());
    _gunConnectionSub?.cancel();
    _gunBatterySub?.cancel();
    _gunTelemetrySub?.cancel();
    _gunSfxCutoffTimer?.cancel();
    unawaited(_teamVoiceRecorder.dispose());
    unawaited(_teamVoicePlayer.dispose());
    unawaited(_gunSfxPlayer.dispose());
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
                _eventText = 'Gun connected: ${profile.displayName}.';
              });
              unawaited(_startBatteryMonitoring(profile));
              unawaited(_startTelemetryMonitoring(profile));
            }
            return;
          }

          if (_gunConnected || !_showGunDisconnectedAlert) {
            setState(() {
              _gunConnected = false;
              _showGunDisconnectedAlert = true;
              _gunBatteryLevel = null;
              _lastTriggerCounter = null;
              _lastReloadCounter = null;
              _lastStartCounter = null;
              _eventText =
                  'Gun disconnected. Check Bluetooth range and reconnect it.';
            });
            unawaited(_gunTelemetrySub?.cancel());
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
    _lastHitBy1Key = null;
    _lastHitBy2Key = null;

    _gunTelemetrySub =
        BleGunController.watchTelemetry(deviceId: profile.deviceId).listen((
          sample,
        ) {
          if (!mounted) {
            return;
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
            _onHitFromGun(sample.hitBy1);
          }

          final hitBy2Key = (sample.hitBy2 << 3) | sample.hitBy2ShotId;
          if (sample.hitBy2 > 0 && hitBy2Key != _lastHitBy2Key) {
            _lastHitBy2Key = hitBy2Key;
            _onHitFromGun(sample.hitBy2);
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
    if (_isReloading || _ammoLeft <= 0) {
      return false;
    }

    _ammoLeft -= 1;
    _shotsFired += 1;
    return true;
  }

  Future<void> _fireByMode(FireMode mode) async {
    if (!mounted || _isReloading) {
      return;
    }

    if (_ammoLeft <= 0) {
      setState(() {
        _eventText = 'Trigger pressed: Empty magazine.';
      });
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

    setState(() {
      if (firedShots == 0) {
        _eventText = 'Trigger pressed: Empty magazine.';
      } else {
        _eventText =
            'Trigger pressed: $modeLabel fired $firedShots shot${firedShots == 1 ? '' : 's'}.';
      }
    });
  }

  void _onHitFromGun(int shooterId) {
    if (!mounted) {
      return;
    }

    setState(() {
      _hitsTaken += 1;
      if (_shieldActive) {
        _shieldActive = false;
        _eventText = 'Hit from player $shooterId blocked by shield.';
        return;
      }

      _livesLeft = (_livesLeft - 1).clamp(0, _maxLives);
      if (_livesLeft == 0) {
        _isGameRunning = false;
        _eventText = 'You were hit by player $shooterId and eliminated.';
      } else {
        _eventText =
            'Hit from player $shooterId. Lives: $_livesLeft/$_maxLives.';
      }
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
      setState(() {
        _eventText =
            'Gun connected, but recoil command failed. Try reconnecting the gun.';
      });
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
      setState(() {
        _eventText =
            'Gun connected, but fire mode command failed. Try reconnecting the gun.';
      });
    }
  }

  Future<void> _reconnectGun() async {
    final profile = _savedGunProfile ?? await GunProfileStorage.load();
    if (!mounted || profile == null) {
      return;
    }

    setState(() {
      _eventText = 'Reconnecting gun ${profile.displayName}...';
    });

    try {
      await BleGunController.connect(deviceId: profile.deviceId);
      if (!mounted) {
        return;
      }

      setState(() {
        _savedGunProfile = profile;
        _gunConnected = true;
        _showGunDisconnectedAlert = false;
        _eventText = 'Gun reconnected: ${profile.displayName}.';
      });

      await _startGunConnectionMonitoring(profile);
      await _startBatteryMonitoring(profile);
      await _startTelemetryMonitoring(profile);
      await _applyShotModeToGun(profile);
      await _applyRecoilModeToGun(profile);
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _savedGunProfile = profile;
        _gunConnected = false;
        _showGunDisconnectedAlert = true;
        _eventText = 'Could not reconnect gun. Check Bluetooth and try again.';
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
    setState(() {
      _savedGunProfile = profile;
      _syncFireTypeFromProfile(profile);
    });
    await _reconnectGun();
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
    await _teamVoicePlayer.play(BytesSource(base64Decode(encoded)));

    if (!mounted) {
      return;
    }

    setState(() {
      _teamVoiceStatus = 'Team voice clip sent and played back (simulation).';
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
    }

    _positionSubscription =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 2,
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
      final nextX = (contact.xMeters + driftX).clamp(
        -_radarRangeMeters,
        _radarRangeMeters,
      );
      final nextY = (contact.yMeters + driftY).clamp(
        -_radarRangeMeters,
        _radarRangeMeters,
      );
      return _RadarContact(
        id: contact.id,
        team: contact.team,
        xMeters: nextX,
        yMeters: nextY,
      );
    }).toList();
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
      spawnX =
          anchor.xMeters + math.cos(angle) * _itemFallbackSpawnDistanceMeters;
      spawnY =
          anchor.yMeters + math.sin(angle) * _itemFallbackSpawnDistanceMeters;
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
      const _SimulatedPlayer(
        id: 'Player One',
        team: 'Red Team',
        xMeters: 0,
        yMeters: 0,
      ),
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

  void _toggleShieldBonus() {
    setState(() {
      _shieldActive = !_shieldActive;
      _eventText = _shieldActive
          ? 'Shield bonus enabled.'
          : 'Shield bonus disabled.';
    });
  }

  void _toggleHealingBonus() {
    setState(() {
      _healingBoostActive = !_healingBoostActive;
      _eventText = _healingBoostActive
          ? 'Healing bonus enabled.'
          : 'Healing bonus disabled.';
    });
  }

  void _cycleFireType() {
    final profile = _savedGunProfile;
    if (profile == null) {
      setState(() {
        _eventText = 'Open Gun Settings first to configure the gun profile.';
      });
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
      setState(() {
        _eventText = 'Open Gun Settings first to configure the gun profile.';
      });
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
      setState(() {
        _eventText = 'No fire modes are allowed in the current profile.';
      });
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
      _eventText =
          'Fire mode switched to ${_displayFireType(nextMode)} via Start Button.';
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
      setState(() {
        _eventText =
            '${button.label} pressed (simulated). Open Gun Settings to map controls.';
      });
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
        setState(() {
          _eventText = '${button.label} pressed: Reload in progress.';
        });
        return;
      }

      await _fireByMode(profile.selectedFireMode);
      return;
    }

    if (button == GunButton.reload) {
      if (_isReloading) {
        setState(() {
          _eventText = '${button.label} pressed: Already reloading.';
        });
        return;
      }

      _stopAutoFireLoop();
      unawaited(_playReloadSound());

      setState(() {
        _isReloading = true;
        _eventText = '${button.label} pressed: Reloading...';
      });

      _reloadTimer?.cancel();
      _reloadTimer = Timer(_reloadTelemetrySyncWindow, () {
        if (!mounted) {
          return;
        }
        setState(() {
          _ammoLeft = _startingAmmo;
          _isReloading = false;
          _eventText = 'Reload complete.';
        });
      });
      return;
    }

    setState(() {
      _eventText =
          '${button.label} pressed: no action mapped for this button in profile.';
    });
  }

  Future<void> _toggleRecoilFromPowerButton() async {
    final profile = _savedGunProfile;
    if (profile == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _eventText = 'Open Gun Settings first to configure the gun profile.';
      });
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
      _eventText = nextRecoilEnabled
          ? 'Recoil mode enabled via Power Button.'
          : 'Recoil mode disabled via Power Button.';
    });

    if (_gunConnected) {
      await _applyRecoilModeToGun(updatedProfile);
    }
  }

  Widget _buildGunButtonTestPad() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: GunButton.values.map((button) {
        return OutlinedButton(
          onPressed: () => unawaited(_handleGunButtonPress(button)),
          child: Text(button.label),
        );
      }).toList(),
    );
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

  Color _teamColor(String team) {
    return teamPaletteFor(team).accent;
  }

  LatLng _playerPosition() {
    return _gpsPlayerPosition ??
        const LatLng(_playerLatitude, _playerLongitude);
  }

  LatLng _contactToLatLng(_RadarContact contact) {
    return _metersToLatLng(contact.xMeters, contact.yMeters);
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
          child: Icon(Icons.circle, color: _teamColor(contact.team), size: 14),
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
              border: Border.all(color: _itemColor(item.category), width: 2),
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
    final brightness = Theme.of(context).brightness;
    final teamPalette = teamPaletteFor(_team);
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
    final healthValue = _livesLeft / _maxLives;
    final brightness = Theme.of(context).brightness;
    final teamPalette = teamPaletteFor(_team);
    final teamColors = teamBackgroundColors(_team, brightness: brightness);
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
        title: const Text('Player Screen Test (Simulation)'),
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
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: panelBg,
                                border: Border.all(color: panelBorder),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                'Simulation mode: no server required. Live HUD and radar test.',
                                style: TextStyle(
                                  color: panelTextColor,
                                  fontSize: 12,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(height: 8),
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
                                              _playerName,
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
                                            _team,
                                            style: TextStyle(
                                              color: _teamColor(_team),
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
                                            onTap: _toggleShieldBonus,
                                            activeColor: _shieldActive
                                                ? Colors.lightBlueAccent
                                                : Colors.white54,
                                          ),
                                          const SizedBox(width: 6),
                                          _statusIconTile(
                                            icon: Icons.healing,
                                            title: 'Heal',
                                            value: _healingBoostActive
                                                ? 'On'
                                                : 'Off',
                                            onTap: _toggleHealingBonus,
                                            activeColor: _healingBoostActive
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
                                                'Lives $_livesLeft/$_maxLives',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 12,
                                                ),
                                                maxLines: 2,
                                              ),
                                            ),
                                            Expanded(
                                              child: Text(
                                                'Score $_score\n'
                                                'Shots $_shotsFired\n'
                                                'Hits $_hitsTaken\n'
                                                'Items ${_items.length}',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 12,
                                                ),
                                                maxLines: 4,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Text(
                                        'Event: $_eventText',
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 12,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
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
                                                  contacts: _contacts,
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
                            const SizedBox(height: 8),
                            _buildGunButtonTestPad(),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
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

enum _ItemCategory { healing, armor, damage, special }

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
