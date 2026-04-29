import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lasertag_app/screens/player/player_game_screen.dart';

import '../../network/game_network_service.dart';
import '../../theme/theme_toggle_button.dart';

class PlayerLobbyScreen extends StatefulWidget {
  const PlayerLobbyScreen({
    super.key,
    required this.service,
    required this.initialTeam,
  });

  final GameNetworkService service;
  final String initialTeam;

  @override
  State<PlayerLobbyScreen> createState() => _PlayerLobbyScreenState();
}

class _PlayerLobbyScreenState extends State<PlayerLobbyScreen> {
  static const List<String> _teams = <String>['Red', 'Blue', 'Green', 'Yellow'];

  late String _selectedTeam;
  late NetworkSnapshot _snapshot;
  StreamSubscription<NetworkSnapshot>? _updatesSub;

  @override
  void initState() {
    super.initState();
    _selectedTeam = widget.initialTeam;
    _snapshot = widget.service.snapshot;
    _updatesSub = widget.service.updates.listen((snapshot) {
      if (!mounted) {
        return;
      }

      // Navigate to game screen when match starts
      if (snapshot.gamePhase == GamePhase.running &&
          _snapshot.gamePhase != GamePhase.running) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => PlayerGameScreen(service: widget.service),
          ),
        );
        return;
      }

      setState(() {
        _snapshot = snapshot;
      });
    });
  }

  bool get _isFreeForAll =>
      _snapshot.lobbyRules.gameType == GameType.freeForAll;

  bool get _countdownStarted =>
      _snapshot.scheduledGameStartAt != null ||
      _snapshot.gamePhase == GamePhase.running ||
      _snapshot.gamePhase == GamePhase.ended;

  bool get _canChangeTeam => !_isFreeForAll && !_countdownStarted;

  Future<void> _changeTeam(String team) async {
    if (!_canChangeTeam || _selectedTeam == team) {
      return;
    }

    setState(() {
      _selectedTeam = team;
    });

    await widget.service.updateLocalProfile(group: team);
    if (!mounted) {
      return;
    }
  }

  String _formatCountdown(Duration duration) {
    final totalSeconds = duration.inSeconds.clamp(0, 3599);
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Map<String, List<PlayerState>> _playersByTeam(List<PlayerState> players) {
    if (_isFreeForAll) {
      return <String, List<PlayerState>>{'Players': players};
    }

    final buckets = <String, List<PlayerState>>{};
    for (final team in _teams) {
      buckets[team] = <PlayerState>[];
    }
    for (final player in players) {
      buckets.putIfAbsent(player.group, () => <PlayerState>[]).add(player);
    }
    return buckets;
  }

  @override
  void dispose() {
    _updatesSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allPlayers = _snapshot.players.values.toList();
    final localPlayer = _snapshot.players[widget.service.localPlayerId];
    if (localPlayer != null &&
        !allPlayers.any(
          (player) => player.id == widget.service.localPlayerId,
        )) {
      allPlayers.insert(0, localPlayer);
    }

    final groupedPlayers = _playersByTeam(allPlayers);
    final rules = _snapshot.lobbyRules;
    final scheduledStartAt = _snapshot.scheduledGameStartAt;
    final countdown = scheduledStartAt?.difference(
      widget.service.synchronizedNow,
    );
    final countdownLabel = countdown == null
        ? null
        : _formatCountdown(countdown);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Waiting Lobby'),
        actions: const <Widget>[ThemeToggleButton()],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Card(
            color: Colors.green.shade700,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: <Widget>[
                  Icon(Icons.check_circle, color: Colors.white),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Waiting for game start...',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text('Game type: ${rules.gameType.label}'),
          const SizedBox(height: 4),
          if (countdownLabel != null) ...<Widget>[
            Text('Start countdown: $countdownLabel'),
          ] else ...<Widget>[const Text('Start countdown: not started')],
          const SizedBox(height: 12),
          if (!_isFreeForAll)
            DropdownButtonFormField<String>(
              initialValue: _selectedTeam,
              decoration: InputDecoration(
                labelText: _countdownStarted
                    ? 'Team (locked, countdown started)'
                    : 'Team selection',
                border: const OutlineInputBorder(),
              ),
              items: _teams
                  .map(
                    (team) => DropdownMenuItem<String>(
                      value: team,
                      child: Text(team),
                    ),
                  )
                  .toList(),
              onChanged: _canChangeTeam
                  ? (team) {
                      if (team != null) {
                        unawaited(_changeTeam(team));
                      }
                    }
                  : null,
            ),
          const Divider(height: 28),
          Text(
            _isFreeForAll ? 'Players (${allPlayers.length})' : 'Team members',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (allPlayers.isEmpty)
            const Text('No players connected yet.')
          else
            ...groupedPlayers.entries
                .where((entry) => entry.value.isNotEmpty)
                .expand((entry) {
                  final section = <Widget>[];
                  if (!_isFreeForAll) {
                    section.add(
                      Padding(
                        padding: const EdgeInsets.only(top: 6, bottom: 2),
                        child: Text(
                          'Team ${entry.key}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    );
                  }
                  section.addAll(
                    entry.value.map(
                      (player) => ListTile(
                        title: Text(player.name),
                        subtitle: !_isFreeForAll
                            ? Text('Team ${player.group}')
                            : null,
                        trailing: player.isHost
                            ? const Icon(Icons.shield)
                            : null,
                      ),
                    ),
                  );
                  return section;
                }),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back),
            label: const Text('Back To Player Setup'),
          ),
        ],
      ),
    );
  }
}
