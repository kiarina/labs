import 'dart:convert';

import 'package:flutter/material.dart';

import 'controller.dart';
import 'engine.dart';

const _auto = String.fromEnvironment('AUTO');
const _whisper = String.fromEnvironment('WHISPER_MODEL', defaultValue: 'base');
const _ortThreads = int.fromEnvironment('ORT_THREADS');
const _whisperThreads = int.fromEnvironment('WHISPER_THREADS');
const _fitAudioCtx = bool.fromEnvironment('FIT_AUDIO_CTX');
const _minSilenceMs = int.fromEnvironment('MIN_SILENCE_MS', defaultValue: 300);
const _maxVoiceMs = int.fromEnvironment('MAX_VOICE_MS', defaultValue: 8000);
// dart-define has no doubles; thresholds are passed in thousandths
const _speakerThreshold = int.fromEnvironment('SPEAKER_THRESHOLD_MILLI', defaultValue: 450);
const _asrSpeakersOnly = bool.fromEnvironment('ASR_SPEAKERS_ONLY', defaultValue: true);
const _asrMinMs = int.fromEnvironment('ASR_MIN_MS', defaultValue: 500);
const _newSpeakerMinMs = int.fromEnvironment('NEW_SPEAKER_MIN_MS', defaultValue: 1500);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = HearingController(
    config: const EngineConfig(
      whisperModel: _whisper,
      threads: _ortThreads == 0 ? null : _ortThreads,
      whisperThreads: _whisperThreads,
      fitAudioCtx: _fitAudioCtx,
      minSilenceMs: _minSilenceMs,
      maxVoiceMs: _maxVoiceMs,
      speakerThreshold: _speakerThreshold / 1000,
      asrSpeakersOnly: _asrSpeakersOnly,
      asrMinSeconds: _asrMinMs / 1000,
      newSpeakerMinSeconds: _newSpeakerMinMs / 1000,
    ),
  );
  runApp(HearingLabApp(controller: controller));
  if (_auto.isNotEmpty) controller.runAuto(_auto);
}

class HearingLabApp extends StatelessWidget {
  const HearingLabApp({super.key, required this.controller});

  final HearingController controller;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Hearing lab',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: ListenableBuilder(listenable: controller, builder: (context, _) => _Home(c: controller)),
      );
}

class _Home extends StatelessWidget {
  const _Home({required this.c});

  final HearingController c;

  @override
  Widget build(BuildContext context) {
    final a = c.engine?.analyzer;
    return Scaffold(
      appBar: AppBar(title: Text('Hearing lab · $platformName · whisper ${c.config.whisperModel}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.tonal(
              onPressed: c.permission == 'granted' ? null : c.requestPermission,
              child: Text('1. Mic permission (${c.permission})'),
            ),
            FilledButton(
              onPressed: c.downloaded && !c.loading ? () => c.setMic(!c.micOn) : null,
              child: Text(c.micOn ? '2. Mic OFF (brain)' : '2. Mic ON (brain)'),
            ),
            OutlinedButton(
              onPressed: c.downloaded && !c.replaying && !c.micOn ? () => c.replayWav() : null,
              child: const Text('Replay test WAV'),
            ),
            OutlinedButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('recall_hearing (last 5 min)'),
                  content: SingleChildScrollView(
                    child: SelectableText(const JsonEncoder.withIndent(' ').convert(c.recall()),
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                  ),
                ),
              ),
              child: const Text('3. Recall (brain tool)'),
            ),
            OutlinedButton(
              onPressed: c.downloaded ? c.modelParity : null,
              child: const Text('Model parity'),
            ),
          ]),
          if (c.error != null) Text(c.error!, style: const TextStyle(color: Colors.red)),
          const SizedBox(height: 12),
          for (final p in c.downloads.values)
            ListTile(
              dense: true,
              title: Text(p.file.filename),
              subtitle: LinearProgressIndicator(value: p.total == 0 ? null : p.fraction),
              trailing: Text(p.cached ? 'cached' : '${(p.received / 1e6).toStringAsFixed(1)} MB'),
            ),
          if (c.loading) const ListTile(leading: CircularProgressIndicator(), title: Text('Loading models…')),
          if (a != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'VAD p=${a.lastVoiceProbability.toStringAsFixed(2)} ${a.inVoice ? '● voice' : ''}\n'
                  '${const JsonEncoder.withIndent(' ').convert(a.statsJson())}',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          const Divider(),
          for (final line in c.log.reversed.take(60)) Text(line, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}
