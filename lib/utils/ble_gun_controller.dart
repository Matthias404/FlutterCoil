import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'gun_profile_storage.dart';

enum GunBatteryLevel { empty, low, medium, full }

class GunTelemetrySample {
  const GunTelemetrySample({
    required this.recoilPlayerId,
    required this.buttons,
    required this.triggerCounter,
    required this.reloadCounter,
    required this.thumbCounter,
    required this.powerCounter,
    required this.batteryRaw,
    required this.batteryLevel,
    required this.hitBy1,
    required this.hitBy1ShotId,
    required this.hitBy2,
    required this.hitBy2ShotId,
    required this.shotsRemaining,
    required this.status,
  });

  final int recoilPlayerId;
  final int buttons;
  final int triggerCounter;
  final int reloadCounter;
  final int thumbCounter;
  final int powerCounter;
  final int batteryRaw;
  final GunBatteryLevel batteryLevel;
  final int hitBy1;
  final int hitBy1ShotId;
  final int hitBy2;
  final int hitBy2ShotId;
  final int shotsRemaining;
  final int status;
}

extension GunBatteryLevelLabel on GunBatteryLevel {
  String get label {
    switch (this) {
      case GunBatteryLevel.empty:
        return 'Empty';
      case GunBatteryLevel.low:
        return 'Low';
      case GunBatteryLevel.medium:
        return 'Medium';
      case GunBatteryLevel.full:
        return 'Full';
    }
  }
}

class BleGunController {
  BleGunController._();

  static final Map<String, Future<void>> _configWriteLocks =
      <String, Future<void>>{};
  static final Map<String, Future<void>> _commandWriteLocks =
      <String, Future<void>>{};
  static final Map<String, int> _commandIds = <String, int>{};
  static final Map<String, BluetoothCharacteristic> _configCharacteristics =
    <String, BluetoothCharacteristic>{};
  static final Map<String, BluetoothCharacteristic> _telemetryCharacteristics =
    <String, BluetoothCharacteristic>{};
  static final Map<String, BluetoothCharacteristic> _commandCharacteristics =
    <String, BluetoothCharacteristic>{};

  // SimpleCoil / RECOIL UUIDs.
  static final Guid _recoilMainServiceUuid = Guid(
    'e6f59d10-8230-4a5c-b22f-c062b1d329e3',
  );
  static final Guid _recoilConfigCharacteristicUuid = Guid(
    'e6f59d14-8230-4a5c-b22f-c062b1d329e3',
  );
  static final Guid _recoilTelemetryCharacteristicUuid = Guid(
    'e6f59d12-8230-4a5c-b22f-c062b1d329e3',
  );
  static final Guid _recoilCommandCharacteristicUuid = Guid(
    'e6f59d13-8230-4a5c-b22f-c062b1d329e3',
  );

  static const int _recoilTelemetryBatteryOffset = 7;
  static const int _recoilTelemetryTeamOffset = 1;
  static const int _recoilTelemetryButtonsOffset = 2;
  static const int _recoilTelemetryReloadTriggerCounterOffset = 3;
  static const int _recoilTelemetryThumbCounterOffset = 4;
  static const int _recoilTelemetryPowerCounterOffset = 5;
  static const int _recoilTelemetryHitBy1ShotIdOffset = 8;
  static const int _recoilTelemetryHitBy1Offset = 9;
  static const int _recoilTelemetryHitBy2ShotIdOffset = 11;
  static const int _recoilTelemetryHitBy2Offset = 12;
  static const int _recoilTelemetryShotsRemainingOffset = 14;
  static const int _recoilTelemetryStatusOffset = 15;

  // Force pistol behavior for RECOIL profile tuning.
  static const int _pistolOutdoorFiringModeByte5 = 0xFF;
  static const int _pistolIndoorFiringModeByte5 = 0x19;
  static const int _pistolFiringModeByte6 = 0x00;
  static const int _pistolRecoilStrength = 0x80;

  static String _normalizeDeviceId(String deviceId) {
    final normalizedDeviceId = deviceId.trim();
    if (normalizedDeviceId.isEmpty) {
      throw const FormatException('Bluetooth device id is empty.');
    }
    return normalizedDeviceId;
  }

  static BluetoothDevice deviceFromId(String deviceId) {
    return BluetoothDevice.fromId(_normalizeDeviceId(deviceId));
  }

  static bool isConnected({required String deviceId}) {
    return deviceFromId(deviceId).isConnected;
  }

  static Stream<bool> watchConnection({required String deviceId}) {
    return deviceFromId(deviceId).connectionState
        .map((state) => state == BluetoothConnectionState.connected)
        .distinct();
  }

  static Future<BluetoothCharacteristic> _configCharacteristicForDevice(
    String deviceId,
  ) async {
    final key = _normalizeDeviceId(deviceId);
    final cached = _configCharacteristics[key];
    if (cached != null) {
      return cached;
    }

    final device = await connect(deviceId: deviceId);

    final services = await device.discoverServices();
    final service = services
        .where((candidate) => candidate.uuid == _recoilMainServiceUuid)
        .cast<BluetoothService?>()
        .firstWhere((candidate) => candidate != null, orElse: () => null);
    if (service == null) {
      throw StateError('SimpleCoil RECOIL service not found on the gun.');
    }

    final characteristic = service.characteristics
        .where((candidate) => candidate.uuid == _recoilConfigCharacteristicUuid)
        .cast<BluetoothCharacteristic?>()
        .firstWhere((candidate) => candidate != null, orElse: () => null);
    if (characteristic == null) {
      throw StateError('SimpleCoil RECOIL config characteristic not found.');
    }

    final supportsWrite = characteristic.properties.write;
    final supportsWriteNoResponse =
        characteristic.properties.writeWithoutResponse;
    if (!supportsWrite && !supportsWriteNoResponse) {
      throw StateError(
        'SimpleCoil RECOIL config characteristic is not writable.',
      );
    }

    _configCharacteristics[key] = characteristic;
    return characteristic;
  }

  static Future<BluetoothCharacteristic> _telemetryCharacteristicForDevice(
    String deviceId,
  ) async {
    final key = _normalizeDeviceId(deviceId);
    final cached = _telemetryCharacteristics[key];
    if (cached != null) {
      return cached;
    }

    final device = await connect(deviceId: deviceId);

    final services = await device.discoverServices();
    final service = services
        .where((candidate) => candidate.uuid == _recoilMainServiceUuid)
        .cast<BluetoothService?>()
        .firstWhere((candidate) => candidate != null, orElse: () => null);
    if (service == null) {
      throw StateError('SimpleCoil RECOIL service not found on the gun.');
    }

    final characteristic = service.characteristics
        .where(
          (candidate) => candidate.uuid == _recoilTelemetryCharacteristicUuid,
        )
        .cast<BluetoothCharacteristic?>()
        .firstWhere((candidate) => candidate != null, orElse: () => null);
    if (characteristic == null) {
      throw StateError('SimpleCoil RECOIL telemetry characteristic not found.');
    }

    if (!characteristic.properties.notify &&
        !characteristic.properties.indicate) {
      throw StateError(
        'SimpleCoil RECOIL telemetry characteristic does not support notifications.',
      );
    }

    _telemetryCharacteristics[key] = characteristic;
    return characteristic;
  }

  static Future<BluetoothCharacteristic> _commandCharacteristicForDevice(
    String deviceId,
  ) async {
    final key = _normalizeDeviceId(deviceId);
    final cached = _commandCharacteristics[key];
    if (cached != null) {
      return cached;
    }

    final device = await connect(deviceId: deviceId);

    final services = await device.discoverServices();
    final service = services
        .where((candidate) => candidate.uuid == _recoilMainServiceUuid)
        .cast<BluetoothService?>()
        .firstWhere((candidate) => candidate != null, orElse: () => null);
    if (service == null) {
      throw StateError('SimpleCoil RECOIL service not found on the gun.');
    }

    final characteristic = service.characteristics
        .where(
          (candidate) => candidate.uuid == _recoilCommandCharacteristicUuid,
        )
        .cast<BluetoothCharacteristic?>()
        .firstWhere((candidate) => candidate != null, orElse: () => null);
    if (characteristic == null) {
      throw StateError('SimpleCoil RECOIL command characteristic not found.');
    }

    final supportsWrite = characteristic.properties.write;
    final supportsWriteNoResponse =
        characteristic.properties.writeWithoutResponse;
    if (!supportsWrite && !supportsWriteNoResponse) {
      throw StateError(
        'SimpleCoil RECOIL command characteristic is not writable.',
      );
    }

    _commandCharacteristics[key] = characteristic;
    return characteristic;
  }

  static int _nextCommandId(String deviceId) {
    final key = _normalizeDeviceId(deviceId);
    final current = _commandIds[key] ?? 0;
    _commandIds[key] = (current + 0x10) & 0xFF;
    return current & 0xFF;
  }

  static Future<void> setPlayerId({
    required String deviceId,
    required int playerId,
  }) async {
    if (playerId < 1 || playerId > 63) {
      throw RangeError.range(playerId, 1, 63, 'playerId');
    }

    final characteristic = await _commandCharacteristicForDevice(deviceId);
    final command = List<int>.filled(20, 0);
    command[0] = _nextCommandId(deviceId);
    command[2] = 0x80;
    command[4] = playerId & 0xFF;

    await _writeCommand(
      deviceId: deviceId,
      characteristic: characteristic,
      data: command,
    );
  }

  static Future<void> reloadAmmo({
    required String deviceId,
    required int playerId,
    int shotCount = 30,
  }) async {
    if (playerId < 1 || playerId > 63) {
      throw RangeError.range(playerId, 1, 63, 'playerId');
    }

    final normalizedShotCount = shotCount.clamp(1, 255);
    final characteristic = await _commandCharacteristicForDevice(deviceId);

    // Stage 1: enter reload status (F0 00 02 00 PLAYER_ID ...)
    final reloadStart = List<int>.filled(20, 0);
    reloadStart[0] = _nextCommandId(deviceId);
    reloadStart[2] = 0x02;
    reloadStart[4] = playerId & 0xFF;
    await _writeCommand(
      deviceId: deviceId,
      characteristic: characteristic,
      data: reloadStart,
    );

    await Future<void>.delayed(const Duration(milliseconds: 120));

    // Stage 2: load shots and allow fire (00 00 04 00 PLAYER_ID 00 SHOTS ...)
    final reloadFinish = List<int>.filled(20, 0);
    reloadFinish[0] = _nextCommandId(deviceId);
    reloadFinish[2] = 0x04;
    reloadFinish[4] = playerId & 0xFF;
    reloadFinish[5] = 0x00;
    reloadFinish[6] = normalizedShotCount;
    await _writeCommand(
      deviceId: deviceId,
      characteristic: characteristic,
      data: reloadFinish,
    );
  }

  static Stream<GunBatteryLevel> watchBatteryLevel({
    required String deviceId,
  }) async* {
    DateTime? lastEmittedAt;
    GunBatteryLevel? lastEmittedLevel;

    await for (final sample in watchTelemetry(deviceId: deviceId)) {
      final level = sample.batteryLevel;
      final now = DateTime.now();

      final shouldEmit =
          lastEmittedAt == null ||
          now.difference(lastEmittedAt) >= const Duration(minutes: 1);

      if (!shouldEmit) {
        continue;
      }

      // Avoid duplicate UI refresh when battery tier did not change.
      if (level == lastEmittedLevel) {
        lastEmittedAt = now;
        continue;
      }

      lastEmittedAt = now;
      lastEmittedLevel = level;
      yield level;
    }
  }

  static Stream<GunTelemetrySample> watchTelemetry({
    required String deviceId,
  }) async* {
    final characteristic = await _telemetryCharacteristicForDevice(deviceId);
    if (!characteristic.isNotifying) {
      await characteristic.setNotifyValue(true);
    }

    yield* characteristic.lastValueStream
        .where((value) => value.length > _recoilTelemetryStatusOffset)
        .map(_parseTelemetrySample);
  }

  static GunTelemetrySample _parseTelemetrySample(List<int> value) {
    final triggerAndReload =
        value[_recoilTelemetryReloadTriggerCounterOffset] & 0xFF;
    final triggerCounter = triggerAndReload & 0x0F;
    final reloadCounter = (triggerAndReload & 0xF0) >> 4;
    final batteryRaw = value[_recoilTelemetryBatteryOffset] & 0xFF;

    return GunTelemetrySample(
      recoilPlayerId: value[_recoilTelemetryTeamOffset] & 0xFF,
      buttons: value[_recoilTelemetryButtonsOffset] & 0xFF,
      triggerCounter: triggerCounter,
      reloadCounter: reloadCounter,
      thumbCounter: value[_recoilTelemetryThumbCounterOffset] & 0xFF,
      powerCounter: value[_recoilTelemetryPowerCounterOffset] & 0xFF,
      batteryRaw: batteryRaw,
      batteryLevel: _batteryLevelFromRaw(batteryRaw),
      hitBy1: value[_recoilTelemetryHitBy1Offset] & 0xFF,
      hitBy1ShotId: value[_recoilTelemetryHitBy1ShotIdOffset] & 0x07,
      hitBy2: value[_recoilTelemetryHitBy2Offset] & 0xFF,
      hitBy2ShotId: value[_recoilTelemetryHitBy2ShotIdOffset] & 0x07,
      shotsRemaining: value[_recoilTelemetryShotsRemainingOffset] & 0xFF,
      status: value[_recoilTelemetryStatusOffset] & 0xFF,
    );
  }

  static GunBatteryLevel _batteryLevelFromRaw(int rawBatteryValue) {
    if (rawBatteryValue >= 14) {
      return GunBatteryLevel.full;
    }
    if (rawBatteryValue >= 11) {
      return GunBatteryLevel.medium;
    }
    if (rawBatteryValue >= 8) {
      return GunBatteryLevel.low;
    }
    return GunBatteryLevel.empty;
  }

  static Future<void> setShotMode({
    required String deviceId,
    required FireMode mode,
    bool useIndoorProfile = false,
  }) async {
    final characteristic = await _configCharacteristicForDevice(deviceId);

    // Mirrors SimpleCoil setShotMode command format:
    // 00 00 09 xx yy ff c8 ff ff 80 02 34 ...
    final config = List<int>.filled(20, 0);
    config[0] = 0x00;
    config[2] = 0x09;
    // Always use pistol profile tuning.
    config[5] = useIndoorProfile
        ? _pistolIndoorFiringModeByte5
        : _pistolOutdoorFiringModeByte5;
    config[6] = _pistolFiringModeByte6;
    config[7] = 0xFF;
    config[8] = 0xFF;
    config[9] = _pistolRecoilStrength;
    config[10] = 0x02;
    config[11] = 0x34;

    switch (mode) {
      case FireMode.single:
        config[3] = 0xFE;
        config[4] = 0x00;
        break;
      case FireMode.burst3:
        config[3] = 0x03;
        config[4] = 0x03;
        break;
      case FireMode.auto:
        config[3] = 0xFE;
        config[4] = 0x01;
        break;
    }

    await _writeConfig(
      deviceId: deviceId,
      characteristic: characteristic,
      data: config,
    );
  }

  static Future<BluetoothDevice> connect({
    required String deviceId,
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final isBluetoothOn =
        await FlutterBluePlus.adapterState.first == BluetoothAdapterState.on;
    if (!isBluetoothOn) {
      throw StateError('Bluetooth is off.');
    }

    final device = deviceFromId(deviceId);
    final key = _normalizeDeviceId(deviceId);
    if (device.isDisconnected) {
      _configCharacteristics.remove(key);
      _telemetryCharacteristics.remove(key);
      _commandCharacteristics.remove(key);
      try {
        await device.connect(timeout: timeout);
      } on Exception {
        if (device.isDisconnected) {
          rethrow;
        }
      }
    }

    return device;
  }

  static Future<void> disconnect({required String deviceId}) async {
    final key = _normalizeDeviceId(deviceId);
    final device = deviceFromId(deviceId);

    _configCharacteristics.remove(key);
    _telemetryCharacteristics.remove(key);
    _commandCharacteristics.remove(key);
    _configWriteLocks.remove(key);
    _commandWriteLocks.remove(key);

    if (device.isDisconnected) {
      return;
    }

    await device.disconnect();
  }

  static Future<void> setRecoilMode({
    required String deviceId,
    required bool enabled,
  }) async {
    final characteristic = await _configCharacteristicForDevice(deviceId);

    final config = List<int>.filled(20, 0);
    config[0] = 0x10;
    config[2] = 0x02;
    config[3] = enabled ? 0x03 : 0x02;
    config[4] = 0xFF;

    await _writeConfig(
      deviceId: deviceId,
      characteristic: characteristic,
      data: config,
    );

    // Some RECOIL units occasionally miss a single config write right after
    // reconnection; repeat enabled command once for reliability.
    if (enabled) {
      await Future<void>.delayed(const Duration(milliseconds: 12));
      await _writeConfig(
        deviceId: deviceId,
        characteristic: characteristic,
        data: config,
      );
    }
  }

  // Re-send recoil enabled command on shot without forcing off->on transitions.
  static Future<void> reinforceRecoilOnShot({required String deviceId}) async {
    final characteristic = await _configCharacteristicForDevice(deviceId);
    final config = List<int>.filled(20, 0);
    config[0] = 0x10;
    config[2] = 0x02;
    config[3] = 0x03;
    config[4] = 0xFF;

    await _writeConfig(
      deviceId: deviceId,
      characteristic: characteristic,
      data: config,
    );
  }

  static Future<void> _writeConfig({
    required String deviceId,
    required BluetoothCharacteristic characteristic,
    required List<int> data,
  }) {
    final supportsWriteNoResponse =
        characteristic.properties.writeWithoutResponse;
    final withoutResponse = supportsWriteNoResponse;

    final queueKey = _normalizeDeviceId(deviceId);
    final previous = _configWriteLocks[queueKey] ?? Future<void>.value();
    final next = previous.then((_) async {
      await characteristic.write(
        data,
        withoutResponse: withoutResponse,
        timeout: 1500,
      );
    });

    _configWriteLocks[queueKey] = next.catchError((_) {});
    return next;
  }

  static Future<void> _writeCommand({
    required String deviceId,
    required BluetoothCharacteristic characteristic,
    required List<int> data,
  }) {
    final supportsWriteNoResponse =
        characteristic.properties.writeWithoutResponse;
    final withoutResponse = supportsWriteNoResponse;

    final queueKey = _normalizeDeviceId(deviceId);
    final previous = _commandWriteLocks[queueKey] ?? Future<void>.value();
    final next = previous.then((_) async {
      await characteristic.write(
        data,
        withoutResponse: withoutResponse,
        timeout: 1500,
      );
    });

    _commandWriteLocks[queueKey] = next.catchError((_) {});
    return next;
  }

  static Future<void> pulseRecoil({required String deviceId}) async {
    final characteristic = await _configCharacteristicForDevice(deviceId);
    final supportsWriteNoResponse =
        characteristic.properties.writeWithoutResponse;
    final withoutResponse = supportsWriteNoResponse;

    // Off command: 10 00 02 02 ff ...
    final recoilOff = List<int>.filled(20, 0);
    recoilOff[0] = 0x10;
    recoilOff[2] = 0x02;
    recoilOff[3] = 0x02;
    recoilOff[4] = 0xFF;

    // On command: 10 00 02 03 ff ...
    final recoilOn = List<int>.filled(20, 0);
    recoilOn[0] = 0x10;
    recoilOn[2] = 0x02;
    recoilOn[3] = 0x03;
    recoilOn[4] = 0xFF;

    await characteristic.write(
      recoilOff,
      withoutResponse: withoutResponse,
      timeout: 1500,
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await characteristic.write(
      recoilOn,
      withoutResponse: withoutResponse,
      timeout: 1500,
    );
  }
}
