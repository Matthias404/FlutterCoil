import 'dart:math';

import 'package:flutter/material.dart';

import '../media_confic.dart';
import 'item_models.dart';

/// Full configuration for a single item type.
///
/// To add, remove, or tweak an item edit the [ItemRegistry.definitions] map
/// below — the server spawn algorithm and HUD automatically reflect changes.
class ItemDefinition {
  const ItemDefinition({
    required this.effectType,
    required this.name,
    required this.description,
    required this.category,
    required this.icon,
    required this.pickupSound,
    required this.useSound,
    required this.spawnWeight,
  });

  /// The gameplay effect granted when a player picks this item up.
  final GameItemEffectType effectType;

  /// Human-readable display name (HUD, pickup feed, test buttons).
  final String name;

  /// Short description shown in item info overlays and tooltips.
  final String description;

  /// Broad category used for colour-coding and UI grouping.
  final GameItemCategory category;

  /// Icon displayed on the map marker and HUD badge.
  final IconData icon;

  /// Audio asset path relative to `assets/` (compatible with [AssetSource])
  /// played for the picking-up player when this item is collected.
  final String pickupSound;

  /// Audio asset path played when this item's effect is activated/used.
  /// For instant effects this fires immediately on pickup; for stored items
  /// (e.g. [GameItemEffectType.playerHeal]) it fires when the player
  /// deliberately consumes the charge.
  final String useSound;

  /// Relative probability weight used by the server's weighted-random spawn
  /// algorithm. Higher values make this item appear more frequently.
  /// E.g. weight 3.0 spawns ~3× as often as an item with weight 1.0.
  final double spawnWeight;
}

/// Central registry of every item in the game.
///
/// Add a new item here by:
///   1. Adding a value to [GameItemEffectType] in `item_models.dart`.
///   2. Adding a matching [ItemDefinition] entry in [definitions] below.
///   3. Handling the new effect type in `game_network_service.dart`.
class ItemRegistry {
  ItemRegistry._();

  /// All item definitions keyed by [GameItemEffectType].
  static const Map<GameItemEffectType, ItemDefinition> definitions = {
    // ── Healing ──────────────────────────────────────────────────────────────
    GameItemEffectType.teamHeal: ItemDefinition(
      effectType: GameItemEffectType.teamHeal,
      name: 'Team Heal',
      description: 'Restores health for every member of your team.',
      category: GameItemCategory.healing,
      icon: Icons.favorite,
      pickupSound: MediaConfic.spawn,
      useSound: MediaConfic.healUp,
      spawnWeight: 2.5,
    ),
    GameItemEffectType.playerHeal: ItemDefinition(
      effectType: GameItemEffectType.playerHeal,
      name: 'Medkit',
      description: 'Stores a single-use heal charge for the carrier.',
      category: GameItemCategory.healing,
      icon: Icons.medical_services,
      pickupSound: MediaConfic.spawn,
      useSound: MediaConfic.healUp,
      spawnWeight: 3.0,
    ),

    // ── Armor ─────────────────────────────────────────────────────────────────
    GameItemEffectType.teamArmor: ItemDefinition(
      effectType: GameItemEffectType.teamArmor,
      name: 'Team Armor',
      description: 'Grants temporary damage reduction to your entire team.',
      category: GameItemCategory.armor,
      icon: Icons.shield,
      pickupSound: MediaConfic.spawn,
      useSound: MediaConfic.shield,
      spawnWeight: 2.0,
    ),
    GameItemEffectType.playerShield: ItemDefinition(
      effectType: GameItemEffectType.playerShield,
      name: 'Personal Shield',
      description: 'Wraps the carrier in a short-duration energy shield.',
      category: GameItemCategory.armor,
      icon: Icons.security,
      pickupSound: MediaConfic.spawn,
      useSound: MediaConfic.shield,
      spawnWeight: 2.5,
    ),

    // ── Damage / Ammo ─────────────────────────────────────────────────────────
    GameItemEffectType.teamAmmo: ItemDefinition(
      effectType: GameItemEffectType.teamAmmo,
      name: 'Team Ammo Pack',
      description: 'Refills ammo for every member of your team.',
      category: GameItemCategory.damage,
      icon: Icons.electric_bolt,
      pickupSound: MediaConfic.spawn,
      useSound: MediaConfic.reload,
      spawnWeight: 2.5,
    ),
    GameItemEffectType.playerAmmo: ItemDefinition(
      effectType: GameItemEffectType.playerAmmo,
      name: 'Ammo Pack',
      description: "Instantly refills the carrier's ammo.",
      category: GameItemCategory.damage,
      icon: Icons.bolt,
      pickupSound: MediaConfic.spawn,
      useSound: MediaConfic.reload,
      spawnWeight: 3.0,
    ),
    GameItemEffectType.doubleDamage: ItemDefinition(
      effectType: GameItemEffectType.doubleDamage,
      name: 'Double Damage',
      description: 'Doubles outgoing damage for a limited time.',
      category: GameItemCategory.damage,
      icon: Icons.flash_on,
      pickupSound: MediaConfic.spawn,
      useSound: MediaConfic.score,
      spawnWeight: 1.5,
    ),

    // ── Special ───────────────────────────────────────────────────────────────
    GameItemEffectType.airStrike: ItemDefinition(
      effectType: GameItemEffectType.airStrike,
      name: 'Air Strike',
      description: 'Calls in an air strike that eliminates nearby enemies.',
      category: GameItemCategory.special,
      icon: Icons.flight,
      pickupSound: MediaConfic.spawn,
      useSound: MediaConfic.bombDropping,
      spawnWeight: 1.0,
    ),
    GameItemEffectType.invisibility: ItemDefinition(
      effectType: GameItemEffectType.invisibility,
      name: 'Cloak',
      description: 'Renders the carrier invisible to enemy sensors temporarily.',
      category: GameItemCategory.special,
      icon: Icons.visibility_off,
      pickupSound: MediaConfic.spawn,
      useSound: MediaConfic.beep,
      spawnWeight: 1.0,
    ),
  };

  /// Returns the definition for [effectType], or `null` if not registered.
  static ItemDefinition? of(GameItemEffectType effectType) =>
      definitions[effectType];

  /// Picks an effect type using weighted random selection.
  ///
  /// When [freeForAll] is `true`, team-wide effects are excluded from the pool.
  static GameItemEffectType pickEffectType({
    required bool freeForAll,
    required Random random,
  }) {
    final pool = definitions.values
        .where((d) => !freeForAll || !d.effectType.isTeamEffect)
        .toList();

    if (pool.isEmpty) return GameItemEffectType.playerHeal;

    final totalWeight = pool.fold<double>(0.0, (sum, d) => sum + d.spawnWeight);
    var roll = random.nextDouble() * totalWeight;
    for (final def in pool) {
      roll -= def.spawnWeight;
      if (roll <= 0) return def.effectType;
    }
    return pool.last.effectType;
  }
}
