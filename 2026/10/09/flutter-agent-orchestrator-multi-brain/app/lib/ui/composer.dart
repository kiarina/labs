import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../console/console.dart';
import 'theme.dart';

/// The only input: messages to the orchestrator.
class Composer extends StatefulWidget {
  const Composer({super.key, required this.console});

  final ConsoleMirror console;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty || !widget.console.ready) return;
    _controller.clear();
    try {
      await widget.console.sendToOrchestrator(text);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final console = widget.console;
    final o = console.orchestrator;
    final running = o?.view.isRunning ?? false;
    final hasText = _controller.text.trim().isNotEmpty;
    final agent = console.brainAgent;
    final runsOn = [
      if (agent['label'] case final String l) l,
      if ((o?.model ?? agent['model']) case final String m) m,
    ].join(' · ');
    return Container(
      decoration: BoxDecoration(
        color: Palette.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Palette.border),
      ),
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 8),
      child: Column(
        children: [
          CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter): _submit,
            },
            child: TextField(
              controller: _controller,
              autofocus: true,
              minLines: 1,
              maxLines: 10,
              style: const TextStyle(fontSize: 14, height: 1.5),
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: running
                    ? 'Add to what ${console.brain} is doing…'
                    : 'Ask ${console.brain}',
                hintStyle: const TextStyle(color: Palette.textFaint),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    runsOn,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Palette.textFaint,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (running && !hasText)
                IconButton.filled(
                  tooltip: 'Stop ${console.brain}',
                  onPressed: console.interruptOrchestrator,
                  icon: const Icon(Icons.stop_rounded, size: 18),
                )
              else
                IconButton.filled(
                  tooltip: 'Send',
                  onPressed: hasText && console.ready ? _submit : null,
                  icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
