import 'dart:async';

import 'package:flutter/material.dart';

import '../agents/agent_thread.dart';
import '../console/console.dart';
import 'theme.dart';

/// Every worker with its status; running ones first. Click to open its
/// transcript, the square to stop it.
class WorkersPanel extends StatefulWidget {
  const WorkersPanel({super.key, required this.console});

  final ConsoleMirror console;

  @override
  State<WorkersPanel> createState() => _WorkersPanelState();
}

class _WorkersPanelState extends State<WorkersPanel> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Elapsed times.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  static int _rank(AgentState s) => switch (s) {
    AgentState.running => 0,
    AgentState.queued => 1,
    _ => 2,
  };

  @override
  Widget build(BuildContext context) {
    final console = widget.console;
    final workers = [...console.workers]
      ..sort((a, b) {
        final r = _rank(a.state).compareTo(_rank(b.state));
        return r != 0 ? r : b.createdAt.compareTo(a.createdAt);
      });
    final queued = console.workers
        .where((w) => w.state == AgentState.queued)
        .length;
    return Container(
      color: Palette.sidebar,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 36),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 12, 8),
            child: Row(
              children: [
                const Text(
                  'Workers',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(
                  '${console.runningCount} running'
                  '${queued > 0 ? ' · $queued queued' : ''}'
                  ' · ${console.settings.maxConcurrent}/body',
                  style: const TextStyle(fontSize: 11, color: Palette.textDim),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: workers.isEmpty
                ? const Center(
                    child: Text(
                      'No workers yet.\nThe orchestrator starts them.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: Palette.textFaint),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.all(8),
                    children: [
                      for (final w in workers) _WorkerTile(console: console, worker: w),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _WorkerTile extends StatelessWidget {
  const _WorkerTile({required this.console, required this.worker});

  final ConsoleMirror console;
  final ThreadMirror worker;

  @override
  Widget build(BuildContext context) {
    final w = worker;
    final selected = console.viewing == w;
    final busy = w.state == AgentState.running || w.state == AgentState.queued;
    return Material(
      color: selected ? Palette.surfaceHigh : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => console.view(selected ? null : w),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
          child: Row(
            children: [
              _StateIcon(state: w.state),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      w.title ?? w.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${w.label} · ${w.body} · ${w.provider.label}${w.model != null ? ' · ${w.model}' : ''} · ${_stateText(w)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Palette.textFaint,
                      ),
                    ),
                  ],
                ),
              ),
              if (busy)
                IconButton(
                  tooltip: w.state == AgentState.queued
                      ? 'Remove from the queue'
                      : 'Stop',
                  iconSize: 16,
                  onPressed: () => console.stopWorker(w),
                  icon: const Icon(
                    Icons.stop_circle_outlined,
                    color: Palette.textDim,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _stateText(ThreadMirror w) {
    final start = w.turnStartedAt;
    String fmt(Duration d) => d.inMinutes > 0
        ? '${d.inMinutes}m ${d.inSeconds % 60}s'
        : '${d.inSeconds}s';
    return switch (w.state) {
      AgentState.running when start != null =>
        'running ${fmt(DateTime.now().difference(start))}',
      AgentState.idle when start != null && w.finishedAt != null =>
        'done in ${fmt(w.finishedAt!.difference(start))}',
      final s => s.name,
    };
  }
}

class _StateIcon extends StatelessWidget {
  const _StateIcon({required this.state});

  final AgentState state;

  @override
  Widget build(BuildContext context) {
    if (state == AgentState.running) {
      return const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 1.5,
          color: Palette.textDim,
        ),
      );
    }
    final (icon, color) = switch (state) {
      AgentState.queued => (Icons.schedule, Palette.textDim),
      AgentState.idle => (Icons.check_circle_outline, Palette.added),
      AgentState.failed => (Icons.error_outline, Palette.removed),
      AgentState.interrupted => (Icons.pause_circle_outline, Palette.warning),
      _ => (Icons.remove_circle_outline, Palette.textFaint),
    };
    return Icon(icon, size: 14, color: color);
  }
}
