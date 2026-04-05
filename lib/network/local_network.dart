import 'dart:io';

Future<String?> getLocalIpAddress() async {
  try {
    final interfaces = await NetworkInterface.list();
    for (final interface in interfaces) {
      for (final addr in interface.addresses) {
        if (addr.type == InternetAddressType.IPv4 &&
            !addr.address.startsWith('127.') &&
            !addr.address.startsWith('169.254')) {
          return addr.address;
        }
      }
    }
  } catch (_) {
    return null;
  }
  return null;
}
