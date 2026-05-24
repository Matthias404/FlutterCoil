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
  late final TextEditingController _deviceIdController;
  String _selectedDeviceName = 'LaserTag Gun';
  String _statusMessage = '';

  bool _isScanning = false;
  bool _isConnecting = false;
  bool _isDisconnecting = false;
  bool _liveGunConnected = false;
  bool _showGunDisconnectedOverlay = false;
  GunBatteryLevel? _liveBatteryLevel;
  final List<ScanResult> _discoveredDevices = <ScanResult>[];
  StreamSubscription<List<ScanResult>>? _scanResultsSubscription;
  StreamSubscription<bool>? _connectionSubscription;

  @override
  void initState() {
    super.initState();
    final profile =
        widget.initialProfile ??
        const GunProfile(displayName: 'LaserTag Gun', deviceId: '');
    _deviceIdController = TextEditingController(text: profile.deviceId);
    _selectedDeviceName = profile.displayName;
    final initialDeviceId = profile.deviceId.trim();
    if (initialDeviceId.isNotEmpty) {
      _liveGunConnected = BleGunController.isConnected(deviceId: initialDeviceId);
      _showGunDisconnectedOverlay = !_liveGunConnected;
      unawaited(_startConnectionMonitoring(initialDeviceId));
    }
  }

  @override
  void dispose() {
    _scanResultsSubscription?.cancel();
    _connectionSubscription?.cancel();
    _deviceIdController.dispose();
    super.dispose();
  }

  Future<void> _startConnectionMonitoring(String deviceId) async {
    await _connectionSubscription?.cancel();
    _connectionSubscription = BleGunController.watchConnection(
      deviceId: deviceId,
    ).listen((connected) {
      if (!mounted) {
        return;
      }

      setState(() {
        _liveGunConnected = connected;
        if (connected) {
          _showGunDisconnectedOverlay = false;
          _statusMessage = 'Gun connected.';
        } else if (_deviceIdController.text.trim().isNotEmpty) {
          _showGunDisconnectedOverlay = true;
          _liveBatteryLevel = null;
          _statusMessage = 'Gun disconnected.';
        }
      });
    });
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
      if (mounted) {
        setState(() {
          _statusMessage = 'Bluetooth and location permissions are required.';
        });
      }
      return;
    }

    bool isBluetoothOn;
    try {
      isBluetoothOn =
          await FlutterBluePlus.adapterState.first == BluetoothAdapterState.on;
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusMessage = 'Could not access Bluetooth state: $e';
      });
      return;
    }
    if (!isBluetoothOn) {
      if (mounted) {
        setState(() {
          _statusMessage = 'Please enable Bluetooth and try again.';
        });
      }
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
        setState(() {
          _isScanning = false;
          _statusMessage =
              'Scan complete. Found ${_discoveredDevices.length} device(s).';
        });
      }
    } catch (e) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isScanning = false;
        _statusMessage = 'Scan failed: $e';
      });
    }
  }

  void _selectDevice(String deviceAddress, String deviceName) {
    setState(() {
      _deviceIdController.text = deviceAddress;
      _selectedDeviceName = deviceName.isNotEmpty
          ? deviceName
          : 'LaserTag Gun';
      _liveGunConnected = BleGunController.isConnected(deviceId: deviceAddress);
      _liveBatteryLevel = null;
      _showGunDisconnectedOverlay = !_liveGunConnected;
    });
    unawaited(_startConnectionMonitoring(deviceAddress));
  }

  Future<void> _connectSelectedGun() async {
    final deviceId = _deviceIdController.text.trim();
    if (deviceId.isEmpty) {
      if (mounted) {
        setState(() {
          _statusMessage = 'Please select a gun from scan results.';
        });
      }
      return;
    }

    setState(() {
      _isConnecting = true;
    });

    try {
      await BleGunController.connect(deviceId: deviceId);
      if (!mounted) {
        return;
      }

      Navigator.of(context).pop(
        GunProfile(displayName: _selectedDeviceName, deviceId: deviceId),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusMessage = 'Connection failed: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isConnecting = false;
        });
      }
    }
  }

  Future<void> _disconnectSelectedGun() async {
    final deviceId = _deviceIdController.text.trim();
    if (deviceId.isEmpty) {
      if (mounted) {
        setState(() {
          _statusMessage = 'No selected gun to disconnect.';
        });
      }
      return;
    }

    setState(() {
      _isDisconnecting = true;
    });

    try {
      await BleGunController.disconnect(deviceId: deviceId);
      if (!mounted) {
        return;
      }
      setState(() {
        _liveGunConnected = false;
        _liveBatteryLevel = null;
        _showGunDisconnectedOverlay = true;
        _statusMessage = 'Gun disconnected.';
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusMessage = 'Disconnect failed: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isDisconnecting = false;
        });
      }
    }
  }

  Widget _buildGunDisconnectedOverlay(ButtonStyle searchButtonStyle) {
    final deviceId = _deviceIdController.text.trim();
    if (!_showGunDisconnectedOverlay || deviceId.isEmpty) {
      return const SizedBox.shrink();
    }

    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.68),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Material(
                color: Colors.red.shade900.withValues(alpha: 0.94),
                borderRadius: BorderRadius.circular(18),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: Colors.amberAccent,
                        size: 40,
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Gun disconnected',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '$_selectedDeviceName is offline. Reconnect the gun or search for another gun.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 18),
                      FilledButton.icon(
                        onPressed: _isConnecting ? null : _connectSelectedGun,
                        icon: const Icon(Icons.bluetooth_connected),
                        label: const Text('Reconnect Gun'),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        style: searchButtonStyle,
                        onPressed: () {
                          setState(() {
                            _showGunDisconnectedOverlay = false;
                          });
                          unawaited(_startBLEScan());
                        },
                        icon: const Icon(Icons.search),
                        label: const Text('Search Gun'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final overlaySearchButtonStyle = OutlinedButton.styleFrom(
      foregroundColor: Colors.white,
      side: const BorderSide(color: Colors.white54),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Gun Connection'),
      ),
      body: Stack(
        children: <Widget>[
          ListView(
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
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
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
                      if (_discoveredDevices.isEmpty && !_isScanning)
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: Text(
                            'No devices yet. Tap Scan to search for guns.',
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
                      const Text(
                        'Selected Gun',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 12),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.bluetooth_connected),
                        title: Text(_selectedDeviceName),
                        subtitle: Text(
                          _deviceIdController.text.trim().isEmpty
                              ? 'No device selected'
                              : _deviceIdController.text.trim(),
                        ),
                      ),
                      const SizedBox(height: 8),
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
                          border: Border.all(
                            color: Theme.of(context).dividerColor,
                          ),
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
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
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
                      FilledButton.icon(
                        onPressed: _isConnecting ? null : _connectSelectedGun,
                        icon: _isConnecting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.bluetooth_connected),
                        label: Text(
                          _isConnecting
                              ? 'Connecting...'
                              : 'Connect Selected Gun',
                        ),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: _isDisconnecting
                            ? null
                            : _disconnectSelectedGun,
                        icon: _isDisconnecting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.bluetooth_disabled),
                        label: Text(
                          _isDisconnecting
                              ? 'Disconnecting...'
                              : 'Disconnect Gun',
                        ),
                      ),
                      if (_statusMessage.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(
                            _statusMessage,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          _buildGunDisconnectedOverlay(overlaySearchButtonStyle),
        ],
      ),
    );
  }
}
