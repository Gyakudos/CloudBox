import 'dart:convert';
import 'dart:typed_data';

import 'package:cloudbox_pc/core/pinning.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

// The same agent-generated certificate fixture the Android app uses. The desktop client must
// derive exactly the same pin from it, or it would refuse its own PC.
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
  test('extracts the SPKI exactly as the Go agent marshals it', () {
    expect(subjectPublicKeyInfo(_der()), base64.decode(_spkiBase64));
  });

  test('matches the pin computed by the Go agent', () {
    expect(pinForCertificate(_der()), _pin);
  });

  test('is base64 of the SHA-256 of the SPKI', () {
    final expected = base64.encode(sha256.convert(subjectPublicKeyInfo(_der())).bytes);
    expect(pinForCertificate(_der()), expected);
    expect(base64.decode(pinForCertificate(_der())), hasLength(32));
  });

  test('rejects bytes that are not a certificate', () {
    expect(() => subjectPublicKeyInfo(Uint8List.fromList([1, 2, 3])), throwsFormatException);
  });
}
