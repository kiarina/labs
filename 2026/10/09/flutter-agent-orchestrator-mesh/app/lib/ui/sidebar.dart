import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../agents/agent_thread.dart';
import '../console/console.dart';
import '../orchestrator/hub.dart' show HubSettings;
import 'theme.dart';

/// Left: this app, orchestrator provider, new conversation, project,
/// settings, and the bodies connected to the brain.
class Sidebar extends StatelessWidget {
  const Sidebar({super.key, required this.console, required this.onToggleLog});

  final ConsoleMirror console;
  final VoidCallback onToggleLog;

  @override
  Widget build(BuildContext context) {
    final current = console.orchestrator?.provider ?? console.settings.orchestrator;
    return Container(
      width: 240,
      color: Palette.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 36),
          _ThisApp(console: console),
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
                  enabled: console.providers.contains(Provider.kiapi),
                ),
              ],
              selected: {current},
              onSelectionChanged: (s) async {
                if (s.first == current) return;
                if (console.orchestrator != null &&
                    !await _confirmSwitch(context, s.first)) {
                  return;
                }
                await console.newConversation(provider: s.first);
              },
            ),
          ),
          const SizedBox(height: 8),
          _Nav(
            icon: Icons.edit_square,
            label: 'New conversation',
            onTap: () => console.newConversation(),
          ),
          _Nav(
            icon: Icons.folder_open_outlined,
            label:
                console.projectDir
                    .split('/')
                    .where((p) => p.isNotEmpty)
                    .lastOrNull ??
                '/',
            tooltip: console.isBrain
                ? console.projectDir
                : '${console.projectDir} (on ${console.brain}; pick it on the brain)',
            onTap: () async {
              // The path is on the brain's machine.
              if (!console.isBrain) return;
              final dir = await getDirectoryPath(
                initialDirectory: console.projectDir,
              );
              if (dir != null) console.setProject(dir);
            },
          ),
          _Nav(
            icon: Icons.tune,
            label: 'Settings',
            onTap: () => showSettings(context, console),
          ),
          const Spacer(),
          const Divider(height: 1),
          Flexible(
            flex: 0,
            child: SingleChildScrollView(
              child: _Bodies(console: console, onToggleLog: onToggleLog),
            ),
          ),
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

/// This app's name, role and link to the brain.
class _ThisApp extends StatelessWidget {
  const _ThisApp({required this.console});

  final ConsoleMirror console;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.circle,
                size: 8,
                color: console.connected ? Palette.added : Palette.removed,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  console.selfName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _Badge(console.isBrain ? 'brain' : 'body'),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            console.link,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: Palette.textDim),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Palette.border),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 10, color: Palette.textDim),
      ),
    );
  }
}

/// The bodies the brain knows: online, providers, workers running there,
/// subscription usage.
class _Bodies extends StatelessWidget {
  const _Bodies({required this.console, required this.onToggleLog});

  final ConsoleMirror console;
  final VoidCallback onToggleLog;

  @override
  Widget build(BuildContext context) {
    final bodies = console.bodies;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Bodies · ${bodies.where((b) => b.online).length}',
                style: const TextStyle(fontSize: 11, color: Palette.textFaint),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Protocol log (this app)',
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                onPressed: onToggleLog,
                icon: const Icon(Icons.data_object, color: Palette.textFaint),
              ),
            ],
          ),
          if (!console.connected)
            Text(
              console.startupError ?? 'Not connected to a brain.',
              style: const TextStyle(fontSize: 11, color: Palette.textDim),
            ),
          for (final b in bodies)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Tooltip(
                message: b.projectDir,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.circle,
                          size: 7,
                          color: b.online ? Palette.added : Palette.textFaint,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            b.name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: b.name == console.selfName
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                        if (b.isBrain) ...[
                          const SizedBox(width: 6),
                          const _Badge('brain'),
                        ],
                      ],
                    ),
                    Text(
                      b.online
                          ? '${b.host} · ${b.providers.map((p) => p.label).join(', ')} · ${b.running} running'
                          : 'offline',
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: Palette.textDim,
                      ),
                    ),
                    if (b.online)
                      for (final u in b.usage)
                        Text(
                          u,
                          style: const TextStyle(
                            fontSize: 10.5,
                            color: Palette.textFaint,
                          ),
                        ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Concurrency limit, waking the orchestrator, default worker models.
Future<void> showSettings(BuildContext context, ConsoleMirror console) async {
  // Edit a copy; the brain saves it and sends it back to every console.
  final s = HubSettings()..load(console.settings.toJson());
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        Widget modelPicker(Provider p) {
          final models = console.ready
              ? console.modelsFor(p)
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
                        'Workers running at once (per body)',
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
                  console.providers.contains(Provider.kiapi)
                      ? 'kiapi worker model: ${console.defaultModelFor(Provider.kiapi) ?? '-'} '
                            '(${s.kiapiMaxConcurrent} at a time per body)'
                      : 'kiapi unavailable on the brain: ${console.brainBody?.kiapiError ?? 'starting'}',
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
  console.saveSettings(s);
}
