import 'package:flutter_test/flutter_test.dart';
import 'package:lasertag_app/network/fake_transport.dart';
import 'package:lasertag_app/network/game_network_service.dart';
import 'package:lasertag_app/network/peer_directory.dart';
import 'package:lasertag_app/network/transport.dart';

void main() {
  group('GameNetworkService without hardware', () {
    late FakeNetworkHub hub;
    late GameNetworkService alpha;
    late GameNetworkService bravo;

    setUp(() async {
      hub = FakeNetworkHub();

      alpha = GameNetworkService(
        transport: FakeNetworkTransport(
          hub: hub,
          localHost: 'alpha.local',
          localPort: 9001,
        ),
        localPlayerId: 'alpha',
        initialPlayerName: 'Alpha',
        initialPlayerGroup: 'Red',
        peerDirectory: PeerDirectory(
          initialPeers: const <PeerEndpoint>[
            PeerEndpoint(host: 'bravo.local', port: 9002),
          ],
        ),
        isServer: true,
      );

      bravo = GameNetworkService(
        transport: FakeNetworkTransport(
          hub: hub,
          localHost: 'bravo.local',
          localPort: 9002,
        ),
        localPlayerId: 'bravo',
        initialPlayerName: 'Bravo',
        initialPlayerGroup: 'Blue',
        peerDirectory: PeerDirectory(
          initialPeers: const <PeerEndpoint>[
            PeerEndpoint(host: 'alpha.local', port: 9001),
          ],
        ),
      );

      await alpha.start();
      await bravo.start();
      await alpha.setLobbyOpen(true);
    });

    tearDown(() async {
      await alpha.stop();
      await bravo.stop();
    });

    test('discovers peers through hello/join handshake', () async {
      await alpha.connect();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Server (alpha) sees bravo as a game player.
      expect(alpha.snapshot.players.containsKey('bravo'), isTrue);
      expect(alpha.snapshot.players['bravo']?.name, 'Bravo');

      // Server must NOT appear as a game player on client side.
      expect(bravo.snapshot.players.containsKey('alpha'), isFalse);

      // Bravo knows about itself in the synced player list.
      expect(bravo.snapshot.players.containsKey('bravo'), isTrue);
    });

    test('records non-lethal hit without awarding kill score', () async {
      await alpha.connect();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await alpha.queueGameStart(delay: const Duration(milliseconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await alpha.sendShot('bravo');
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(alpha.localPlayer.shotsFired, 1);
      expect(alpha.localPlayer.score, 0);
      expect(alpha.localPlayer.kills, 0);
      expect(bravo.localPlayer.hitsTaken, 1);
      expect(bravo.localPlayer.deaths, 0);
    });

    test('awards kill score only when target reaches zero health', () async {
      await alpha.connect();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await alpha.updateLobbyRules(
        const LobbyRules(
          gameType: GameType.time,
          magazineSize: 15,
          reloadTimeSeconds: 2,
          maxLives: 2,
          matchLengthMinutes: 10,
          maxPlayers: 6,
          respawnDelaySeconds: 5,
          itemSpawnRateSeconds: 30,
          friendlyFire: false,
          allowMidGameJoin: true,
          teamLeadVoiceOnly: true,
        ),
      );

      await alpha.queueGameStart(delay: const Duration(milliseconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await alpha.sendShot('bravo');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(alpha.localPlayer.score, 0);
      expect(alpha.localPlayer.kills, 0);

      await alpha.sendShot('bravo');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(alpha.localPlayer.score, 1);
      expect(alpha.localPlayer.kills, 1);
      expect(bravo.localPlayer.deaths, 1);
    });

    test('syncs lobby rules from server to player', () async {
      await alpha.connect();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await alpha.updateLobbyRules(
        const LobbyRules(
          gameType: GameType.time,
          magazineSize: 15,
          reloadTimeSeconds: 3,
          maxLives: 15,
          matchLengthMinutes: 12,
          maxPlayers: 10,
          respawnDelaySeconds: 4,
          itemSpawnRateSeconds: 30,
          friendlyFire: true,
          allowMidGameJoin: true,
          teamLeadVoiceOnly: true,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(bravo.snapshot.lobbyRules.maxLives, 15);
      expect(bravo.snapshot.lobbyRules.magazineSize, 15);
      expect(bravo.snapshot.lobbyRules.reloadTimeSeconds, 3);
      expect(bravo.snapshot.lobbyRules.matchLengthMinutes, 12);
      expect(bravo.snapshot.lobbyRules.friendlyFire, isTrue);
      expect(bravo.snapshot.lobbyRules.teamLeadVoiceOnly, isTrue);
    });

    test('auto ends match when timer expires', () async {
      await alpha.connect();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await alpha.updateLobbyRules(
        const LobbyRules(
          gameType: GameType.time,
          magazineSize: 15,
          reloadTimeSeconds: 2,
          maxLives: 10,
          matchLengthMinutes: 0,
          maxPlayers: 6,
          respawnDelaySeconds: 3,
          itemSpawnRateSeconds: 30,
          friendlyFire: false,
          allowMidGameJoin: true,
          teamLeadVoiceOnly: true,
        ),
      );

      await alpha.queueGameStart(delay: const Duration(milliseconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(alpha.snapshot.gamePhase, GamePhase.ended);
      expect(bravo.snapshot.gamePhase, GamePhase.ended);
    });

    test('keeps score when game is ended by server', () async {
      await alpha.connect();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await alpha.updateLobbyRules(
        const LobbyRules(
          gameType: GameType.time,
          magazineSize: 15,
          reloadTimeSeconds: 2,
          maxLives: 1,
          matchLengthMinutes: 10,
          maxPlayers: 6,
          respawnDelaySeconds: 5,
          itemSpawnRateSeconds: 30,
          friendlyFire: false,
          allowMidGameJoin: true,
          teamLeadVoiceOnly: true,
        ),
      );

      await alpha.queueGameStart(delay: const Duration(milliseconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await alpha.sendShot('bravo');
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(alpha.localPlayer.score, 1);

      await alpha.endGame();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(alpha.snapshot.gamePhase, GamePhase.ended);
      expect(alpha.localPlayer.score, 1);
      expect(bravo.snapshot.gamePhase, GamePhase.ended);
    });
  });
}
