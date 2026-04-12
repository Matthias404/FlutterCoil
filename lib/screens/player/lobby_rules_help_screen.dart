import 'package:flutter/material.dart';

import '../../network/game_network_service.dart';

class LobbyRulesHelpScreen extends StatelessWidget {
  const LobbyRulesHelpScreen({super.key, required this.rules});

  final LobbyRules rules;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Game Rules')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(
            rules.gameType.label,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          Text('Max lives: ${rules.maxLives}'),
          Text('Match length: ${rules.matchLengthMinutes} minutes'),
          Text('Max players: ${rules.maxPlayers}'),
          Text('Respawn delay: ${rules.respawnDelaySeconds} seconds'),
          Text(
            'Item spawn: ${rules.itemSpawnRateSeconds <= 0 ? 'never' : '${rules.itemSpawnRateSeconds} seconds'}',
          ),
          Text(
            'Respawn mode: ${rules.respawnMode == RespawnMode.atTeamBase ? 'At team base' : 'On death timer'}',
          ),
          Text('Base radius: ${rules.baseRadiusMeters.toStringAsFixed(1)}m'),
          Text('Friendly fire: ${rules.friendlyFire ? 'enabled' : 'disabled'}'),
          Text(
            'Mid-game join: ${rules.allowMidGameJoin ? 'allowed' : 'not allowed'}',
          ),
          Text(
            'Voice chat: ${rules.teamLeadVoiceOnly ? 'team leads only' : 'all players'}',
          ),
          Text(
            'Map visibility: ${rules.showOtherPlayersOnMap ? 'all players' : 'teammates only'}',
          ),
          const SizedBox(height: 16),
          const Text(
            'Team lead selection',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          const Text(
            'When the server starts the game countdown, one player from each team is randomly chosen as Team Lead.',
          ),
        ],
      ),
    );
  }
}
