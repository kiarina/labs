import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_controller.dart';
import 'theme.dart';

class Composer extends StatefulWidget {
  const Composer({super.key, required this.app});

  final AppController app;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    try {
      await widget.app.send(text);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final running = app.current?.isRunning ?? false;
    final hasText = _controller.text.trim().isNotEmpty;
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
              focusNode: _focus,
              autofocus: true,
              minLines: 1,
              maxLines: 10,
              style: const TextStyle(fontSize: 14, height: 1.5),
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: running
                    ? 'Steer the current turn…'
                    : app.current == null
                    ? 'Ask Claude anything'
                    : 'Ask for follow-up changes',
                hintStyle: const TextStyle(color: Palette.textFaint),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              // The pickers scroll sideways when the window is narrow (e.g.
              // with the protocol log open) instead of overflowing.
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _Picker(
                        icon: Icons.auto_awesome_outlined,
                        value: app.model,
                        options: [
                          for (final m in app.models) m['id'] as String,
                        ],
                        labels: {
                          for (final m in app.models)
                            m['id'] as String: m['displayName'] as String,
                        },
                        onSelected: app.setModel,
                      ),
                      const SizedBox(width: 4),
                      _Picker(
                        icon: Icons.speed,
                        value: app.effort,
                        options: app.effortOptions,
                        onSelected: app.setEffort,
                      ),
                      const SizedBox(width: 4),
                      _Picker(
                        icon: Icons.shield_outlined,
                        value: app.accessMode,
                        options: const [
                          'default',
                          'acceptEdits',
                          'plan',
                          'auto',
                          'bypassPermissions',
                        ],
                        // Claude Code's permission modes.
                        labels: const {
                          'default': 'Ask permissions',
                          'acceptEdits': 'Accept edits',
                          'plan': 'Plan',
                          'auto': 'Auto',
                          'bypassPermissions': 'Bypass permissions',
                        },
                        onSelected: app.setAccessMode,
                      ),
                      const SizedBox(width: 4),
                      Tooltip(
                        message: app.chrome
                            ? 'Claude in Chrome is on'
                            : 'Claude in Chrome is off',
                        child: InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: () => app.setChrome(!app.chrome),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 4,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.public,
                                  size: 14,
                                  color: app.chrome
                                      ? Palette.text
                                      : Palette.textFaint,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'Chrome',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: app.chrome
                                        ? Palette.text
                                        : Palette.textFaint,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _UsageRing(app: app),
              const SizedBox(width: 8),
              if (running && !hasText)
                IconButton.filled(
                  tooltip: 'Interrupt',
                  onPressed: app.interrupt,
                  icon: const Icon(Icons.stop_rounded, size: 18),
                )
              else
                IconButton.filled(
                  tooltip: running ? 'Steer' : 'Send',
                  onPressed: hasText ? _submit : null,
                  icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Picker extends StatelessWidget {
  const _Picker({
    required this.icon,
    required this.value,
    required this.options,
    required this.onSelected,
    this.labels = const {},
  });

  final IconData icon;
  final String? value;
  final List<String> options;
  final Map<String, String> labels;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '',
      enabled: options.isNotEmpty,
      color: Palette.surfaceHigh,
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (final o in options)
          CheckedPopupMenuItem(
            value: o,
            checked: o == value,
            child: Text(labels[o] ?? o),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Palette.textDim),
            const SizedBox(width: 4),
            Text(
              labels[value] ?? value ?? '—',
              style: const TextStyle(fontSize: 12, color: Palette.textDim),
            ),
            const Icon(
              Icons.arrow_drop_down,
              size: 16,
              color: Palette.textFaint,
            ),
          ],
        ),
      ),
    );
  }
}

/// Context window usage of the open thread.
class _UsageRing extends StatelessWidget {
  const _UsageRing({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final usage = app.current?.tokenUsage;
    final window = (usage?['modelContextWindow'] as num?)?.toDouble();
    final used = ((usage?['last'] as Map?)?['inputTokens'] as num?)?.toDouble();
    if (window == null || used == null || window == 0) {
      return const SizedBox.shrink();
    }
    final ratio = (used / window).clamp(0.0, 1.0);
    return Tooltip(
      message: '${used.toInt()} / ${window.toInt()} tokens in context',
      child: SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(
          value: ratio,
          strokeWidth: 2,
          color: Palette.textDim,
          backgroundColor: Palette.border,
        ),
      ),
    );
  }
}
