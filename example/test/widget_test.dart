import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_llm_router_example/main.dart';

void main() {
  testWidgets('demo shows spend, outage switch, and empty attempt logs', (
    tester,
  ) async {
    await tester.pumpWidget(const DemoApp());
    await tester.pump();

    expect(find.text(r'$0.00000000'), findsOneWidget);
    expect(find.text('Simulate primary outage (HTTP 429)'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.receipt_long));
    await tester.pumpAndSettle();

    expect(find.text('Attempt logs'), findsOneWidget);
    expect(find.textContaining('No attempts yet'), findsOneWidget);
  });
}
