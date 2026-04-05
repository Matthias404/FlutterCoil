import 'dart:async';

import 'transport.dart';

class PeerDirectory {
  PeerDirectory({Iterable<PeerEndpoint> initialPeers = const <PeerEndpoint>[]}) {
    _peers.addAll(initialPeers);
  }

  final List<PeerEndpoint> _peers = <PeerEndpoint>[];
  final StreamController<List<PeerEndpoint>> _changes =
      StreamController<List<PeerEndpoint>>.broadcast();

  List<PeerEndpoint> get peers => List<PeerEndpoint>.unmodifiable(_peers);

  Stream<List<PeerEndpoint>> get changes => _changes.stream;

  bool contains(PeerEndpoint peer) => _peers.contains(peer);

  void add(PeerEndpoint peer) {
    if (_peers.contains(peer)) {
      return;
    }

    _peers.add(peer);
    _emit();
  }

  bool remove(PeerEndpoint peer) {
    final removed = _peers.remove(peer);
    if (removed) {
      _emit();
    }
    return removed;
  }

  void replaceAll(Iterable<PeerEndpoint> peers) {
    _peers
      ..clear()
      ..addAll(peers.toSet());
    _emit();
  }

  void clear() {
    if (_peers.isEmpty) {
      return;
    }

    _peers.clear();
    _emit();
  }

  Future<void> dispose() async {
    await _changes.close();
  }

  void _emit() {
    if (_changes.isClosed) {
      return;
    }

    _changes.add(List<PeerEndpoint>.unmodifiable(_peers));
  }
}
