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
    });

    tearDown(() async {
      await alpha.stop();
      await bravo.stop();
    });

    test('discovers peers through hello/join handshake', () async {
      await alpha.connect();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(alpha.snapshot.players.containsKey('bravo'), isTrue);
      expect(bravo.snapshot.players.containsKey('alpha'), isTrue);
      expect(alpha.snapshot.players['bravo']?.name, 'Bravo');
      expect(bravo.snapshot.players['alpha']?.name, 'Alpha');
    });

    test('records hit and score over simulated network', () async {
      await alpha.connect();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await alpha.queueGameStart(delay: const Duration(milliseconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await alpha.sendShot('bravo');
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(alpha.localPlayer.shotsFired, 1);
      expect(alpha.localPlayer.score, 1);
      expect(bravo.localPlayer.hitsTaken, 1);
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
  });
}
