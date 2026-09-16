// Presence client built on firebase_dart.
//
// Signs in to the Auth emulator (or restores the persisted session), keeps
// /presence/{uid} online while connected, and re-registers onDisconnect on
// every `.info/connected == true`, the same pattern the official SDKs need.
//
// Events are printed as JSON lines on stdout. Commands are read from stdin:
//   graceful  write offline, cancel onDisconnect, goOffline, exit 0
//   refresh   force an ID token refresh
//   touch     write to the presence node (after refresh)
//   watchdog  heartbeat write every 5 s; reconnect when it times out
//   probe     try to write another user's node (rules check)
//   exit      exit immediately without cleanup
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_dart/auth.dart';
import 'package:firebase_dart/core.dart';
import 'package:firebase_dart/database.dart';
import 'package:firebase_dart/implementation/pure_dart.dart' hide Platform;
import 'package:http/http.dart' as http;
import 'package:jose/jose.dart';

final _env = Platform.environment;
final _authEmulator = _env['AUTH_EMULATOR'] ?? '127.0.0.1:9099';
final _databaseUrl =
    _env['DATABASE_URL'] ?? 'http://127.0.0.1:9000/?ns=demo-lab-default-rtdb';
final _storagePath = _env['STORAGE_PATH'];
final _email = _env['EMAIL'] ?? 'body@example.com';
final _password = _env['PASSWORD'] ?? 'password123';
final _session = _env['SESSION'] ?? '$pid';

void emit(String event, [Map<String, Object?> data = const {}]) {
  stdout.writeln(
    jsonEncode({
      't': DateTime.now().toUtc().toIso8601String(),
      'session': _session,
      'event': event,
      ...data,
    }),
  );
}

/// Sends Google Identity Toolkit / Secure Token calls to the Auth emulator.
///
/// The emulator issues unsigned (`alg: none`) ID tokens, which firebase_dart
/// rejects because it verifies tokens against Google's JWKS. This shim
/// re-signs emulator tokens with a throwaway RS256 key and serves that key
/// as the JWKS. Claims are left untouched, and the RTDB emulator does not
/// check signatures, so only signature verification is substituted.
class EmulatorClient extends http.BaseClient {
  final http.Client _inner = http.Client();
  final JsonWebKey _key = JsonWebKey.fromJson({
    ...JsonWebKey.generate('RS256', keyBitLength: 2048).toJson(),
    'kid': 'lab-emulator',
    'alg': 'RS256',
    'use': 'sig',
  });
  static const _hosts = {
    'identitytoolkit.googleapis.com',
    'securetoken.googleapis.com',
  };
  static const _jwksHost = 'www.googleapis.com';

  Map<String, dynamic> get _publicJwks {
    final jwk = Map<String, dynamic>.from(_key.toJson())
      ..removeWhere(
        (k, _) => const {'d', 'p', 'q', 'dp', 'dq', 'qi'}.contains(k),
      );
    return {
      'keys': [jwk],
    };
  }

  String _resign(String token) {
    final claims = JsonWebToken.unverified(token).claims.toJson();
    return (JsonWebSignatureBuilder()
          ..jsonContent = claims
          ..addRecipient(_key, algorithm: 'RS256'))
        .build()
        .toCompactSerialization();
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final url = request.url;
    if (url.host == _jwksHost) {
      return http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(_publicJwks))),
        200,
        headers: {'content-type': 'application/json'},
        request: request,
      );
    }
    if (!_hosts.contains(url.host)) return _inner.send(request);
    final target = Uri.parse(
      'http://$_authEmulator/${url.host}${url.path}${url.hasQuery ? '?${url.query}' : ''}',
    );
    emit('auth_http', {
      'method': request.method,
      'path': '${url.host}${url.path}',
    });
    final forwarded = http.Request(request.method, target)
      ..headers.addAll(request.headers)
      ..bodyBytes = await request.finalize().toBytes();
    final response = await http.Response.fromStream(
      await _inner.send(forwarded),
    );
    var body = response.body;
    if (response.statusCode == 200) {
      final json = jsonDecode(body) as Map<String, dynamic>;
      for (final field in ['idToken', 'id_token', 'access_token']) {
        if (json[field] is String) json[field] = _resign(json[field] as String);
      }
      body = jsonEncode(json);
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      response.statusCode,
      headers: {'content-type': 'application/json'},
      request: request,
    );
  }
}

Future<void> main() async {
  FirebaseDart.setup(storagePath: _storagePath, httpClient: EmulatorClient());

  final app = await Firebase.initializeApp(
    options: FirebaseOptions(
      apiKey: 'fake-api-key',
      appId: 'demo-app',
      messagingSenderId: 'demo',
      projectId: 'demo-lab',
      databaseURL: _databaseUrl,
    ),
  );
  final auth = FirebaseAuth.instanceFor(app: app);

  auth.idTokenChanges().listen((user) async {
    if (user == null) return;
    final token = await user.getIdTokenResult();
    emit('id_token', {
      'uid': user.uid,
      'expires': token.expirationTime?.toUtc().toIso8601String(),
      'issued': token.issuedAtTime?.toUtc().toIso8601String(),
    });
  });

  // authStateChanges emits the restored user (or null) once persistence loads.
  var user = await auth.authStateChanges().first;
  if (user != null) {
    emit('restored', {'uid': user.uid});
  } else {
    try {
      user = (await auth.signInWithEmailAndPassword(
        email: _email,
        password: _password,
      )).user;
    } on FirebaseAuthException catch (e) {
      if (e.code != 'user-not-found' && e.code != 'invalid-credential') rethrow;
      user = (await auth.createUserWithEmailAndPassword(
        email: _email,
        password: _password,
      )).user;
    }
    emit('signed_in', {'uid': user!.uid});
  }
  final uid = user.uid;

  final db = FirebaseDatabase(app: app, databaseURL: _databaseUrl);
  final presence = db.reference().child('presence').child(uid);
  final offline = {'online': false, 'session': _session};

  var registrations = 0;
  db.reference().child('.info/connected').onValue.listen((event) async {
    final connected = event.snapshot.value == true;
    emit('connected', {'value': connected});
    if (!connected) return;
    try {
      // Reserve first, then mark online, so a crash in between stays correct.
      await presence.onDisconnect().set(offline);
      await presence.set({
        'online': true,
        'session': _session,
        'at': ServerValue.timestamp,
      });
      registrations++;
      emit('registered', {'count': registrations});
    } catch (e) {
      emit('register_error', {'error': '$e'});
    }
  });

  Future<void> graceful() async {
    final sw = Stopwatch()..start();
    // Write first and cancel the reservation last (see the spirits-garden
    // presence pitfall): dying in between still leaves the server correct.
    await presence.set(offline);
    await presence.onDisconnect().cancel();
    await db.goOffline();
    emit('graceful_done', {'ms': sw.elapsedMilliseconds});
    await stdout.flush();
    exit(0);
  }

  Timer? watchdog;
  var beating = false;

  ProcessSignal.sigterm.watch().listen((_) => graceful());

  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((
    line,
  ) async {
    switch (line.trim()) {
      case 'graceful':
        await graceful();
      case 'refresh':
        final token = await auth.currentUser?.getIdToken(true) ?? "";
        emit('refreshed', {'length': token.length});
      case 'touch':
        // A write after a refresh proves the database accepted the new token.
        await presence.update({'touched': ServerValue.timestamp});
        emit('touched');
      case 'probe':
        // Writing another user's node must be rejected by the rules.
        try {
          await db.reference().child('presence/someone-else').set(true);
          emit('probe', {'denied': false});
        } catch (e) {
          emit('probe', {'denied': true, 'error': '$e'});
        }
      case 'watchdog':
        watchdog?.cancel();
        watchdog = Timer.periodic(const Duration(seconds: 5), (_) async {
          if (beating) return;
          beating = true;
          try {
            await presence
                .child('beat')
                .set(ServerValue.timestamp)
                .timeout(const Duration(seconds: 5));
          } on TimeoutException catch (e) {
            emit('watchdog_timeout', {'error': '$e'});
            await db.goOffline();
            await db.goOnline();
            emit('watchdog_reconnect');
          } finally {
            beating = false;
          }
        });
        emit('watchdog_on');
      case 'watchdog_off':
        watchdog?.cancel();
        emit('watchdog_off');
      case 'exit':
        exit(3);
    }
  });

  emit('ready', {'uid': uid});
}
