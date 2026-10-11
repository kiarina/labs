import 'dart:convert';

import 'package:flutter/material.dart';

import '../agents/agent_check.dart';
import '../agents/mac_permissions.dart';
import '../agents/worker_types.dart';
import '../state/thread_view.dart' show Json;
import 'agents_editor.dart';
import 'theme.dart';

/// Sends a `body/...` request to the body (through a brain it belongs to).
typedef BodyRequest = Future<Object?> Function(String method, [Json params]);

/// Sets the brains a body belongs to (through the signaling server).
typedef BodyAssign = Future<(bool, String?)> Function(List<String> brains);

/// A connected body's settings, edited from a console: the brains it belongs
/// to (several: a shared body), and its agents with the same editor as its
/// start screen, every check run on the body's machine. Offered only while
/// the body is paused with no brain's workers there. Saving changed agents
/// restarts them. A body that belongs to no brain has nothing to relay
/// [request] (null): only its brains can be set.
Future<void> showBodySettings(
  BuildContext context, {
  required String body,
  required List<String> owners,
  required List<String> brains,
  required BodyAssign assign,
  BodyRequest? request,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => BodySettingsDialog(
    body: body,
    owners: owners,
    brains: brains,
    assign: assign,
    request: request,
  ),
);

class BodySettingsDialog extends StatefulWidget {
  const BodySettingsDialog({
    super.key,
    required this.body,
    required this.owners,
    required this.brains,
    required this.assign,
    this.request,
  });

  final String body;

  /// The brains it belongs to now, and the brains online to choose from.
  final List<String> owners;
  final List<String> brains;
  final BodyAssign assign;
  final BodyRequest? request;

  @override
  State<BodySettingsDialog> createState() => _BodySettingsDialogState();
}

class _BodySettingsDialogState extends State<BodySettingsDialog> {
  AgentsDraft? _draft;

  /// The agents as read, to save them only when they changed.
  String? _loaded;
  late final _owners = [...widget.owners];
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.request != null) _load(widget.request!);
  }

  Future<void> _load(BodyRequest request) async {
    try {
      final r = (await request('body/config') as Map).cast<String, dynamic>();
      final config = WorkerTypesConfig.fromJson((r['config'] as Map).cast());
      _loaded = jsonEncode(config.toJson());
      final draft = AgentsDraft(
        config,
        checker: RemoteAgentChecker(
          (what, args) => request('body/check', {'what': what, 'args': args}),
        ),
        permissions: _RemotePermissions(request),
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

  bool get _ownersChanged =>
      _owners.length != widget.owners.length ||
      !_owners.every(widget.owners.contains);

  Future<void> _save() async {
    final draft = _draft;
    final (config, error) = draft == null
        ? (null, null)
        : draft.read(needOne: false);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      // Agents first, through a brain it still belongs to; then its brains.
      if (config != null && jsonEncode(config.toJson()) != _loaded) {
        await widget.request!('body/configure', {'config': config.toJson()});
      }
      if (_ownersChanged) {
        final (ok, reason) = await widget.assign(_owners);
        if (!ok) throw StateError(reason ?? 'could not change its brains');
      }
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
      title: Text('Settings of ${widget.body}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Belongs to', style: theme.textTheme.titleSmall),
              Text(
                'Only these brains run workers here. With several it is shared: one brain uses it at a time.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Palette.textDim,
                ),
              ),
              for (final b in {...widget.brains, ...widget.owners})
                CheckboxListTile(
                  key: Key('belongs-$b'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _owners.contains(b),
                  title: Text(b),
                  onChanged: _saving
                      ? null
                      : (v) => setState(
                          () => v == true ? _owners.add(b) : _owners.remove(b),
                        ),
                ),
              const Divider(),
              Text('Agents', style: theme.textTheme.titleSmall),
              Text(
                widget.request == null
                    ? 'It belongs to no brain yet: set its agents once it does.'
                    : 'Checks run on ${widget.body}\'s machine. Saving changed agents restarts them: the threads '
                          'it had end. It stays paused; resume it when you are done.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Palette.textDim,
                ),
              ),
              const SizedBox(height: 12),
              if (widget.request != null && draft == null && _error == null)
                const Text(
                  'Reading its settings…',
                  style: TextStyle(fontSize: 12, color: Palette.textDim),
                ),
              if (draft != null) AgentsEditor(draft: draft),
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
          onPressed: (widget.request != null && draft == null) || _saving
              ? null
              : _save,
          child: Text(_saving ? 'Saving…' : 'Save'),
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
