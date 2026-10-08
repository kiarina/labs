import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../agents/agent_thread.dart';
import '../orchestrator/hub.dart';
import 'theme.dart';

/// Left: orchestrator provider, new conversation, project, settings, usage.
class Sidebar extends StatelessWidget {
  const Sidebar({super.key, required this.hub, required this.onToggleLog});

  final Hub hub;
  final VoidCallback onToggleLog;

  @override
  Widget build(BuildContext context) {
    final current = hub.orchestrator?.provider ?? hub.settings.orchestrator;
    return Container(
      width: 240,
      color: Palette.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 36),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
            child: Text(
              'Orchestrator',
              style: const TextStyle(fontSize: 11, color: Palette.textFaint),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SegmentedButton<Provider>(
              showSelectedIcon: false,
              segments: [
                const ButtonSegment(value: Provider.codex, label: Text('Codex')),
                const ButtonSegment(value: Provider.claude, label: Text('Claude')),
                ButtonSegment(
                  value: Provider.kiapi,
                  label: const Text('kiapi'),
                  enabled: hub.kiapi != null,
                ),
              ],
              selected: {current},
              onSelectionChanged: (s) async {
                if (s.first == current) return;
                if (hub.orchestrator != null &&
                    !await _confirmSwitch(context, s.first)) {
                  return;
                }
                await hub.newConversation(provider: s.first);
              },
            ),
          ),
          const SizedBox(height: 8),
          _Nav(
            icon: Icons.edit_square,
            label: 'New conversation',
            onTap: () => hub.newConversation(),
          ),
          _Nav(
            icon: Icons.folder_open_outlined,
            label:
                hub.projectDir
                    .split('/')
                    .where((p) => p.isNotEmpty)
                    .lastOrNull ??
                '/',
            tooltip: hub.projectDir,
            onTap: () async {
              final dir = await getDirectoryPath(
                initialDirectory: hub.projectDir,
              );
              if (dir != null) {
                hub.projectDir = dir;
                await hub.newConversation();
              }
            },
          ),
          _Nav(
            icon: Icons.tune,
            label: 'Settings',
            onTap: () => showSettings(context, hub),
          ),
          const Spacer(),
          const Divider(height: 1),
          _Usage(hub: hub, onToggleLog: onToggleLog),
        ],
      ),
    );
  }

  Future<bool> _confirmSwitch(BuildContext context, Provider p) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: Palette.surface,
            title: Text(
              'Switch the orchestrator to ${p.label}?',
              style: const TextStyle(fontSize: 15),
            ),
            content: const Text(
              'This starts a new orchestrator conversation. Workers keep running.',
              style: TextStyle(fontSize: 13),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Switch'),
              ),
            ],
          ),
        ) ??
        false;
  }
}

class _Nav extends StatelessWidget {
  const _Nav({
    required this.icon,
    required this.label,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final child = InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 16, color: Palette.text),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: tooltip == null ? child : Tooltip(message: tooltip!, child: child),
    );
  }
}

/// Accounts and subscription usage of both providers.
class _Usage extends StatelessWidget {
  const _Usage({required this.hub, required this.onToggleLog});

  final Hub hub;
  final VoidCallback onToggleLog;

  @override
  Widget build(BuildContext context) {
    if (!hub.ready) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          hub.startupError ?? 'Starting Codex and Claude…',
          style: TextStyle(
            fontSize: 11,
            color: hub.startupError == null ? Palette.textDim : Palette.removed,
          ),
        ),
      );
    }
    final codexLimit = hub.codex.rateLimits?['primary'] as Map?;
    final claudeLimit = hub.claude.rateLimits;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Codex · ${hub.codex.account?['planType'] ?? '?'}'
                  '${codexLimit != null ? ' · ${codexLimit['usedPercent']}% of week' : ''}',
                  style: const TextStyle(fontSize: 11, color: Palette.textDim),
                ),
                Text(
                  'Claude · ${hub.claude.account?['subscriptionType'] ?? '?'}'
                  '${claudeLimit != null ? ' · ${claudeLimit['rateLimitType'] ?? ''} ${claudeLimit['status']}' : ''}',
                  style: const TextStyle(fontSize: 11, color: Palette.textDim),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Protocol log',
            iconSize: 16,
            onPressed: onToggleLog,
            icon: const Icon(Icons.data_object, color: Palette.textFaint),
          ),
        ],
      ),
    );
  }
}

/// Concurrency limit, waking the orchestrator, default worker models.
Future<void> showSettings(BuildContext context, Hub hub) async {
  final s = hub.settings;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        Widget modelPicker(Provider p) {
          final models = hub.ready
              ? hub.modelsFor(p)
              : const <Map<String, dynamic>>[];
          return DropdownButton<String>(
            value:
                s.workerModel[p] != null &&
                    models.any((m) => m['id'] == s.workerModel[p])
                ? s.workerModel[p]
                : null,
            hint: const Text('Default', style: TextStyle(fontSize: 13)),
            isDense: true,
            dropdownColor: Palette.surfaceHigh,
            items: [
              for (final m in models)
                DropdownMenuItem(
                  value: m['id'] as String,
                  child: Text(
                    '${m['displayName']}',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
            ],
            onChanged: (v) => setState(() => s.workerModel[p] = v),
          );
        }

        return AlertDialog(
          backgroundColor: Palette.surface,
          title: const Text('Settings', style: TextStyle(fontSize: 15)),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Workers running at once',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                    IconButton(
                      onPressed: s.maxConcurrent > 1
                          ? () => setState(() => s.maxConcurrent--)
                          : null,
                      icon: const Icon(Icons.remove, size: 16),
                    ),
                    Text(
                      '${s.maxConcurrent}',
                      style: const TextStyle(fontSize: 14),
                    ),
                    IconButton(
                      onPressed: s.maxConcurrent < 32
                          ? () => setState(() => s.maxConcurrent++)
                          : null,
                      icon: const Icon(Icons.add, size: 16),
                    ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Wake the orchestrator when a worker finishes',
                    style: TextStyle(fontSize: 13),
                  ),
                  value: s.wakeOnFinish,
                  onChanged: (v) => setState(() => s.wakeOnFinish = v),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Codex worker model',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                    modelPicker(Provider.codex),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Claude worker model',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                    modelPicker(Provider.claude),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  hub.kiapi != null
                      ? 'kiapi worker model: ${hub.defaultModelFor(Provider.kiapi) ?? '-'} '
                            '(${s.kiapiMaxConcurrent} at a time)'
                      : 'kiapi unavailable: ${hub.kiapiError ?? 'starting'}',
                  style: const TextStyle(fontSize: 12, color: Palette.textDim),
                ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        );
      },
    ),
  );
  await hub.saveSettings();
  // A higher limit may let queued workers start.
  hub.drainQueue();
}
