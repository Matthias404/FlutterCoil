import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class GunProfile {
  const GunProfile({
    required this.displayName,
    required this.deviceId,
    this.reloadButton = GunButton.reload,
    this.shootButton = GunButton.trigger,
    this.changeFireModeButton = GunButton.thumb,
    this.selectedFireMode = FireMode.single,
    this.allowSingleShotMode = true,
    this.allowBurst3ShotMode = true,
    this.allowAutoShotMode = true,
    this.recoilEnabled = true,
  });

  final String displayName;
  final String deviceId;
  final GunButton reloadButton;
  final GunButton shootButton;
  final GunButton changeFireModeButton;
  final FireMode selectedFireMode;
  final bool allowSingleShotMode;
  final bool allowBurst3ShotMode;
  final bool allowAutoShotMode;
  final bool recoilEnabled;

  GunProfile copyWith({
    String? displayName,
    String? deviceId,
    GunButton? reloadButton,
    GunButton? shootButton,
    GunButton? changeFireModeButton,
    FireMode? selectedFireMode,
    bool? allowSingleShotMode,
    bool? allowBurst3ShotMode,
    bool? allowAutoShotMode,
    bool? recoilEnabled,
  }) {
    return GunProfile(
      displayName: displayName ?? this.displayName,
      deviceId: deviceId ?? this.deviceId,
      reloadButton: reloadButton ?? this.reloadButton,
      shootButton: shootButton ?? this.shootButton,
      changeFireModeButton: changeFireModeButton ?? this.changeFireModeButton,
      selectedFireMode: selectedFireMode ?? this.selectedFireMode,
      allowSingleShotMode: allowSingleShotMode ?? this.allowSingleShotMode,
      allowBurst3ShotMode: allowBurst3ShotMode ?? this.allowBurst3ShotMode,
      allowAutoShotMode: allowAutoShotMode ?? this.allowAutoShotMode,
      recoilEnabled: recoilEnabled ?? this.recoilEnabled,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'displayName': displayName,
      'deviceId': deviceId,
      'reloadButton': reloadButton.name,
      'shootButton': shootButton.name,
      'changeFireModeButton': changeFireModeButton.name,
      'selectedFireMode': selectedFireMode.name,
      'allowSingleShotMode': allowSingleShotMode,
      'allowBurst3ShotMode': allowBurst3ShotMode,
      'allowAutoShotMode': allowAutoShotMode,
      'recoilEnabled': recoilEnabled,
    };
  }

  factory GunProfile.fromJson(Map<String, dynamic> json) {
    return GunProfile(
      displayName: json['displayName'] as String? ?? 'LaserTag Gun',
      deviceId: json['deviceId'] as String? ?? '',
      reloadButton: GunButton.reload,
      shootButton: GunButton.trigger,
      changeFireModeButton: GunButton.thumb,
      selectedFireMode: _parseFireMode(
        json['selectedFireMode'] as String?,
        fallback: FireMode.single,
      ),
      allowSingleShotMode: json['allowSingleShotMode'] as bool? ?? true,
      allowBurst3ShotMode: json['allowBurst3ShotMode'] as bool? ?? true,
      allowAutoShotMode: json['allowAutoShotMode'] as bool? ?? true,
      recoilEnabled: json['recoilEnabled'] as bool? ?? true,
    );
  }

  static FireMode _parseFireMode(
    String? rawValue, {
    required FireMode fallback,
  }) {
    if (rawValue == null || rawValue.trim().isEmpty) {
      return fallback;
    }

    return FireMode.values
        .where((mode) => mode.name == rawValue)
        .firstWhere((_) => true, orElse: () => fallback);
  }
}

enum GunButton { trigger, reload, thumb, power }

enum FireMode { single, burst3, auto }

extension FireModeLabel on FireMode {
  String get label {
    switch (this) {
      case FireMode.single:
        return 'Single';
      case FireMode.burst3:
        return 'Burst 3';
      case FireMode.auto:
        return 'Full Auto';
    }
  }
}

extension GunButtonLabel on GunButton {
  String get label {
    switch (this) {
      case GunButton.trigger:
        return 'Trigger';
      case GunButton.reload:
        return 'Reload Button';
      case GunButton.thumb:
        return 'Thumb / Rear Button';
      case GunButton.power:
        return 'Power Button';
    }
  }
}

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
