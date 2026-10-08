import 'dart:convert';

import 'package:flutter/material.dart';

import '../console/console.dart';
import '../state/thread_view.dart';
import 'theme.dart';

/// Shown above the composer while Claude waits for the user: a `canUseTool`
/// call forwarded by the bridge as `permission/request`.
class PendingRequestCard extends StatelessWidget {
  const PendingRequestCard({
    super.key,
    required this.app,
    required this.request,
  });

  final ConsoleMirror app;
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
      child: p['toolName'] == 'AskUserQuestion'
          ? _QuestionForm(app: app, request: request)
          : _permission(p),
    );
  }

  Widget _permission(Json p) {
    final tool = p['toolName'] as String;
    final input = (p['input'] as Map? ?? const {}).cast<String, dynamic>();
    final suggestions = (p['suggestions'] as List? ?? const []).cast<Map>();
    final (title, body) = _describe(tool, input);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        if (p['decisionReason'] case final String reason) ...[
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
            constraints: const BoxConstraints(maxHeight: 220),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Palette.background,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                body,
                style: const TextStyle(fontFamily: monoFamily, fontSize: 12),
              ),
            ),
          ),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: () => app.answer(request, {'behavior': 'allow'}),
              child: const Text('Allow'),
            ),
            // Claude Code's suggestions, e.g. switch this session to
            // acceptEdits, or add an allow rule for the command.
            if (suggestions.isNotEmpty)
              OutlinedButton(
                onPressed: () => app.answer(request, {
                  'behavior': 'allow',
                  'updatedPermissions': suggestions,
                }),
                child: Text(_describeSuggestions(suggestions)),
              ),
            TextButton(
              onPressed: () => app.answer(request, {
                'behavior': 'deny',
                'message': 'The user declined this action',
              }),
              child: const Text('Deny'),
            ),
          ],
        ),
      ],
    );
  }

  static (String, String) _describe(String tool, Json input) {
    switch (tool) {
      case 'Bash':
        return ('Run this command?', input['command'] as String? ?? '');
      case 'Write':
        return (
          'Create ${input['file_path']}?',
          input['content'] as String? ?? '',
        );
      case 'Edit' || 'MultiEdit':
        return ('Edit ${input['file_path']}?', _editPreview(input));
      case 'WebFetch':
        return ('Fetch this URL?', input['url'] as String? ?? '');
      default:
        return (
          'Allow $tool?',
          const JsonEncoder.withIndent('  ').convert(input),
        );
    }
  }

  static String _editPreview(Json input) {
    final edits = input['edits'] is List
        ? (input['edits'] as List).cast<Map>()
        : [input];
    return edits
        .map(
          (e) => [
            ...const LineSplitter()
                .convert(e['old_string'] as String? ?? '')
                .map((l) => '- $l'),
            ...const LineSplitter()
                .convert(e['new_string'] as String? ?? '')
                .map((l) => '+ $l'),
          ].join('\n'),
        )
        .join('\n\n');
  }

  static String _describeSuggestions(List<Map> suggestions) {
    final parts = <String>[];
    for (final s in suggestions) {
      final scope = s['destination'] == 'session' ? 'this session' : 'always';
      switch (s['type']) {
        case 'setMode':
          parts.add(switch (s['mode']) {
            'acceptEdits' => 'accept edits for $scope',
            'bypassPermissions' => 'bypass permissions for $scope',
            final m => '$m for $scope',
          });
        case 'addRules':
          final rules = (s['rules'] as List? ?? const []).cast<Map>().map((r) {
            final content = r['ruleContent'];
            return content == null
                ? r['toolName']
                : '${r['toolName']}($content)';
          });
          parts.add('allow ${rules.join(', ')} ($scope)');
        case 'addDirectories':
          parts.add('allow ${(s['directories'] as List).join(', ')}');
        default:
          parts.add('${s['type']}');
      }
    }
    final text = parts.join(', ');
    return 'Allow and ${text.length > 60 ? '${text.substring(0, 60)}…' : text}';
  }
}

/// AskUserQuestion: Claude Code asks through `canUseTool`, and the answers go
/// back in `updatedInput.answers` (question text -> chosen label).
class _QuestionForm extends StatefulWidget {
  const _QuestionForm({required this.app, required this.request});

  final ConsoleMirror app;
  final PendingRequest request;

  @override
  State<_QuestionForm> createState() => _QuestionFormState();
}

class _QuestionFormState extends State<_QuestionForm> {
  final _answers = <String, String>{};

  @override
  Widget build(BuildContext context) {
    final input = (widget.request.params['input'] as Map)
        .cast<String, dynamic>();
    final questions = (input['questions'] as List? ?? const []).cast<Map>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final q in questions) ...[
          Text(
            q['question'] as String,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final o in (q['options'] as List? ?? const []).cast<Map>())
                ChoiceChip(
                  label: Text(o['label'] as String),
                  tooltip: o['description'] as String?,
                  selected: _answers[q['question']] == o['label'],
                  onSelected: (_) => setState(
                    () => _answers[q['question'] as String] =
                        o['label'] as String,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
        ],
        Row(
          children: [
            FilledButton(
              onPressed: _answers.length < questions.length
                  ? null
                  : () => widget.app.answer(widget.request, {
                      'behavior': 'allow',
                      'updatedInput': {...input, 'answers': _answers},
                    }),
              child: const Text('Submit'),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => widget.app.answer(widget.request, {
                'behavior': 'deny',
                'message': 'The user dismissed the question',
              }),
              child: const Text('Dismiss'),
            ),
          ],
        ),
      ],
    );
  }
}
