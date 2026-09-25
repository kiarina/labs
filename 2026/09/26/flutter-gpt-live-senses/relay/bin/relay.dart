// SDP relay for GPT-Live over WebRTC.
//
//   OPENAI_API_KEY=... dart run bin/relay.dart [--port 8788]
//
// POST /session with the client's SDP offer as text/plain. The relay sends it
// to POST https://api.openai.com/v1/live/sessions with the API key and returns
// the SDP answer as text/plain. After that, audio and the `oai-events` data
// channel flow directly between the client and OpenAI; the key never leaves
// this process.
import 'dart:convert';
import 'dart:io';

const _instructions = '''
あなたは実験用の音声アシスタントです。日本語で、短く自然に話してください。
相手の話を遮らず、相槌は控えめにしてください。
''';

Future<void> main(List<String> args) async {
  final key = Platform.environment['OPENAI_API_KEY'];
  if (key == null || key.isEmpty) {
    stderr.writeln('OPENAI_API_KEY is not set');
    exit(2);
  }
  final portIndex = args.indexOf('--port');
  final port = portIndex >= 0 ? int.parse(args[portIndex + 1]) : 8788;
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln('relay on http://0.0.0.0:$port/session');
  final client = HttpClient();

  await for (final request in server) {
    final res = request.response;
    // The web build is served from another origin.
    res.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Headers', 'Content-Type')
      ..set('Access-Control-Allow-Methods', 'POST, OPTIONS');
    if (request.method == 'OPTIONS') {
      await res.close();
      continue;
    }
    if (request.method != 'POST' || request.uri.path != '/session') {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      continue;
    }
    final started = DateTime.now();
    try {
      final offer = await utf8.decodeStream(request);
      final upstream = await client.postUrl(
        Uri.parse('https://api.openai.com/v1/live/sessions'),
      );
      upstream.headers
        ..set('Authorization', 'Bearer $key')
        ..contentType = ContentType.json;
      upstream.write(jsonEncode({
        'session': {'model': 'gpt-live-1', 'instructions': _instructions},
        'transport': {'type': 'webrtc', 'sdp': offer},
      }));
      final reply = await upstream.close();
      final body = await utf8.decodeStream(reply);
      final ms = DateTime.now().difference(started).inMilliseconds;
      if (reply.statusCode != 200 && reply.statusCode != 201) {
        stdout.writeln('upstream ${reply.statusCode} in ${ms}ms: $body');
        res.statusCode = HttpStatus.badGateway;
        res.write(body);
      } else {
        final json = jsonDecode(body) as Map<String, dynamic>;
        final session = json['session'] as Map<String, dynamic>?;
        stdout.writeln('session ${session?['id']} in ${ms}ms');
        res.headers.contentType = ContentType.text;
        res.write((json['transport'] as Map<String, dynamic>)['sdp']);
      }
    } catch (e) {
      stdout.writeln('relay error: $e');
      res.statusCode = HttpStatus.internalServerError;
      res.write('$e');
    }
    await res.close();
  }
}
