import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:carsoc/screens/settings/remote_access_screen.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Remote Access screen renders server controls', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RemoteAccessScreen()));
    await tester.pump();

    expect(find.text('Remote Access'), findsOneWidget);
    expect(find.text('Web server'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsOneWidget);
    expect(find.text('Port'), findsOneWidget);
    expect(find.text('Access token'), findsOneWidget);
    // Port and token cards each have a Save button.
    expect(find.text('Save'), findsNWidgets(2));
  });
}
