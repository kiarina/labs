import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:realtime_core/realtime_core.dart';

import '../app/dependency_container.dart';
import '../app/exit.dart';
import 'session_page.dart' show AutorunSpec;
import 'widgets.dart';

/// Second device of the two-device WebRTC test: publishes camera and mic and
/// answers actions that the viewer's pipeline sends over the DataChannel.
class PublisherPage extends StatefulWidget {
  final SessionOptions options;
  final AutorunSpec? autorun;

  const PublisherPage({super.key, required this.options, this.autorun});

  @override
  State<PublisherPage> createState() => _PublisherPageState();
}

class _PublisherPageState extends State<PublisherPage> {
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  PublisherBundle? _bundle;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    await _renderer.initialize();
    try {
      final bundle = await PublisherBundle.start(widget.options);
      if (!mounted) {
        await bundle.dispose();
        return;
      }
      _renderer.srcObject = bundle.stream;
      setState(() => _bundle = bundle);
      final autorun = widget.autorun;
      if (autorun != null) {
        Timer(autorun.duration, () {
          final json = jsonEncode({
            'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
            'mode': 'publisher',
            'seconds': autorun.duration.inSeconds,
            'connectionState': bundle.peer.connectionState.value?.name,
            'responder': bundle.responder.toJson(),
          });
          // ignore: avoid_print
          print('REALTIME_RESULT $json');
          writeResultFile(json);
          printResultChunks(json);
          if (autorun.exitWhenDone) exitApp();
        });
      }
    } on MediaException catch (e) {
      setState(() => _error = '${e.failure}');
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _renderer.srcObject = null;
    unawaited(_renderer.dispose());
    unawaited(_bundle?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bundle = _bundle;
    return Scaffold(
      appBar: AppBar(title: const Text('Publisher')),
      body: _error != null
          ? Center(child: Text('Failed: $_error'))
          : bundle == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                SizedBox(
                  height: 260,
                  child: ColoredBox(
                    color: Colors.black,
                    child: RTCVideoView(_renderer, mirror: true),
                  ),
                ),
                const SizedBox(height: 12),
                Text('Signaling: ${widget.options.signalingUri}'),
                ValueListenableBuilder(
                  valueListenable: bundle.peer.connectionState,
                  builder: (context, s, _) => Text(
                    'PeerConnection: ${s?.name ?? 'waiting for viewer'}',
                  ),
                ),
                StreamBuilder(
                  stream: bundle.responder.changes,
                  builder: (context, _) {
                    final r = bundle.responder;
                    return Section('Actions from the viewer', [
                      StatusDot(on: r.connected, label: 'DataChannel'),
                      Text('Received ${r.received} · pongs ${r.pongsSent}'),
                      Text(jsonEncode(r.countsByType)),
                      Text('Last: ${jsonEncode(r.lastAction)}'),
                    ]);
                  },
                ),
              ],
            ),
    );
  }
}
