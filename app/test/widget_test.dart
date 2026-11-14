import 'package:cloudbox/core/gen/version.dart';
import 'package:cloudbox/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('pairing screen is the first thing the user sees', (tester) async {
    await tester.pumpWidget(const CloudBoxApp());

    expect(find.text('Connect to your PC'), findsOneWidget);
    expect(find.text('Pair'), findsOneWidget);
    expect(find.text('CloudBox $kCloudBoxVersion'), findsOneWidget);
  });

  testWidgets('an invalid pairing code surfaces a readable error', (tester) async {
    await tester.pumpWidget(const CloudBoxApp());

    await tester.enterText(find.byType(TextField).first, 'definitely not a pairing code');
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();

    expect(find.textContaining('does not look like a CloudBox pairing code'), findsOneWidget);
  });
}
