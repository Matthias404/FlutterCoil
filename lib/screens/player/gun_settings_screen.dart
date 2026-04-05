import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../utils/gun_profile_storage.dart';

class GunSettingsScreen extends StatefulWidget {
  const GunSettingsScreen({super.key, this.initialProfile});

  final GunProfile? initialProfile;

  @override
  State<GunSettingsScreen> createState() => _GunSettingsScreenState();
}

class _GunSettingsScreenState extends State<GunSettingsScreen> {
  late final TextEditingController _nameController;
  late final TextEditingController _deviceIdController;
  late final TextEditingController _ammoController;
  late final TextEditingController _healthController;
  late final TextEditingController _damageMultController;

  late FireMode _selectedFireMode;
  late bool _recoilEnabled;
  bool _isScanning = false;
  final List<ScanResult> _discoveredDevices = [];

  @override
  void initState() {
    super.initState();
    final profile =
        widget.initialProfile ??
        const GunProfile(displayName: 'LaserTag Gun', deviceId: '');
    _nameController = TextEditingController(text: profile.displayName);
    _deviceIdController = TextEditingController(text: profile.deviceId);
    _ammoController = TextEditingController(text: '${profile.ammo}');
    _healthController = TextEditingController(text: '${profile.health}');
    _damageMultController = TextEditingController(
      text: '${profile.damageMult}',
    );
    _selectedFireMode = profile.fireMode;
    _recoilEnabled = profile.recoilEnabled;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _deviceIdController.dispose();
    _ammoController.dispose();
    _healthController.dispose();
    _damageMultController.dispose();
    super.dispose();
  }

  Future<bool> _requestBlePermissions() async {
    if (Platform.isAndroid) {
      final statuses = await <Permission>[
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();

      return statuses.values.every((status) => status.isGranted);
    }

    if (Platform.isIOS) {
      final statuses = await <Permission>[
        Permission.bluetooth,
        Permission.locationWhenInUse,
      ].request();

      return statuses.values.every((status) => status.isGranted);
    }

    final statuses = await <Permission>[
      Permission.bluetooth,
      Permission.locationWhenInUse,
    ].request();
    return statuses.values.every((status) => status.isGranted);
  }

  Future<void> _startBLEScan() async {
    final hasPermissions = await _requestBlePermissions();
    if (!hasPermissions) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Bluetooth and location permissions are required.'),
        ),
      );
      return;
    }

    // Check if Bluetooth is enabled (like SimpleCoil: BluetoothAdapter.isEnabled())
    final isBluetoothOn = await FlutterBluePlus.isOn;
    if (!isBluetoothOn) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enable Bluetooth and try again.')),
      );
      return;
    }

    setState(() {
      _isScanning = true;
      _discoveredDevices.clear();
    });

    try {
      // Start scanning (like SimpleCoil: BluetoothLeScanner.startScan)
      FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));

      // Listen to scan results (like SimpleCoil: ScanCallback.onScanResult)
      FlutterBluePlus.scanResults.listen((results) {
        if (mounted) {
          setState(() {
            _discoveredDevices.clear();
            // Filter devices with readable names (like SimpleCoil filters for "SRG1")
            for (final result in results) {
              if (result.device.name.isNotEmpty) {
                _discoveredDevices.add(result);
              }
            }
          });
        }
      });

      // Wait for scan to complete
      await Future.delayed(const Duration(seconds: 5));

      if (mounted) {
        setState(() => _isScanning = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Scan complete. Found ${_discoveredDevices.length} device(s).',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isScanning = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Scan failed: $e')));
      }
    }
  }

  void _selectDevice(String deviceAddress, String deviceName) {
    _deviceIdController.text = deviceAddress;
    if (_nameController.text.isEmpty ||
        _nameController.text == 'LaserTag Gun') {
      _nameController.text = deviceName.isNotEmpty
          ? deviceName
          : 'LaserTag Gun';
    }
  }

  void _saveAndClose() {
    final name = _nameController.text.trim();
    final deviceId = _deviceIdController.text.trim();
    if (deviceId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a Bluetooth device ID.')),
      );
      return;
    }

    int ammo = 120;
    int health = 100;
    double damageMult = 1.0;
    try {
      ammo = int.parse(_ammoController.text);
      health = int.parse(_healthController.text);
      damageMult = double.parse(_damageMultController.text);
    } catch (_) {
      // Use defaults
    }

    Navigator.of(context).pop(
      GunProfile(
        displayName: name.isEmpty ? 'LaserTag Gun' : name,
        deviceId: deviceId,
        ammo: ammo,
        health: health,
        fireMode: _selectedFireMode,
        damageMult: damageMult,
        recoilEnabled: _recoilEnabled,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Gun Bluetooth Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          // Device Scanner Section (like SimpleCoil's weapon connect UI)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      const Text(
                        'Nearby Bluetooth Devices',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      if (!_isScanning)
                        ElevatedButton.icon(
                          onPressed: _startBLEScan,
                          icon: const Icon(Icons.search, size: 16),
                          label: const Text('Scan'),
                        )
                      else
                        SizedBox(
                          width: 120,
                          child: ElevatedButton.icon(
                            onPressed: null,
                            icon: const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            label: const Text('Scanning...'),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_isScanning)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_discoveredDevices.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'No devices found. Make sure your gun is powered on and Bluetooth is enabled.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                    )
                  else
                    ...List.generate(_discoveredDevices.length, (i) {
                      final device = _discoveredDevices[i].device;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: OutlinedButton.icon(
                          onPressed: () => _selectDevice(
                            device.remoteId.toString(),
                            device.name,
                          ),
                          icon: const Icon(Icons.devices, size: 18),
                          label: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                device.name.isEmpty
                                    ? 'Unknown Device'
                                    : device.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              Text(
                                device.remoteId.toString(),
                                style: const TextStyle(fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Gun Identity
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Gun Name',
              hintText: 'e.g. Red Team Blaster',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.label),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _deviceIdController,
            decoration: const InputDecoration(
              labelText: 'Bluetooth Device ID (MAC Address)',
              hintText: 'Scanned or entered manually',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.perm_device_information),
            ),
          ),
          const SizedBox(height: 16),

          // Gun Settings
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text(
                    'Gun Configuration',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          controller: _ammoController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Ammo',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.grain),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _healthController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Health',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.favorite),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          controller: _damageMultController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Damage Multiplier',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.bolt),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Fire Mode',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: SegmentedButton<FireMode>(
                          segments: const <ButtonSegment<FireMode>>[
                            ButtonSegment<FireMode>(
                              value: FireMode.single,
                              label: Text('Single'),
                            ),
                            ButtonSegment<FireMode>(
                              value: FireMode.burst,
                              label: Text('Burst'),
                            ),
                            ButtonSegment<FireMode>(
                              value: FireMode.auto,
                              label: Text('Auto'),
                            ),
                          ],
                          selected: <FireMode>{_selectedFireMode},
                          onSelectionChanged: (Set<FireMode> newSelection) {
                            setState(
                              () => _selectedFireMode = newSelection.first,
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    value: _recoilEnabled,
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.sports_motorsports),
                    title: const Text('Recoil Mode'),
                    subtitle: Text(
                      _recoilEnabled
                          ? 'Enabled (gun kickback on shot)'
                          : 'Disabled (no kickback)',
                    ),
                    onChanged: (value) {
                      setState(() {
                        _recoilEnabled = value;
                      });
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _saveAndClose,
            icon: const Icon(Icons.save),
            label: const Text('Save Gun Profile'),
          ),
        ],
      ),
    );
  }
}
