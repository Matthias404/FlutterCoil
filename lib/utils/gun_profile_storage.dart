import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class GunProfile {
  const GunProfile({
    required this.displayName,
    required this.deviceId,
    this.ammo = 120,
    this.health = 100,
    this.fireMode = FireMode.single,
    this.damageMult = 1.0,
    this.recoilEnabled = true,
  });

  final String displayName;
  final String deviceId;
  final int ammo;
  final int health;
  final FireMode fireMode;
  final double damageMult;
  final bool recoilEnabled;

  GunProfile copyWith({
    String? displayName,
    String? deviceId,
    int? ammo,
    int? health,
    FireMode? fireMode,
    double? damageMult,
    bool? recoilEnabled,
  }) {
    return GunProfile(
      displayName: displayName ?? this.displayName,
      deviceId: deviceId ?? this.deviceId,
      ammo: ammo ?? this.ammo,
      health: health ?? this.health,
      fireMode: fireMode ?? this.fireMode,
      damageMult: damageMult ?? this.damageMult,
      recoilEnabled: recoilEnabled ?? this.recoilEnabled,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'displayName': displayName,
      'deviceId': deviceId,
      'ammo': ammo,
      'health': health,
      'fireMode': fireMode.toString(),
      'damageMult': damageMult,
      'recoilEnabled': recoilEnabled,
    };
  }

  factory GunProfile.fromJson(Map<String, dynamic> json) {
    return GunProfile(
      displayName: json['displayName'] as String? ?? 'LaserTag Gun',
      deviceId: json['deviceId'] as String? ?? '',
      ammo: json['ammo'] as int? ?? 120,
      health: json['health'] as int? ?? 100,
      fireMode: _parseFireMode(
        json['fireMode'] as String? ?? 'FireMode.single',
      ),
      damageMult: (json['damageMult'] as num?)?.toDouble() ?? 1.0,
      recoilEnabled: json['recoilEnabled'] as bool? ?? true,
    );
  }

  static FireMode _parseFireMode(String modeStr) {
    if (modeStr.contains('burst')) return FireMode.burst;
    if (modeStr.contains('auto')) return FireMode.auto;
    return FireMode.single;
  }
}

enum FireMode { single, burst, auto }

class GunProfileStorage {
  static const String _fileName = 'gun_profile.json';

  static Future<File> _profileFile() async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/$_fileName');
  }

  static Future<GunProfile?> load() async {
    try {
      final file = await _profileFile();
      if (!await file.exists()) {
        return null;
      }

      final content = await file.readAsString();
      if (content.trim().isEmpty) {
        return null;
      }

      final data = jsonDecode(content) as Map<String, dynamic>;
      final profile = GunProfile.fromJson(data);
      if (profile.deviceId.trim().isEmpty) {
        return null;
      }
      return profile;
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(GunProfile profile) async {
    final file = await _profileFile();
    await file.writeAsString(jsonEncode(profile.toJson()), flush: true);
  }

  static Future<void> clear() async {
    final file = await _profileFile();
    if (await file.exists()) {
      await file.delete();
    }
  }
}
