import 'package:cloudbox_pc/core/local_api.dart';
import 'package:cloudbox_pc/core/models.dart';
import 'package:cloudbox_pc/features/backups/backups_screen.dart';
import 'package:cloudbox_pc/features/devices/paired_devices_screen.dart';
import 'package:cloudbox_pc/features/pairing/pairing_screen.dart';
import 'package:cloudbox_pc/features/storage/storage_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeApi implements LocalAgentApi {
  FakeApi({
    LocalState? state,
    List<VolumeInfo>? available,
    List<PairedDevice>? paired,
    List<BackupStatus>? backupList,
  })  : state = state ?? _state(),
        available = available ?? _volumes,
        _pairedDevices = paired ?? _devices,
        _backupStatuses = backupList ?? _backups;

  LocalState state;
  final List<VolumeInfo> available;
  List<PairedDevice> _pairedDevices;
  final List<BackupStatus> _backupStatuses;
  int refreshes = 0;
  int revokes = 0;
  SelectedFolder? lastSet;
  DeviceBackupConfig? lastDeviceBackup;

  @override
  Future<LocalState> status() async => state;

  @override
  Future<LocalState> refreshPairing() async {
    refreshes++;
    return state;
  }

  @override
  Future<List<VolumeInfo>> volumes() async => available;

  @override
  Future<SelectedFolder> setDestination({
    required String volume,
    required String subfolder,
  }) async {
    lastSet = SelectedFolder(id: 'default', name: subfolder, root: '$volume\\$subfolder');
    return lastSet!;
  }

  @override
  Future<List<PairedDevice>> devices() async => _pairedDevices;

  @override
  Future<void> revokeDevice(String id) async {
    revokes++;
    _pairedDevices = _pairedDevices.where((d) => d.id != id).toList();
  }

  @override
  Future<PairedDevice> setDeviceBackup({
    required String id,
    required String volume,
    required String subfolder,
    required bool enabled,
  }) async {
    lastDeviceBackup = DeviceBackupConfig(
      folderId: 'backup-$id',
      volume: volume,
      subfolder: subfolder,
      root: '$volume\\$subfolder',
      enabled: enabled,
    );
    final updated = _pairedDevices.firstWhere((d) => d.id == id).copyWith(backup: lastDeviceBackup!);
    _pairedDevices = _pairedDevices.map((d) => d.id == id ? updated : d).toList();
    return updated;
  }

  @override
  Future<List<BackupStatus>> backups() async => _backupStatuses;

  @override
  void close() {}
}

LocalState _state() => LocalState(
      serverName: 'MY-PC',
      serverId: '0123456789abcdef',
      version: '0.01.15.11.26',
      pin: 'pin',
      endpoints: const ['127.0.0.1:8443'],
      pairing: LocalPairing(
        token: 'one-time-token',
        expiresAt: DateTime.now().add(const Duration(minutes: 4)),
        active: true,
      ),
      destination: null,
      payload: '{}',
      qrPngBase64: '',
    );

// Two valid 1x1 PNGs. The QR widget decodes base64 into a MemoryImage provider; these let a test
// assert that polling rebuilds reuse the provider while a refreshed code replaces it.
const _whitePixel =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAANSURBVBhXY/j///9/AAn7A/0FQ0XKAAAAAElFTkSuQmCC';
const _blackPixel =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAANSURBVBhXY2BgYPgPAAEEAQBwIGULAAAAAElFTkSuQmCC';

LocalState _stateWithQr(String qr) => LocalState(
      serverName: 'MY-PC',
      serverId: '0123456789abcdef',
      version: '0.01.15.11.26',
      pin: 'pin',
      endpoints: const ['127.0.0.1:8443'],
      pairing: LocalPairing(
        token: 'one-time-token',
        expiresAt: DateTime.now().add(const Duration(minutes: 4)),
        active: true,
      ),
      destination: null,
      payload: '{}',
      qrPngBase64: qr,
    );

final List<VolumeInfo> _volumes = [
  const VolumeInfo(
    name: 'C:',
    label: 'OS',
    path: r'C:\',
    fsType: 'NTFS',
    total: 500000000000,
    free: 100000000000,
    removable: false,
    network: false,
  ),
  const VolumeInfo(
    name: 'E:',
    label: 'Elements',
    path: r'E:\',
    fsType: 'NTFS',
    total: 2000000000000,
    free: 1000000000000,
    removable: true,
    network: false,
  ),
];

final List<PairedDevice> _devices = [
  PairedDevice(
    id: 'dev-1',
    name: 'Pixel 8',
    platform: 'android',
    appVersion: '0.01.15.11.26',
    createdAt: '2026-11-15T10:00:00Z',
    lastSeenAt: '2026-11-15T11:00:00Z',
    active: true,
    backup: const DeviceBackupConfig(
      folderId: 'backup-dev-1',
      volume: 'E:',
      subfolder: 'CloudBox/Pixel-8',
      root: r'E:\CloudBox\Pixel-8',
      enabled: true,
    ),
  ),
];

final List<BackupStatus> _backups = [
  BackupStatus(
    deviceId: 'dev-1',
    deviceName: 'Pixel 8',
    folderId: 'backup-dev-1',
    volume: 'E:',
    subfolder: 'CloudBox/Pixel-8',
    root: r'E:\CloudBox\Pixel-8',
    available: true,
    enabled: true,
    lastBackupAt: '2026-11-15T11:00:00Z',
    fileCount: 12,
    bytes: 2048,
  ),
];

void main() {
  testWidgets('pairing screen shows the live code and can refresh it', (tester) async {
    final api = FakeApi();
    await tester.pumpWidget(MaterialApp(
      home: PairingScreen(
        state: api.state,
        error: null,
        refreshing: false,
        onRefresh: () => api.refreshes++,
      ),
    ));

    expect(find.text('Pair your phone'), findsOneWidget);
    expect(find.text('one-time-token'), findsOneWidget);
    expect(find.text('Waiting for phone'), findsOneWidget);
    expect(find.text('Show a new code'), findsOneWidget);

    await tester.tap(find.text('Show a new code'));
    expect(api.refreshes, 1);
  });

  testWidgets('pairing screen reports a used code as paired', (tester) async {
    final used = _state().copyWithPairing(LocalPairing(
          token: 'used-token',
          expiresAt: DateTime.now().add(const Duration(minutes: 4)),
          active: false,
        ));
    await tester.pumpWidget(MaterialApp(
      home: PairingScreen(state: used, error: null, refreshing: false, onRefresh: () {}),
    ));

    expect(find.text('Phone paired'), findsOneWidget);
  });

  testWidgets('QR image survives countdown and poll rebuilds without reloading', (tester) async {
    Widget build(LocalState state) => MaterialApp(
          home: PairingScreen(
            state: state,
            error: null,
            refreshing: false,
            onRefresh: () {},
          ),
        );

    await tester.pumpWidget(build(_stateWithQr(_whitePixel)));
    await tester.pumpAndSettle();
    final initial = tester.widget<Image>(find.byType(Image)).image;

    // A status poll replaces the state object but the QR bytes are identical. The provider must
    // be the same instance or the image cache misses and the QR visibly flashes.
    await tester.pumpWidget(build(_stateWithQr(_whitePixel)));
    await tester.pump();
    expect(tester.widget<Image>(find.byType(Image)).image, same(initial));

    // Refreshing the code genuinely changes the image.
    await tester.pumpWidget(build(_stateWithQr(_blackPixel)));
    await tester.pump();
    expect(tester.widget<Image>(find.byType(Image)).image, isNot(same(initial)));
  });

  testWidgets('storage screen sends the chosen drive and folder to the agent', (tester) async {
    final api = FakeApi();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: StorageScreen(api: api, current: null, onChanged: () async {})),
    ));
    await tester.pumpAndSettle();

    expect(find.text('E:  Elements'), findsOneWidget);
    await tester.tap(find.text('E:  Elements'));
    await tester.enterText(find.byType(TextField), 'Backups');
    await tester.ensureVisible(find.text('Use this drive'));
    await tester.pump();
    await tester.tap(find.text('Use this drive'));
    await tester.pumpAndSettle();

    expect(api.lastSet?.root, r'E:\Backups');
    expect(api.lastSet?.name, 'Backups');
  });

  testWidgets('storage screen prefills from the current destination', (tester) async {
    final state = _state();
    final api = FakeApi(state: state);
    final current = DestinationInfo(volume: 'C:', subfolder: 'Photos', root: r'C:\Photos');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: StorageScreen(api: api, current: current, onChanged: () async {})),
    ));
    await tester.pumpAndSettle();

    expect(find.text(r'C:\Photos'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, 'Photos');
  });

  testWidgets('paired devices screen can configure a device backup folder', (tester) async {
    final api = FakeApi();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: PairedDevicesScreen(
        api: api,
        volumes: api.available,
        onAddDevice: () async {},
      )),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Pixel 8'), findsOneWidget);
    expect(find.text(r'E:\CloudBox\Pixel-8'), findsOneWidget);

    await tester.tap(find.text('Configure backup'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Backups/Phone');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(api.lastDeviceBackup?.subfolder, 'Backups/Phone');
    expect(api.lastDeviceBackup?.volume, 'E:');
  });

  testWidgets('paired devices screen can revoke a device', (tester) async {
    final api = FakeApi();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: PairedDevicesScreen(
        api: api,
        volumes: api.available,
        onAddDevice: () async {},
      )),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove device'));
    await tester.pumpAndSettle();

    expect(api.revokes, 1);
    expect(find.text('No phones have paired yet.'), findsOneWidget);
  });

  testWidgets('backups screen shows each device destination', (tester) async {
    final api = FakeApi();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: BackupsScreen(api: api, onConfigure: (_) {})),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Pixel 8'), findsOneWidget);
    expect(find.text(r'E:\CloudBox\Pixel-8'), findsOneWidget);
    expect(find.text('Available'), findsOneWidget);
    expect(find.text('2.0 KB'), findsOneWidget);
  });
}
