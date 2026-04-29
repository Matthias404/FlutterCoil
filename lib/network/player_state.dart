class PlayerState {
  const PlayerState({
    required this.id,
    required this.name,
    required this.group,
    required this.playerClass,
    required this.score,
    required this.kills,
    required this.hitsLanded,
    required this.shotsFired,
    required this.hitsTaken,
    required this.gunConnected,
    required this.isHost,
    required this.lastSeen,
    this.latitude,
    this.longitude,
    this.isNetworkConnected = true,
  });

  final String id;
  final String name;
  final String group;
  final String playerClass;
  final int score;
  final int kills;
  final int hitsLanded;
  final int shotsFired;
  final int hitsTaken;
  final bool gunConnected;
  final bool isHost;
  final DateTime lastSeen;
  final double? latitude;
  final double? longitude;
  final bool isNetworkConnected;

  PlayerState copyWith({
    String? id,
    String? name,
    String? group,
    String? playerClass,
    int? score,
    int? kills,
    int? hitsLanded,
    int? shotsFired,
    int? hitsTaken,
    bool? gunConnected,
    bool? isHost,
    DateTime? lastSeen,
    double? latitude,
    double? longitude,
    bool? isNetworkConnected,
  }) {
    return PlayerState(
      id: id ?? this.id,
      name: name ?? this.name,
      group: group ?? this.group,
      playerClass: playerClass ?? this.playerClass,
      score: score ?? this.score,
      kills: kills ?? this.kills,
      hitsLanded: hitsLanded ?? this.hitsLanded,
      shotsFired: shotsFired ?? this.shotsFired,
      hitsTaken: hitsTaken ?? this.hitsTaken,
      gunConnected: gunConnected ?? this.gunConnected,
      isHost: isHost ?? this.isHost,
      lastSeen: lastSeen ?? this.lastSeen,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      isNetworkConnected: isNetworkConnected ?? this.isNetworkConnected,
    );
  }
}
