import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../theme/team_colors.dart';
import '../../theme/theme_toggle_button.dart';
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
  bool _isRecordingTeamVoice = false;
  String _teamVoiceStatus = 'Team voice ready.';
  final MapController _mapController = MapController();
  StreamSubscription<Position>? _positionSubscription;
  LatLng? _gpsPlayerPosition;
  String _gpsStatus = 'GPS: requesting location...';

  @override
  void initState() {
    super.initState();
    _teamVoiceRecorder = AudioRecorder();
    _teamVoicePlayer = AudioPlayer();
    unawaited(_initializeGpsTracking());
    _startTimer();
  }

  @override
  void dispose() {
    _matchTimer?.cancel();
    unawaited(_positionSubscription?.cancel());
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
              Icon(icon, color: activeColor ?? Colors.white70),
              const SizedBox(height: 6),
              Text(title, style: const TextStyle(fontSize: 12)),
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
                        style: TextStyle(color: panelTextColor),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      flex: compact ? 4 : 5,
                      child: Card(
                        color: panelBgStrong,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: panelBorder),
                        ),
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
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge
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
                                    healthValue > 0.5
                                        ? Colors.lightGreenAccent
                                        : Colors.amberAccent,
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
                                    activeColor: _shieldActive
                                        ? Colors.lightBlueAccent
                                        : Colors.white54,
                                  ),
                                  const SizedBox(width: 6),
                                  _statusIconTile(
                                    icon: Icons.healing,
                                    title: 'Heal',
                                    value: _healingBoostActive ? 'On' : 'Off',
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
                                style: Theme.of(context).textTheme.titleMedium
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
                                        'Lives $_livesLeft/$_maxLives\n'
                                        'Ammo $_ammoLeft/$_startingAmmo',
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ),
                                        maxLines: 3,
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
                                        ),
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
                        color: panelBgStrong,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: panelBorder),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                'GPS Radar (${_radarRangeMeters.toInt()}m)',
                                style: Theme.of(context).textTheme.titleSmall
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
                                  fontSize: 12,
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
                                        mapController: _mapController,
                                        options: MapOptions(
                                          initialCenter: _playerPosition(),
                                          initialZoom: 18,
                                          interactionOptions:
                                              const InteractionOptions(
                                                flags: InteractiveFlag.none,
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
                                            circles: _buildItemPickupCircles(),
                                          ),
                                          MarkerLayer(
                                            markers: _buildMapMarkers(),
                                          ),
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
                        _isRecordingTeamVoice
                            ? Icons.stop_circle_outlined
                            : Icons.mic,
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
