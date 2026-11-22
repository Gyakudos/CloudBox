import 'package:cloudbox/core/agent_client.dart';
import 'package:cloudbox/core/gen/version.dart';
import 'package:cloudbox/core/models.dart';
import 'package:cloudbox/core/pairing_flow.dart';
import 'package:cloudbox/core/pairing_payload.dart';
import 'package:cloudbox/main.dart';
import 'package:cloudbox/ui/send_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferences.getInstance();
  });

  testWidgets('paired devices is the first thing the user sees', (tester) async {
    await tester.pumpWidget(const CloudBoxApp());
    await tester.pumpAndSettle();

    expect(find.text('Paired devices'), findsOneWidget);
    expect(find.text('No paired PCs yet'), findsOneWidget);
    expect(find.text('Pair a PC'), findsOneWidget);
  });

  testWidgets('an invalid pairing code surfaces a readable error', (tester) async {
    await tester.pumpWidget(const CloudBoxApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Pair a PC'));
    await tester.pumpAndSettle();
    expect(find.text('Connect to your PC'), findsOneWidget);
    expect(find.text('CloudBox $kCloudBoxVersion'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'definitely not a pairing code');
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    expect(find.textContaining('does not look like a CloudBox pairing code'), findsOneWidget);
  });

  testWidgets('Send screen offers a Paired Devices button that opens the selector', (tester) async {
    final payload = PairingPayload(
      version: 1,
      serverId: 'server',
      endpoints: const ['127.0.0.1:8443'],
      pin: 'pin',
      token: 'token',
    );
    final client = CloudBoxClient.forPayload(payload);
    addTearDown(client.close);
    final outcome = PairingOutcome(
      client: client,
      pairing: PairingResult(
        deviceId: 'abc',
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
          id: 'abc',
          name: 'Pixel',
          platform: 'android',
          appVersion: 'test',
        ),
        folders: const [
          CloudBoxFolder(id: 'backup-abc', name: 'CloudBox/Pixel', root: 'D:/CloudBox/Pixel'),
        ],
      ),
      payload: payload,
      deviceName: 'Pixel',
      appVersion: 'test',
      platform: 'android',
    );

    await tester.pumpWidget(MaterialApp(home: SendScreen(outcome: outcome)));
    await tester.pumpAndSettle();

    expect(find.text('Paired Devices'), findsOneWidget);
    expect(find.textContaining('on PC'), findsOneWidget);

    await tester.tap(find.text('Paired Devices'));
    await tester.pumpAndSettle();

    expect(find.text('Select a PC'), findsOneWidget);
    expect(
      find.textContaining('Files and folders you already added stay in the queue'),
      findsOneWidget,
    );
  });
}
