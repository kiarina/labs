import 'package:flutter/material.dart';

import '../agents/agent_check.dart';
import '../orchestrator/brain_config.dart';
import '../state/thread_view.dart' show Json;
import 'brain_editor.dart';
import 'theme.dart';

/// Sends a `brain/...` request to a brain.
typedef BrainRequest = Future<Object?> Function(String method, [Json params]);

/// A brain's settings, edited from any console: the Brain step of its start
/// screen, with the checks run on the brain's machine. Saving restarts the
/// orchestrator's agent and starts a new conversation (refused while the
/// orchestrator is running); workers keep running.
Future<void> showBrainSettings(
  BuildContext context, {
  required String brain,
  required BrainRequest request,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => BrainSettingsDialog(brain: brain, request: request),
);

class BrainSettingsDialog extends StatefulWidget {
  const BrainSettingsDialog({
    super.key,
    required this.brain,
    required this.request,
  });

  final String brain;
  final BrainRequest request;

  @override
  State<BrainSettingsDialog> createState() => _BrainSettingsDialogState();
}

class _BrainSettingsDialogState extends State<BrainSettingsDialog> {
  BrainDraft? _draft;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = (await widget.request('brain/config') as Map)
          .cast<String, dynamic>();
      final draft = BrainDraft(
        BrainConfig.fromJson((r['config'] as Map).cast()),
        checker: RemoteAgentChecker(
          (what, args) =>
              widget.request('brain/check', {'what': what, 'args': args}),
        ),
        local: false,
        projectDirDefault:
            'its project folder (${r['projectDirDefault'] ?? 'on that machine'})',
      );
      if (!mounted) {
        draft.dispose();
        return;
      }
      setState(() => _draft = draft);
      draft.runCheck();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not read its settings: $e');
    }
  }

  @override
  void dispose() {
    _draft?.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final (config, error) = _draft!.read();
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.request('brain/configure', {'config': config!.toJson()});
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final draft = _draft;
    return AlertDialog(
      backgroundColor: Palette.surface,
      title: Text('Settings of ${widget.brain}'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'What its orchestrator runs on. Checks run on ${widget.brain}\'s machine. Saving restarts '
                'the orchestrator and starts a new conversation; workers keep running. What each body '
                'runs is that body\'s settings (⚙ in Bodies).',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Palette.textDim,
                ),
              ),
              const SizedBox(height: 12),
              if (draft == null && _error == null)
                const Text(
                  'Reading its settings…',
                  style: TextStyle(fontSize: 12, color: Palette.textDim),
                ),
              if (draft != null) BrainEditor(draft: draft),
              if (_error case final e?)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    e,
                    key: const Key('brain-settings-error'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('brain-settings-save'),
          onPressed: draft == null || _saving ? null : _save,
          child: Text(_saving ? 'Restarting…' : 'Save and start over'),
        ),
      ],
    );
  }
}
