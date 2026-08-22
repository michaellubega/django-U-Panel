import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:u_panel/main.dart';

void main() {
  testWidgets('app builds', (WidgetTester tester) async {
    await tester.pumpWidget(const UPanelApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
