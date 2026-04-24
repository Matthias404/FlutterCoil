import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:lasertag_app/screens/player/player_game_screen.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';

import 'network/join_code.dart';
import 'network/protocol.dart';
import 'network/transport.dart';
import 'screens/player/player_screen.dart';
import 'screens/player/player_screen_with_code.dart';
import 'screens/server/server_screen.dart';
import 'theme/app_theme.dart';
import 'theme/team_colors.dart';
import 'theme/theme_controller.dart';
import 'theme/theme_toggle_button.dart';
import 'utils/offline_map_cache.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LaserTagApp());
}

class LaserTagApp extends StatefulWidget {
  const LaserTagApp({super.key});

  @override
  State<LaserTagApp> createState() => _LaserTagAppState();
}

class _LaserTagAppState extends State<LaserTagApp> {
  late final AppThemeController _themeController;

  @override
  void initState() {
    super.initState();
    _themeController = AppThemeController();
  }

  @override
  void dispose() {
    _themeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppThemeScope(
      controller: _themeController,
      child: ListenableBuilder(
        listenable: _themeController,
        builder: (context, _) {
          return MaterialApp(
            title: 'LaserTag Lobby',
            theme: buildLightTheme(),
            darkTheme: buildDarkTheme(),
            themeMode: _themeController.value,
            home: const _AppBootstrapGate(child: StartScreen()),
          );
        },
      ),
    );
  }
}

class _AppBootstrapGate extends StatefulWidget {
  const _AppBootstrapGate({required this.child});

  final Widget child;

  @override
  State<_AppBootstrapGate> createState() => _AppBootstrapGateState();
}

class _AppBootstrapGateState extends State<_AppBootstrapGate> {
  bool _done = false;
  String _status = 'Preparing app startup...';
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _runBootstrap();
  }

  Future<void> _runBootstrap() async {
    await _requestStartupPermissions();

    final center = await _resolveMapCenter();
    if (!mounted) {
      return;
    }

    setState(() {
      _status = 'Preparing offline map tiles...';
      _progress = 0.1;
    });

    await OfflineMapCache.ensureInitialized();

    try {
      await OfflineMapCache.prefetchGreaterArea(
        center: center,
        radiusKm: OfflineMapCache.startupRadiusKm,
        onProgress: (completed, total) {
          if (!mounted || total <= 0) {
            return;
          }
          setState(() {
            _status = 'Downloading map tiles ($completed/$total)...';
            _progress = 0.1 + (completed / total) * 0.9;
          });
        },
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _status =
              'Offline map prefetch skipped (likely no internet). Continuing...';
          _progress = 1;
        });
      }
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _done = true;
      _status = 'Ready';
      _progress = 1;
    });
  }

  Future<void> _requestStartupPermissions() async {
    if (mounted) {
      setState(() {
        _status = 'Requesting required permissions...';
        _progress = 0.05;
      });
    }

    final permissions = <Permission>[Permission.microphone];
    if (Platform.isAndroid) {
      permissions.addAll(<Permission>[
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.nearbyWifiDevices,
        Permission.locationWhenInUse,
      ]);
    } else if (Platform.isIOS) {
      permissions.addAll(<Permission>[
        Permission.bluetooth,
        Permission.locationWhenInUse,
      ]);
    } else {
      permissions.addAll(<Permission>[
        Permission.bluetooth,
        Permission.locationWhenInUse,
      ]);
    }

    await permissions.request();
  }

  Future<LatLng> _resolveMapCenter() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return OfflineMapCache.defaultCenter;
    }

    final permission = await Geolocator.checkPermission();
    final hasLocationPermission =
        permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
    if (!hasLocationPermission) {
      return OfflineMapCache.defaultCenter;
    }

    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      return LatLng(position.latitude, position.longitude);
    } catch (_) {
      return OfflineMapCache.defaultCenter;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_done) {
      return widget.child;
    }

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(_status, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: _progress.clamp(0, 1)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class StartScreen extends StatefulWidget {
  const StartScreen({super.key});

  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen> {
  late double _offlineRadiusKm;

  @override
  void initState() {
    super.initState();
    _offlineRadiusKm = OfflineMapCache.startupRadiusKm;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final isDark = brightness == Brightness.dark;
    final gradientColors = teamPaletteFor('Red').background(brightness);
    final foregroundColor = isDark ? Colors.white : theme.colorScheme.onSurface;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: gradientColors,
                ),
              ),
            ),
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              Align(
                                alignment: Alignment.centerRight,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.surface.withValues(
                                      alpha: isDark ? 0.12 : 0.82,
                                    ),
                                    shape: BoxShape.circle,
                                  ),
                                  child: ThemeToggleButton(
                                    color: foregroundColor,
                                  ),
                                ),
                              ),
                              Text(
                                'LaserTag Lobby',
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.displaySmall
                                    ?.copyWith(
                                      color: foregroundColor,
                                      fontWeight: FontWeight.bold,
                                    ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'Choose whether this device controls the match or joins it as a player.',
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      color: foregroundColor.withValues(
                                        alpha: 0.75,
                                      ),
                                    ),
                              ),
                              const SizedBox(height: 18),
                              Card(
                                color: theme.colorScheme.surface.withValues(
                                  alpha: isDark ? 0.25 : 0.8,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        'Offline Map Radius: ${_offlineRadiusKm.toStringAsFixed(1)} km',
                                        style: TextStyle(
                                          color: foregroundColor,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      Slider(
                                        min: OfflineMapCache.minRadiusKm,
                                        max: OfflineMapCache.maxRadiusKm,
                                        divisions: 22,
                                        value: _offlineRadiusKm,
                                        label:
                                            '${_offlineRadiusKm.toStringAsFixed(1)} km',
                                        onChanged: (value) {
                                          setState(() {
                                            _offlineRadiusKm =
                                                OfflineMapCache.normalizeRadiusKm(
                                                  value,
                                                );
                                            OfflineMapCache.startupRadiusKm =
                                                _offlineRadiusKm;
                                          });
                                        },
                                      ),
                                      Text(
                                        'Used for startup tile prefetch (applies after app restart).',
                                        style: TextStyle(
                                          color: foregroundColor.withValues(
                                            alpha: 0.72,
                                          ),
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
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
                                  foregroundColor: foregroundColor,
                                  side: BorderSide(
                                    color: foregroundColor.withValues(
                                      alpha: 0.45,
                                    ),
                                  ),
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
                                  foregroundColor: foregroundColor,
                                  side: BorderSide(
                                    color: foregroundColor.withValues(
                                      alpha: 0.45,
                                    ),
                                  ),
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
                              
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class GameBrowserScreen extends StatefulWidget {
  const GameBrowserScreen({
    super.key, 
    this.allowManualCodeFallback = false,
    this.playerName,
    this.selectedTeam,
  });

  final bool allowManualCodeFallback;
  final String? playerName;
  final String? selectedTeam;

  @override
  State<GameBrowserScreen> createState() => _GameBrowserScreenState();
}

class _GameBrowserScreenState extends State<GameBrowserScreen> {
  static const int _defaultServerPort = 7777;
  List<AdvertisedGame> _discoveredGames = <AdvertisedGame>[];
  bool _isSearching = false;
  String? _permissionHint;
  String? _permissionStatusDetails;

  @override
  void initState() {
    super.initState();

    (_checkLanPermissionStatus());
    _searchForGames();
  }

  Future<void> _searchForGames() async {
    setState(() {
      _isSearching = true;
      _discoveredGames = <AdvertisedGame>[];
      _permissionHint = null;
    });

    final hasLanPermissions = await _ensureAndroidLanPermissions();
    if (!hasLanPermissions) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isSearching = false;
      });
      return;
    }

    final discoveredByHost = <String, AdvertisedGame>{};
    RawDatagramSocket? socket;

    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
        reusePort: true,
      );
      socket.broadcastEnabled = true;

      socket.listen((event) {
        if (event != RawSocketEvent.read) {
          return;
        }
        final datagram = socket?.receive();
        if (datagram == null) {
          return;
        }

        try {
          final packet = NetworkPacket.decode(utf8.decode(datagram.data));
          if (!_isServerAdvertisement(packet)) {
            return;
          }

          final host = datagram.address.address;
          final statePlayers =
              (packet.payload['players'] as List?) ?? const <dynamic>[];
          final stateRules = (packet.payload['rules'] as Map?)
              ?.cast<String, dynamic>();

          final playerCount = statePlayers.length;
          final maxPlayers = stateRules?['maxPlayers'] as int? ?? 8;
          final serverName = packet.playerName?.trim().isNotEmpty == true
              ? packet.playerName!.trim()
              : 'LAN Server';

          discoveredByHost[host] = AdvertisedGame(
            name: serverName,
            host: host,
            port: datagram.port,
            playerCount: playerCount,
            maxPlayers: maxPlayers,
          );
        } catch (_) {
          // Ignore non-protocol traffic.
        }
      });

      final probe = NetworkPacket(
        type: PacketType.hello,
        playerId: 'browse-${DateTime.now().microsecondsSinceEpoch}',
        playerName: 'LAN Browser',
        payload: const <String, dynamic>{
          'group': 'Browser',
          'playerClass': 'Assult',
          'gunConnected': false,
          'isHost': false,
        },
      );
      final payload = utf8.encode(probe.encode());

      final probeTargets = <InternetAddress>{
        ...await _broadcastTargets(),
        ...await _subnetProbeTargets(),
      };

      for (final target in probeTargets) {
        socket.send(payload, target, _defaultServerPort);
      }

      await Future<void>.delayed(const Duration(seconds: 2));
    } catch (_) {
      // Keep UX graceful; list remains empty and user can retry/manual join.
    } finally {
      socket?.close();
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _discoveredGames = discoveredByHost.values.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      _isSearching = false;
    });
  }

  Future<bool> _ensureAndroidLanPermissions() async {
    if (!Platform.isAndroid) {
      return true;
    }

    final blockingPermissions = <Permission>[Permission.locationWhenInUse];
    final optionalPermissions = <Permission>[Permission.nearbyWifiDevices];

    final statusMap = await blockingPermissions.request();
    final optionalStatusMap = await optionalPermissions.request();
    final deniedPermissions = <String>[];
    for (final entry in statusMap.entries) {
      if (!entry.value.isGranted) {
        if (entry.key == Permission.locationWhenInUse) {
          deniedPermissions.add('Location');
        }
      }
    }

    final nearbyWifiStatus = optionalStatusMap[Permission.nearbyWifiDevices];
    if (nearbyWifiStatus != null && !nearbyWifiStatus.isGranted && mounted) {
      setState(() {
        _permissionHint =
            'Nearby Wi-Fi permission is denied on this phone. LAN scan will still try using location + UDP fallback.';
      });
    }

    if (deniedPermissions.isEmpty) {
      await _checkLanPermissionStatus();
      return true;
    }

    if (mounted) {
      setState(() {
        _permissionHint =
            'Allow Android LAN permissions to discover games: ${deniedPermissions.join(', ')}.';
      });
    }
    await _checkLanPermissionStatus();
    return false;
  }

  Future<void> _checkLanPermissionStatus() async {
    if (!mounted) {
      return;
    }

    if (!Platform.isAndroid) {
      setState(() {
        _permissionStatusDetails =
            'LAN permission check: non-Android device, using standard network permissions.';
      });
      return;
    }

    final locationServiceEnabled = await Geolocator.isLocationServiceEnabled();
    final locationStatus = await Permission.locationWhenInUse.status;
    final nearbyWifiStatus = await Permission.nearbyWifiDevices.status;

    if (!mounted) {
      return;
    }

    String statusLabel(PermissionStatus status) {
      if (status.isGranted) {
        return 'granted';
      }
      if (status.isPermanentlyDenied) {
        return 'permanently denied';
      }
      if (status.isRestricted) {
        return 'restricted';
      }
      if (status.isLimited) {
        return 'limited';
      }
      return 'denied';
    }

    setState(() {
      _permissionStatusDetails =
          'Phone checks: Location service ${locationServiceEnabled ? 'ON' : 'OFF'}, '
          'Location permission ${statusLabel(locationStatus)}, '
          'Nearby Wi-Fi permission ${statusLabel(nearbyWifiStatus)}.';
    });
  }

  Future<List<InternetAddress>> _broadcastTargets() async {
    final targets = <InternetAddress>{InternetAddress('255.255.255.255')};
    try {
      final interfaces = await NetworkInterface.list();
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.type != InternetAddressType.IPv4) {
            continue;
          }
          if (address.address.startsWith('127.') ||
              address.address.startsWith('169.254')) {
            continue;
          }

          final octets = address.address.split('.');
          if (octets.length != 4) {
            continue;
          }
          final subnetBroadcast = '${octets[0]}.${octets[1]}.${octets[2]}.255';
          targets.add(InternetAddress(subnetBroadcast));
        }
      }
    } catch (_) {
      // Ignore and keep global broadcast fallback.
    }
    return targets.toList();
  }

  Future<List<InternetAddress>> _subnetProbeTargets() async {
    final targets = <InternetAddress>{};
    try {
      final interfaces = await NetworkInterface.list();
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (address.type != InternetAddressType.IPv4) {
            continue;
          }
          if (address.address.startsWith('127.') ||
              address.address.startsWith('169.254')) {
            continue;
          }

          final octets = address.address.split('.');
          if (octets.length != 4) {
            continue;
          }

          final prefix = '${octets[0]}.${octets[1]}.${octets[2]}';
          final ownLast = int.tryParse(octets[3]) ?? -1;
          for (var host = 1; host <= 254; host++) {
            if (host == ownLast) {
              continue;
            }
            targets.add(InternetAddress('$prefix.$host'));
          }
        }
      }
    } catch (_) {
      // Ignore and use broadcast-only discovery.
    }
    return targets.toList();
  }

  bool _isServerAdvertisement(NetworkPacket packet) {
    if (packet.type == PacketType.state) {
      final serverId = packet.payload['serverPlayerId'] as String?;
      return serverId != null && serverId == packet.playerId;
    }

    if (packet.type == PacketType.join) {
      return packet.payload['isHost'] == true;
    }

    return false;
  }

  Future<void> _joinGame(AdvertisedGame game) async {
    final endpoint = PeerEndpoint(host: game.host, port: game.port);
    final code = JoinCodeCodec.encode(endpoint);

    if (!mounted) {
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreenWithCode(
          joinCode: code,
          initialPlayerName: widget.playerName,
          initialTeam: widget.selectedTeam,
          autoJoinOnOpen: widget.playerName?.trim().isNotEmpty == true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Browse Games'),
        actions: const <Widget>[ThemeToggleButton()],
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
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _checkLanPermissionStatus,
                    icon: const Icon(Icons.privacy_tip_outlined),
                    label: const Text('Check Phone Permissions'),
                  ),
                  if (_permissionStatusDetails != null) ...<Widget>[
                    const SizedBox(height: 8),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Text(
                        _permissionStatusDetails!,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                  if (_permissionHint != null) ...<Widget>[
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Text(
                        _permissionHint!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: openAppSettings,
                      icon: const Icon(Icons.settings),
                      label: const Text('Open App Settings'),
                    ),
                  ],
                  if (widget.allowManualCodeFallback) ...<Widget>[
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).pop(true),
                      icon: const Icon(Icons.qr_code),
                      label: const Text('Use Join Code Instead'),
                    ),
                  ],
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
