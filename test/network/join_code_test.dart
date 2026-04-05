import 'package:flutter_test/flutter_test.dart';
import 'package:lasertag_app/network/join_code.dart';
import 'package:lasertag_app/network/transport.dart';

void main() {
  group('JoinCodeCodec', () {
    test('encodes and decodes a peer endpoint', () {
      const endpoint = PeerEndpoint(host: '192.168.1.25', port: 7777);

      final code = JoinCodeCodec.encode(endpoint);
      final decoded = JoinCodeCodec.decode(code);

      expect(code.startsWith('LT1-'), isTrue);
      expect(decoded, endpoint);
    });

    test('rejects invalid join code prefix', () {
      expect(
        () => JoinCodeCodec.decode('BAD-CODE'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
