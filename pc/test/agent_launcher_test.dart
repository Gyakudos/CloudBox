import 'dart:convert';
import 'dart:io';

import 'package:cloudbox_pc/core/agent_launcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cloudbox-pc-launcher-');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('reuses a live agent instead of starting a second one', () async {
    File('${dir.path}${Platform.pathSeparator}pairing.json').writeAsStringSync(
      jsonEncode({'pin': 'test-pin', 'eps': const ['127.0.0.1:8443'], 'tok': 'token', 'v': 1}),
    );

    var probes = 0;
    final config = await ensureLocalAgent(
      dataDirectory: dir.path,
      probe: (config) async {
        probes++;
        expect(config.pin, 'test-pin');
        return true;
      },
    );

    expect(probes, 1);
    expect(config, isNotNull);
    expect(config!.endpoint.host, '127.0.0.1');
  });
}
