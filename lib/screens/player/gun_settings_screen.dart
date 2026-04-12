import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../utils/ble_gun_controller.dart';
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

  late FireMode _selectedFireMode;
  late bool _allowSingleShotMode;
  late bool _allowBurst3ShotMode;
  late bool _allowAutoShotMode;
  late bool _recoilEnabled;

  bool _isScanning = false;
  bool _liveGunConnected = false;
  GunBatteryLevel? _liveBatteryLevel;
  final List<ScanResult> _discoveredDevices = <ScanResult>[];
  StreamSubscription<List<ScanResult>>? _scanResultsSubscription;
  StreamSubscription<bool>? _gunConnectionSub;
  StreamSubscription<GunBatteryLevel>? _batterySub;

  @override
  void initState() {
    super.initState();
    final profile =
        widget.initialProfile ??
        const GunProfile(displayName: 'LaserTag Gun', deviceId: '');
    _nameController = TextEditingController(text: profile.displayName);
    _deviceIdController = TextEditingController(text: profile.deviceId);
    _selectedFireMode = profile.selectedFireMode;
    _allowSingleShotMode = profile.allowSingleShotMode;
    _allowBurst3ShotMode = profile.allowBurst3ShotMode;
    _allowAutoShotMode = profile.allowAutoShotMode;
    _recoilEnabled = profile.recoilEnabled;

    _ensureAtLeastOneModeEnabled();
    _ensureSelectedModeAllowed();
    _startLiveMonitoring();
  }

  @override
  void dispose() {
    _gunConnectionSub?.cancel();
    _batterySub?.cancel();
    _scanResultsSubscription?.cancel();
    _nameController.dispose();
    _deviceIdController.dispose();
    super.dispose();
  }

  Future<void> _startLiveMonitoring() async {
    final deviceId = _deviceIdController.text.trim();
    if (deviceId.isEmpty) {
      return;
    }

    await _gunConnectionSub?.cancel();
    await _batterySub?.cancel();

    final connected = BleGunController.isConnected(deviceId: deviceId);
    if (mounted) {
      setState(() {
        _liveGunConnected = connected;
        if (!connected) {
          _liveBatteryLevel = null;
        }
      });
    }

    _gunConnectionSub = BleGunController.watchConnection(deviceId: deviceId)
        .listen((connectedNow) {
          if (!mounted) {
            return;
          }

          setState(() {
            _liveGunConnected = connectedNow;
            if (!connectedNow) {
              _liveBatteryLevel = null;
            }
          });

          if (connectedNow) {
            unawaited(_startBatteryMonitoring(deviceId));
          }
        });

    if (connected) {
      await _startBatteryMonitoring(deviceId);
    }
  }

  Future<void> _startBatteryMonitoring(String deviceId) async {
    await _batterySub?.cancel();
    _batterySub = BleGunController.watchBatteryLevel(deviceId: deviceId).listen(
      (level) {
        if (!mounted) {
          return;
        }
        setState(() {
          _liveBatteryLevel = level;
        });
      },
      onError: (_) {
        if (!mounted) {
          return;
        }
        setState(() {
          _liveBatteryLevel = null;
        });
      },
    );
  }

  IconData _batteryIconForLevel(GunBatteryLevel? level) {
    switch (level) {
      case GunBatteryLevel.empty:
        return Icons.battery_0_bar;
      case GunBatteryLevel.low:
        return Icons.battery_2_bar;
      case GunBatteryLevel.medium:
        return Icons.battery_5_bar;
      case GunBatteryLevel.full:
        return Icons.battery_full;
      case null:
        return Icons.battery_unknown;
    }
  }

  Color _batteryColorForLevel(GunBatteryLevel? level) {
    switch (level) {
      case GunBatteryLevel.empty:
        return Colors.redAccent;
      case GunBatteryLevel.low:
        return Colors.orangeAccent;
      case GunBatteryLevel.medium:
        return Colors.amber;
      case GunBatteryLevel.full:
        return Colors.lightGreen;
      case null:
        return Colors.blueGrey;
    }
  }

  String _batteryTextForLevel(GunBatteryLevel? level) {
    if (!_liveGunConnected) {
      return 'Disconnected';
    }
    return level?.label ?? 'Reading...';
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

    final isBluetoothOn =
        await FlutterBluePlus.adapterState.first == BluetoothAdapterState.on;
    if (!isBluetoothOn) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enable Bluetooth and try again.')),
      );
      return;
    }

    await _scanResultsSubscription?.cancel();
    setState(() {
      _isScanning = true;
      _discoveredDevices.clear();
    });

    try {
      _scanResultsSubscription = FlutterBluePlus.scanResults.listen((results) {
        if (!mounted) {
          return;
        }

        setState(() {
          _discoveredDevices
            ..clear()
            ..addAll(
              results.where(
                (result) => result.device.platformName.trim().isNotEmpty,
              ),
            );
        });
      });

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));
      await Future<void>.delayed(const Duration(seconds: 5));

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
      if (!mounted) {
        return;
      }

      setState(() => _isScanning = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Scan failed: $e')));
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
    unawaited(_startLiveMonitoring());
  }

  void _setModeAllowed(FireMode mode, bool value) {
    setState(() {
      switch (mode) {
        case FireMode.single:
          _allowSingleShotMode = value;
          break;
        case FireMode.burst3:
          _allowBurst3ShotMode = value;
          break;
        case FireMode.auto:
          _allowAutoShotMode = value;
          break;
      }

      _ensureAtLeastOneModeEnabled();
      _ensureSelectedModeAllowed();
    });
  }

  bool _isModeAllowed(FireMode mode) {
    switch (mode) {
      case FireMode.single:
        return _allowSingleShotMode;
      case FireMode.burst3:
        return _allowBurst3ShotMode;
      case FireMode.auto:
        return _allowAutoShotMode;
    }
  }

  void _ensureAtLeastOneModeEnabled() {
    if (_allowSingleShotMode || _allowBurst3ShotMode || _allowAutoShotMode) {
      return;
    }
    _allowSingleShotMode = true;
  }

  void _ensureSelectedModeAllowed() {
    if (_isModeAllowed(_selectedFireMode)) {
      return;
    }

    if (_allowSingleShotMode) {
      _selectedFireMode = FireMode.single;
      return;
    }
    if (_allowBurst3ShotMode) {
      _selectedFireMode = FireMode.burst3;
      return;
    }
    _selectedFireMode = FireMode.auto;
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

    Navigator.of(context).pop(
      GunProfile(
        displayName: name.isEmpty ? 'LaserTag Gun' : name,
        deviceId: deviceId,
        reloadButton: GunButton.reload,
        shootButton: GunButton.trigger,
        changeFireModeButton: GunButton.thumb,
        selectedFireMode: _selectedFireMode,
        allowSingleShotMode: _allowSingleShotMode,
        allowBurst3ShotMode: _allowBurst3ShotMode,
        allowAutoShotMode: _allowAutoShotMode,
        recoilEnabled: _recoilEnabled,
      ),
    );
  }

  Widget _fixedMappingTile({required String title, required String subtitle}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.check_circle, color: Colors.green),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gun Bluetooth Settings'),
        actions: const <Widget>[
          Padding(
            padding: EdgeInsets.only(right: 12),
            child: Icon(Icons.check_circle, color: Colors.greenAccent),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
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
                        const SizedBox(
                          width: 120,
                          child: ElevatedButton(
                            onPressed: null,
                            child: SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (_discoveredDevices.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: SizedBox(
                        height: 200,
                        child: ListView.builder(
                          itemCount: _discoveredDevices.length,
                          itemBuilder: (context, index) {
                            final device = _discoveredDevices[index];
                            final name = device.device.platformName;
                            return ListTile(
                              title: Text(
                                name.isNotEmpty ? name : 'Unknown Device',
                              ),
                              subtitle: Text(device.device.remoteId.str),
                              onTap: () => _selectDevice(
                                device.device.remoteId.str,
                                name,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Theme.of(context).dividerColor),
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          _batteryIconForLevel(_liveBatteryLevel),
                          color: _batteryColorForLevel(_liveBatteryLevel),
                          size: 22,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Gun Battery: ${_batteryTextForLevel(_liveBatteryLevel)}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        if (!_liveGunConnected)
                          const Text(
                            'Not live',
                            style: TextStyle(fontSize: 12),
                          ),
                      ],
                    ),
                  ),
                  const Text(
                    'Gun Profile',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'Gun Name',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.edit),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _deviceIdController,
                    onChanged: (_) => unawaited(_startLiveMonitoring()),
                    decoration: const InputDecoration(
                      labelText: 'Bluetooth Device ID (MAC Address)',
                      hintText: 'Scanned or entered manually',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.perm_device_information),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'SimpleCoil fixed control layout is active. Controls are locked to the standard mapping.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  _fixedMappingTile(
                    title: 'Trigger -> Shoot',
                    subtitle: 'Trigger always fires the gun.',
                  ),
                  _fixedMappingTile(
                    title: 'Reload Button -> Reload',
                    subtitle: 'Reload button always triggers reload.',
                  ),
                  _fixedMappingTile(
                    title: 'Thumb / Rear Button -> Change Fire Mode',
                    subtitle: 'Thumb/rear button cycles fire mode.',
                  ),
                  _fixedMappingTile(
                    title: 'Power Button -> Toggle Recoil Mode',
                    subtitle: 'Power button switches recoil on or off.',
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'SimpleCoil Fire Modes',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<FireMode>(
                    segments: const <ButtonSegment<FireMode>>[
                      ButtonSegment<FireMode>(
                        value: FireMode.single,
                        label: Text('Single'),
                      ),
                      ButtonSegment<FireMode>(
                        value: FireMode.burst3,
                        label: Text('Burst 3'),
                      ),
                      ButtonSegment<FireMode>(
                        value: FireMode.auto,
                        label: Text('Auto'),
                      ),
                    ],
                    selected: <FireMode>{_selectedFireMode},
                    onSelectionChanged: (newSelection) {
                      final mode = newSelection.first;
                      if (!_isModeAllowed(mode)) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              '${mode.label} is disabled in allowed modes.',
                            ),
                          ),
                        );
                        return;
                      }
                      setState(() => _selectedFireMode = mode);
                    },
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    value: _allowSingleShotMode,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Allow Single'),
                    subtitle: const Text('SimpleCoil allowShotModeSingle'),
                    onChanged: (value) =>
                        _setModeAllowed(FireMode.single, value ?? false),
                  ),
                  CheckboxListTile(
                    value: _allowBurst3ShotMode,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Allow Burst 3'),
                    subtitle: const Text('SimpleCoil allowShotModeBurst3'),
                    onChanged: (value) =>
                        _setModeAllowed(FireMode.burst3, value ?? false),
                  ),
                  CheckboxListTile(
                    value: _allowAutoShotMode,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Allow Auto'),
                    subtitle: const Text('SimpleCoil allowShotModeAuto'),
                    onChanged: (value) =>
                        _setModeAllowed(FireMode.auto, value ?? false),
                  ),
                  const SizedBox(height: 8),
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
                    onChanged: (value) =>
                        setState(() => _recoilEnabled = value),
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
