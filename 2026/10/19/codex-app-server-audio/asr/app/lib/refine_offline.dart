import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'local/onnx.dart';
import 'local/dsp/pcm.dart';
import 'local/vad/silero_vad.dart';
import 'local/scd/pyannote_scd.dart';
import 'local/scd/speaker_change_detector.dart';
import 'local/embedding/ecapa.dart';
import 'wav.dart';
import 'speaker_tracker.dart';

void main() {
  runApp(
    const MaterialApp(
      home: Scaffold(
        body: Text('Offline speaker refinement: no microphone / no cloud'),
      ),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) => run());
}

Future<void> run() async {
  final models = <OnnxModel>[];
  try {
    final backend = FlutterOnnxBackend(threads: 2);
    for (final name in ['silero_vad.onnx', 'model.onnx', 'ecapa_tdnn.onnx']) {
      final data = await rootBundle.load('assets/models/$name');
      final file = File('${Directory.systemTemp.path}/refine-$name');
      await file.writeAsBytes(data.buffer.asUint8List());
      models.add(await backend.load(file.path));
    }
    final wav = Wav.parse(
      (await rootBundle.load('assets/conversation.wav')).buffer.asUint8List(),
    );
    final third = Wav.parse(
      (await rootBundle.load('assets/refine-third.wav')).buffer.asUint8List(),
    );
    final reference = (jsonDecode(
      await rootBundle.loadString('assets/refine-reference.json'),
    ) as List).cast<Map<String, dynamic>>();
    final scenarios = <String, List<int>>{
      'original': [0, 1, 2, 3, 4, 5],
      'reordered': [1, 0, 3, 2, 5, 4],
      'one_speaker': [0, 2, 4, 0, 2, 4],
      'three_speakers': [0, 1, 6, 2, 3, 4, 5, 6],
    };
    final reports = <Map<String, dynamic>>[];
    for (final entry in scenarios.entries) {
      final parts = <Float32List>[Float32List(32000)];
      final truth = <Map<String, dynamic>>[];
      var cursor = 32000;
      for (final i in entry.value) {
        final piece = i == 6
            ? third.samples
            : Float32List.sublistView(
                wav.samples,
                ((reference[i]['start'] as num) * 16000).round(),
                ((reference[i]['end'] as num) * 16000).round(),
              );
        truth.add({
          'start': cursor / 16000,
          'end': (cursor + piece.length) / 16000,
          'speaker': i == 6 ? 2 : i % 2,
        });
        parts.add(piece);
        cursor += piece.length;
        parts.add(Float32List(8000));
        cursor += 8000;
      }
      if (entry.key == 'original') {
        parts.clear();
        parts.addAll([Float32List(32000), wav.samples, Float32List(16000)]);
        truth.clear();
        for (var i = 0; i < reference.length; i++) {
          truth.add({
            'start': (reference[i]['start'] as num) + 2,
            'end': (reference[i]['end'] as num) + 2,
            'speaker': i % 2,
          });
        }
      }
      parts.add(Float32List(32000));
      final input = concatFloat32(parts);
      final vad = SileroVad(models[0]),
          scd = SpeakerChangeDetector(PyannoteScd(models[1])),
          ecapa = EcapaSpeakerEmbedder(models[2]);
      final ranges = <List<int>>[];
      final baseline = SpeakerTracker(refined: false),
          refined = SpeakerTracker();
      final ba = <Map<String, dynamic>>[], ra = <Map<String, dynamic>>[];
      var read = 0, observations = 0;
      final clock = Stopwatch()..start();
      for (var end = 4000; end + 4000 <= input.length; end += 4000) {
        final winEnd = end + 4000;
        while (read + 512 <= winEnd) {
          final prob = await vad.predict(
            Float32List.sublistView(input, read, read + 512),
            16000,
          );
          if (prob >= .5) ranges.add([max(0, read - 3200), read + 512 + 3200]);
          read += 512;
        }
        final start = max(0, end - 96000);
        final speeches = await scd.detect(
          Float32List.sublistView(input, start, winEnd),
          16000,
          start / 16000,
        );
        for (final s in speeches) {
          if (s.kind != 'speaker') continue;
          final a = (s.startTimestamp * 16000).round(),
              b = (s.endTimestamp * 16000).round();
          if (b <= end - 4000 || a >= end) continue;
          final voices = ranges.where((r) => r[1] > a && r[0] < b).toList();
          if (voices.isEmpty) continue;
          final cropA = max(a, voices.first[0]), cropB = min(b, voices.last[1]);
          if ((cropB - cropA) / 16000 < .6) continue;
          final vector = await ecapa.embed(
            Float32List.sublistView(input, cropA, cropB),
            16000,
          );
          observations++;
          final old = baseline.observe(vector, cropA / 16000, cropB / 16000),
              improved = refined.observe(vector, cropA / 16000, cropB / 16000);
          ba.add({'observation': old, 'available': end / 16000});
          ra.add({'observation': improved, 'available': end / 16000});
        }
      }
      List<int?> labels(List<Map<String, dynamic>> annotations) {
        final labels = <int?>[];
        for (final t in truth) {
          final middle = ((t['start'] as num) + (t['end'] as num)) / 2;
          final matches = annotations.where((a) {
            final o = a['observation'] as SpeakerObservation;
            return o.start <= middle && o.end >= middle && o.speaker != null;
          }).toList();
          labels.add(
            matches.isEmpty
                ? null
                : (matches.last['observation'] as SpeakerObservation).speaker,
          );
        }
        return labels;
      }

      reports.add({
        'scenario': entry.key,
        'input_seconds': input.length / 16000,
        'observations': observations,
        'expected_speakers': entry.key == 'one_speaker'
            ? 1
            : entry.key == 'three_speakers'
            ? 3
            : 2,
        'truth_roles': truth.map((t) => t['speaker']).toList(),
        'baseline_clusters': baseline.speakers.length,
        'refined_clusters': refined.speakers.length,
        'baseline_labels': labels(ba),
        'refined_labels': labels(ra),
        'processing_ms': clock.elapsedMilliseconds,
      });
    }
    stdout.writeln(
      'REFINE_OFFLINE ${jsonEncode({'no_cloud': true, 'no_microphone': true, 'matching_threshold': .45, 'new_speaker_min_seconds': 2.0, 'near_match_min_seconds': 3.0, 'scenarios': reports})}',
    );
    for (final m in models) {
      await m.close();
    }
    exit(0);
  } catch (e) {
    stdout.writeln('REFINE_ERROR ${e.runtimeType}: $e');
    exit(1);
  }
}
