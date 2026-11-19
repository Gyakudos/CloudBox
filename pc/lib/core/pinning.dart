// TLS certificate pinning, identical to the Android app's core/pinning.dart.
//
// The agent's certificate is self-signed, so there is no CA to validate against. The desktop
// app reads the pin from the agent's pairing handoff file before it makes its first request,
// then accepts a certificate only when its SPKI digest matches.
//
// Keep this file in sync with app/lib/core/pinning.dart.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Computes the CloudBox pin for a certificate given as DER bytes.
String pinForCertificate(Uint8List certificateDer) {
  final spki = subjectPublicKeyInfo(certificateDer);
  return base64.encode(sha256.convert(spki).bytes);
}

/// Extracts the raw DER of the SubjectPublicKeyInfo from an X.509 certificate.
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
  if (fields.isNotEmpty && fields.first.tag == 0xA0) {
    fields = fields.sublist(1);
  }

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

  Uint8List bytes(Uint8List buffer) => Uint8List.sublistView(buffer, start, end);
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
