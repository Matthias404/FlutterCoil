import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class BleGunController {
  BleGunController._();

  // SimpleCoil / RECOIL UUIDs.
  static final Guid _recoilMainServiceUuid = Guid(
    'e6f59d10-8230-4a5c-b22f-c062b1d329e3',
  );
  static final Guid _recoilConfigCharacteristicUuid = Guid(
    'e6f59d14-8230-4a5c-b22f-c062b1d329e3',
  );

  static Future<void> setRecoilMode({
    required String deviceId,
    required bool enabled,
  }) async {
    final normalizedDeviceId = deviceId.trim();
    if (normalizedDeviceId.isEmpty) {
      throw const FormatException('Bluetooth device id is empty.');
    }

    final isBluetoothOn = await FlutterBluePlus.isOn;
    if (!isBluetoothOn) {
      throw StateError('Bluetooth is off.');
    }

    final device = BluetoothDevice.fromId(normalizedDeviceId);

    try {
      await device.connect(timeout: const Duration(seconds: 6));
    } on Exception {
      // Already connected or connect failed; discovery below determines if usable.
    }

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

    final config = List<int>.filled(20, 0);
    config[0] = 0x10;
    config[2] = 0x02;
    config[3] = enabled ? 0x03 : 0x02;
    config[4] = 0xFF;

    await characteristic.write(
      config,
      withoutResponse: supportsWriteNoResponse && !supportsWrite,
      timeout: 1500,
    );
  }
}
