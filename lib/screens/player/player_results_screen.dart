import 'package:flutter/material.dart';

import '../../network/player_state.dart';
import 'player_screen.dart';
import '../../theme/team_colors.dart';

class PlayerResultsScreen extends StatelessWidget {
  const PlayerResultsScreen({
    super.key,
    required this.players,
    required this.localPlayerId,
  });

  final List<PlayerState> players;
  final String localPlayerId;

  @override
  Widget build(BuildContext context) {
    final sortedPlayers = List<PlayerState>.of(players)
      ..sort((a, b) {
        final scoreOrder = b.score.compareTo(a.score);
        if (scoreOrder != 0) {
          return scoreOrder;
        }
        final deathOrder = a.deaths.compareTo(b.deaths);
        if (deathOrder != 0) {
          return deathOrder;
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    final topScore = sortedPlayers.isEmpty ? 0 : sortedPlayers.first.score;
    final winnerIds = sortedPlayers
        .where((player) => player.score == topScore)
        .map((player) => player.id)
        .toSet();
    final winnerNames = sortedPlayers
        .where((player) => winnerIds.contains(player.id))
        .map((player) => player.name)
        .join(', ');
    final localIsWinner = winnerIds.contains(localPlayerId);

    return Scaffold(
      appBar: AppBar(title: const Text('Match Results')),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[Color(0xFF0B1E2B), Color(0xFF112F1B)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Card(
                  color: localIsWinner ? Colors.amber.shade700 : Colors.blueGrey.shade800,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Icon(
                              localIsWinner
                                  ? Icons.emoji_events
                                  : Icons.flag_circle,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              localIsWinner ? 'You Won!' : 'Match Finished',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          winnerIds.length > 1
                              ? 'Winners: $winnerNames'
                              : 'Winner: $winnerNames',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Top score: $topScore',
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Players (${sortedPlayers.length})',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Card(
                    color: Colors.black.withValues(alpha: 0.28),
                    child: ListView.separated(
                      itemCount: sortedPlayers.length,
                        separatorBuilder: (_, unusedIndex) =>
                          const Divider(height: 1, color: Colors.white24),
                      itemBuilder: (context, index) {
                        final player = sortedPlayers[index];
                        final isWinner = winnerIds.contains(player.id);
                        final isLocal = player.id == localPlayerId;
                        final rank = index + 1;

                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: isWinner
                                ? Colors.amber
                                : teamPaletteFor(player.group).accent,
                            child: Text(
                              '$rank',
                              style: const TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          title: Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  player.name,
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: isLocal
                                        ? FontWeight.w800
                                        : FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (isWinner)
                                const Icon(
                                  Icons.emoji_events,
                                  color: Colors.amber,
                                  size: 18,
                                ),
                            ],
                          ),
                          subtitle: Text(
                            'Team ${player.group} • Kills ${player.kills} • Deaths ${player.deaths} • Hits ${player.hitsLanded} • Shots ${player.shotsFired}',
                            style: const TextStyle(color: Colors.white70),
                          ),
                          trailing: Text(
                            '${player.score} pts',
                            style: const TextStyle(
                              color: Colors.lightGreenAccent,
                              fontWeight: FontWeight.w800,
                              fontSize: 16,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute<void>(
                        builder: (_) => const PlayerScreen(),
                      ),
                      (route) => false,
                    );
                  },
                  icon: const Icon(Icons.home),
                  label: const Text('Back To Player Setup'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
