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
    // Group threads by project (cwd), like the Codex app.
    final groups = <String, List<ThreadSummary>>{};
    for (final t in app.threads) {
      groups.putIfAbsent(t.cwd, () => []).add(t);
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
                for (final entry in groups.entries) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.folder_outlined,
                          size: 13,
                          color: Palette.textFaint,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _basename(entry.key),
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Palette.textDim,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  for (final t in entry.value) _ThreadTile(app: app, thread: t),
                ],
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
                  if (v == 'archive') app.archive(thread);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'archive', child: Text('Archive')),
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
