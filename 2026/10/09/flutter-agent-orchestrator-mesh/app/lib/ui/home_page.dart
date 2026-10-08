import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../agents/agent_thread.dart';
import '../console/console.dart';
import 'approvals.dart';
import 'composer.dart';
import 'sidebar.dart';
import 'theme.dart';
import 'transcript.dart';
import 'workers_panel.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.console});

  final ConsoleMirror console;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _showLog = false;

  @override
  void initState() {
    super.initState();
    // For unattended checks: ORCH_PROMPT goes to the orchestrator on start.
    final prompt = Platform.environment['ORCH_PROMPT'];
    if (prompt != null && prompt.isNotEmpty) {
      Future<void> waitAndSend() async {
        while (!widget.console.ready && widget.console.startupError == null) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        if (widget.console.ready) {
          await widget.console.sendToOrchestrator(prompt);
        }
      }

      unawaited(waitAndSend());
    }
  }

  @override
  Widget build(BuildContext context) {
    final console = widget.console;
    return ListenableBuilder(
      listenable: console,
      builder: (context, _) {
        final shown = console.viewing ?? console.orchestrator;
        final viewingWorker = console.viewing != null;
        return Scaffold(
          body: Row(
            children: [
              Sidebar(
                console: console,
                onToggleLog: () => setState(() => _showLog = !_showLog),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  children: [
                    _Header(
                      console: console,
                      shown: shown,
                      viewingWorker: viewingWorker,
                    ),
                    Expanded(
                      child: shown == null
                          ? _Empty(console: console)
                          : Transcript(key: ValueKey(shown), view: shown.view),
                    ),
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 808),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 0, 24, 18),
                          child: viewingWorker
                              ? _WorkerFooter(
                                  console: console,
                                  worker: console.viewing!,
                                )
                              : Column(
                                  children: [
                                    if (console.orchestrator case final o?)
                                      ListenableBuilder(
                                        listenable: o.view,
                                        builder: (context, _) => Column(
                                          children: [
                                            for (final r in o.view.pending)
                                              PendingRequestCard(
                                                app: console,
                                                request: r,
                                              ),
                                          ],
                                        ),
                                      ),
                                    Composer(console: console),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const VerticalDivider(width: 1),
              SizedBox(width: 300, child: WorkersPanel(console: console)),
              if (_showLog) ...[
                const VerticalDivider(width: 1),
                SizedBox(width: 420, child: _ProtocolLog(console: console)),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.console,
    required this.shown,
    required this.viewingWorker,
  });

  final ConsoleMirror console;
  final ThreadMirror? shown;
  final bool viewingWorker;

  @override
  Widget build(BuildContext context) {
    final s = shown;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Palette.border)),
      ),
      child: Row(
        children: [
          if (viewingWorker)
            TextButton.icon(
              onPressed: () => console.view(null),
              icon: const Icon(Icons.arrow_back, size: 14),
              label: const Text('Orchestrator', style: TextStyle(fontSize: 12)),
            ),
          const SizedBox(width: 8),
          if (s != null) ...[
            Flexible(
              child: Text(
                viewingWorker
                    ? '${s.label} · ${s.title ?? ''}'
                    : 'Orchestrator · ${s.provider.label}',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${s.body} · ${s.model ?? ''} · ${s.cwd}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Palette.textFaint),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Workers are driven by the orchestrator; the user can watch and stop them.
class _WorkerFooter extends StatelessWidget {
  const _WorkerFooter({required this.console, required this.worker});

  final ConsoleMirror console;
  final ThreadMirror worker;

  @override
  Widget build(BuildContext context) {
    final busy =
        worker.state == AgentState.running || worker.state == AgentState.queued;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Palette.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Palette.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${worker.label} is run by the orchestrator (${worker.state.name}). '
              'Talk to the orchestrator to change what it does.',
              style: const TextStyle(fontSize: 12, color: Palette.textDim),
            ),
          ),
          if (busy)
            OutlinedButton.icon(
              onPressed: () => console.stopWorker(worker),
              icon: const Icon(Icons.stop_rounded, size: 16),
              label: const Text('Stop'),
            ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.console});

  final ConsoleMirror console;

  @override
  Widget build(BuildContext context) {
    final name =
        console.projectDir.split('/').where((p) => p.isNotEmpty).lastOrNull ??
        '/';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.hub_outlined, size: 40, color: Palette.textDim),
          const SizedBox(height: 12),
          const Text(
            'What should the agents do?',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            '$name · orchestrator: ${console.settings.orchestrator.label}',
            style: const TextStyle(fontSize: 14, color: Palette.textDim),
          ),
        ],
      ),
    );
  }
}

class _ProtocolLog extends StatefulWidget {
  const _ProtocolLog({required this.console});

  final ConsoleMirror console;

  @override
  State<_ProtocolLog> createState() => _ProtocolLogState();
}

class _ProtocolLogState extends State<_ProtocolLog> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final log = widget.console.protocolLog;
    return Container(
      color: Palette.sidebar,
      child: ListView.builder(
        reverse: true,
        padding: const EdgeInsets.all(8),
        itemCount: log.length,
        itemBuilder: (context, i) {
          final e = log[log.length - 1 - i];
          final line = e.line.length > 400
              ? '${e.line.substring(0, 400)}…'
              : e.line;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              '${e.source} ${e.outgoing ? '→' : '←'} $line',
              style: TextStyle(
                fontFamily: monoFamily,
                fontSize: 10.5,
                color: e.outgoing ? Palette.added : Palette.textDim,
              ),
            ),
          );
        },
      ),
    );
  }
}
