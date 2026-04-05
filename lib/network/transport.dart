import 'protocol.dart';

class DatagramEnvelope {
  const DatagramEnvelope({
    required this.host,
    required this.port,
    required this.packet,
  });

  final String host;
  final int port;
  final NetworkPacket packet;
}

abstract class NetworkTransport {
  Stream<DatagramEnvelope> get incoming;

  Future<void> start();

  Future<void> send(String host, int port, NetworkPacket packet);

  Future<void> stop();
}

class PeerEndpoint {
  const PeerEndpoint({required this.host, required this.port});

  final String host;
  final int port;

  @override
  String toString() => '$host:$port';

  @override
  bool operator ==(Object other) {
    return other is PeerEndpoint && other.host == host && other.port == port;
  }

  @override
  int get hashCode => Object.hash(host, port);
}
