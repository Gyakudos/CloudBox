import 'dart:convert';
import 'dart:io';

import 'package:cloudbox_pc/core/config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cloudbox-pc-config-');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  void writePairing({
    String pin = 'test-pin',
    List<String> endpoints = const ['192.168.1.42:8443', '127.0.0.1:8443'],
  }) {
    File('${dir.path}${Platform.pathSeparator}pairing.json').writeAsStringSync(
      jsonEncode({'pin': pin, 'eps': endpoints, 'tok': 'token', 'v': 1}),
    );
  }

  test('prefers a loopback endpoint from the handoff file', () {
    writePairing();
    final config = readAgentConfig(dataDirectory: dir.path);

    expect(config.endpoint.scheme, 'https');
    expect(config.endpoint.host, '127.0.0.1');
    expect(config.endpoint.port, 8443);
    expect(config.pin, 'test-pin');
  });

  test('understands IPv6 loopback and bracketed endpoints', () {
    writePairing(endpoints: const ['[::1]:9000']);
    final config = readAgentConfig(dataDirectory: dir.path);
    expect(config.endpoint.host, '::1');
    expect(config.endpoint.port, 9000);
  });

  test('falls back to a published address when no loopback is advertised', () {
    writePairing(endpoints: const ['cloudbox.local:8443']);
    final config = readAgentConfig(dataDirectory: dir.path);
    expect(config.endpoint.host, 'cloudbox.local');
  });

  test('reports a missing handoff file as a friendly error', () {
    expect(
      () => readAgentConfig(dataDirectory: dir.path),
      throwsA(isA<ConfigException>().having((e) => e.message, 'message', contains('Start CloudBox'))),
    );
  });

  test('rejects a handoff file without a pin', () {
    File('${dir.path}${Platform.pathSeparator}pairing.json').writeAsStringSync('{"eps":["127.0.0.1:8443"]}');
    expect(
      () => readAgentConfig(dataDirectory: dir.path),
      throwsA(isA<ConfigException>().having((e) => e.message, 'message', contains('certificate pin'))),
    );
  });
}
