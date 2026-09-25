import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:realtime_core/realtime_core.dart';

import '../app/dependency_container.dart';
import '../app/exit.dart';
import 'widgets.dart';

/// Scripted run for measurements: ping every second, one move halfway, then
/// print a `REALTIME_RESULT {json}` line and optionally exit.
final class AutorunSpec {
  final Duration duration;
  final bool exitWhenDone;

  const AutorunSpec({required this.duration, required this.exitWhenDone});
}

class SessionPage extends StatefulWidget {
  final SessionMode mode;
  final SessionOptions options;
  final AutorunSpec? autorun;

  const SessionPage({
    super.key,
    required this.mode,
    required this.options,
    this.autorun,
  });

  @override
  State<SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<SessionPage> {
  SessionBundle? _bundle;
  String? _buildError;
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  bool _rendererReady = false;
  Timer? _autorunTimer;
  int _autorunTicks = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    await _renderer.initialize();
    _rendererReady = true;
    try {
      final bundle = await buildSession(widget.mode, widget.options);
      if (!mounted) {
        await bundle.dispose();
        return;
      }
      bundle.preview?.previewStream.addListener(_onPreview);
      setState(() => _bundle = bundle);
      await bundle.controller.start();
      _onPreview();
      if (widget.autorun != null) _startAutorun(bundle);
    } on MediaException catch (e) {
      _fail('${e.failure}');
    } catch (e) {
      _fail('$e');
    }
  }

  void _fail(String message) {
    if (mounted) setState(() => _buildError = message);
    if (widget.autorun != null) {
      _printResult({'error': message});
      if (widget.autorun!.exitWhenDone) exitApp();
    }
  }

  void _onPreview() {
    if (!_rendererReady) return;
    final stream = _bundle?.preview?.previewStream.value;
    if (_renderer.srcObject != stream) {
      _renderer.srcObject = stream;
      if (mounted) setState(() {});
    }
  }

  void _startAutorun(SessionBundle bundle) {
    final spec = widget.autorun!;
    final total = spec.duration.inSeconds;
    _autorunTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      _autorunTicks++;
      unawaited(bundle.controller.sendPing());
      if (_autorunTicks == total ~/ 2) {
        unawaited(bundle.controller.sendMove(0.1, -0.1));
      }
      if (_autorunTicks >= total) {
        timer.cancel();
        final metrics = bundle.controller.lastMetrics;
        _printResult({
          'sessionState': switch (bundle.controller.state) {
            SessionFailed(:final message) => 'failed: $message',
            final state => state.runtimeType.toString(),
          },
          'metrics': metrics?.toJson(),
          'diagnostics': bundle.diagnostics(),
          'renderer': {
            'videoWidth': _renderer.videoWidth,
            'videoHeight': _renderer.videoHeight,
          },
          'connectionState': bundle.connectionState?.value?.name,
        });
        await bundle.controller.stop();
        if (spec.exitWhenDone) exitApp();
      }
    });
  }

  void _printResult(Map<String, Object?> body) {
    final result = {
      'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
      'mode': widget.mode.key,
      'probe': widget.options.probe.name,
      'seconds': widget.autorun?.duration.inSeconds,
      ...body,
    };
    // debugPrint may throttle and split long lines; print keeps one line.
    // ignore: avoid_print
    print('REALTIME_RESULT ${jsonEncode(result)}');
    writeResultFile(jsonEncode(result));
    printResultChunks(jsonEncode(result));
  }

  @override
  void dispose() {
    _autorunTimer?.cancel();
    final bundle = _bundle;
    bundle?.preview?.previewStream.removeListener(_onPreview);
    _renderer.srcObject = null;
    unawaited(_renderer.dispose());
    if (bundle != null) unawaited(bundle.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bundle = _bundle;
    return Scaffold(
      appBar: AppBar(title: const Text('Session')),
      body: switch ((bundle, _buildError)) {
        (_, final String error) => Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Failed: $error'),
          ),
        ),
        (null, _) => const Center(child: CircularProgressIndicator()),
        (final SessionBundle b, _) => StreamBuilder<SessionState>(
          stream: b.controller.states,
          initialData: b.controller.state,
          builder: (context, snapshot) => _body(b, snapshot.data!),
        ),
      },
    );
  }

  Widget _body(SessionBundle bundle, SessionState state) {
    final metrics = switch (state) {
      SessionRunning(:final metrics) => metrics,
      _ => bundle.controller.lastMetrics,
    };
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth > 760;
        final preview = _preview(bundle);
        final details = _details(bundle, state, metrics);
        return wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 5, child: preview),
                  Expanded(flex: 4, child: details),
                ],
              )
            : ListView(
                children: [
                  SizedBox(height: 240, child: preview),
                  details,
                ],
              );
      },
    );
  }

  Widget _preview(SessionBundle bundle) {
    if (bundle.preview == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: Text('No preview (mock media)')),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ColoredBox(
          color: Colors.black,
          child: RTCVideoView(
            _renderer,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
          ),
        ),
      ),
    );
  }

  Widget _details(SessionBundle bundle, SessionState state, SessionMetrics? m) {
    final controller = bundle.controller;
    final stateLabel = switch (state) {
      SessionIdle() => 'Stopped',
      SessionStarting() => 'Starting…',
      SessionRunning() => 'Running',
      SessionStopping() => 'Stopping…',
      SessionFailed(:final message) => 'Failed: $message',
    };
    final running = state is SessionRunning;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Section('Mode', [
            Text(bundle.mode.label),
            Text('Session: $stateLabel'),
            if (bundle.connectionState != null)
              ValueListenableBuilder(
                valueListenable: bundle.connectionState!,
                builder: (context, s, _) =>
                    Text('PeerConnection: ${s?.name ?? '-'}'),
              ),
            StatusDot(
              on: m?.transportConnected ?? false,
              label: 'Action transport (${m?.transportKind ?? '-'})',
            ),
          ]),
          if (m != null) ...[
            Section('Video', [
              StatusDot(on: m.videoActive, label: 'Active'),
              Text('${m.videoWidth ?? '-'} × ${m.videoHeight ?? '-'}'),
              Text(
                '${fmt(m.videoFps)} fps (pipeline) / '
                '${fmt(m.stats?.videoFps)} fps (stats)',
              ),
              Text('Last frame #${m.lastFrameSequence ?? '-'}'),
            ]),
            Section('Audio', [
              StatusDot(on: m.audioActive, label: 'Active'),
              LevelBar(level: m.audioLevel ?? 0),
            ]),
            Section('Processing', [
              Text(
                'Events/sec: in ${fmt(m.inputEventsPerSecond)} · '
                'processed ${fmt(m.processedEventsPerSecond)}',
              ),
              Text(
                'Dropped: video ${m.droppedVideoFrames} · '
                'audio ${m.droppedAudioEvents}',
              ),
              Text(
                'Latency: last ${ms(m.lastLatency)} · avg '
                '${ms(m.averageLatency)} · max ${ms(m.maxLatency)}',
              ),
              Text('Last result: ${m.lastResult ?? '-'}'),
            ]),
            Section('Action transport', [
              Text('Sent: ${m.actionsSent} · Received: ${m.actionsReceived}'),
              Text('Send errors: ${m.sendErrors}'),
              Text('RTT: ${ms(m.lastRoundTrip)}'),
              Text(
                'Last action: ${m.lastAction == null ? '-' : jsonEncode(m.lastAction)}',
              ),
              if (m.lastError != null) Text('Last error: ${m.lastError}'),
            ]),
            if (m.stats != null)
              Section('WebRTC stats', [
                Text(
                  'RTT ${fmt(m.stats!.roundTripTime, 4)} s · jitter '
                  '${fmt(m.stats!.jitter, 4)} s · lost ${m.stats!.packetsLost ?? '-'}',
                ),
                Text(
                  'bitrate ${fmt(m.stats!.bitrateKbps)} kbps · decoded '
                  '${m.stats!.framesDecoded ?? '-'} · dropped '
                  '${m.stats!.framesDropped ?? '-'}',
                ),
              ]),
          ],
          if (bundle.operationApi != null)
            Section('Local operation API', [
              StreamBuilder(
                stream: bundle.operationApi!.changes,
                initialData: bundle.operationApi!.state,
                builder: (context, s) => OperationApiView(state: s.data!),
              ),
            ]),
          if (bundle.remoteResponder != null)
            Section('Peer A (DataChannel far end)', [
              StreamBuilder(
                stream: bundle.remoteResponder!.changes,
                builder: (context, _) {
                  final r = bundle.remoteResponder!;
                  return Text(
                    'Received ${r.received} · pongs ${r.pongsSent}\n'
                    '${jsonEncode(r.countsByType)}\n'
                    'Last: ${jsonEncode(r.lastAction)}',
                  );
                },
              ),
            ]),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: running ? controller.sendPing : null,
                child: const Text('Send Ping'),
              ),
              FilledButton(
                onPressed: running
                    ? () => controller.sendMove(0.1, -0.1)
                    : null,
                child: const Text('Test Move'),
              ),
              OutlinedButton(
                onPressed: running && m != null
                    ? () => controller.setTrackEnabled(
                        MediaKind.audio,
                        !m.audioEnabled,
                      )
                    : null,
                child: Text(
                  m?.audioEnabled ?? true ? 'Mute Mic' : 'Unmute Mic',
                ),
              ),
              OutlinedButton(
                onPressed: running && m != null
                    ? () => controller.setTrackEnabled(
                        MediaKind.video,
                        !m.videoEnabled,
                      )
                    : null,
                child: Text(
                  m?.videoEnabled ?? true ? 'Disable Camera' : 'Enable Camera',
                ),
              ),
              OutlinedButton(
                onPressed: running ? controller.stop : null,
                child: const Text('Stop'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
