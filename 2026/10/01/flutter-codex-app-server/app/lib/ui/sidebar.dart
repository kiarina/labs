import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import 'theme.dart';

class Sidebar extends StatelessWidget {
  const Sidebar({super.key, required this.app, required this.onToggleLog});

  final AppController app;
  final VoidCallback onToggleLog;

  @override
  Widget build(BuildContext context) {
    // Sections first (all of them, so empty ones stay visible), then the
    // threads outside any section grouped by project (cwd), like the Codex app.
    final bySection = <String, List<ThreadSummary>>{
      for (final s in app.sections) s['id'] as String: [],
    };
    final byProject = <String, List<ThreadSummary>>{};
    for (final t in app.threads) {
      final list = t.sectionId == null ? null : bySection[t.sectionId];
      if (list != null) {
        list.add(t);
      } else {
        byProject.putIfAbsent(t.cwd, () => []).add(t);
      }
    }
    return Container(
      width: 272,
      color: Palette.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Room for the macOS traffic lights.
          const SizedBox(height: 36),
          _NavButton(
            icon: Icons.edit_square,
            label: 'New thread',
            onTap: app.newThread,
          ),
          _NavButton(
            icon: Icons.folder_open_outlined,
            label: _basename(app.projectDir),
            tooltip: app.projectDir,
            onTap: () async {
              final dir = await getDirectoryPath(
                initialDirectory: app.projectDir,
              );
              if (dir != null) {
                app
                  ..setProjectDir(dir)
                  ..newThread();
              }
            },
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Threads',
                    style: TextStyle(fontSize: 11, color: Palette.textFaint),
                  ),
                ),
                IconButton(
                  tooltip: 'New section',
                  iconSize: 14,
                  visualDensity: VisualDensity.compact,
                  onPressed: () async {
                    final name = await _askName(context, 'New section');
                    if (name != null) await app.createSection(name);
                  },
                  icon: const Icon(
                    Icons.create_new_folder_outlined,
                    color: Palette.textFaint,
                  ),
                ),
                Tooltip(
                  message: app.onlyOwnThreads
                      ? 'Showing threads started in this app'
                      : 'Showing every local Codex thread',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: () => app.setOnlyOwnThreads(!app.onlyOwnThreads),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      child: Text(
                        app.onlyOwnThreads ? 'This app' : 'All',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Palette.textDim,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                for (final section in app.sections) ...[
                  _SectionHeader(app: app, section: section),
                  for (final t in bySection[section['id']]!)
                    _ThreadTile(app: app, thread: t),
                ],
                for (final entry in byProject.entries) ...[
                  _GroupHeader(
                    icon: Icons.folder_outlined,
                    label: _basename(entry.key),
                  ),
                  for (final t in entry.value) _ThreadTile(app: app, thread: t),
                ],
                if (app.hasMoreOwnThreads)
                  TextButton(
                    onPressed: app.showMoreThreads,
                    child: const Text(
                      'Show more',
                      style: TextStyle(fontSize: 12, color: Palette.textDim),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          _AccountFooter(app: app, onToggleLog: onToggleLog),
        ],
      ),
    );
  }
}

String _basename(String path) {
  final parts = path.split('/').where((p) => p.isNotEmpty).toList();
  return parts.isEmpty ? '/' : parts.last;
}

Future<String?> _askName(
  BuildContext context,
  String title, {
  String initial = '',
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) {
      void submit() {
        final name = controller.text.trim();
        Navigator.pop(context, name.isEmpty ? null : name);
      }

      return AlertDialog(
        backgroundColor: Palette.surface,
        title: Text(title, style: const TextStyle(fontSize: 15)),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (_) => submit(),
          decoration: const InputDecoration(hintText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(onPressed: submit, child: const Text('OK')),
        ],
      );
    },
  );
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.icon, required this.label, this.trailing});

  final IconData icon;
  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(8, 10, trailing == null ? 8 : 0, 4),
      child: Row(
        children: [
          Icon(icon, size: 13, color: Palette.textFaint),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Palette.textDim),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.app, required this.section});

  final AppController app;
  final Map<String, dynamic> section;

  @override
  Widget build(BuildContext context) {
    final id = section['id'] as String;
    final name = section['name'] as String;
    return _GroupHeader(
      icon: Icons.bookmark_border,
      label: name,
      trailing: SizedBox(
        height: 20,
        child: PopupMenuButton<String>(
          tooltip: '',
          padding: EdgeInsets.zero,
          iconSize: 14,
          icon: const Icon(Icons.more_horiz, color: Palette.textFaint),
          color: Palette.surfaceHigh,
          onSelected: (v) async {
            if (v == 'rename') {
              final newName = await _askName(
                context,
                'Rename section',
                initial: name,
              );
              if (newName != null) await app.renameSection(id, newName);
            } else if (v == 'delete') {
              await app.deleteSection(id);
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'rename', child: Text('Rename')),
            PopupMenuItem(value: 'delete', child: Text('Delete section')),
          ],
        ),
      ),
    );
  }
}

/// Picks a section for a thread, or creates one.
Future<void> _moveThread(
  BuildContext context,
  AppController app,
  ThreadSummary thread,
) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      backgroundColor: Palette.surface,
      title: const Text('Move to section', style: TextStyle(fontSize: 15)),
      children: [
        for (final s in app.sections)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, s['id'] as String),
            child: Row(
              children: [
                Icon(
                  thread.sectionId == s['id']
                      ? Icons.check
                      : Icons.bookmark_border,
                  size: 16,
                  color: Palette.textDim,
                ),
                const SizedBox(width: 10),
                Text(s['name'] as String),
              ],
            ),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, '+new'),
          child: const Row(
            children: [
              Icon(Icons.add, size: 16, color: Palette.textDim),
              SizedBox(width: 10),
              Text('New section…'),
            ],
          ),
        ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return;
  var sectionId = choice;
  if (choice == '+new') {
    final name = await _askName(context, 'New section');
    if (name == null) return;
    sectionId = await app.createSection(name);
  }
  await app.moveToSection(thread, sectionId);
}

class _NavButton extends StatelessWidget {
  const _NavButton({
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

class _ThreadTile extends StatelessWidget {
  const _ThreadTile({required this.app, required this.thread});

  final AppController app;
  final ThreadSummary thread;

  @override
  Widget build(BuildContext context) {
    final selected = app.current?.threadId == thread.id;
    final active = thread.status == 'active';
    return Material(
      color: selected ? Palette.surfaceHigh : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => app.openThread(thread),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 7, 4, 7),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  thread.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: selected ? Palette.text : Palette.textDim,
                  ),
                ),
              ),
              if (active)
                const Padding(
                  padding: EdgeInsets.only(left: 6, right: 6),
                  child: SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: Palette.textDim,
                    ),
                  ),
                )
              else
                Text(
                  _ago(thread.updatedAt),
                  style: const TextStyle(
                    fontSize: 11,
                    color: Palette.textFaint,
                  ),
                ),
              PopupMenuButton<String>(
                tooltip: '',
                padding: EdgeInsets.zero,
                iconSize: 14,
                icon: const Icon(Icons.more_horiz, color: Palette.textFaint),
                color: Palette.surfaceHigh,
                onSelected: (v) {
                  switch (v) {
                    case 'move':
                      _moveThread(context, app, thread);
                    case 'unsection':
                      app.moveToSection(thread, null);
                    case 'archive':
                      app.archive(thread);
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'move',
                    child: Text('Move to section…'),
                  ),
                  if (thread.sectionId != null)
                    const PopupMenuItem(
                      value: 'unsection',
                      child: Text('Remove from section'),
                    ),
                  const PopupMenuItem(value: 'archive', child: Text('Archive')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _ago(int seconds) {
    if (seconds == 0) return '';
    final d = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
    );
    if (d.inMinutes < 1) return 'now';
    if (d.inHours < 1) return '${d.inMinutes}m';
    if (d.inDays < 1) return '${d.inHours}h';
    return '${d.inDays}d';
  }
}

class _AccountFooter extends StatelessWidget {
  const _AccountFooter({required this.app, required this.onToggleLog});

  final AppController app;
  final VoidCallback onToggleLog;

  @override
  Widget build(BuildContext context) {
    final account = app.account;
    final primary = app.rateLimits?['primary'] as Map?;
    final label = switch (account?['type']) {
      'chatgpt' => '${account!['email']} · ${account['planType']}',
      'apiKey' => 'API key',
      _ => app.serverInfo == null ? 'Connecting…' : 'Not signed in',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Palette.textDim),
                ),
                if (primary != null)
                  Text(
                    '${primary['usedPercent']}% of weekly limit used',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Palette.textFaint,
                    ),
                  ),
                if (app.serverInfo != null)
                  Text(
                    app.serverInfo!['userAgent'] as String? ?? '',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Palette.textFaint,
                    ),
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
