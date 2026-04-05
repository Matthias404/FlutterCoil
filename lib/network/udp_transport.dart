import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'protocol.dart';
import 'transport.dart';

class UdpNetworkTransport implements NetworkTransport {
  UdpNetworkTransport({required this.localPort})
      : _incoming = StreamController<DatagramEnvelope>.broadcast();

  final int localPort;
  final StreamController<DatagramEnvelope> _incoming;
  RawDatagramSocket? _socket;

  @override
  Stream<DatagramEnvelope> get incoming => _incoming.stream;

  @override
  Future<void> start() async {
    if (_socket != null) {
      return;
    }

    _socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      localPort,
      reuseAddress: true,
      reusePort: true,
    );

    _socket!.listen((event) {
      if (event != RawSocketEvent.read) {
        return;
      }

      final datagram = _socket!.receive();
      if (datagram == null) {
        return;
      }

      try {
        final message = utf8.decode(datagram.data);
        final packet = NetworkPacket.decode(message);
        _incoming.add(
          DatagramEnvelope(
            host: datagram.address.address,
            port: datagram.port,
            packet: packet,
          ),
        );
      } catch (_) {
        // Invalid packet; ignore so one corrupt packet does not break the loop.
      }
    });
  }

  @override
  Future<void> send(String host, int port, NetworkPacket packet) async {
    final socket = _socket;
    if (socket == null) {
      throw StateError('Transport must be started before send().');
    }

    final bytes = utf8.encode(packet.encode());
    socket.send(bytes, InternetAddress(host), port);
  }

  @override
  Future<void> stop() async {
    _socket?.close();
    _socket = null;
    await _incoming.close();
  }
}
