import 'package:flutter/material.dart';

import '../agents/agent_check.dart';
import '../agents/mac_permissions.dart';
import '../agents/worker_types.dart';
import '../state/thread_view.dart' show Json;
import 'agents_editor.dart';
import 'theme.dart';

/// Sends a `body/...` request to the body (through the brain that owns it).
typedef BodyRequest = Future<Object?> Function(String method, [Json params]);

/// A connected body's agents, edited from a console: the same editor as its
/// start screen, with every check run on the body's machine. Saving restarts
/// the body's agents, so it is offered only while the body is paused with
/// nothing running there.
Future<void> showBodySettings(
  BuildContext context, {
  required String body,
  required bool isBrain,
  required BodyRequest request,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      BodySettingsDialog(body: body, isBrain: isBrain, request: request),
);

class BodySettingsDialog extends StatefulWidget {
  const BodySettingsDialog({
    super.key,
    required this.body,
    required this.isBrain,
    required this.request,
  });

  final String body;

  /// The body of a brain: its orchestrator needs at least one agent.
  final bool isBrain;
  final BodyRequest request;

  @override
  State<BodySettingsDialog> createState() => _BodySettingsDialogState();
}

class _BodySettingsDialogState extends State<BodySettingsDialog> {
  AgentsDraft? _draft;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = (await widget.request('body/config') as Map)
          .cast<String, dynamic>();
      final draft = AgentsDraft(
        WorkerTypesConfig.fromJson((r['config'] as Map).cast()),
        checker: RemoteAgentChecker(
          (what, args) =>
              widget.request('body/check', {'what': what, 'args': args}),
        ),
        permissions: _RemotePermissions(widget.request),
        local: false,
        projectDirDefault: r['projectDirDefault'] as String?,
      );
      if (!mounted) {
        draft.dispose();
        return;
      }
      setState(() => _draft = draft);
      draft.checkAll();
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
    final (config, error) = _draft!.read(needOne: widget.isBrain);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.request('body/configure', {'config': config!.toJson()});
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
      title: Text('Agents of ${widget.body}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Checks run on ${widget.body}\'s machine. Saving restarts its agents: the threads it had '
                'end. It stays paused; resume it when you are done.',
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
              if (draft != null)
                AgentsEditor(draft: draft, brain: widget.isBrain, body: true),
              if (_error case final e?)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    e,
                    key: const Key('body-settings-error'),
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
          key: const Key('body-settings-save'),
          onPressed: draft == null || _saving ? null : _save,
          child: Text(
            _saving ? 'Restarting its agents…' : 'Save and restart agents',
          ),
        ),
      ],
    );
  }
}

/// The body app's macOS permissions, read on its machine (granting them
/// stays there).
class _RemotePermissions extends MacPermissions {
  const _RemotePermissions(this.request);

  final BodyRequest request;

  @override
  Future<Map<String, bool>?> status() async {
    try {
      final r = await request('body/check', {'what': 'permissions'});
      return (r as Map?)?.cast<String, bool>();
    } catch (_) {
      return null;
    }
  }
}
