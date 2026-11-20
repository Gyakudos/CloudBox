import 'package:cloudbox/core/agent_client.dart';
import 'package:cloudbox/core/models.dart';
import 'package:cloudbox/core/pairing_flow.dart';
import 'package:cloudbox/core/pairing_payload.dart';
import 'package:flutter_test/flutter_test.dart';

PairingOutcome _outcome({
  required String deviceId,
  required List<CloudBoxFolder> folders,
}) {
  final client = CloudBoxClient.forPayload(PairingPayload(
    version: 1,
    serverId: 'server',
    endpoints: const ['127.0.0.1:8443'],
    pin: 'pin',
    token: 'token',
  ));
  addTearDown(client.close);
  return PairingOutcome(
    client: client,
    pairing: PairingResult(
      deviceId: deviceId,
      deviceToken: 'token',
      serverId: 'server',
      serverName: 'PC',
      serverVersion: 'test',
    ),
    info: ServerInfo(
      serverId: 'server',
      serverName: 'PC',
      version: 'test',
      platform: 'windows',
      device: PairedDevice(
        id: deviceId,
        name: 'Pixel',
        platform: 'android',
        appVersion: 'test',
      ),
      folders: folders,
    ),
  );
}

void main() {
  test('uses the per-device backup folder the PC reported', () {
    final outcome = _outcome(deviceId: 'abc', folders: const [
      CloudBoxFolder(id: 'default', name: 'CloudBox', root: 'D:/CloudBox'),
      CloudBoxFolder(id: 'backup-abc', name: 'CloudBox/Pixel', root: 'D:/CloudBox/Pixel'),
    ]);

    expect(outcome.destinationFolder.id, 'backup-abc');
    expect(outcome.destinationFolder.root, 'D:/CloudBox/Pixel');
  });

  test('falls back to the shared default folder on an older agent', () {
    final outcome = _outcome(deviceId: 'abc', folders: const [
      CloudBoxFolder(id: 'default', name: 'CloudBox', root: 'D:/CloudBox'),
    ]);

    expect(outcome.destinationFolder.id, 'default');
  });

  test('has a usable fallback when the agent reports no folders', () {
    final outcome = _outcome(deviceId: 'abc', folders: const []);

    expect(outcome.destinationFolder.id, 'default');
    expect(outcome.destinationFolder.name, 'CloudBox');
  });
}
