/// [Rtc] on libdatachannel through dart:ffi and native/ldc_shim.c.
///
/// The libraries are looked up in `LDC_DIR` (default
/// `../build/libdatachannel/out`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'rtc.dart';

typedef _EventC = Void Function(Int32 kind, Int32 id, Int32 a, Pointer<Char> text, Int32 size);

class _Lib {
  _Lib._(DynamicLibrary rtc, DynamicLibrary shim)
    : init = shim.lookupFunction<Void Function(Pointer<NativeFunction<_EventC>>), void Function(Pointer<NativeFunction<_EventC>>)>('ldc_init'),
      free = shim.lookupFunction<Void Function(Pointer<Char>), void Function(Pointer<Char>)>('ldc_free'),
      attachPc = shim.lookupFunction<Int32 Function(Int32), int Function(int)>('ldc_attach_pc'),
      createPc = shim.lookupFunction<Int32 Function(Pointer<Pointer<Char>>, Int32), int Function(Pointer<Pointer<Char>>, int)>('ldc_create_pc'),
      createDc = shim.lookupFunction<Int32 Function(Int32, Pointer<Char>), int Function(int, Pointer<Char>)>('ldc_create_dc'),
      setRemoteDescription = rtc.lookupFunction<Int32 Function(Int32, Pointer<Char>, Pointer<Char>), int Function(int, Pointer<Char>, Pointer<Char>)>('rtcSetRemoteDescription'),
      addRemoteCandidate = rtc.lookupFunction<Int32 Function(Int32, Pointer<Char>, Pointer<Char>), int Function(int, Pointer<Char>, Pointer<Char>)>('rtcAddRemoteCandidate'),
      sendMessage = rtc.lookupFunction<Int32 Function(Int32, Pointer<Char>, Int32), int Function(int, Pointer<Char>, int)>('rtcSendMessage'),
      closePc = rtc.lookupFunction<Int32 Function(Int32), int Function(int)>('rtcClosePeerConnection'),
      deletePc = rtc.lookupFunction<Int32 Function(Int32), int Function(int)>('rtcDeletePeerConnection'),
      initLogger = rtc.lookupFunction<Void Function(Int32, Pointer<Void>), void Function(int, Pointer<Void>)>('rtcInitLogger');

  static _Lib? _instance;
  static _Lib get instance => _instance ??= () {
    final dir = Platform.environment['LDC_DIR'] ?? '../build/libdatachannel/out';
    final ext = Platform.isMacOS ? 'dylib' : (Platform.isWindows ? 'dll' : 'so');
    final rtc = DynamicLibrary.open(Platform.isMacOS ? '$dir/libdatachannel.0.dylib' : '$dir/libdatachannel.$ext');
    final shim = DynamicLibrary.open('$dir/libldc_shim.$ext');
    return _Lib._(rtc, shim);
  }();

  final void Function(Pointer<NativeFunction<_EventC>>) init;
  final void Function(Pointer<Char>) free;
  final int Function(int) attachPc;
  final int Function(Pointer<Pointer<Char>>, int) createPc;
  final int Function(int, Pointer<Char>) createDc;
  final int Function(int, Pointer<Char>, Pointer<Char>) setRemoteDescription;
  final int Function(int, Pointer<Char>, Pointer<Char>) addRemoteCandidate;
  final int Function(int, Pointer<Char>, int) sendMessage;
  final int Function(int) closePc;
  final int Function(int) deletePc;
  final void Function(int, Pointer<Void>) initLogger;
}

/// Routes the shim's events to the connection or channel they belong to.
class _Events {
  static final _byId = <(bool, int), void Function(int kind, int a, String? text, List<int>? bytes)>{};

  /// Events for a channel Dart has not registered yet (its open and first
  /// messages can come before the data channel event reaches Dart).
  static final _pending = <int, List<(int, int, String?, List<int>?)>>{};

  static void register(int dc, void Function(int kind, int a, String? text, List<int>? bytes) on) {
    _byId[(true, dc)] = on;
    for (final (k, a, t, b) in _pending.remove(dc) ?? const <(int, int, String?, List<int>?)>[]) {
      on(k, a, t, b);
    }
  }
  static NativeCallable<_EventC>? _callable;

  static void ensure() {
    if (_callable != null) return;
    _callable = NativeCallable<_EventC>.listener(_on);
    _Lib.instance.init(_callable!.nativeFunction);
    final level = int.tryParse(Platform.environment['LDC_LOG'] ?? '');
    // Logs go to stdout through plog when a level is set (1 fatal .. 6 verbose).
    if (level != null) _Lib.instance.initLogger(level, nullptr);
  }

  static void _on(int kind, int id, int a, Pointer<Char> text, int size) {
    List<int>? bytes;
    if (text != nullptr) {
      bytes = text.cast<Uint8>().asTypedList(size).toList();
      _Lib.instance.free(text);
    }
    final isDc = kind >= 5 && kind <= 8;
    final t = bytes == null ? null : utf8.decode(bytes, allowMalformed: true);
    final on = _byId[(isDc, id)];
    if (on != null) {
      on(kind, a, t, bytes);
    } else if (isDc) {
      (_pending[id] ??= []).add((kind, a, t, bytes));
    }
  }
}

const _stateNames = ['new', 'connecting', 'connected', 'disconnected', 'failed', 'closed'];

class LdcRtc implements Rtc {
  LdcRtc({List<String> iceServers = const []}) : _iceServers = iceServers;

  final List<String> _iceServers;
  late final int _pc;
  final _signals = StreamController<Map<String, dynamic>>();
  final _states = StreamController<String>.broadcast();
  final _channel = Completer<_Channel>();
  var _described = false;
  final _outbox = <Map<String, dynamic>>[];
  var _remoteSet = false;
  final _early = <Map<String, dynamic>>[];

  @override
  Stream<Map<String, dynamic>> get signals => _signals.stream;

  @override
  Stream<String> get states => _states.stream;

  @override
  Map<String, Object?> get info => {'impl': 'libdatachannel', 'version': Platform.environment['LIBDATACHANNEL_VERSION'] ?? 'v0.24.6'};

  @override
  Future<TextChannel> start({required bool offer}) async {
    _Events.ensure();
    final lib = _Lib.instance;
    final servers = calloc<Pointer<Char>>(_iceServers.length + 1);
    for (var i = 0; i < _iceServers.length; i++) {
      servers[i] = _iceServers[i].toNativeUtf8().cast();
    }
    _pc = lib.createPc(servers, _iceServers.length);
    if (_pc < 0) throw StateError('rtcCreatePeerConnection: $_pc');
    _Events._byId[(false, _pc)] = _onPc;
    lib.attachPc(_pc);
    if (offer) {
      // Creating the first channel negotiates by itself (auto negotiation):
      // the offer arrives as a description event.
      final label = 'nerve'.toNativeUtf8();
      final dc = lib.createDc(_pc, label.cast());
      calloc.free(label);
      if (dc < 0) throw StateError('rtcCreateDataChannel: $dc');
      final ch = _Channel(dc, 'nerve');
      _Events.register(dc, ch._on);
      await ch._open.future;
      return ch;
    }
    final ch = await _channel.future;
    await ch._open.future;
    return ch;
  }

  void _onPc(int kind, int a, String? text, List<int>? _) {
    switch (kind) {
      case 1: // description
        final nl = text!.indexOf('\n');
        _signals.add({'k': text.substring(0, nl), 'sdp': text.substring(nl + 1)});
        _described = true;
        _outbox.forEach(_signals.add);
        _outbox.clear();
      case 2: // candidate
        final nl = text!.indexOf('\n');
        var cand = text.substring(nl + 1);
        if (cand.startsWith('a=')) cand = cand.substring(2);
        final m = {'k': 'cand', 'candidate': cand, 'sdpMid': text.substring(0, nl), 'sdpMLineIndex': 0};
        _described ? _signals.add(m) : _outbox.add(m);
      case 3:
        _states.add(_stateNames[a]);
      case 4: // a channel opened by the other end
        final ch = _Channel(a, 'nerve');
        // libdatachannel reports the channel when it is open.
        ch._open.complete();
        _Events.register(a, ch._on);
        if (!_channel.isCompleted) _channel.complete(ch);
    }
  }

  Future<void> _addCandidate(Map<String, dynamic> m) async {
    final s = m['candidate'] as String?;
    if (s == null || s.isEmpty) return;
    final c = s.toNativeUtf8(), mid = ((m['sdpMid'] as String?) ?? '0').toNativeUtf8();
    final r = _Lib.instance.addRemoteCandidate(_pc, c.cast(), mid.cast());
    calloc
      ..free(c)
      ..free(mid);
    if (r < 0) stderr.writeln('rtcAddRemoteCandidate $r: $s');
  }

  @override
  Future<void> onSignal(Map<String, dynamic> m) async {
    switch (m['k']) {
      case 'offer' || 'answer':
        final sdp = (m['sdp'] as String).toNativeUtf8(), type = (m['k'] as String).toNativeUtf8();
        final r = _Lib.instance.setRemoteDescription(_pc, sdp.cast(), type.cast());
        calloc
          ..free(sdp)
          ..free(type);
        if (r < 0) throw StateError('rtcSetRemoteDescription: $r');
        _remoteSet = true;
        for (final c in _early) {
          await _addCandidate(c);
        }
        _early.clear();
      case 'cand':
        _remoteSet ? await _addCandidate(m) : _early.add(m);
    }
  }

  @override
  Future<void> close() async {
    _Lib.instance.closePc(_pc);
    _Lib.instance.deletePc(_pc);
  }
}

class _Channel implements TextChannel {
  _Channel(this._dc, this.label);

  final int _dc;
  @override
  final String label;
  final _open = Completer<void>();
  final _messages = StreamController<String>();
  final _closed = Completer<void>();

  void _on(int kind, int a, String? text, List<int>? bytes) {
    switch (kind) {
      case 5:
        if (!_open.isCompleted) _open.complete();
      case 6:
        if (!_closed.isCompleted) _closed.complete();
      case 7:
        stderr.writeln('channel error: $text');
      case 8:
        if (a == 1) _messages.add(text!);
    }
  }

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Future<void> get closed => _closed.future;

  @override
  Future<void> send(String text) async {
    final p = text.toNativeUtf8();
    final r = _Lib.instance.sendMessage(_dc, p.cast(), -1);
    calloc.free(p);
    if (r < 0) throw StateError('rtcSendMessage: $r');
  }
}
