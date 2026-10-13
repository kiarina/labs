import 'package:agent_orchestrator/console/console.dart';
import 'package:agent_orchestrator/state/thread_view.dart' show Json;
import 'package:agent_orchestrator/ui/composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The console as the composer sees it: ready, idle, records what is sent.
class _Console extends ChangeNotifier implements ConsoleMirror {
  final sent = <String>[];

  @override
  bool get ready => true;
  @override
  String get brain => 'brain-a';
  @override
  Json get brainAgent => const {};
  @override
  Future<void> sendToOrchestrator(String text) async => sent.add(text);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  testWidgets('Enter confirms a Japanese conversion; the next Enter sends', (
    tester,
  ) async {
    final console = _Console();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Composer(console: console)),
      ),
    );
    await tester.showKeyboard(find.byType(TextField));

    // Converting: the Enter belongs to the input method.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '日本語',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 0, end: 3),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(console.sent, isEmpty);

    // Confirmed: Enter sends.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '日本語',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(console.sent, ['日本語']);
  });
}
