import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../console/console.dart';
import '../orchestrator/hub.dart' show HubSettings;
import '../state/thread_view.dart' show Json;
import 'body_settings.dart';
import 'theme.dart';

/// Left: this app, the orchestrator's worker type, new conversation, project,
/// settings, and the bodies connected to the brain.
class Sidebar extends StatelessWidget {
  const Sidebar({super.key, required this.console, required this.onToggleLog});

  final ConsoleMirror console;
  final VoidCallback onToggleLog;

  @override
  Widget build(BuildContext context) {
    final current =
        console.orchestrator?.workerType ?? console.settings.orchestrator;
    // The brain's own worker types; the current one stays listed even if it
    // stopped being available.
    final types = {...console.workerTypes, current}.toList();
    return Container(
      width: 240,
      color: Palette.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 36),
          _ThisApp(console: console),
          _BrainPicker(console: console),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
            child: Text(
              'Orchestrator',
              style: const TextStyle(fontSize: 11, color: Palette.textFaint),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: types.length > 3
                ? DropdownButton<String>(
                    key: const Key('orchestrator-type'),
                    value: current,
                    isExpanded: true,
                    dropdownColor: Palette.surfaceHigh,
                    items: [
                      for (final t in types)
                        DropdownMenuItem(
                          value: t,
                          enabled: console.workerTypes.contains(t),
                          child: Text(
                            console.labelOf(t),
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                    ],
                    onChanged: (t) async {
                      if (t == null || t == current) return;
                      if (console.orchestrator != null &&
                          !await _confirmSwitch(context, t)) {
                        return;
                      }
                      await console.newConversation(workerType: t);
                    },
                  )
                : SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: [
                      for (final t in types)
                        ButtonSegment(
                          value: t,
                          label: Text(
                            console.labelOf(t),
                            overflow: TextOverflow.ellipsis,
                          ),
                          enabled: console.workerTypes.contains(t),
                        ),
                    ],
                    selected: {current},
                    onSelectionChanged: (s) async {
                      if (s.first == current) return;
                      if (console.orchestrator != null &&
                          !await _confirmSwitch(context, s.first)) {
                        return;
                      }
                      await console.newConversation(workerType: s.first);
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
            tooltip: console.selectedIsSelf
                ? console.projectDir
                : '${console.projectDir} (on ${console.brain}; pick it on the brain)',
            onTap: () async {
              // The path is on the brain's machine.
              if (!console.selectedIsSelf) return;
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

  Future<bool> _confirmSwitch(BuildContext context, String type) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: Palette.surface,
            title: Text(
              'Switch the orchestrator to ${console.labelOf(type)}?',
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
              _Badge(console.roles),
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
  const _Badge(this.text, {this.color = Palette.textDim});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: color == Palette.textDim ? Palette.border : color,
        ),
      ),
      child: Text(text, style: TextStyle(fontSize: 10, color: color)),
    );
  }
}

/// Which brain this console shows and talks to.
class _BrainPicker extends StatelessWidget {
  const _BrainPicker({required this.console});

  final ConsoleMirror console;

  @override
  Widget build(BuildContext context) {
    final brains = console.brains;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 0, 4, 4),
            child: Text(
              'Brain',
              style: TextStyle(fontSize: 11, color: Palette.textFaint),
            ),
          ),
          if (brains.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'No brain online.',
                style: TextStyle(fontSize: 12, color: Palette.textDim),
              ),
            )
          else
            for (final b in brains)
              Material(
                color: b == console.selected
                    ? Palette.surfaceHigh
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => console.select(b),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          b == console.selected
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          size: 14,
                          color: Palette.textDim,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            b,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                        if (b == console.selfName) const _Badge('this app'),
                      ],
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// Every body on the network: the brain that owns it (a menu moves it to
/// another brain, refused while its workers run), what it runs and how many
/// at once; its project folder and subscription usage on hover.
class _Bodies extends StatelessWidget {
  const _Bodies({required this.console, required this.onToggleLog});

  final ConsoleMirror console;
  final VoidCallback onToggleLog;

  @override
  Widget build(BuildContext context) {
    final bodies = console.allBodies;
    final brains = [
      for (final n in console.signal.nodes)
        if (n.brain && n.online) n.name,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Bodies · ${bodies.where((b) => b.node.online).length}',
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
              console.link,
              style: const TextStyle(fontSize: 11, color: Palette.textDim),
            ),
          if (console.notice case final n?)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                n,
                style: const TextStyle(fontSize: 11, color: Palette.warning),
              ),
            ),
          for (final b in bodies)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Tooltip(
                message: [
                  if (b.view case final v?) ...[v.projectDir, ...v.usage],
                ].join('\n'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.circle,
                          size: 7,
                          color: b.node.online
                              ? Palette.added
                              : Palette.textFaint,
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
                        if (b.node.brain) ...[
                          const SizedBox(width: 6),
                          const _Badge('brain'),
                        ],
                        if (b.view?.paused ?? false) ...[
                          const SizedBox(width: 6),
                          const _Badge('paused', color: Palette.warning),
                        ],
                        const Spacer(),
                        if (console.canPause(b)) ...[
                          _BodySettingsButton(console: console, body: b),
                          _PauseButton(console: console, body: b),
                        ],
                      ],
                    ),
                    _OwnerMenu(console: console, body: b, brains: brains),
                    if (b.node.online && b.view != null)
                      Text(
                        [
                          b.view!.host,
                          b.view!.workerTypes.isEmpty
                              ? 'no agents'
                              : b.view!.workerTypes
                                    .map(b.view!.labelOf)
                                    .join(', '),
                          if (b.view!.maxWorkers case final m?) '$m at once',
                        ].join(' · '),
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: Palette.textDim,
                        ),
                      ),
                    if (!b.node.online)
                      const Text(
                        'offline',
                        style: TextStyle(
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

/// Pauses the body for its brain (nothing new starts there; what runs
/// finishes) or resumes it. The connection stays.
class _PauseButton extends StatelessWidget {
  const _PauseButton({required this.console, required this.body});

  final ConsoleMirror console;
  final BodyEntry body;

  @override
  Widget build(BuildContext context) {
    final paused = body.view!.paused;
    return IconButton(
      key: ValueKey('pause-${body.name}'),
      tooltip: paused
          ? 'Resume: ${body.owner} may use it again'
          : 'Pause: ${body.owner} starts nothing new here; what runs finishes',
      iconSize: 15,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
      padding: EdgeInsets.zero,
      onPressed: () => console.setPaused(body, !paused),
      icon: Icon(
        paused ? Icons.play_arrow : Icons.pause,
        color: paused ? Palette.warning : Palette.textFaint,
      ),
    );
  }
}

/// Opens the body's agents (the editor of its start screen), only while it
/// is paused with no workers of its brain running or waiting there: saving
/// restarts its agents.
class _BodySettingsButton extends StatelessWidget {
  const _BodySettingsButton({required this.console, required this.body});

  final ConsoleMirror console;
  final BodyEntry body;

  @override
  Widget build(BuildContext context) {
    final paused = body.view!.paused;
    final ready = paused && body.running == 0;
    return IconButton(
      key: ValueKey('body-settings-${body.name}'),
      tooltip: !paused
          ? 'Change its agents: pause it first'
          : body.running > 0
          ? 'Change its agents: wait for its ${body.running} worker(s) to finish'
          : 'Change its agents',
      iconSize: 15,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
      padding: EdgeInsets.zero,
      onPressed: ready
          ? () => showBodySettings(
              context,
              body: body.name,
              isBrain: body.node.brain,
              request: (m, [p = const {}]) => console.bodyRequest(body, m, p),
            )
          : null,
      icon: Icon(
        Icons.tune,
        color: ready ? Palette.text : Palette.textFaint.withValues(alpha: 0.5),
      ),
    );
  }
}

/// "→ brain-a · 1 running"; a menu of brains to move the body to.
class _OwnerMenu extends StatelessWidget {
  const _OwnerMenu({
    required this.console,
    required this.body,
    required this.brains,
  });

  final ConsoleMirror console;
  final BodyEntry body;
  final List<String> brains;

  @override
  Widget build(BuildContext context) {
    final busy = body.running > 0;
    final label =
        '→ ${body.owner ?? 'no brain'}${busy ? ' · ${body.running} running' : ''}';
    return PopupMenuButton<String>(
      tooltip: busy
          ? 'Its workers are running; it can move when they finish'
          : 'Move to another brain',
      enabled: !busy && console.connected,
      color: Palette.surfaceHigh,
      onSelected: (v) => console.assign(body.name, v.isEmpty ? null : v),
      itemBuilder: (_) => [
        for (final b in brains)
          CheckedPopupMenuItem(
            value: b,
            checked: b == body.owner,
            child: Text(b, style: const TextStyle(fontSize: 13)),
          ),
        CheckedPopupMenuItem(
          value: '',
          checked: body.owner == null,
          child: const Text('No brain', style: TextStyle(fontSize: 13)),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: body.owner == null ? Palette.warning : Palette.text,
                ),
              ),
            ),
            if (!busy)
              const Icon(
                Icons.arrow_drop_down,
                size: 14,
                color: Palette.textFaint,
              ),
          ],
        ),
      ),
    );
  }
}

/// The selected brain's settings: what its orchestrator runs on (worker type,
/// model, effort; for new conversations) and whether a finished worker wakes
/// it. What a body runs, its folders and how many workers at once are that
/// body's own (its start screen).
Future<void> showSettings(BuildContext context, ConsoleMirror console) async {
  // Edit a copy; the brain saves it and sends it back to every console.
  final s = HubSettings()..load(console.settings.toJson());
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final types = {...console.workerTypes, s.orchestrator}.toList();
        final models = console.ready
            ? console.modelsFor(s.orchestrator)
            : const <Json>[];
        final model =
            models.where((m) => m['id'] == s.orchestratorModel).firstOrNull ??
            models.where((m) => m['isDefault'] == true).firstOrNull ??
            models.firstOrNull;
        final efforts = [
          for (final e
              in (model?['supportedEffortLevels'] as List? ?? const []))
            '$e',
        ];
        Widget row(String label, Widget field) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(label, style: const TextStyle(fontSize: 13)),
              ),
              field,
            ],
          ),
        );
        DropdownButton<String?> pick(
          String key,
          String? value,
          List<(String?, String)> items,
          void Function(String?) onChanged,
        ) => DropdownButton<String?>(
          key: Key(key),
          value: items.any((e) => e.$1 == value) ? value : null,
          isDense: true,
          dropdownColor: Palette.surfaceHigh,
          items: [
            for (final (v, l) in items)
              DropdownMenuItem(
                value: v,
                child: Text(l, style: const TextStyle(fontSize: 13)),
              ),
          ],
          onChanged: (v) => setState(() => onChanged(v)),
        );
        return AlertDialog(
          backgroundColor: Palette.surface,
          title: Text(
            'Settings of ${console.brain}',
            style: const TextStyle(fontSize: 15),
          ),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Orchestrator (new conversations)',
                  style: TextStyle(fontSize: 11, color: Palette.textFaint),
                ),
                row(
                  'Runs on',
                  pick(
                    'settings-type',
                    s.orchestrator,
                    [for (final t in types) (t, console.labelOf(t))],
                    (v) {
                      s.orchestrator = v ?? s.orchestrator;
                      s.orchestratorModel = null;
                      s.orchestratorEffort = null;
                    },
                  ),
                ),
                row(
                  'Model',
                  pick(
                    'settings-model',
                    s.orchestratorModel,
                    [
                      (null, 'Default'),
                      for (final m in models)
                        (m['id'] as String, '${m['displayName'] ?? m['id']}'),
                    ],
                    (v) {
                      s.orchestratorModel = v;
                      s.orchestratorEffort = null;
                    },
                  ),
                ),
                if (efforts.isNotEmpty)
                  row(
                    'Effort',
                    pick('settings-effort', s.orchestratorEffort, [
                      (null, 'Default'),
                      for (final e in efforts) (e, e),
                    ], (v) => s.orchestratorEffort = v),
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
                Text(
                  'What each body runs (agents, their models and folders, tools) and how many workers at once '
                  'are set on that body\'s start screen.',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Palette.textFaint,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('settings-save'),
              onPressed: () {
                console.saveSettings(s);
                Navigator.pop(context);
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    ),
  );
}
