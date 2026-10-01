import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import '../state/thread_view.dart';
import 'theme.dart';

/// Shown above the composer while the agent waits for the user, like the
/// approval prompt in the Codex app.
class PendingRequestCard extends StatelessWidget {
  const PendingRequestCard({
    super.key,
    required this.app,
    required this.request,
  });

  final AppController app;
  final PendingRequest request;

  @override
  Widget build(BuildContext context) {
    final p = request.params;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Palette.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Palette.warning.withValues(alpha: 0.5)),
      ),
      child: switch (request.method) {
        'item/commandExecution/requestApproval' => _approval(
          title: 'Run this command?',
          body: p['command'] as String? ?? '',
          reason: p['reason'] as String?,
          footnote: p['cwd'] as String?,
        ),
        'item/fileChange/requestApproval' => _approval(
          title: 'Apply these file changes?',
          body: p['grantRoot'] != null
              ? 'Allow writes under ${p['grantRoot']}'
              : '',
          reason: p['reason'] as String?,
        ),
        'item/permissions/requestApproval' => _permissions(),
        // MCP tools ask through elicitation. Computer Use (the cua_repl
        // server) asks "Allow Computer Use to use <app>?" this way.
        'mcpServer/elicitation/request' when p['mode'] == 'url' =>
          _unsupported(),
        'mcpServer/elicitation/request' => _elicitation(),
        'item/tool/requestUserInput' => _UserInputForm(
          app: app,
          request: request,
        ),
        _ => _unsupported(),
      },
    );
  }

  Widget _approval({
    required String title,
    required String body,
    String? reason,
    String? footnote,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        if (reason != null && reason.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            reason,
            style: const TextStyle(color: Palette.textDim, fontSize: 12),
          ),
        ],
        if (body.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Palette.background,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              body,
              style: const TextStyle(fontFamily: monoFamily, fontSize: 12),
            ),
          ),
        ],
        if (footnote != null) ...[
          const SizedBox(height: 4),
          Text(
            footnote,
            style: const TextStyle(color: Palette.textFaint, fontSize: 11),
          ),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: () => app.answer(request, {'decision': 'accept'}),
              child: const Text('Approve'),
            ),
            OutlinedButton(
              onPressed: () =>
                  app.answer(request, {'decision': 'acceptForSession'}),
              child: const Text('Approve for session'),
            ),
            TextButton(
              onPressed: () => app.answer(request, {'decision': 'decline'}),
              child: const Text('Decline'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _permissions() {
    final p = request.params;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Grant additional permissions?',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        const SizedBox(height: 6),
        SelectableText(
          '${p['reason'] ?? ''}\n${p['permissions']}',
          style: const TextStyle(fontFamily: monoFamily, fontSize: 12),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              onPressed: () => app.answer(request, {
                'permissions': p['permissions'],
                'scope': 'turn',
              }),
              child: const Text('Allow for this turn'),
            ),
            TextButton(
              onPressed: () => app.answer(request, {
                'permissions': <String, dynamic>{},
                'scope': 'turn',
              }),
              child: const Text('Deny'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _elicitation() {
    final p = request.params;
    final meta = (p['_meta'] as Map?) ?? const {};
    final params = (meta['tool_params_display'] as List? ?? const [])
        .cast<Map>()
        .map((e) => '${e['display_name']}: ${e['value']}')
        .join('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          p['message'] as String? ?? '${p['serverName']} asks for input',
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        const SizedBox(height: 4),
        Text(
          '${meta['connector_name'] ?? p['serverName']}'
          '${meta['tool_name'] != null ? ' · ${meta['tool_name']}' : ''}',
          style: const TextStyle(color: Palette.textDim, fontSize: 12),
        ),
        if (params.isNotEmpty) ...[
          const SizedBox(height: 6),
          SelectableText(
            params,
            style: const TextStyle(fontFamily: monoFamily, fontSize: 12),
          ),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              onPressed: () => app.answer(request, {
                'action': 'accept',
                'content': <String, dynamic>{},
                '_meta': null,
              }),
              child: const Text('Allow'),
            ),
            // `_meta.persist` lists the scopes the server can remember the
            // answer for; without it Computer Use asks again for every key.
            for (final scope
                in (meta['persist'] as List? ?? const []).cast<String>())
              OutlinedButton(
                onPressed: () => app.answer(request, {
                  'action': 'accept',
                  'content': <String, dynamic>{},
                  '_meta': {'persist': scope},
                }),
                child: Text(
                  scope == 'session' ? 'Allow for session' : 'Always allow',
                ),
              ),
            TextButton(
              onPressed: () => app.answer(request, {
                'action': 'decline',
                'content': null,
                '_meta': null,
              }),
              child: const Text('Decline'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _unsupported() {
    return Row(
      children: [
        Expanded(
          child: Text(
            'Unsupported request: ${request.method}',
            style: const TextStyle(fontSize: 12, color: Palette.textDim),
          ),
        ),
        TextButton(
          onPressed: () {
            app.client!.respondError(
              request.request.id,
              -32601,
              'not supported by this client',
            );
            app.current?.removePending(request);
          },
          child: const Text('Dismiss'),
        ),
      ],
    );
  }
}

class _UserInputForm extends StatefulWidget {
  const _UserInputForm({required this.app, required this.request});

  final AppController app;
  final PendingRequest request;

  @override
  State<_UserInputForm> createState() => _UserInputFormState();
}

class _UserInputFormState extends State<_UserInputForm> {
  final _answers = <String, String>{};

  @override
  Widget build(BuildContext context) {
    final questions = (widget.request.params['questions'] as List).cast<Map>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final q in questions) ...[
          Text(
            q['question'] as String,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          const SizedBox(height: 6),
          if (q['options'] case final List options)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final o in options.cast<Map>())
                  ChoiceChip(
                    label: Text(o['label'] as String),
                    tooltip: o['description'] as String?,
                    selected: _answers[q['id']] == o['label'],
                    onSelected: (_) => setState(
                      () => _answers[q['id'] as String] = o['label'] as String,
                    ),
                  ),
              ],
            )
          else
            TextField(
              obscureText: q['isSecret'] == true,
              onChanged: (v) => _answers[q['id'] as String] = v,
            ),
          const SizedBox(height: 10),
        ],
        FilledButton(
          onPressed: () => widget.app.answer(widget.request, {
            'answers': {
              for (final e in _answers.entries)
                e.key: {
                  'answers': [e.value],
                },
            },
          }),
          child: const Text('Submit'),
        ),
      ],
    );
  }
}
