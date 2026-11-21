import 'package:daily_postbox/features/message/recipient_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('validates email format', () {
    expect(isValidEmailAddress('a@example.test'), isTrue);
    expect(isValidEmailAddress('a@example'), isFalse);
    expect(isValidEmailAddress('a b@example.test'), isFalse);
  });

  testWidgets('suggests, selects by keyboard, deletes and flags invalid chips',
      (tester) async {
    final key = GlobalKey<RecipientFieldState>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RecipientField(
          key: key,
          label: 'To',
          errorText: 'bad',
          suggest: (q) async => ['alice@example.test', 'alan@example.test'],
          onChanged: (_) {},
        ),
      ),
    ));

    await tester.enterText(find.byType(TextField), 'al');
    await tester.pumpAndSettle();
    expect(find.text('alice@example.test'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, 'alan@example.test'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'broken,');
    await tester.pumpAndSettle();
    expect(find.text('bad'), findsOneWidget);
    expect(key.currentState!.hasInvalid, isTrue);

    await tester.tap(find.descendant(
        of: find.widgetWithText(InputChip, 'broken'),
        matching: find.byType(Icon)));
    await tester.pumpAndSettle();
    expect(find.text('bad'), findsNothing);
    expect(key.currentState!.commitPending(), ['alan@example.test']);
  });
}
