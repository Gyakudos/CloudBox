import 'dart:convert';
import 'dart:typed_data';

import 'package:cloudbox/core/pinning.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// A self-signed certificate produced by the agent's own identity code
/// (`identity.LoadOrCreate`), plus the SPKI and pin that code computed for it.
///
/// This is the cross-language check that matters: the phone and the PC must agree, byte for
/// byte, on the SubjectPublicKeyInfo and therefore on the pin. Regenerate with a throwaway
/// `main` that calls `identity.LoadOrCreate` and prints `x509.MarshalPKIXPublicKey` +
/// `identity.PinForCertificate` if the certificate template ever changes.
const _spkiBase64 =
    'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE7asbd/NlTeQfrt0WOZZx+YMAklfO/o0ptd5eHGPEHnsjenYD'
    'FqxCqqM0vsoRgUTHjf90zL0z/CzyFoGcEZ1y6Q==';

const _pin = 'm6OVSTaS98s2advX1taScSo6NXLBbsp7zMwfsZ3/XSU=';

const _derBase64 =
    'MIICHTCCAcSgAwIBAgIQBtV6sTUL36RdG8YaMNXDiDAKBggqhkjOPQQDAjAvMREwDwYDVQQKEwhDbG91ZEJv'
    'eDEaMBgGA1UEAxMRY2xvdWRib3gtZjA3OWM2NWQwHhcNMjYxMTE0MDExOTA1WhcNMzYxMTExMDIxOTA1WjAv'
    'MREwDwYDVQQKEwhDbG91ZEJveDEaMBgGA1UEAxMRY2xvdWRib3gtZjA3OWM2NWQwWTATBgcqhkjOPQIBBggq'
    'hkjOPQMBBwNCAATtqxt382VN5B+u3RY5lnH5gwCSV87+jSm13l4cY8QeeyN6dgMWrEKqozS+yhGBRMeN/3TM'
    'vTP8LPIWgZwRnXLpo4HBMIG+MA4GA1UdDwEB/wQEAwIFoDATBgNVHSUEDDAKBggrBgEFBQcDATAMBgNVHRMB'
    'Af8EAjAAMIGIBgNVHREEgYAwfoIJbG9jYWxob3N0gghjbG91ZGJveIIOY2xvdWRib3gubG9jYWyCD2Nsb3Vk'
    'Ym94LmxvY2FsLocEfwAAAYcQAAAAAAAAAAAAAAAAAAAAAYcQ/XQDPWRQAAGPpbYEEZypJocQ/XQDPWRQAAGx'
    'fHYfyXZlvocEwKgEFYcErB1gATAKBggqhkjOPQQDAgNHADBEAiARhZr28rjXUF/FIw6ORgUpj8UyWzd/x7F8'
    '8XVG9uxD4gIgBSn+ad6j9tLgY7SI0X4nZN4grE++5CeitxH4Bx0YL8g=';

Uint8List _der() => base64.decode(_derBase64);

void main() {
  group('subjectPublicKeyInfo', () {
    test('extracts exactly what the Go agent marshals', () {
      expect(subjectPublicKeyInfo(_der()), base64.decode(_spkiBase64));
    });

    test('returns a DER SEQUENCE', () {
      expect(subjectPublicKeyInfo(_der()).first, 0x30);
    });

    test('rejects bytes that are not a certificate', () {
      expect(
        () => subjectPublicKeyInfo(Uint8List.fromList([0x01, 0x02, 0x03])),
        throwsFormatException,
      );
    });
  });

  group('pinForCertificate', () {
    test('matches the pin computed by the Go agent', () {
      expect(pinForCertificate(_der()), _pin);
    });

    test('is base64 of the SHA-256 of the extracted SPKI', () {
      final expected = base64.encode(sha256.convert(subjectPublicKeyInfo(_der())).bytes);
      expect(pinForCertificate(_der()), expected);
    });

    test('is base64, not hex', () {
      final pin = pinForCertificate(_der());
      expect(pin, endsWith('='));
      expect(base64.decode(pin), hasLength(32)); // SHA-256
    });

    test('ignores the signature, because the pin covers the key', () {
      // Flip a byte in the signature (the tail of the certificate). The public key is
      // untouched, so the pin must not move: that is the whole point of pinning the SPKI.
      final tampered = Uint8List.fromList(_der());
      tampered[tampered.length - 1] ^= 0xFF;
      expect(pinForCertificate(tampered), _pin);
    });
  });
}
