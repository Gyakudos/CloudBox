// HTTPS client for the agent's loopback-only API.
//
// The agent uses a self-signed certificate, so the pin learned from pairing.json is checked on
// every connection. There is no device token here: the /local/* routes are restricted to
// loopback by the agent, which is the right boundary for a UI running on the same machine.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'config.dart';
import 'models.dart';
import 'pinning.dart';

class CloudBoxException implements Exception {
  const CloudBoxException(this.message, {this.code, this.statusCode});

  final String message;
  final String? code;
  final int? statusCode;

  @override
  String toString() => message;
}

/// The operations the PC UI needs from the agent. Abstract so widget tests can use a fake.
abstract class LocalAgentApi {
  Future<LocalState> status();
  Future<LocalState> refreshPairing();
  Future<List<VolumeInfo>> volumes();
  Future<SelectedFolder> setDestination({
    required String volume,
    required String subfolder,
  });

  /// Devices known to the agent, newest first.
  Future<List<PairedDevice>> devices();
  Future<void> revokeDevice(String id);
  Future<PairedDevice> setDeviceBackup({
    required String id,
    required String volume,
    required String subfolder,
    required bool enabled,
  });
  Future<List<BackupStatus>> backups();

  void close();
}

class PinnedLocalAgentApi implements LocalAgentApi {
  PinnedLocalAgentApi(this._config) {
    _http = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..idleTimeout = const Duration(seconds: 30)
      ..userAgent = 'CloudBox-PC';
    _http.badCertificateCallback = (cert, host, port) {
      try {
        final matches = pinForCertificate(cert.der) == _config.pin;
        if (!matches) _pinMismatch = true;
        return matches;
      } catch (_) {
        // A certificate we cannot parse is a certificate we cannot trust.
        _pinMismatch = true;
        return false;
      }
    };
  }

  final AgentConfig _config;
  late final HttpClient _http;
  bool _pinMismatch = false;

  static const _timeout = Duration(seconds: 8);

  @override
  Future<LocalState> status() async {
    return LocalState.fromJson(await _request('GET', '/local/status'));
  }

  @override
  Future<LocalState> refreshPairing() async {
    return LocalState.fromJson(await _request('POST', '/local/pairing/refresh'));
  }

  @override
  Future<List<VolumeInfo>> volumes() async {
    final json = await _request('GET', '/local/volumes');
    final list = json['volumes'] as List? ?? const [];
    return list
        .whereType<Map>()
        .map((v) => VolumeInfo.fromJson(v.cast<String, dynamic>()))
        .toList(growable: false);
  }

  @override
  Future<SelectedFolder> setDestination({
    required String volume,
    required String subfolder,
  }) async {
    final json = await _request('PUT', '/local/destination', body: {
      'volume': volume,
      'subfolder': subfolder,
    });
    final folder = json['folder'];
    if (folder is! Map) {
      throw const CloudBoxException('The agent did not confirm the destination.');
    }
    return SelectedFolder.fromJson(folder.cast<String, dynamic>());
  }

  @override
  Future<List<PairedDevice>> devices() async {
    final json = await _request('GET', '/local/devices');
    final list = json['devices'] as List? ?? const [];
    return list
        .whereType<Map>()
        .map((item) => PairedDevice.fromJson(item.cast<String, dynamic>()))
        .toList(growable: false);
  }

  @override
  Future<void> revokeDevice(String id) async {
    await _request('DELETE', '/local/devices/${Uri.encodeComponent(id)}');
  }

  @override
  Future<PairedDevice> setDeviceBackup({
    required String id,
    required String volume,
    required String subfolder,
    required bool enabled,
  }) async {
    final json = await _request(
      'PUT',
      '/local/devices/${Uri.encodeComponent(id)}/backup',
      body: {
        'volume': volume,
        'subfolder': subfolder,
        'enabled': enabled,
      },
    );
    final device = json['device'];
    if (device is! Map) {
      throw const CloudBoxException('The agent did not confirm the device backup settings.');
    }
    return PairedDevice.fromJson(device.cast<String, dynamic>());
  }

  @override
  Future<List<BackupStatus>> backups() async {
    final json = await _request('GET', '/local/backups');
    final list = json['backups'] as List? ?? const [];
    return list
        .whereType<Map>()
        .map((item) => BackupStatus.fromJson(item.cast<String, dynamic>()))
        .toList(growable: false);
  }

  @override
  void close() => _http.close(force: true);

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Object? body,
  }) async {
    _pinMismatch = false;
    final uri = _config.endpoint.replace(path: path);
    final HttpClientResponse response;

    try {
      final request = await _http.openUrl(method, uri).timeout(_timeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        request.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
        request.headers.contentLength = bytes.length;
        request.add(bytes);
      }
      response = await request.close().timeout(_timeout);
    } on TimeoutException {
      throw const CloudBoxException(
        'The CloudBox agent did not answer in time. Check that it is still running.',
      );
    } on IOException catch (error) {
      if (_pinMismatch) {
        throw const CloudBoxException(
          'The agent presented a certificate that does not match its pairing file. '
          'Restart the agent and try again.',
        );
      }
      throw CloudBoxException(
        'Could not reach the CloudBox agent on this PC. Start it from the Start Menu or '
        'desktop shortcut, then try again. ($error)',
      );
    }

    final text = await response.transform(utf8.decoder).join();
    final Object? decoded;
    if (text.trim().isEmpty) {
      decoded = null;
    } else {
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        throw const CloudBoxException('The agent sent a response this app could not read.');
      }
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (decoded is Map) return decoded.cast<String, dynamic>();
      throw const CloudBoxException('The agent sent an unexpected response.');
    }

    var message = 'The agent refused the request (HTTP ${response.statusCode}).';
    String? code;
    if (decoded is Map) {
      final error = decoded['error'];
      if (error is Map) {
        code = error['code'] as String?;
        message = error['message'] as String? ?? message;
      }
    }
    if (code == 'LOCAL_ONLY') {
      message = 'The agent refused a connection that did not come from this PC.';
    }
    throw CloudBoxException(message, code: code, statusCode: response.statusCode);
  }
}
