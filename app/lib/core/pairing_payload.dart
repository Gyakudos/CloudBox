// The pairing payload carried by the QR code the PC agent displays.
//
// It is JSON with deliberately short keys, because every byte adds QR modules and makes the
// code harder to scan:
//   { "v":1, "sid":"<server id>", "eps":["<host:port>", ...], "pin":"<base64 spki>", "tok":"..." }

import 'dart:convert';

class PairingPayload {
  PairingPayload({
    required this.version,
    required this.serverId,
    required this.endpoints,
    required this.pin,
    required this.token,
  });

  final int version;
  final String serverId;
  final List<String> endpoints;
  final String pin;
  final String token;

  /// Parses and validates a payload pasted or scanned by the user.
  ///
  /// Throws [FormatException] with a message meant for a person, not a stack trace.
  static PairingPayload parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Paste the pairing code shown on the PC.');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      throw const FormatException('That does not look like a CloudBox pairing code.');
    }

    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Pairing code must be a JSON object.');
    }

    final version = decoded['v'];
    final serverId = decoded['sid'];
    final endpoints = decoded['eps'];
    final pin = decoded['pin'];
    final token = decoded['tok'];

    if (version is! int) {
      throw const FormatException('Pairing code is missing its version.');
    }
    if (version != 1) {
      throw FormatException('Pairing code version $version is not supported by this app.');
    }
    if (serverId is! String || serverId.isEmpty) {
      throw const FormatException('Pairing code is missing the server id.');
    }
    if (endpoints is! List || endpoints.isEmpty || endpoints.any((e) => e is! String)) {
      throw const FormatException('Pairing code has no reachable addresses.');
    }
    if (pin is! String || pin.isEmpty) {
      throw const FormatException('Pairing code is missing the certificate pin.');
    }
    if (token is! String || token.isEmpty) {
      throw const FormatException('Pairing code is missing its pairing token.');
    }

    return PairingPayload(
      version: version,
      serverId: serverId,
      endpoints: endpoints.cast<String>(),
      pin: pin,
      token: token,
    );
  }

  /// Serializes back to the compact JSON form understood by [parse].
  ///
  /// Used when a scanned QR code fills the pairing-code field, so the existing paste/connect
  /// flow can validate and consume exactly the same payload.
  String toJson() => jsonEncode(<String, Object>{
        'v': version,
        'sid': serverId,
        'eps': endpoints,
        'pin': pin,
        'tok': token,
      });
}
