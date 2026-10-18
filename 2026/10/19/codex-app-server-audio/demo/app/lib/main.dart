import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:record/record.dart';

import 'native_bridge.dart';

void main() => runApp(
  const MaterialApp(debugShowCheckedModeBanner: false, home: VoiceDemo()),
);

class VoiceDemo extends StatefulWidget {
  const VoiceDemo({super.key});
  @override
  State<VoiceDemo> createState() => _VoiceDemoState();
}

class _VoiceDemoState extends State<VoiceDemo> {
  final bridge = CaptureBridge();
  final recorder = AudioRecorder();
  RTCPeerConnection? pc;
  MediaStream? stream;
  WebSocket? socket;
  StreamSubscription<Uint8List>? audio;
  StreamSubscription<dynamic>? messages;
  bool busy = false, connected = false, muted = false, prepared = false;
  double level = 0;
  String status = '開始するとマイクを使用します', user = '', voice = '', thinking = '';
  final List<String> log = [];
  int inputBytes = 0;
  Timer? expiry;
  void update(String text) {
    if (!mounted) return;
    setState(() {
      status = text;
      log.insert(0, text);
      if (log.length > 24) log.removeLast();
    });
  }

  Future<void> start() async {
    setState(() {
      busy = true;
      user = '';
      voice = '';
      thinking = '';
    });
    try {
      final url = Platform.environment['VOICE_LAB_URL'];
      if (url == null) throw StateError('起動スクリプトから開いてください');
      if (!prepared) {
        stream = await bridge.create();
        prepared = true;
      }
      pc = await createPeerConnection({
        'iceServers': [],
        'sdpSemantics': 'unified-plan',
      });
      pc!.onConnectionState = (s) {
        update('接続: ${s.name}');
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          setState(() => connected = true);
        }
      };
      for (final t in stream!.getAudioTracks()) {
        await pc!.addTrack(t, stream!);
      }
      await pc!.createDataChannel('oai-events', RTCDataChannelInit());
      await pc!.setLocalDescription(await pc!.createOffer());
      final until = DateTime.now().add(const Duration(seconds: 5));
      while (pc!.iceGatheringState !=
              RTCIceGatheringState.RTCIceGatheringStateComplete &&
          DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      socket = await WebSocket.connect(url);
      final answered = Completer<void>();
      messages = socket!.listen(
        (raw) async {
          final e = jsonDecode(raw as String) as Map<String, dynamic>;
          switch (e['type']) {
            case 'answer':
              await pc!.setRemoteDescription(
                RTCSessionDescription(e['sdp'] as String, 'answer'),
              );
              if (!answered.isCompleted) answered.complete();
            case 'user_transcript':
              if (mounted) setState(() => user = e['text'] as String);
            case 'voice_transcript':
              if (mounted) setState(() => voice = e['text'] as String);
            case 'thinker_start':
              if (mounted) setState(() => thinking = '考えています…');
              update('Thinker に委譲しました');
            case 'thinker_result':
              if (mounted) setState(() => thinking = e['text'] as String);
              update('Thinker の結果を音声側へ返しました');
            case 'error':
              update(e['text'] as String);
              if (!answered.isCompleted)
                answered.completeError(StateError(e['text'] as String));
              unawaited(stop());
            case 'status':
              update(e['text'] as String);
          }
        },
        onDone: () {
          if (mounted && busy) unawaited(stop());
        },
      );
      socket!.add(
        jsonEncode({
          'type': 'start',
          'sdp': (await pc!.getLocalDescription())!.sdp,
        }),
      );
      update('ChatGPT ログインで接続中…');
      await answered.future.timeout(const Duration(seconds: 40));
      await bridge.flush();
      if (Platform.environment['VOICE_LAB_AUTOTEST'] == '1') {
        update('合成音声で接続試験中');
        final bytes = (await rootBundle.load('assets/probe.pcm')).buffer
            .asUint8List();
        for (var i = 0; i < bytes.length; i += 960) {
          await bridge.pushAudio(
            Uint8List.sublistView(bytes, i, min(i + 960, bytes.length)),
          );
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await Future<void>.delayed(const Duration(seconds: 18));
        final stats = await const MethodChannel('external_capture')
            .invokeMethod('stats');
        // Synthetic test only: no human audio/transcript is printed.
        stdout.writeln(
          jsonEncode({
            'demo_autotest': true,
            'thinker_result': thinking,
            'voice_transcript': voice,
            'stats': stats,
          }),
        );
        await stop();
        exit(0);
      }
      if (!await recorder.hasPermission()) throw StateError('マイクの使用許可が必要です');
      audio =
          (await recorder.startStream(
            const RecordConfig(
              encoder: AudioEncoder.pcm16bits,
              sampleRate: 48000,
              numChannels: 1,
              echoCancel: false,
              noiseSuppress: false,
              autoGain: false,
              audioInterruption: AudioInterruptionMode.none,
            ),
          )).listen(
            (bytes) {
              var sum = 0.0;
              final data = ByteData.sublistView(bytes);
              for (var i = 0; i + 1 < bytes.length; i += 2) {
                final v = data.getInt16(i, Endian.little) / 32768;
                sum += v * v;
              }
              if (mounted)
                setState(() => level = sqrt(sum / max(1, bytes.length ~/ 2)));
              if (!muted) {
                inputBytes += bytes.length;
                unawaited(bridge.pushAudio(bytes));
              }
            },
            onError: (Object e) {
              update('マイク取得エラー');
              unawaited(stop());
            },
          );
      expiry = Timer(const Duration(minutes: 10), () {
        update('10分の体験時間が終了しました');
        unawaited(stop());
      });
      update('話しかけてください');
    } catch (e) {
      update('$e');
      await stop();
    }
  }

  bool stopping = false;
  Future<void> stop() async {
    if (stopping) return;
    stopping = true;
    expiry?.cancel();
    await audio?.cancel();
    audio = null;
    if (await recorder.isRecording()) await recorder.stop();
    try {
      socket?.add(jsonEncode({'type': 'stop'}));
    } catch (_) {}
    await messages?.cancel();
    messages = null;
    await socket?.close();
    socket = null;
    await pc?.close();
    pc = null;
    if (prepared) await bridge.flush();
    if (mounted)
      setState(() {
        busy = false;
        connected = false;
        level = 0;
      });
    stopping = false;
  }

  @override
  void initState() {
    super.initState();
    if (Platform.environment['VOICE_LAB_AUTOTEST'] == '1') {
      WidgetsBinding.instance.addPostFrameCallback((_) => start());
    }
  }

  @override
  void dispose() {
    expiry?.cancel();
    unawaited(stop());
    super.dispose();
  }

  Widget panel(String label, String text) => Expanded(
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(
                  text.isEmpty ? '—' : text,
                  style: const TextStyle(fontSize: 17, height: 1.6),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xfff4f6fa),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Voice × Thinker',
              style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              'record → GPT Live → 自前 Thinker → 音声の返答',
              style: TextStyle(fontSize: 17),
            ),
            const SizedBox(height: 12),
            const Text('ヘッドホンを使用してください。開始中の音声は OpenAI に送信します。録音・会話の保存はしません。'),
            const SizedBox(height: 16),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: busy ? null : start,
                  icon: const Icon(Icons.mic),
                  label: const Text('会話を開始'),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: !busy
                      ? null
                      : () async {
                          setState(() => muted = !muted);
                          await bridge.flush();
                        },
                  child: Text(muted ? 'マイクを送信する' : 'マイクをミュート'),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: busy ? stop : null,
                  child: const Text('終了'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(status),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: min(1, level * 8), minHeight: 5),
            const SizedBox(height: 12),
            const Text('例：「A17 の予約分を引いた在庫は？」 → 「それを3人で分けると？」'),
            const SizedBox(height: 12),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  panel('あなたの音声', user),
                  panel('Thinker', thinking),
                  panel('音声の返答', voice),
                ],
              ),
            ),
            Text(
              connected
                  ? '接続中 · Thinker: gpt-6-luna · ChatGPT 認証'
                  : '待機中 · カメラは使用しません',
            ),
          ],
        ),
      ),
    ),
  );
}
