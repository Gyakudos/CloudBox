// TLS certificate pinning.
//
// The PC agent uses a self-signed certificate, so there is no CA to trust. Instead the phone
// learns the certificate's public key digest out-of-band, from the pairing QR code, and refuses
// any connection whose certificate does not match. This is what makes pairing safe on a LAN.
//
// The pin is the base64 SHA-256 digest of the certificate's SubjectPublicKeyInfo (SPKI), which
// is exactly what the agent computes in internal/identity. Dart's X509Certificate exposes only
// the full DER, so we walk the ASN.1 to pull the SPKI out before hashing it.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Computes the CloudBox pin for a certificate given as DER bytes.
String pinForCertificate(Uint8List certificateDer) {
  final spki = subjectPublicKeyInfo(certificateDer);
  return base64.encode(sha256.convert(spki).bytes);
}

/// Extracts the raw DER of the SubjectPublicKeyInfo from an X.509 certificate.
///
/// Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
/// TBSCertificate ::= SEQUENCE { [0] version, serialNumber, signature, issuer, validity,
///                               subject, subjectPublicKeyInfo, ... }
Uint8List subjectPublicKeyInfo(Uint8List certificateDer) {
  final certificate = _readTlv(certificateDer, 0);
  if (certificate.tag != _sequence) {
    throw const FormatException('not a DER SEQUENCE: not an X.509 certificate');
  }

  final certificateChildren = _children(certificateDer, certificate);
  if (certificateChildren.isEmpty) {
    throw const FormatException('certificate has no tbsCertificate');
  }

  final tbs = certificateChildren.first;
  if (tbs.tag != _sequence) {
    throw const FormatException('tbsCertificate is not a SEQUENCE');
  }

  var fields = _children(certificateDer, tbs);

  // Version is optional and, when present, is a context-specific [0] wrapper.
  if (fields.isNotEmpty && fields.first.tag == 0xA0) {
    fields = fields.sublist(1);
  }

  // serialNumber, signature, issuer, validity, subject, subjectPublicKeyInfo
  const spkiIndex = 5;
  if (fields.length <= spkiIndex) {
    throw const FormatException('certificate is missing the subjectPublicKeyInfo');
  }
  return fields[spkiIndex].bytes(certificateDer);
}

const int _sequence = 0x30;

class _Tlv {
  _Tlv(this.tag, this.start, this.contentStart, this.end);

  final int tag;
  final int start;
  final int contentStart;
  final int end;

  /// The complete TLV, tag and length included, which is what gets hashed.
  Uint8List bytes(Uint8List buffer) =>
      Uint8List.sublistView(buffer, start, end);
}

_Tlv _readTlv(Uint8List buffer, int position) {
  if (position + 2 > buffer.length) {
    throw FormatException('DER: truncated at $position');
  }

  final tag = buffer[position];
  var cursor = position + 1;
  var length = buffer[cursor++];

  if (length & 0x80 != 0) {
    final lengthBytes = length & 0x7F;
    if (lengthBytes == 0 || lengthBytes > 4) {
      throw const FormatException('DER: unsupported length encoding');
    }
    length = 0;
    for (var i = 0; i < lengthBytes; i++) {
      if (cursor >= buffer.length) {
        throw const FormatException('DER: truncated length');
      }
      length = (length << 8) | buffer[cursor++];
    }
  }

  final contentStart = cursor;
  final end = contentStart + length;
  if (end > buffer.length) {
    throw const FormatException('DER: element overruns the buffer');
  }
  return _Tlv(tag, position, contentStart, end);
}

List<_Tlv> _children(Uint8List buffer, _Tlv parent) {
  final children = <_Tlv>[];
  var cursor = parent.contentStart;
  while (cursor < parent.end) {
    final child = _readTlv(buffer, cursor);
    children.add(child);
    cursor = child.end;
  }
  return children;
}
