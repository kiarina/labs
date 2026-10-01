import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import 'approvals.dart';
import 'composer.dart';
import 'sidebar.dart';
import 'theme.dart';
import 'transcript.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.app});

  final AppController app;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _showLog = false;

  @override
  void initState() {
    super.initState();
    // For unattended checks: CODEX_FLUTTER_PROMPT sends one message once the
    // models are loaded.
    final prompt = Platform.environment['CODEX_FLUTTER_PROMPT'];
    if (prompt != null && prompt.isNotEmpty) {
      Future<void> waitAndSend() async {
        while (widget.app.model == null && widget.app.startupError == null) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        if (widget.app.startupError == null) await widget.app.send(prompt);
      }

      unawaited(waitAndSend());
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final view = app.current;
        return Scaffold(
          body: Row(
            children: [
              Sidebar(
                app: app,
                onToggleLog: () => setState(() => _showLog = !_showLog),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Column(
                  children: [
                    _Header(app: app),
                    if (app.startupError != null)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: SelectableText(
                          app.startupError!,
                          style: const TextStyle(
                            color: Palette.removed,
                            fontFamily: monoFamily,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    Expanded(
                      child: view == null
                          ? _Empty(app: app)
                          : Transcript(
                              key: ValueKey(view.threadId),
                              view: view,
                            ),
                    ),
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 808),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 0, 24, 18),
                          child: view == null
                              ? Composer(app: app)
                              : ListenableBuilder(
                                  listenable: view,
                                  builder: (context, _) => Column(
                                    children: [
                                      for (final r in view.pending)
                                        PendingRequestCard(
                                          app: app,
                                          request: r,
                                        ),
                                      Composer(app: app),
                                    ],
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_showLog) ...[
                const VerticalDivider(width: 1),
                SizedBox(width: 420, child: _ProtocolLog(app: app)),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final view = app.current;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      alignment: Alignment.centerLeft,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Palette.border)),
      ),
      child: view == null
          ? const SizedBox.shrink()
          : ListenableBuilder(
              listenable: view,
              builder: (context, _) => Row(
                children: [
                  Flexible(
                    child: Text(
                      view.title ??
                          app.threads
                              .where((t) => t.id == view.threadId)
                              .firstOrNull
                              ?.title ??
                          'New thread',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    view.cwd,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Palette.textFaint,
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    final name =
        app.projectDir.split('/').where((p) => p.isNotEmpty).lastOrNull ?? '/';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.blur_on, size: 40, color: Palette.textDim),
          const SizedBox(height: 12),
          const Text(
            "Let's build",
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            name,
            style: const TextStyle(fontSize: 22, color: Palette.textDim),
          ),
        ],
      ),
    );
  }
}

class _ProtocolLog extends StatefulWidget {
  const _ProtocolLog({required this.app});

  final AppController app;

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
    final log = widget.app.protocolLog;
    return Container(
      color: Palette.sidebar,
      child: ListView.builder(
        reverse: true,
        padding: const EdgeInsets.all(8),
        itemCount: log.length,
        itemBuilder: (context, i) {
          final e = log[log.length - 1 - i];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              '${e.outgoing ? '→' : '←'} ${e.line.length > 400 ? '${e.line.substring(0, 400)}…' : e.line}',
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
