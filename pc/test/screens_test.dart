import 'package:cloudbox_pc/core/local_api.dart';
import 'package:cloudbox_pc/core/models.dart';
import 'package:cloudbox_pc/features/pairing/pairing_screen.dart';
import 'package:cloudbox_pc/features/storage/storage_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeApi implements LocalAgentApi {
  FakeApi({LocalState? state, List<VolumeInfo>? available})
      : state = state ?? _state(),
        available = available ?? _volumes;

  LocalState state;
  final List<VolumeInfo> available;
  int refreshes = 0;
  SelectedFolder? lastSet;

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
}
