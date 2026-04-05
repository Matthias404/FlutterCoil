import 'dart:convert';

import 'transport.dart';

class JoinCodeCodec {
  static const String _prefix = 'LT1';

  static String encode(PeerEndpoint endpoint) {
    final payload = jsonEncode(<String, dynamic>{
      'host': endpoint.host,
      'port': endpoint.port,
    });
    final encoded = base64Url.encode(utf8.encode(payload)).replaceAll('=', '');
    return <String>[_prefix, _group(encoded)].join('-');
  }

  static PeerEndpoint decode(String code) {
    final compact = code.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
    final normalized = compact.replaceAll('-', '');
    if (!normalized.startsWith(_prefix)) {
      throw const FormatException('Invalid join code prefix.');
    }

    final payloadPart = normalized.substring(_prefix.length);
    if (payloadPart.isEmpty) {
      throw const FormatException('Join code payload is missing.');
    }

    final normalizedBase64 = base64Url.normalize(payloadPart);
    final decoded = utf8.decode(base64Url.decode(normalizedBase64));
    final json = jsonDecode(decoded) as Map<String, dynamic>;
    final host = json['host'] as String?;
    final port = json['port'] as int?;

    if (host == null || host.isEmpty || port == null) {
      throw const FormatException('Join code is missing host or port.');
    }

    return PeerEndpoint(host: host, port: port);
  }

  static String _group(String encoded) {
    final buffer = StringBuffer();
    for (var index = 0; index < encoded.length; index++) {
      if (index > 0 && index % 4 == 0) {
        buffer.write('-');
      }
      buffer.write(encoded[index]);
    }
    return buffer.toString();
  }
}
