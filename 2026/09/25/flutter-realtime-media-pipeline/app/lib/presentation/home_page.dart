import 'package:flutter/material.dart';
import 'package:realtime_core/realtime_core.dart';

import '../app/dependency_container.dart';
import '../infrastructure/local/local_media_source.dart';
import 'publisher_page.dart';
import 'session_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

/// `null` mode = the publisher role of the two-device WebRTC test.
class _HomePageState extends State<HomePage> {
  SessionMode? _mode = SessionMode.mockToMock;
  LocalStatsProbe _probe = LocalStatsProbe.loopback;
  final _signaling = TextEditingController(text: 'ws://127.0.0.1:8787');
  final _room = TextEditingController(text: 'lab');
  List<MediaDevice> _devices = const [];
  String? _audioDevice;
  String? _videoDevice;
  String? _deviceError;

  @override
  void dispose() {
    _signaling.dispose();
    _room.dispose();
    super.dispose();
  }

  Future<void> _loadDevices() async {
    final source = LocalMediaSource(clock: StopwatchClock());
    try {
      final devices = await source.availableDevices();
      setState(() {
        _devices = devices;
        _deviceError = null;
      });
    } on MediaException catch (e) {
      setState(() => _deviceError = '${e.failure}');
    } finally {
      await source.dispose();
    }
  }

  SessionOptions get _options => SessionOptions(
    audioDeviceId: _audioDevice,
    videoDeviceId: _videoDevice,
    signalingUrl: _signaling.text.trim(),
    room: _room.text.trim(),
    probe: _probe,
  );

  void _start() {
    final mode = _mode;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => mode == null
            ? PublisherPage(options: _options)
            : SessionPage(mode: mode, options: _options),
      ),
    );
  }

  Widget _deviceSelector(
    MediaKind kind,
    String? value,
    ValueChanged<String?> onChanged,
  ) {
    final devices = _devices.where((d) => d.kind == kind).toList();
    return DropdownButton<String?>(
      isExpanded: true,
      value: devices.any((d) => d.id == value) ? value : null,
      hint: const Text('Default device'),
      items: [
        const DropdownMenuItem(value: null, child: Text('Default device')),
        for (final d in devices)
          DropdownMenuItem(
            value: d.id,
            child: Text(d.label, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    final usesLocal =
        _mode == SessionMode.localToMock ||
        _mode == SessionMode.localToLocalApi ||
        _mode == SessionMode.loopback ||
        _mode == null;
    final usesSignaling = _mode == SessionMode.webrtc || _mode == null;
    return Scaffold(
      appBar: AppBar(title: const Text('Realtime Pipeline Test')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Mode', style: Theme.of(context).textTheme.titleMedium),
          RadioGroup<SessionMode?>(
            groupValue: _mode,
            onChanged: (v) => setState(() => _mode = v),
            child: Column(
              children: [
                for (final m in SessionMode.values)
                  RadioListTile<SessionMode?>(value: m, title: Text(m.label)),
                const RadioListTile<SessionMode?>(
                  value: null,
                  title: Text('Publisher (other device of WebRTC mode)'),
                ),
              ],
            ),
          ),
          if (usesLocal) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Text('Devices', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _loadDevices,
                  child: const Text('Refresh'),
                ),
              ],
            ),
            if (_deviceError != null) Text(_deviceError!),
            const Text('Camera:'),
            _deviceSelector(
              MediaKind.video,
              _videoDevice,
              (v) => setState(() => _videoDevice = v),
            ),
            const Text('Microphone:'),
            _deviceSelector(
              MediaKind.audio,
              _audioDevice,
              (v) => setState(() => _audioDevice = v),
            ),
          ],
          if (_mode == SessionMode.localToMock ||
              _mode == SessionMode.localToLocalApi) ...[
            const SizedBox(height: 8),
            const Text('Local stats probe:'),
            DropdownButton<LocalStatsProbe>(
              value: _probe,
              items: [
                for (final p in LocalStatsProbe.values)
                  DropdownMenuItem(value: p, child: Text(p.name)),
              ],
              onChanged: (v) => setState(() => _probe = v ?? _probe),
            ),
          ],
          if (usesSignaling) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _signaling,
              decoration: const InputDecoration(labelText: 'Signaling URL'),
            ),
            TextField(
              controller: _room,
              decoration: const InputDecoration(labelText: 'Room'),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(onPressed: _start, child: const Text('Start Session')),
        ],
      ),
    );
  }
}
