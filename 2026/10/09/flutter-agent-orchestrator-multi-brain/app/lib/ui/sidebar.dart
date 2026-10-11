import 'package:flutter/material.dart';

import '../console/console.dart';
import 'body_settings.dart';
import 'brain_settings.dart';
import 'theme.dart';

/// Left: this app, the brains (pick one to talk to; each with a new
/// conversation and its settings), and the bodies on the network.
class Sidebar extends StatelessWidget {
  const Sidebar({super.key, required this.console, required this.onToggleLog});

  final ConsoleMirror console;
  final VoidCallback onToggleLog;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 240,
      color: Palette.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 36),
          _ThisApp(console: console),
          Expanded(
            child: SingleChildScrollView(child: _BrainPicker(console: console)),
          ),
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

/// The brains: pick one to talk to. Each shows what its orchestrator runs
/// on, with a new conversation (↺) and its settings (the Brain step of its
/// start screen).
class _BrainPicker extends StatelessWidget {
  const _BrainPicker({required this.console});

  final ConsoleMirror console;

  @override
  Widget build(BuildContext context) {
    final brains = console.brains;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 0, 4, 4),
            child: Text(
              'Brains',
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
            for (final b in brains) _BrainRow(console: console, brain: b),
        ],
      ),
    );
  }
}

class _BrainRow extends StatelessWidget {
  const _BrainRow({required this.console, required this.brain});

  final ConsoleMirror console;
  final String brain;

  @override
  Widget build(BuildContext context) {
    final selected = brain == console.selected;
    final agent = console.brainAgentOf(brain);
    final error = agent['error'] as String?;
    final runsOn = [
      if (agent['label'] case final String l) l,
      if (agent['model'] case final String m) m,
      if (agent['effort'] case final String e) e,
    ].join(' · ');
    Widget icon(String key, String tip, IconData i, VoidCallback onPressed) =>
        IconButton(
          key: ValueKey('$key-$brain'),
          tooltip: tip,
          iconSize: 15,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
          padding: EdgeInsets.zero,
          onPressed: onPressed,
          icon: Icon(i, color: Palette.textDim),
        );
    return Material(
      color: selected ? Palette.surfaceHigh : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => console.select(brain),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 14,
                color: Palette.textDim,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            brain,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                        if (console.isLocalBrain(brain)) ...[
                          const SizedBox(width: 6),
                          const _Badge('this app'),
                        ],
                      ],
                    ),
                    if (runsOn.isNotEmpty || error != null)
                      Text(
                        error ?? runsOn,
                        key: ValueKey('brain-runs-on-$brain'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: error != null
                              ? Palette.warning
                              : Palette.textDim,
                        ),
                      ),
                  ],
                ),
              ),
              icon(
                'new-conversation',
                'New conversation (workers keep running)',
                Icons.restart_alt,
                () => _newConversation(context),
              ),
              icon('brain-settings', 'Settings of $brain', Icons.tune, () {
                showBrainSettings(
                  context,
                  brain: brain,
                  request: (m, [p = const {}]) =>
                      console.brainRequest(brain, m, p),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _newConversation(BuildContext context) async {
    if (console.hasConversation(brain)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Palette.surface,
          title: Text(
            'New conversation on $brain?',
            style: const TextStyle(fontSize: 15),
          ),
          content: const Text(
            'Its orchestrator starts over. Workers keep running.',
            style: TextStyle(fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('new-conversation-ok'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Start over'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    console.newConversationOn(brain);
  }
}

/// Every body on the network, in two groups: the selected brain's bodies,
/// and the others (other brains' and those of no brain). Each shows how many
/// brains it belongs to (one: its own; several: shared), what it runs and
/// how many at once, and "in use by" when another brain is using it; its
/// project folder, usage and brains on hover. Its brains are changed in its
/// settings (⚙).
class _Bodies extends StatelessWidget {
  const _Bodies({required this.console, required this.onToggleLog});

  final ConsoleMirror console;
  final VoidCallback onToggleLog;

  @override
  Widget build(BuildContext context) {
    final bodies = console.allBodies;
    final selected = console.selected;
    final mine = [
      for (final b in bodies)
        if (selected != null && b.owners.contains(selected)) b,
    ];
    final others = [
      for (final b in bodies)
        if (!mine.contains(b)) b,
    ];
    Widget heading(String text, {Widget? trailing}) => Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Text(
            text,
            style: const TextStyle(fontSize: 11, color: Palette.textFaint),
          ),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          heading(
            selected == null ? 'Bodies' : 'Bodies of $selected',
            trailing: IconButton(
              tooltip: 'Protocol log (this app)',
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              onPressed: onToggleLog,
              icon: const Icon(Icons.data_object, color: Palette.textFaint),
            ),
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
          if (mine.isEmpty)
            const Text(
              'None.',
              style: TextStyle(fontSize: 11, color: Palette.textDim),
            ),
          for (final b in mine) _BodyRow(console: console, body: b),
          if (others.isNotEmpty) ...[
            const SizedBox(height: 10),
            heading('Other bodies'),
            for (final b in others) _BodyRow(console: console, body: b),
          ],
        ],
      ),
    );
  }
}

class _BodyRow extends StatelessWidget {
  const _BodyRow({required this.console, required this.body});

  final ConsoleMirror console;
  final BodyEntry body;

  @override
  Widget build(BuildContext context) {
    final b = body;
    final v = b.view;
    final holder = v?.heldBy;
    final inUseByOther = holder != null && holder != console.selected;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Tooltip(
        message: [
          'belongs to ${b.owners.isEmpty ? 'no brain' : b.owners.join(', ')}',
          if (v != null) ...[v.projectDir, ...v.usage],
        ].join('\n'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 7,
                  color: b.node.online ? Palette.added : Palette.textFaint,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    '${b.name} (${b.owners.length})',
                    key: ValueKey('body-name-${b.name}'),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: b.name == console.selfName
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
                if (v?.paused ?? false) ...[
                  const SizedBox(width: 6),
                  const _Badge('paused', color: Palette.warning),
                ],
                const Spacer(),
                if (b.node.online && v != null)
                  _BodySettingsButton(console: console, body: b),
                if (console.canPause(b))
                  _PauseButton(console: console, body: b),
              ],
            ),
            if (b.node.online && v != null)
              Text(
                [
                  v.host,
                  v.workerTypes.isEmpty
                      ? 'no agents'
                      : v.workerTypes.map(v.labelOf).join(', '),
                  if (v.maxWorkers case final m?) '$m at once',
                ].join(' · '),
                style: const TextStyle(fontSize: 10.5, color: Palette.textDim),
              ),
            if (inUseByOther)
              Text(
                'in use by $holder',
                key: ValueKey('body-holder-${b.name}'),
                style: const TextStyle(fontSize: 10.5, color: Palette.warning),
              ),
            if (!b.node.online)
              const Text(
                'offline',
                style: TextStyle(fontSize: 10.5, color: Palette.textFaint),
              ),
          ],
        ),
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
          ? 'Resume: its brains may use it again'
          : 'Pause: its brains start nothing new here; what runs finishes',
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

/// Opens the body's settings (its brains and agents), only while it is
/// paused with no brain's workers there. A body of no brain cannot be paused
/// (no brain relays it) and runs nothing: its settings open any time, with
/// its brains only.
class _BodySettingsButton extends StatelessWidget {
  const _BodySettingsButton({required this.console, required this.body});

  final ConsoleMirror console;
  final BodyEntry body;

  @override
  Widget build(BuildContext context) {
    final unowned = body.owners.isEmpty;
    final relay = console.canPause(body);
    final paused = body.view!.paused;
    final holder = body.view!.heldBy;
    final ready =
        unowned || (relay && paused && holder == null && body.running == 0);
    return IconButton(
      key: ValueKey('body-settings-${body.name}'),
      tooltip: ready
          ? 'Settings of ${body.name}'
          : !relay
          ? 'Settings: none of its brains is linked to this console'
          : !paused
          ? 'Settings: pause it first'
          : 'Settings: wait for the workers of ${holder ?? 'its brain'} to finish',
      iconSize: 15,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
      padding: EdgeInsets.zero,
      onPressed: ready
          ? () => showBodySettings(
              context,
              body: body.name,
              owners: body.owners,
              brains: console.signal.brains,
              assign: (brains) => console.assign(body.name, brains),
              request: unowned
                  ? null
                  : (m, [p = const {}]) => console.bodyRequest(body, m, p),
            )
          : null,
      icon: Icon(
        Icons.tune,
        color: ready ? Palette.text : Palette.textFaint.withValues(alpha: 0.5),
      ),
    );
  }
}
