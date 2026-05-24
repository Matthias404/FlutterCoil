import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../theme/team_colors.dart';

final Map<String, String> _runtimeDeviceIdsByPrefix = <String, String>{};

String deviceId(String prefix) {
  return _runtimeDeviceIdsByPrefix.putIfAbsent(
    prefix,
    () => '$prefix-${DateTime.now().microsecondsSinceEpoch}',
  );
}

Future<bool> ensureMicrophonePermission() async {
  final status = await Permission.microphone.request();
  return status.isGranted;
}

String buildNetworkHintForHost(String host) {
  final normalized = host.trim().toLowerCase();
  if (normalized.isEmpty) {
    return 'Host is empty in this code.';
  }

  if (normalized == 'localhost') {
    return 'This code points to localhost and only works on the same device.';
  }

  final parsed = Uri.tryParse('http://$normalized')?.host ?? normalized;
  final parts = parsed.split('.');
  if (parts.length == 4) {
    final octets = parts.map(int.tryParse).toList();
    final isIpv4 = octets.every(
      (value) => value != null && value >= 0 && value <= 255,
    );
    if (isIpv4) {
      final first = octets[0]!;
      final second = octets[1]!;
      final isPrivate =
          first == 10 ||
          first == 127 ||
          (first == 172 && second >= 16 && second <= 31) ||
          (first == 192 && second == 168) ||
          (first == 169 && second == 254);
      if (isPrivate) {
        return 'LAN game detected: you must be on the same local network as the server.';
      }
      return 'Online host detected: this can work over the internet if server port forwarding is configured.';
    }
  }

  // Domain names and non-private hosts are treated as online targets.
  return 'Online host detected: this can work over the internet if server port forwarding is configured.';
}

List<Color> teamBackgroundColors(
  String team, {
  Brightness brightness = Brightness.dark,
}) {
  return teamPaletteFor(team).background(brightness);
}
