class PlayerState {
  const PlayerState({
    required this.id,
    required this.name,
    required this.group,
    required this.playerClass,
    required this.score,
    required this.shotsFired,
    required this.hitsTaken,
    required this.gunConnected,
    required this.isHost,
    required this.lastSeen,
  });

  final String id;
  final String name;
  final String group;
  final String playerClass;
  final int score;
  final int shotsFired;
  final int hitsTaken;
  final bool gunConnected;
  final bool isHost;
  final DateTime lastSeen;

  PlayerState copyWith({
    String? id,
    String? name,
    String? group,
    String? playerClass,
    int? score,
    int? shotsFired,
    int? hitsTaken,
    bool? gunConnected,
    bool? isHost,
    DateTime? lastSeen,
  }) {
    return PlayerState(
      id: id ?? this.id,
      name: name ?? this.name,
      group: group ?? this.group,
      playerClass: playerClass ?? this.playerClass,
      score: score ?? this.score,
      shotsFired: shotsFired ?? this.shotsFired,
      hitsTaken: hitsTaken ?? this.hitsTaken,
      gunConnected: gunConnected ?? this.gunConnected,
      isHost: isHost ?? this.isHost,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }
}