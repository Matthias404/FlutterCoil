import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';

import 'network/join_code.dart';
import 'network/transport.dart';
import 'screens/player/player_game_test_screen.dart';
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
  late final bool _skipBootstrapForTests;

  @override
  void initState() {
    super.initState();
    _themeController = AppThemeController();
    _skipBootstrapForTests = Platform.environment.containsKey('FLUTTER_TEST');
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
            home: _skipBootstrapForTests
                ? const StartScreen()
                : const _AppBootstrapGate(child: StartScreen()),
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
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: gradientColors,
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
                      Align(
                        alignment: Alignment.centerRight,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surface.withValues(
                              alpha: isDark ? 0.12 : 0.82,
                            ),
                            shape: BoxShape.circle,
                          ),
                          child: ThemeToggleButton(color: foregroundColor),
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
                              color: foregroundColor.withValues(alpha: 0.75),
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
                            crossAxisAlignment: CrossAxisAlignment.start,
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
                            color: foregroundColor.withValues(alpha: 0.45),
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
                            color: foregroundColor.withValues(alpha: 0.45),
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
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: foregroundColor,
                          side: BorderSide(
                            color: foregroundColor.withValues(alpha: 0.45),
                          ),
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
