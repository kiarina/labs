import 'package:agent_orchestrator/state/thread_view.dart';
import 'package:agent_orchestrator/ui/items.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ItemState userMessage(String text) => ItemState({
  'id': 'u1',
  'type': 'userMessage',
  'content': [
    {'type': 'text', 'text': text},
  ],
});

Future<void> show(WidgetTester tester, String text) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(body: ItemWidget(item: userMessage(text))),
  ),
);

void main() {
  testWidgets(
    'what the app puts into a conversation is a note from its sender, not the user\'s bubble',
    (tester) async {
      await show(
        tester,
        '[thinker result for: Run the tests on body-c]\nAll 42 tests **pass**.',
      );
      expect(find.byKey(const Key('app-note')), findsOneWidget);
      expect(find.text('From the thinker'), findsOneWidget);
      expect(find.text('· Run the tests on body-c'), findsOneWidget);
      expect(find.textContaining('[thinker result'), findsNothing);

      await show(tester, '[request from the talker]\nLook up the weather.');
      expect(find.text('From the talker'), findsOneWidget);

      await show(tester, '[worker update]\n- w1 (codex on body-c) idle: tests');
      expect(find.text('Worker update'), findsOneWidget);

      // The user's own words stay a bubble, brackets or not.
      await show(tester, '[note] buy milk');
      expect(find.byKey(const Key('app-note')), findsNothing);
      expect(find.text('[note] buy milk'), findsOneWidget);
    },
  );
}
