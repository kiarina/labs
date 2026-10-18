import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'audio_time_mapper.dart';

void main(List<String> args) {
  final root = Directory.current.path;
  final r = jsonDecode(
    File(
      args.isEmpty
          ? '$root/../../results/refined-asr-fixture.json'
          : args.first,
    ).readAsStringSync(),
  ) as Map<String, dynamic>;
  final fragments = [
        for (final f in r['fragments'] as List)
          Map<String, dynamic>.from(f as Map),
      ],
      ledger = [
        for (final x in r['send_ledger'] as List)
          Map<String, dynamic>.from(x as Map),
      ],
      annotations = [
        for (final x in r['speaker_intervals'] as List)
          Map<String, dynamic>.from(x as Map),
      ];
  final evidence = r['clock_evidence'] as Map<String, dynamic>;
  final anchors = [
    for (final a in evidence['anchors'] as List)
      Map<String, dynamic>.from(a as Map),
  ];
  final session = (evidence['alignment']['session_minus_echo_ms'] as num);
  final text = fragments.map((f) => f['text'] as String).join();
  final markers = [
    text.startsWith('もしもし') ? 'もしもし' : 'もし',
    'うん',
    'こっちは',
    '了解',
    '助',
    text.contains('本当') ? '本当' : 'ほんと',
  ];
  final starts = markers.map(text.indexOf).toList();
  const roles = [0, 1, 0, 1, 0, 1];
  var cursor = 0;
  final truth = <Set<int>>[];
  for (final f in fragments) {
    final values = <int>{};
    final part = f['text'] as String;
    for (var j = 0; j < part.length; j++) {
      final char = part[j];
      if (RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(char)) {
        var index = 0;
        for (var k = 0; k < starts.length; k++)
          if (starts[k] <= cursor + j) index = k;
        values.add(roles[index]);
      }
    }
    truth.add(values);
    cursor += part.length;
  }
  const roleForId = {'speaker-2': 0, 'speaker-1': 1};
  final sweep = <Map<String, dynamic>>[];
  for (final guard in [.2, .4, .6, .8, 1.0, 1.2]) {
    var correct = 0, wrong = 0, held = 0, clockHeld = 0;
    final output = <Map<String, dynamic>>[];
    for (var i = 0; i < fragments.length; i++) {
      final f = fragments[i];
      final mapped = mapAudioInterval(
        f['start_ms'] as num,
        f['end_ms'] as num,
        anchors,
        session,
      );
      if (mapped == null) {
        held++;
        clockHeld++;
        output.add({
          'seq': f['seq'],
          'speaker_id': null,
          'reason': 'outside_anchors',
        });
        continue;
      }
      var hits = ledger
          .where(
            (v) =>
                v['sent'] == true &&
                (v['device_ms'] as num) < mapped.end &&
                (v['device_ms'] as num) + 10 > mapped.start,
          )
          .toList();
      if (hits.isEmpty)
        hits = ledger
            .where(
              (v) =>
                  v['sent'] == true &&
                  (v['device_ms'] as num) < mapped.end + 100 &&
                  (v['device_ms'] as num) + 10 > mapped.start - 100,
            )
            .toList();
      if (hits.isEmpty) {
        held++;
        output.add({
          'seq': f['seq'],
          'speaker_id': null,
          'reason': 'no_overlap',
        });
        continue;
      }
      final from = (hits.first['source_ms'] as num) / 1000,
          to = ((hits.last['source_ms'] as num) + 10) / 1000;
      final candidates = speakerCandidates(
        from,
        to,
        annotations,
        guardSeconds: guard,
      );
      final id = candidates.length == 1 ? candidates.single : null;
      if (id == null) {
        held++;
      } else if (truth[i].length == 1 && truth[i].contains(roleForId[id])) {
        correct++;
      } else {
        wrong++;
      }
      output.add({
        'seq': f['seq'],
        'speaker_id': id,
        'source_start': from,
        'source_end': to,
        'clock_extrapolated': mapped.extrapolated,
      });
    }
    sweep.add({
      'guard_seconds': guard,
      'correct': correct,
      'wrong': wrong,
      'held': held,
      'clock_held': clockHeld,
      'assignments': output,
    });
  }
  final holdout = <double>[];
  for (var i = 1; i < anchors.length - 1; i++) {
    final others = [...anchors]..removeAt(i);
    final time = (anchors[i]['echo_ms'] as num) + session;
    final predicted = mapAudioInterval(time, time, others, session);
    if (predicted == null) continue;
    holdout.add((predicted.start - (anchors[i]['device_ms'] as num)).abs());
  }
  final scalar = (evidence['alignment']['offset_ms'] as num);
  final scalarErrors = [
    for (final a in anchors)
      ((a['echo_ms'] as num) + session + scalar - (a['device_ms'] as num))
          .abs(),
  ];
  print(
    'REFINED_BINDING ${jsonEncode({'offline': true, 'uses_runtime_mapper': true, 'scope': 'One retained dialogue; text boundary markers are evaluation labels only. They are never used by the runtime mapping.', 'sweep': sweep, 'waveform_anchors': anchors.length, 'held_out_interpolation_error_ms_max': holdout.reduce(max), 'constant_offset_error_ms_max': scalarErrors.reduce(max), 'word_alignment_complete': false})}',
  );
}
