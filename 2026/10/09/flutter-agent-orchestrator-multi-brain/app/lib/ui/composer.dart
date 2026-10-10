import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../console/console.dart';
import '../orchestrator/hub.dart' show HubSettings;
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
    final type = o?.workerType ?? console.settings.orchestrator;
    final label = console.labelOf(type);
    final models = console.ready
        ? console.modelsFor(type)
        : const <Map<String, dynamic>>[];
    final model = o?.model ?? console.settings.orchestratorModel;
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
                    ? 'Add to what the orchestrator is doing…'
                    : 'Ask the orchestrator ($label)',
                hintStyle: const TextStyle(color: Palette.textFaint),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _Chip(
                        icon: Icons.hub_outlined,
                        text: 'Orchestrator: $label',
                      ),
                      const SizedBox(width: 4),
                      // Applies to the next conversation (and is saved).
                      PopupMenuButton<String>(
                        tooltip: 'Orchestrator model (next conversation)',
                        enabled: models.isNotEmpty,
                        color: Palette.surfaceHigh,
                        onSelected: (id) => console.saveSettings(
                          HubSettings()
                            ..load(console.settings.toJson())
                            ..orchestratorModel = id,
                        ),
                        itemBuilder: (_) => [
                          for (final m in models)
                            CheckedPopupMenuItem(
                              value: m['id'] as String,
                              checked: m['id'] == model,
                              child: Text('${m['displayName']}'),
                            ),
                        ],
                        child: _Chip(
                          icon: Icons.auto_awesome_outlined,
                          text:
                              models
                                      .where((m) => m['id'] == model)
                                      .firstOrNull?['displayName']
                                  as String? ??
                              model ??
                              'default model',
                          dropdown: true,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (running && !hasText)
                IconButton.filled(
                  tooltip: 'Stop the orchestrator',
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

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.text, this.dropdown = false});

  final IconData icon;
  final String text;
  final bool dropdown;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Palette.textDim),
          const SizedBox(width: 4),
          Text(
            text,
            style: const TextStyle(fontSize: 12, color: Palette.textDim),
          ),
          if (dropdown)
            const Icon(
              Icons.arrow_drop_down,
              size: 16,
              color: Palette.textFaint,
            ),
        ],
      ),
    );
  }
}
