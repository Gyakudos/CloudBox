// The HTTPS client the app uses to talk to the PC agent.
//
// Two things make this more than a thin wrapper over HttpClient:
//
//   * Certificate pinning. The agent's certificate is self-signed, so there is no CA to
//     validate against. We accept a certificate only when its SPKI digest equals the pin
//     carried in the pairing code, which is what stops an attacker on the same Wi-Fi from
//     impersonating the PC.
//   * Endpoint failover. The pairing payload lists every address the PC was reachable on at
//     pairing time (LAN IPs, mDNS name, loopback). We try them in order and remember whichever
//     answers, so a laptop that moved between networks keeps working.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'pairing_payload.dart';
import 'pinning.dart';

/// An error with a message written for the person holding the phone.
class CloudBoxException implements Exception {
  CloudBoxException(this.message, {this.code, this.statusCode});

  final String message;
  final String? code;
  final int? statusCode;

  @override
  String toString() => message;
}

/// A client bound to one PC, authenticated with one device token.
class CloudBoxClient {
  CloudBoxClient._(this._http, this._endpoints, this._pin);

  /// Builds a client from a scanned pairing payload. Does not perform any I/O.
  factory CloudBoxClient.forPayload(PairingPayload payload) {
    final http = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..idleTimeout = const Duration(seconds: 30)
      ..userAgent = 'CloudBox';
    final endpoints = payload.endpoints.map(_endpointUri).toList(growable: false);
    final client = CloudBoxClient._(http, endpoints, payload.pin);
    http.badCertificateCallback = client._checkCertificate;
    return client;
  }

  final HttpClient _http;
  final List<Uri> _endpoints;
  final String _pin;

  /// The endpoint that last answered, tried first next time.
  Uri? _preferred;

  /// Set when a peer presents a certificate that does not match the pin.
  bool _pinMismatch = false;

  String? _deviceToken;

  /// The bearer token issued by [pair]. Null until pairing succeeds.
  String? get deviceToken => _deviceToken;

  /// Pairs with the PC using the single-use token from the payload.
  ///
  /// The pairing token is only consumed on success, so a network failure here is safe to retry
  /// (as long as the token has not expired on the PC).
  Future<PairingResult> pair({
    required String pairingToken,
    required String deviceName,
    required String appVersion,
    String platform = 'android',
  }) async {
    final json = await _request('POST', '/v1/pair', body: {
      'token': pairingToken,
      'device_name': deviceName,
      'platform': platform,
      'app_version': appVersion,
    });
    final result = PairingResult.fromJson(json);
    if (result.deviceToken.isEmpty) {
      throw CloudBoxException('The PC did not return a device token.');
    }
    _deviceToken = result.deviceToken;
    return result;
  }

  /// Fetches the PC's identity, version and available folders.
  Future<ServerInfo> info() async {
    final json = await _request('GET', '/v1/system/info', authenticated: true);
    return ServerInfo.fromJson(json);
  }

  /// Lists the drives the PC can write backups to.
  Future<List<CloudBoxDrive>> drives() async {
    final json = await _request('GET', '/v1/system/volumes', authenticated: true);
    final list = (json['volumes'] as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((v) => CloudBoxDrive.fromJson(v.cast<String, dynamic>()))
        .toList(growable: false);
  }

  /// Releases the underlying connection pool.
  void close() => _http.close(force: true);

  // ------------------------------------------------------------------ internals

  bool _checkCertificate(X509Certificate cert, String host, int port) {
    final matches = _matchesPin(cert);
    if (!matches) _pinMismatch = true;
    return matches;
  }

  bool _matchesPin(X509Certificate cert) {
    try {
      return pinForCertificate(cert.der) == _pin;
    } catch (_) {
      // A certificate we cannot parse is a certificate we cannot trust.
      return false;
    }
  }

  /// Tries each endpoint in turn, promoting the first that answers.
  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Object? body,
    bool authenticated = false,
  }) async {
    _pinMismatch = false;

    for (final base in _orderedEndpoints()) {
      try {
        final json = await _requestAt(base, method, path, body: body, authenticated: authenticated);
        _preferred = base;
        return json;
      } on IOException {
        // Transport failure: try the next address the PC advertised.
      } on TimeoutException {
        // Same: a silent address should not stop us reaching a good one.
      }
    }

    if (_pinMismatch) {
      throw CloudBoxException(
        'The PC presented a certificate that does not match the pairing code. '
        'Refusing to connect — someone may be impersonating your PC. Re-pair from the PC to get a fresh code.',
      );
    }
    throw CloudBoxException(
      'Could not reach the PC. Check that the CloudBox agent is running and that this phone is on the same network.',
      code: 'UNREACHABLE',
      statusCode: null,
    );
  }

  Future<Map<String, dynamic>> _requestAt(
    Uri base,
    String method,
    String path, {
    Object? body,
    bool authenticated = false,
  }) async {
    final request = await _http.openUrl(method, base.replace(path: path));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');

    if (authenticated) {
      final token = _deviceToken;
      if (token == null || token.isEmpty) {
        throw CloudBoxException('Not paired yet.');
      }
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }

    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      request.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
      request.headers.contentLength = bytes.length;
      request.add(bytes);
    }

    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();

    final Object? decoded;
    if (text.trim().isEmpty) {
      decoded = null;
    } else {
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        throw CloudBoxException('The PC sent a response this app could not read.');
      }
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (decoded is Map) return decoded.cast<String, dynamic>();
      throw CloudBoxException('The PC sent an unexpected response.');
    }

    var message = 'The PC refused the request (HTTP ${response.statusCode}).';
    String? code;
    if (decoded is Map && decoded['error'] is Map) {
      final error = (decoded['error'] as Map).cast<String, dynamic>();
      code = error['code'] as String?;
      message = error['message'] as String? ?? message;
    }
    if (response.statusCode == 401 && code == 'INVALID_PAIRING_TOKEN') {
      message = 'That pairing code has already been used or has expired. Show a fresh code on the PC.';
    } else if (response.statusCode == 401) {
      message = 'The PC no longer recognises this device. Re-pair to continue.';
    }
    throw CloudBoxException(message, code: code, statusCode: response.statusCode);
  }

  List<Uri> _orderedEndpoints() {
    final preferred = _preferred;
    if (preferred == null) return _endpoints;
    return [preferred, ..._endpoints.where((e) => e != preferred)];
  }
}

/// Parses an agent endpoint (`host:port`, possibly an IPv6 literal) into an HTTPS URI.
Uri _endpointUri(String endpoint) {
  final trimmed = endpoint.trim();
  final separator = trimmed.lastIndexOf(':');
  if (separator <= 0 || separator == trimmed.length - 1) {
    throw CloudBoxException('The pairing code has a malformed address: $endpoint');
  }

  var host = trimmed.substring(0, separator);
  final port = int.tryParse(trimmed.substring(separator + 1));
  if (port == null || port < 1 || port > 65535) {
    throw CloudBoxException('The pairing code has a malformed address: $endpoint');
  }
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }

  return Uri(scheme: 'https', host: host, port: port);
}
