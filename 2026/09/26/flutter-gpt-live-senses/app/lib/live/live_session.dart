import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:media_taps/media_taps.dart';

/// One timestamped event from the `oai-events` data channel.
final class LiveEvent {
  final int atMs;
  final Map<String, Object?> json;

  const LiveEvent(this.atMs, this.json);

  String get type => json['type'] as String? ?? '?';
}

/// State B ("in conversation"): flutter_webrtc owns the camera and the mic.
/// The mic goes to GPT-Live over WebRTC (the SDP is exchanged through the
/// relay that holds the API key); the camera is only tapped locally, never
/// sent. Analysis reads both through `media_taps`.
final class LiveSession {
  final Uri relay;
  final Stopwatch clock;

  MediaStream? stream;
  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  MediaStream? remoteStream;
  MediaStreamTrack? remoteAudio;
  final List<LiveEvent> events = [];
  final Map<String, int> marks = {};
  final List<int> _taps = [];
  final Completer<void> started = Completer();
  final Completer<void> closed = Completer();
  int _eventCounter = 0;

  final bool stopAdm;

  LiveSession({required this.relay, required this.clock, this.stopAdm = false});

  void _mark(String name) => marks[name] ??= clock.elapsedMilliseconds;

  Future<void> start() async {
    _mark('startCalled');
    final s = stream = await navigator.mediaDevices.getUserMedia({
      // WebRTC's own processing (echo cancellation etc.) stays on: the model
      // must not hear its own voice through the speaker.
      'audio': true,
      // Plain numbers: native flutter_webrtc picked 640x480 from nested
      // {'ideal': ...} constraints in the earlier lab.
      'video': {'width': 1280, 'height': 720, 'frameRate': 30},
    });
    _mark('getUserMedia');
    if (!kIsWeb) {
      // Route the model's voice to the loudspeaker on phones (iOS defaults to
      // the receiver in a voice-chat session).
      try {
        await Helper.setSpeakerphoneOn(true);
      } catch (_) {}
    }

    final pc = _pc = await createPeerConnection({
      'iceServers': <Map<String, dynamic>>[],
      'sdpSemantics': 'unified-plan',
    });
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) remoteStream = event.streams.first;
      if (event.track.kind == 'audio') remoteAudio = event.track;
      _mark('remoteTrack');
    };
    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _mark('connected');
      }
    };
    // Only the microphone is sent. GPT-Live takes no video.
    await pc.addTrack(s.getAudioTracks().first, s);
    final dc = _dc = await pc.createDataChannel(
      'oai-events',
      RTCDataChannelInit(),
    );
    dc.onMessage = (message) {
      if (message.isBinary) return;
      final json = jsonDecode(message.text) as Map<String, Object?>;
      events.add(LiveEvent(clock.elapsedMilliseconds, json));
      switch (json['type']) {
        case 'session.started':
          _mark('sessionStarted');
          if (!started.isCompleted) started.complete();
        case 'session.closed':
          _mark('sessionClosed');
          if (!closed.isCompleted) closed.complete();
        case 'session.output_transcript.delta':
          _mark('firstOutputTranscript');
      }
    };

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    // Give ICE a moment so host candidates are in the offer.
    await _waitForGathering(pc, const Duration(seconds: 2));
    final local = await pc.getLocalDescription();
    _mark('offer');
    final response = await http.post(
      relay,
      headers: {'Content-Type': 'text/plain'},
      body: local!.sdp,
    );
    _mark('answer');
    if (response.statusCode != 200) {
      throw StateError('relay ${response.statusCode}: ${response.body}');
    }
    await pc.setRemoteDescription(
      RTCSessionDescription(response.body, 'answer'),
    );
  }

  Future<void> _waitForGathering(RTCPeerConnection pc, Duration max) async {
    if (pc.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      return;
    }
    final done = Completer<void>();
    pc.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !done.isCompleted) {
        done.complete();
      }
    };
    await Future.any([done.future, Future<void>.delayed(max)]);
  }

  void send(String type, Map<String, Object?> fields) {
    final dc = _dc;
    if (dc == null) return;
    final event = {
      'type': type,
      'event_id': 'lab_${++_eventCounter}',
      ...fields,
    };
    events.add(LiveEvent(clock.elapsedMilliseconds, {'sent': true, ...event}));
    dc.send(RTCDataChannelMessage(jsonEncode(event)));
  }

  /// Taps the local mic (post echo cancellation) and camera for analysis.
  Future<Map<String, int>> attachTaps({int convertWidth = 320}) async {
    final s = stream!;
    final taps = MediaTaps.instance;
    final audio = await taps.attach(
      s.getAudioTracks().first,
      local: true,
      stream: s,
      options: const TapOptions(deliver: true),
    );
    final video = await taps.attach(
      s.getVideoTracks().first,
      local: true,
      stream: s,
      options: TapOptions(convertWidth: convertWidth, deliver: true),
    );
    _taps.addAll([audio, video]);
    final ids = {'audio': audio, 'video': video};
    // The model's voice as received, to tell "did not speak" from "spoke but
    // was not heard".
    final remote = remoteAudio;
    if (remote != null) {
      try {
        final id = await taps.attach(
          remote,
          local: false,
          stream: remoteStream,
          options: const TapOptions(deliver: true),
        );
        _taps.add(id);
        ids['remoteAudio'] = id;
      } catch (e) {
        events.add(
          LiveEvent(clock.elapsedMilliseconds, {
            'type': 'lab.tapError',
            'error': '$e',
          }),
        );
      }
    }
    return ids;
  }

  String transcript(String type) => events
      .where((e) => e.type == type)
      .map((e) => e.json['delta'] as String? ?? '')
      .join();

  Future<void> close() async {
    _mark('closeCalled');
    if (_dc?.state == RTCDataChannelState.RTCDataChannelOpen) {
      send('session.close', {});
      await Future.any([
        closed.future,
        Future<void>.delayed(const Duration(seconds: 3)),
      ]);
    }
    for (final id in _taps) {
      await MediaTaps.instance.detach(id);
    }
    _taps.clear();
    await _dc?.close();
    await _pc?.close();
    for (final t in stream?.getTracks() ?? const <MediaStreamTrack>[]) {
      await t.stop();
    }
    await stream?.dispose();
    stream = null;
    // Ask flutter_webrtc's audio device module to stop capturing now, so
    // `record` can take the microphone back (release=stopadm).
    if (!kIsWeb && stopAdm) {
      try {
        await NativeAudioManagement.stopLocalRecording();
        _mark('admStopped');
      } catch (e) {
        events.add(
          LiveEvent(clock.elapsedMilliseconds, {
            'type': 'lab.stopAdmError',
            'error': '$e',
          }),
        );
      }
    }
    _mark('closed');
  }
}
