enum GameItemCategory { healing, armor, damage, special }

extension GameItemCategoryLabel on GameItemCategory {
  String get label {
    switch (this) {
      case GameItemCategory.healing:
        return 'Healing';
      case GameItemCategory.armor:
        return 'Armor';
      case GameItemCategory.damage:
        return 'Damage';
      case GameItemCategory.special:
        return 'Special';
    }
  }
}

enum GameItemEffectType {
  teamHeal,
  playerHeal,
  teamArmor,
  playerShield,
  teamAmmo,
  playerAmmo,
  doubleDamage,
  airStrike,
  invisibility,
}

GameItemEffectType _gameItemEffectTypeFromString(String value) {
  return GameItemEffectType.values.firstWhere(
    (effectType) => effectType.name == value,
    orElse: () => GameItemEffectType.playerHeal,
  );
}

extension GameItemEffectTypeMetadata on GameItemEffectType {
  GameItemCategory get category {
    switch (this) {
      case GameItemEffectType.teamHeal:
      case GameItemEffectType.playerHeal:
        return GameItemCategory.healing;
      case GameItemEffectType.teamArmor:
      case GameItemEffectType.playerShield:
        return GameItemCategory.armor;
      case GameItemEffectType.teamAmmo:
      case GameItemEffectType.playerAmmo:
      case GameItemEffectType.doubleDamage:
        return GameItemCategory.damage;
      case GameItemEffectType.airStrike:
      case GameItemEffectType.invisibility:
        return GameItemCategory.special;
    }
  }

  bool get isTeamEffect {
    switch (this) {
      case GameItemEffectType.teamHeal:
      case GameItemEffectType.teamArmor:
      case GameItemEffectType.teamAmmo:
        return true;
      case GameItemEffectType.playerHeal:
      case GameItemEffectType.playerShield:
      case GameItemEffectType.playerAmmo:
      case GameItemEffectType.doubleDamage:
      case GameItemEffectType.airStrike:
      case GameItemEffectType.invisibility:
        return false;
    }
  }

  String get label {
    switch (this) {
      case GameItemEffectType.teamHeal:
        return 'Team Heal';
      case GameItemEffectType.playerHeal:
        return 'Player Heal';
      case GameItemEffectType.teamArmor:
        return 'Team Armor';
      case GameItemEffectType.playerShield:
        return 'Player Shield';
      case GameItemEffectType.teamAmmo:
        return 'Team Ammo';
      case GameItemEffectType.playerAmmo:
        return 'Player Ammo';
      case GameItemEffectType.doubleDamage:
        return 'Double Damage';
      case GameItemEffectType.airStrike:
        return 'Air Strike';
      case GameItemEffectType.invisibility:
        return 'Invisibility';
    }
  }
}

class GameMapItem {
  const GameMapItem({
    required this.id,
    required this.effectType,
    required this.latitude,
    required this.longitude,
  });

  final String id;
  final GameItemEffectType effectType;
  final double latitude;
  final double longitude;

  GameItemCategory get category => effectType.category;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'effectType': effectType.name,
      'latitude': latitude,
      'longitude': longitude,
    };
  }

  factory GameMapItem.fromJson(Map<String, dynamic> json) {
    return GameMapItem(
      id: json['id'] as String? ?? 'unknown_item',
      effectType: _gameItemEffectTypeFromString(
        json['effectType'] as String? ?? '',
      ),
      latitude: (json['latitude'] as num?)?.toDouble() ?? 0,
      longitude: (json['longitude'] as num?)?.toDouble() ?? 0,
    );
  }
}

class ActiveGameEffect {
  const ActiveGameEffect({
    required this.id,
    required this.playerId,
    required this.effectType,
    required this.createdAt,
    this.expiresAt,
  });

  final String id;
  final String playerId;
  final GameItemEffectType effectType;
  final DateTime createdAt;
  final DateTime? expiresAt;

  bool get isPersistent => expiresAt == null;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'playerId': playerId,
      'effectType': effectType.name,
      'createdAt': createdAt.toIso8601String(),
      'expiresAt': expiresAt?.toIso8601String(),
    };
  }

  factory ActiveGameEffect.fromJson(Map<String, dynamic> json) {
    return ActiveGameEffect(
      id: json['id'] as String? ?? 'unknown_effect',
      playerId: json['playerId'] as String? ?? 'unknown_player',
      effectType: _gameItemEffectTypeFromString(
        json['effectType'] as String? ?? '',
      ),
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      expiresAt: DateTime.tryParse(json['expiresAt'] as String? ?? ''),
    );
  }
}

class GameItemPickupNotification {
  const GameItemPickupNotification({
    required this.id,
    required this.itemId,
    required this.playerId,
    required this.playerName,
    required this.effectType,
    required this.createdAt,
  });

  final String id;
  final String itemId;
  final String playerId;
  final String playerName;
  final GameItemEffectType effectType;
  final DateTime createdAt;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'itemId': itemId,
      'playerId': playerId,
      'playerName': playerName,
      'effectType': effectType.name,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory GameItemPickupNotification.fromJson(Map<String, dynamic> json) {
    return GameItemPickupNotification(
      id: json['id'] as String? ?? 'unknown_pickup',
      itemId: json['itemId'] as String? ?? 'unknown_item',
      playerId: json['playerId'] as String? ?? 'unknown_player',
      playerName: json['playerName'] as String? ?? 'Player',
      effectType: _gameItemEffectTypeFromString(
        json['effectType'] as String? ?? '',
      ),
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

/// A kill/elimination event broadcast to all players so every client can show
/// the kill-screen overlay (both killer and victim side).
class KillEvent {
  const KillEvent({
    required this.id,
    required this.killerPlayerId,
    required this.killerName,
    required this.victimPlayerId,
    required this.victimName,
    required this.weapon,
    required this.createdAt,
  });

  final String id;
  final String killerPlayerId;
  final String killerName;
  final String victimPlayerId;
  final String victimName;

  /// Short label for what caused the kill: 'gun' or 'airStrike'.
  final String weapon;
  final DateTime createdAt;
}
