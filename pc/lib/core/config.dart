// Finds the running agent without asking the user to type an address.
//
// The agent writes pairing.json into its data directory on every start and every code refresh.
// That file carries the certificate pin and the list of addresses the PC is reachable on. The
// desktop app only needs one thing from it: the loopback address and the pin, because this app
// always talks to the agent on the same machine.

import 'dart:convert';
import 'dart:io';

class AgentConfig {
  const AgentConfig({
    required this.endpoint,
    required this.pin,
    required this.dataDirectory,
  });

  /// The HTTPS base URI of the local agent, e.g. https://127.0.0.1:8443.
  final Uri endpoint;

  /// base64 SHA-256 SPKI digest of the agent's self-signed certificate.
  final String pin;

  final String dataDirectory;
}

/// Windows: %APPDATA%\CloudBox (the same directory the Go agent's defaultDataDir uses).
/// Other platforms are only useful for tests and development.
String defaultDataDirectory() {
  for (final key in ['APPDATA', 'LOCALAPPDATA', 'HOME']) {
    final base = Platform.environment[key];
    if (base != null && base.isNotEmpty) {
      return _join(base, 'CloudBox');
    }
  }
  return _join(Directory.current.path, '.cloudbox');
}

String _join(String base, String child) {
  final left = base.replaceAll(RegExp(r'[\\/]+$'), '');
  final right = child.replaceAll(RegExp(r'^[\\/]+'), '');
  return '$left${Platform.pathSeparator}$right';
}

/// Reads the handshake file and returns the loopback endpoint plus pin.
///
/// [dataDirectory] is injectable so tests can use a temporary directory.
AgentConfig readAgentConfig({String? dataDirectory}) {
  final dir = dataDirectory ?? defaultDataDirectory();
  final file = File(_join(dir, 'pairing.json'));
  if (!file.existsSync()) {
    throw const ConfigException(
      'No CloudBox agent found on this PC. Start CloudBox from the Start Menu or the desktop shortcut, then try again.',
    );
  }

  final Map<String, dynamic> json;
  try {
    json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  } on FormatException {
    throw const ConfigException('The agent\'s pairing file is unreadable. Restart CloudBox to create a fresh one.');
  } on IOException catch (error) {
    throw ConfigException('Could not read the agent\'s pairing file: $error');
  }

  final pin = json['pin'] as String? ?? '';
  if (pin.isEmpty) {
    throw const ConfigException('The agent did not publish a certificate pin. Restart CloudBox and try again.');
  }

  final rawEndpoints = json['eps'];
  if (rawEndpoints is! List) {
    throw const ConfigException('The agent did not publish any addresses. Restart CloudBox and try again.');
  }
  final endpoints = rawEndpoints.whereType<String>().toList();

  for (final value in endpoints) {
    final uri = _parseEndpoint(value);
    if (uri != null && _isLoopback(uri.host)) {
      return AgentConfig(endpoint: uri, pin: pin, dataDirectory: dir);
    }
  }

  // An agent bound to a non-default address may not advertise loopback at all, but it is still
  // on this machine: fall back to whatever address it did publish, preferring localhost names.
  for (final value in endpoints) {
    final uri = _parseEndpoint(value);
    if (uri != null) {
      return AgentConfig(endpoint: uri, pin: pin, dataDirectory: dir);
    }
  }
  throw const ConfigException('The agent published no usable address. Restart CloudBox and try again.');
}

bool _isLoopback(String host) {
  final lower = host.toLowerCase();
  return lower == 'localhost' || lower == '127.0.0.1' || lower == '::1' || lower == 'ip6-localhost';
}

Uri? _parseEndpoint(String value) {
  final trimmed = value.trim();
  final separator = trimmed.lastIndexOf(':');
  if (separator <= 0 || separator == trimmed.length - 1) return null;

  var host = trimmed.substring(0, separator);
  final port = int.tryParse(trimmed.substring(separator + 1));
  if (port == null || port < 1 || port > 65535) return null;
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.substring(1, host.length - 1);
  }
  return Uri(scheme: 'https', host: host, port: port);
}

class ConfigException implements Exception {
  const ConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}
