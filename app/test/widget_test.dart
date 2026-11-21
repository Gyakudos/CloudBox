import 'package:cloudbox/core/gen/version.dart';
import 'package:cloudbox/main.dart';
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
}
