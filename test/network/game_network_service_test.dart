import 'package:flutter_test/flutter_test.dart';
import 'package:lasertag_app/network/fake_transport.dart';
import 'package:lasertag_app/network/game_network_service.dart';
import 'package:lasertag_app/network/peer_directory.dart';
import 'package:lasertag_app/network/protocol.dart';
import 'package:lasertag_app/network/transport.dart';

class _PacketSendRecord {
  const _PacketSendRecord({
    required this.host,
    required this.port,
    required this.packet,
  });

  final String host;
  final int port;
  final NetworkPacket packet;
}

class _InstrumentedFakeNetworkTransport implements NetworkTransport {
  _InstrumentedFakeNetworkTransport({required this.inner});

  final FakeNetworkTransport inner;
  final List<_PacketSendRecord> sentPackets = <_PacketSendRecord>[];
  bool Function(String host, int port, NetworkPacket packet)? shouldDropSend;

  @override
  Stream<DatagramEnvelope> get incoming => inner.incoming;

  @override
  Future<void> start() => inner.start();

  @override
  Future<void> send(String host, int port, NetworkPacket packet) async {
    sentPackets.add(_PacketSendRecord(host: host, port: port, packet: packet));
    if (shouldDropSend?.call(host, port, packet) == true) {
      return;
    }
    await inner.send(host, port, packet);
  }

  @override
  Future<void> stop() => inner.stop();
}

void main() {
  group('GameNetworkService without hardware', () {
    late FakeNetworkHub hub;
    late GameNetworkService alpha;
    late GameNetworkService bravo;
    late _InstrumentedFakeNetworkTransport alphaTransport;
    late _InstrumentedFakeNetworkTransport bravoTransport;

    setUp(() async {
      hub = FakeNetworkHub();

      alphaTransport = _InstrumentedFakeNetworkTransport(
        inner: FakeNetworkTransport(
          hub: hub,
          localHost: 'alpha.local',
          localPort: 9001,
        ),
      );

      alpha = GameNetworkService(
        transport: alphaTransport,
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

      bravoTransport = _InstrumentedFakeNetworkTransport(
        inner: FakeNetworkTransport(
          hub: hub,
          localHost: 'bravo.local',
          localPort: 9002,
        ),
      );

      bravo = GameNetworkService(
        transport: bravoTransport,
        localPlayerId: 'bravo',
        initialPlayerName: 'Bravo',
        initialPlayerGroup: 'Blue',
        peerDirectory: PeerDirectory(
          initialPeers: const <PeerEndpoint>[
            PeerEndpoint(host: 'alpha.local', port: 9001),
          ],
        ),
      );
  // should be
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

    test('does not award extra score while target is already dead', () async {
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
      expect(alpha.localPlayer.kills, 1);
      expect(bravo.localPlayer.deaths, 1);

      // Extra shots before respawn must not create additional kill points.
      await alpha.sendShot('bravo');
      await Future<void>.delayed(const Duration(milliseconds: 30));
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

    test('awards points for client versus client kills', () async {
      final charlieTransport = _InstrumentedFakeNetworkTransport(
        inner: FakeNetworkTransport(
          hub: hub,
          localHost: 'charlie.local',
          localPort: 9003,
        ),
      );
      final charlie = GameNetworkService(
        transport: charlieTransport,
        localPlayerId: 'charlie',
        initialPlayerName: 'Charlie',
        initialPlayerGroup: 'Red',
        peerDirectory: PeerDirectory(
          initialPeers: const <PeerEndpoint>[
            PeerEndpoint(host: 'alpha.local', port: 9001),
          ],
        ),
      );

      await charlie.start();
      addTearDown(() async {
        await charlie.stop();
      });

      await alpha.connect();
      await bravo.connect();
      await charlie.connect();
      await Future<void>.delayed(const Duration(milliseconds: 30));

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
      await Future<void>.delayed(const Duration(milliseconds: 70));

      await bravo.sendShot('charlie');
      await Future<void>.delayed(const Duration(milliseconds: 180));

      expect(bravo.localPlayer.score, 1);
      expect(bravo.localPlayer.kills, 1);
      expect(charlie.localPlayer.deaths, 1);
    });

    test('ignores out-of-order state sequence packets', () async {
      await alpha.connect();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final newerState = NetworkPacket(
        type: PacketType.state,
        playerId: 'alpha',
        playerName: 'Alpha',
        payload: <String, dynamic>{
          'stateSequence': 10,
          'lobbyOpen': true,
          'serverPlayerId': 'alpha',
          'serverNow': DateTime.now().toUtc().toIso8601String(),
          'gamePhase': GamePhase.running.name,
          'players': const <Map<String, dynamic>>[],
        },
      );

      final olderState = NetworkPacket(
        type: PacketType.state,
        playerId: 'alpha',
        playerName: 'Alpha',
        payload: <String, dynamic>{
          'stateSequence': 9,
          'lobbyOpen': false,
          'serverPlayerId': 'alpha',
          'serverNow': DateTime.now().toUtc().toIso8601String(),
          'gamePhase': GamePhase.ended.name,
          'players': const <Map<String, dynamic>>[],
        },
      );

      await hub.send(
        from: const PeerEndpoint(host: 'alpha.local', port: 9001),
        to: const PeerEndpoint(host: 'bravo.local', port: 9002),
        packet: newerState,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(bravo.snapshot.gamePhase, GamePhase.running);
      expect(bravo.snapshot.lobbyOpen, isTrue);

      await hub.send(
        from: const PeerEndpoint(host: 'alpha.local', port: 9001),
        to: const PeerEndpoint(host: 'bravo.local', port: 9002),
        packet: olderState,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(bravo.snapshot.gamePhase, GamePhase.running);
      expect(bravo.snapshot.lobbyOpen, isTrue);
    });

    test('applies item effect and pickup deltas from state packets', () async {
      await alpha.connect();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final fullState = NetworkPacket(
        type: PacketType.state,
        playerId: 'alpha',
        playerName: 'Alpha',
        payload: <String, dynamic>{
          'stateSequence': 20,
          'lobbyOpen': true,
          'serverPlayerId': 'alpha',
          'serverNow': DateTime.now().toUtc().toIso8601String(),
          'gamePhase': GamePhase.running.name,
          'items': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'item_a',
              'effectType': 'playerHeal',
              'latitude': 10.0,
              'longitude': 20.0,
            },
          ],
          'activeEffects': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'effect_a',
              'playerId': 'bravo',
              'effectType': 'playerShield',
              'createdAt': DateTime.now().toIso8601String(),
              'expiresAt': null,
            },
          ],
          'recentItemPickups': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'pickup_a',
              'itemId': 'item_a',
              'playerId': 'bravo',
              'playerName': 'Bravo',
              'effectType': 'playerHeal',
              'createdAt': DateTime.now().toIso8601String(),
            },
          ],
          'players': const <Map<String, dynamic>>[],
        },
      );

      await hub.send(
        from: const PeerEndpoint(host: 'alpha.local', port: 9001),
        to: const PeerEndpoint(host: 'bravo.local', port: 9002),
        packet: fullState,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(bravo.snapshot.items.map((item) => item.id), contains('item_a'));
      expect(
        bravo.snapshot.activeEffects.map((effect) => effect.id),
        contains('effect_a'),
      );
      expect(
        bravo.snapshot.recentItemPickups.map((pickup) => pickup.id),
        contains('pickup_a'),
      );

      final deltaState = NetworkPacket(
        type: PacketType.state,
        playerId: 'alpha',
        playerName: 'Alpha',
        payload: <String, dynamic>{
          'stateSequence': 21,
          'lobbyOpen': true,
          'serverPlayerId': 'alpha',
          'serverNow': DateTime.now().toUtc().toIso8601String(),
          'gamePhase': GamePhase.running.name,
          'itemDeltas': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'item_b',
              'effectType': 'doubleDamage',
              'latitude': 11.0,
              'longitude': 21.0,
            },
          ],
          'removedItemIds': <String>['item_a'],
          'activeEffectDeltas': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'effect_b',
              'playerId': 'bravo',
              'effectType': 'doubleDamage',
              'createdAt': DateTime.now().toIso8601String(),
              'expiresAt': DateTime.now()
                  .add(const Duration(seconds: 10))
                  .toIso8601String(),
            },
          ],
          'removedActiveEffectIds': <String>['effect_a'],
          'pickupDeltas': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'pickup_b',
              'itemId': 'item_b',
              'playerId': 'bravo',
              'playerName': 'Bravo',
              'effectType': 'doubleDamage',
              'createdAt': DateTime.now().toIso8601String(),
            },
          ],
          'removedPickupIds': <String>['pickup_a'],
          'playerDeltas': const <Map<String, dynamic>>[],
          'removedPlayerIds': const <String>[],
        },
      );

      await hub.send(
        from: const PeerEndpoint(host: 'alpha.local', port: 9001),
        to: const PeerEndpoint(host: 'bravo.local', port: 9002),
        packet: deltaState,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(bravo.snapshot.items.map((item) => item.id), isNot(contains('item_a')));
      expect(bravo.snapshot.items.map((item) => item.id), contains('item_b'));
      expect(
        bravo.snapshot.activeEffects.map((effect) => effect.id),
        isNot(contains('effect_a')),
      );
      expect(
        bravo.snapshot.activeEffects.map((effect) => effect.id),
        contains('effect_b'),
      );
      expect(
        bravo.snapshot.recentItemPickups.map((pickup) => pickup.id),
        isNot(contains('pickup_a')),
      );
      expect(
        bravo.snapshot.recentItemPickups.map((pickup) => pickup.id),
        contains('pickup_b'),
      );
    });

    test('processes duplicate hit event id only once', () async {
      await alpha.connect();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await alpha.updateLobbyRules(
        const LobbyRules(
          gameType: GameType.time,
          magazineSize: 15,
          reloadTimeSeconds: 2,
          maxLives: 10,
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

      final duplicateEventId = 'dup_hit_event_1';
      final duplicateHit = NetworkPacket(
        type: PacketType.hit,
        playerId: 'alpha',
        targetPlayerId: 'bravo',
        payload: <String, dynamic>{
          'eventId': duplicateEventId,
        },
      );

      await hub.send(
        from: const PeerEndpoint(host: 'bravo.local', port: 9002),
        to: const PeerEndpoint(host: 'alpha.local', port: 9001),
        packet: duplicateHit,
      );
      await hub.send(
        from: const PeerEndpoint(host: 'bravo.local', port: 9002),
        to: const PeerEndpoint(host: 'alpha.local', port: 9001),
        packet: duplicateHit,
      );

      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(alpha.localPlayer.hitsLanded, 1);
      expect(alpha.localPlayer.kills, 0);
      expect(alpha.localPlayer.score, 0);
      expect(alpha.snapshot.players['bravo']?.hitsTaken, 1);
      expect(alpha.snapshot.players['bravo']?.deaths, 0);
    });

    test('ack cancels retry for hit ready and state', () async {
      await alpha.connect();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      var dropShotAck = 1;
      var dropHitAck = 1;
      var dropReadyAck = 1;
      var dropStateAck = 1;

      alphaTransport.shouldDropSend = (host, port, packet) {
        if (packet.type != PacketType.ack) {
          return false;
        }
        final ackType = packet.payload['ackType'] as String?;
        if (ackType == PacketType.shot.name && dropShotAck > 0) {
          dropShotAck -= 1;
          return true;
        }
        if (ackType == PacketType.hit.name && dropHitAck > 0) {
          dropHitAck -= 1;
          return true;
        }
        if (ackType == PacketType.ready.name && dropReadyAck > 0) {
          dropReadyAck -= 1;
          return true;
        }
        return false;
      };
      bravoTransport.shouldDropSend = (host, port, packet) {
        if (packet.type != PacketType.ack) {
          return false;
        }
        final ackType = packet.payload['ackType'] as String?;
        if (ackType == PacketType.state.name && dropStateAck > 0) {
          dropStateAck -= 1;
          return true;
        }
        return false;
      };

      await alpha.updateLobbyRules(
        const LobbyRules(
          gameType: GameType.time,
          magazineSize: 15,
          reloadTimeSeconds: 2,
          maxLives: 10,
          matchLengthMinutes: 10,
          maxPlayers: 6,
          respawnDelaySeconds: 5,
          itemSpawnRateSeconds: 30,
          friendlyFire: false,
          allowMidGameJoin: true,
          teamLeadVoiceOnly: true,
        ),
      );

      alphaTransport.sentPackets.clear();
      bravoTransport.sentPackets.clear();

        // SHOT reliability: first ack dropped, retry must happen, then stop.
        await bravo.sendShot('ghost');
        await Future<void>.delayed(const Duration(milliseconds: 450));

        final shotSends = bravoTransport.sentPackets
          .where((record) => record.packet.type == PacketType.shot)
          .length;
        expect(shotSends, greaterThanOrEqualTo(2));
        expect(shotSends, lessThan(4));

        final shotSendsBeforeStabilityWait = shotSends;
        await Future<void>.delayed(const Duration(milliseconds: 260));
        final shotSendsAfterStabilityWait = bravoTransport.sentPackets
          .where((record) => record.packet.type == PacketType.shot)
          .length;
        expect(shotSendsAfterStabilityWait, shotSendsBeforeStabilityWait);

        expect(alpha.snapshot.players['bravo']?.shotsFired, 1);

      // HIT reliability: first ack dropped, retry must happen, then stop.
      await hub.send(
        from: const PeerEndpoint(host: 'alpha.local', port: 9001),
        to: const PeerEndpoint(host: 'bravo.local', port: 9002),
        packet: const NetworkPacket(
          type: PacketType.shot,
          playerId: 'alpha',
          playerName: 'Alpha',
          targetPlayerId: 'bravo',
          payload: <String, dynamic>{},
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 450));

      final hitSends = bravoTransport.sentPackets
          .where((record) => record.packet.type == PacketType.hit)
          .length;
      expect(hitSends, greaterThanOrEqualTo(2));
      expect(hitSends, lessThan(4));

      final hitSendsBeforeStabilityWait = hitSends;
      await Future<void>.delayed(const Duration(milliseconds: 260));
      final hitSendsAfterStabilityWait = bravoTransport.sentPackets
          .where((record) => record.packet.type == PacketType.hit)
          .length;
      expect(hitSendsAfterStabilityWait, hitSendsBeforeStabilityWait);

      // READY reliability: first ack dropped, retry must happen, then stop.
      await bravo.confirmTeamLeadReadyStart();
      await Future<void>.delayed(const Duration(milliseconds: 450));

      final readySends = bravoTransport.sentPackets
          .where((record) => record.packet.type == PacketType.ready)
          .length;
      expect(readySends, greaterThanOrEqualTo(2));
      expect(readySends, lessThan(4));

      final readyBeforeStabilityWait = readySends;
      await Future<void>.delayed(const Duration(milliseconds: 260));
      final readyAfterStabilityWait = bravoTransport.sentPackets
          .where((record) => record.packet.type == PacketType.ready)
          .length;
      expect(readyAfterStabilityWait, readyBeforeStabilityWait);

      // STATE reliability: first ack dropped, retry must happen, then stop.
      await alpha.setLobbyOpen(false);
      await Future<void>.delayed(const Duration(milliseconds: 450));

      final reliableStateSends = alphaTransport.sentPackets
          .where((record) => record.packet.type == PacketType.state)
          .where((record) => record.packet.payload['requiresAck'] == true)
          .length;
      expect(reliableStateSends, greaterThanOrEqualTo(2));
      expect(reliableStateSends, lessThan(4));

      final stateBeforeStabilityWait = reliableStateSends;
      await Future<void>.delayed(const Duration(milliseconds: 260));
      final stateAfterStabilityWait = alphaTransport.sentPackets
          .where((record) => record.packet.type == PacketType.state)
          .where((record) => record.packet.payload['requiresAck'] == true)
          .length;
      expect(stateAfterStabilityWait, stateBeforeStabilityWait);
    });
  });
}
