import 'dart:async';

import 'protocol.dart';
import 'transport.dart';

class FakeNetworkHub {
  final Map<PeerEndpoint, StreamController<DatagramEnvelope>> _endpoints =
      <PeerEndpoint, StreamController<DatagramEnvelope>>{};

  StreamController<DatagramEnvelope> register(PeerEndpoint endpoint) {
    final controller = StreamController<DatagramEnvelope>.broadcast();
    _endpoints[endpoint] = controller;
    return controller;
  }

  void unregister(PeerEndpoint endpoint) {
    final controller = _endpoints.remove(endpoint);
    controller?.close();
  }

  Future<void> send({
    required PeerEndpoint from,
    required PeerEndpoint to,
    required NetworkPacket packet,
  }) async {
    final target = _endpoints[to];
    if (target == null) {
      return;
    }

    target.add(DatagramEnvelope(host: from.host, port: from.port, packet: packet));
  }
}

class FakeNetworkTransport implements NetworkTransport {
  FakeNetworkTransport({
    required this.hub,
    required this.localHost,
    required this.localPort,
  });

  final FakeNetworkHub hub;
  final String localHost;
  final int localPort;

  StreamController<DatagramEnvelope>? _incoming;

  PeerEndpoint get endpoint => PeerEndpoint(host: localHost, port: localPort);

  @override
  Stream<DatagramEnvelope> get incoming {
    final incoming = _incoming;
    if (incoming == null) {
      throw StateError('Transport must be started before listening.');
    }
    return incoming.stream;
  }

  @override
  Future<void> start() async {
    _incoming ??= hub.register(endpoint);
  }

  @override
  Future<void> send(String host, int port, NetworkPacket packet) async {
    await hub.send(
      from: endpoint,
      to: PeerEndpoint(host: host, port: port),
      packet: packet,
    );
  }

  @override
  Future<void> stop() async {
    if (_incoming == null) {
      return;
    }

    hub.unregister(endpoint);
    _incoming = null;
  }
}
