import 'dart:convert';

enum PacketType { hello, join, shot, hit, heartbeat, state, voice, ready, ack }

PacketType _typeFromString(String value) {
  return PacketType.values.firstWhere(
    (t) => t.name == value,
    orElse: () => PacketType.state,
  );
}

class NetworkPacket {
  const NetworkPacket({
    required this.type,
    required this.playerId,
    this.playerName,
    this.targetPlayerId,
    this.payload = const <String, dynamic>{},
  });

  final PacketType type;
  final String playerId;
  final String? playerName;
  final String? targetPlayerId;
  final Map<String, dynamic> payload;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'type': type.name,
      'playerId': playerId,
      'playerName': playerName,
      'targetPlayerId': targetPlayerId,
      'payload': payload,
    };
  }

  factory NetworkPacket.fromJson(Map<String, dynamic> json) {
    return NetworkPacket(
      type: _typeFromString(json['type'] as String? ?? ''),
      playerId: json['playerId'] as String? ?? 'unknown',
      playerName: json['playerName'] as String?,
      targetPlayerId: json['targetPlayerId'] as String?,
      payload:
          (json['payload'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{},
    );
  }

  String encode() => jsonEncode(toJson());

  factory NetworkPacket.decode(String input) {
    final decoded = jsonDecode(input) as Map<String, dynamic>;
    return NetworkPacket.fromJson(decoded);
  }
}
