// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:loyalty_card/src/loyalty_app.dart';

void main() {
  testWidgets('Home page renders', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(const LoyaltyApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Mes cartes'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
  });
}
