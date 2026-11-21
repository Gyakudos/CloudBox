import 'package:cloudbox/core/agent_client.dart';
import 'package:cloudbox/core/models.dart';
import 'package:cloudbox/core/paired_devices.dart';
import 'package:cloudbox/core/pairing_flow.dart';
import 'package:cloudbox/core/pairing_payload.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

PairingPayload _payload() => PairingPayload(
      version: 1,
      serverId: 'server',
      endpoints: const ['127.0.0.1:8443'],
      pin: 'pin',
      token: 'token',
    );

PairingOutcome _outcome({
  required String deviceId,
  required List<CloudBoxFolder> folders,
}) {
  final payload = _payload();
  final client = CloudBoxClient.forPayload(payload);
  addTearDown(client.close);
  return PairingOutcome(
    client: client,
    pairing: PairingResult(
      deviceId: deviceId,
      deviceToken: 'device-token',
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
    payload: payload,
    deviceName: 'Pixel',
    appVersion: '0.07.21.11.26',
    platform: 'android',
  );
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferences.getInstance();
  });

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

  test('a pairing can be saved and reloaded without the single-use token', () async {
    final record = _outcome(deviceId: 'abc', folders: const []).record;
    expect(record.toPayload().token, isEmpty);
    expect(record.deviceToken, 'device-token');
    expect(record.endpoints, ['127.0.0.1:8443']);

    await PairedDeviceStore.upsert(record);
    final loaded = await PairedDeviceStore.load();

    expect(loaded, hasLength(1));
    expect(loaded.single.key, record.key);
    expect(loaded.single.deviceToken, record.deviceToken);
    expect(loaded.single.pin, record.pin);
    expect(loaded.single.appVersion, '0.07.21.11.26');
  });

  test('re-pairing the same PC replaces the saved record instead of duplicating it', () async {
    final first = _outcome(deviceId: 'abc', folders: const []).record;
    final refreshed = first.copyWith(serverName: 'New PC name');
    await PairedDeviceStore.upsert(first);
    await PairedDeviceStore.upsert(refreshed);

    final loaded = await PairedDeviceStore.load();
    expect(loaded, hasLength(1));
    expect(loaded.single.serverName, 'New PC name');
  });

  test('a saved pairing can be removed', () async {
    final record = _outcome(deviceId: 'abc', folders: const []).record;
    await PairedDeviceStore.upsert(record);
    await PairedDeviceStore.remove(record);

    expect(await PairedDeviceStore.load(), isEmpty);
  });

  test('corrupt saved data is ignored rather than crashing the app', () async {
    SharedPreferences.setMockInitialValues({PairedDeviceStore.key: 'not json'});
    await SharedPreferences.getInstance();

    expect(await PairedDeviceStore.load(), isEmpty);
  });
}
