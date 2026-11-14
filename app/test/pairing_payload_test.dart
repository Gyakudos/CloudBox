import 'dart:convert';

import 'package:cloudbox/core/pairing_payload.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object> _valid() => {
      'v': 1,
      'sid': 'a1b2c3d4e5f60718293a4b5c6d7e8f90',
      'eps': ['192.168.1.10:8443', 'cloudbox.local:8443'],
      'pin': '+xWJJ4AyPn1dphMfwaGTfwy/D4LDxej850RQP01Aueo=',
      'tok': 'single-use-token',
    };

void main() {
  group('PairingPayload.parse', () {
    test('parses a well-formed payload', () {
      final payload = PairingPayload.parse(jsonEncode(_valid()));
      expect(payload.version, 1);
      expect(payload.serverId, 'a1b2c3d4e5f60718293a4b5c6d7e8f90');
      expect(payload.endpoints, ['192.168.1.10:8443', 'cloudbox.local:8443']);
      expect(payload.pin, startsWith('+xWJJ'));
      expect(payload.token, 'single-use-token');
    });

    test('tolerates surrounding whitespace', () {
      final payload = PairingPayload.parse('  \n${jsonEncode(_valid())}\n  ');
      expect(payload.token, 'single-use-token');
    });

    test('rejects an empty string', () {
      expect(() => PairingPayload.parse('   '), throwsFormatException);
    });

    test('rejects non-JSON', () {
      expect(() => PairingPayload.parse('not a pairing code'), throwsFormatException);
    });

    test('rejects a JSON array', () {
      expect(() => PairingPayload.parse('[]'), throwsFormatException);
    });

    test('rejects an unsupported version', () {
      final payload = _valid()..['v'] = 2;
      expect(() => PairingPayload.parse(jsonEncode(payload)), throwsFormatException);
    });

    for (final key in ['sid', 'eps', 'pin', 'tok']) {
      test('rejects a payload missing "$key"', () {
        final payload = _valid()..remove(key);
        expect(() => PairingPayload.parse(jsonEncode(payload)), throwsFormatException);
      });
    }

    test('rejects an empty endpoint list', () {
      final payload = _valid()..['eps'] = <String>[];
      expect(() => PairingPayload.parse(jsonEncode(payload)), throwsFormatException);
    });
  });
}
