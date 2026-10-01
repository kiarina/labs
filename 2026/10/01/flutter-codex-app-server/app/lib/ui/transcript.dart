import 'package:flutter/material.dart';

import '../state/thread_view.dart';
import 'items.dart';
import 'theme.dart';

class Transcript extends StatefulWidget {
  const Transcript({super.key, required this.view});

  final ThreadView view;

  @override
  State<Transcript> createState() => _TranscriptState();
}

class _TranscriptState extends State<Transcript> {
  final _scroll = ScrollController();
  bool _stickToBottom = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      _stickToBottom = pos.pixels >= pos.maxScrollExtent - 48;
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _followBottom() {
    if (!_stickToBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.view,
      builder: (context, _) {
        _followBottom();
        final view = widget.view;
        return CwdScope(
          cwd: view.cwd,
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
            itemCount: view.turns.length + 1,
            itemBuilder: (context, i) {
              if (i == view.turns.length) {
                return _Center(child: _Footer(view: view));
              }
              return _Center(child: _TurnWidget(turn: view.turns[i]));
            },
          ),
        );
      },
    );
  }
}

class _Center extends StatelessWidget {
  const _Center({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: child,
      ),
    );
  }
}

class _TurnWidget extends StatelessWidget {
  const _TurnWidget({required this.turn});

  final TurnState turn;

  @override
  Widget build(BuildContext context) {
    final running = turn.status == 'inProgress';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in turn.items)
          ItemWidget(key: ValueKey(item.id), item: item),
        if (turn.plan.isNotEmpty) _Plan(plan: turn.plan),
        if (running &&
            (turn.items.isEmpty || turn.items.every((i) => i.completed)))
          const _Working(),
        if (turn.error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              turn.error!,
              style: const TextStyle(color: Palette.removed, fontSize: 13),
            ),
          ),
        if (turn.status == 'interrupted')
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text(
              'Interrupted',
              style: TextStyle(color: Palette.textFaint, fontSize: 12),
            ),
          ),
        if (!running && turn.durationMs != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 14),
            child: Row(
              children: [
                Text(
                  'Worked for ${_duration(turn.durationMs!)}',
                  style: const TextStyle(
                    color: Palette.textFaint,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(width: 8),
                const Expanded(child: Divider(height: 1)),
              ],
            ),
          ),
      ],
    );
  }

  static String _duration(int ms) {
    final s = ms ~/ 1000;
    if (s < 60) return '${s}s';
    return '${s ~/ 60}m ${s % 60}s';
  }
}

class _Working extends StatelessWidget {
  const _Working();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: Palette.textDim,
            ),
          ),
          SizedBox(width: 8),
          Text(
            'Working…',
            style: TextStyle(color: Palette.textDim, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _Plan extends StatelessWidget {
  const _Plan({required this.plan});

  final List<Json> plan;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Palette.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Plan',
            style: TextStyle(fontSize: 12, color: Palette.textDim),
          ),
          const SizedBox(height: 6),
          for (final step in plan)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    switch (step['status']) {
                      'completed' => Icons.check_circle,
                      'inProgress' => Icons.radio_button_checked,
                      _ => Icons.radio_button_unchecked,
                    },
                    size: 14,
                    color: step['status'] == 'completed'
                        ? Palette.added
                        : Palette.textDim,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      step['step'] as String,
                      style: TextStyle(
                        fontSize: 13,
                        color: step['status'] == 'completed'
                            ? Palette.textFaint
                            : Palette.text,
                        decoration: step['status'] == 'completed'
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.view});

  final ThreadView view;

  @override
  Widget build(BuildContext context) {
    final diff = view.turns.isEmpty ? '' : view.turns.last.diff;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final e in view.errors.reversed.take(3))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              e,
              style: const TextStyle(color: Palette.warning, fontSize: 12),
            ),
          ),
        if (diff.isNotEmpty && !view.isRunning) _TurnDiff(diff: diff),
      ],
    );
  }
}

/// The aggregated diff of the last turn (`turn/diff/updated`), like the
/// Codex app's "N files changed" card.
class _TurnDiff extends StatefulWidget {
  const _TurnDiff({required this.diff});

  final String diff;

  @override
  State<_TurnDiff> createState() => _TurnDiffState();
}

class _TurnDiffState extends State<_TurnDiff> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final files = RegExp(
      r'^diff --git ',
      multiLine: true,
    ).allMatches(widget.diff).length;
    return Container(
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  const Icon(
                    Icons.difference_outlined,
                    size: 16,
                    color: Palette.textDim,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${files == 0 ? 1 : files} file${files == 1 ? '' : 's'} changed',
                    style: const TextStyle(fontSize: 13),
                  ),
                  const Spacer(),
                  Icon(
                    _open ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: Palette.textFaint,
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: DiffView(diff: widget.diff, maxHeight: 480),
            ),
        ],
      ),
    );
  }
}
