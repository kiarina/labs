import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../state/thread_view.dart';
import 'theme.dart';

final _markdownConfig = MarkdownConfig.darkConfig.copy(
  configs: [
    const PConfig(
      textStyle: TextStyle(fontSize: 14, height: 1.55, color: Palette.text),
    ),
    const CodeConfig(
      style: TextStyle(
        fontFamily: monoFamily,
        fontSize: 12.5,
        backgroundColor: Palette.surfaceHigh,
        color: Palette.text,
      ),
    ),
    PreConfig.darkConfig.copy(
      decoration: BoxDecoration(
        color: Palette.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Palette.border),
      ),
      textStyle: const TextStyle(fontFamily: monoFamily, fontSize: 12.5),
      padding: const EdgeInsets.all(12),
    ),
    H1Config(
      style: const TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: Palette.text,
      ),
    ),
    H2Config(
      style: const TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: Palette.text,
      ),
    ),
    H3Config(
      style: const TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: Palette.text,
      ),
    ),
  ],
);

class ItemWidget extends StatelessWidget {
  const ItemWidget({super.key, required this.item});

  final ItemState item;

  @override
  Widget build(BuildContext context) {
    return switch (item.type) {
      'userMessage' => _UserMessage(item),
      'agentMessage' => _AgentMessage(item),
      'reasoning' => _Reasoning(item),
      'commandExecution' => _Command(item),
      'fileChange' => _FileChange(item),
      'mcpToolCall' => _ToolCall(
        item,
        title: '${item.data['server']}.${item.data['tool']}',
        icon: Icons.extension_outlined,
      ),
      // Claude Code's other tools (Read, Grep, Task, Skill, ...).
      'toolCall' => _ToolCall(
        item,
        title: '${item.data['label'] ?? item.data['tool']}',
        icon: _toolIcon(item.data['tool'] as String?),
        verb: '',
      ),
      'dynamicToolCall' => _ToolCall(
        item,
        title: '${item.data['tool']}',
        icon: Icons.build_outlined,
      ),
      'webSearch' => _Line(
        icon: Icons.travel_explore,
        text: 'Searched “${item.data['query'] ?? ''}”',
        running: !item.completed,
      ),
      'plan' => _AgentMessage(item),
      'contextCompaction' => const _Line(
        icon: Icons.compress,
        text: 'Context compacted',
      ),
      'imageAttachment' => _ImageAttachment(item),
      'imageView' => _Line(
        icon: Icons.image_outlined,
        text: 'Viewed ${item.data['path']}',
      ),
      'enteredReviewMode' => const _Line(
        icon: Icons.rate_review_outlined,
        text: 'Entered review mode',
      ),
      'exitedReviewMode' => _AgentMessage(item),
      _ => _Line(
        icon: Icons.more_horiz,
        text: item.type,
        running: !item.completed,
      ),
    };
  }
}

class _UserMessage extends StatelessWidget {
  const _UserMessage(this.item);

  final ItemState item;

  @override
  Widget build(BuildContext context) {
    final content = (item.data['content'] as List? ?? const []).cast<Map>();
    final text = content
        .map(
          (c) => switch (c['type']) {
            'text' => c['text'] as String,
            'localImage' => '[image: ${c['path']}]',
            'image' => '[image]',
            'mention' || 'skill' => '@${c['name']}',
            _ => '',
          },
        )
        .join('\n');
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 560),
        margin: const EdgeInsets.only(top: 12, bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Palette.surfaceHigh,
          borderRadius: BorderRadius.circular(16),
        ),
        child: SelectableText(
          text,
          style: const TextStyle(fontSize: 14, height: 1.5),
        ),
      ),
    );
  }
}

class _AgentMessage extends StatelessWidget {
  const _AgentMessage(this.item);

  final ItemState item;

  @override
  Widget build(BuildContext context) {
    final text = item.type == 'exitedReviewMode'
        ? item.data['review'] as String? ?? ''
        : item.displayText;
    if (text.isEmpty) return const SizedBox.shrink();
    // Commentary (progress notes between tool calls) is dimmer than the
    // final answer.
    final commentary = item.data['phase'] == 'commentary';
    final md = MarkdownBlock(data: text, config: _markdownConfig);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: commentary ? Opacity(opacity: 0.72, child: md) : md,
    );
  }
}

class _Reasoning extends StatelessWidget {
  const _Reasoning(this.item);

  final ItemState item;

  @override
  Widget build(BuildContext context) {
    final parts = item.reasoningParts
        .where((p) => p.trim().isNotEmpty)
        .toList();
    if (parts.isEmpty) {
      return item.completed
          ? const SizedBox.shrink()
          : const _Line(
              icon: Icons.psychology_outlined,
              text: 'Thinking',
              running: true,
            );
    }
    // The first bold line of a summary part is its heading.
    final heading =
        RegExp(r'^\*\*(.+?)\*\*').firstMatch(parts.last.trim())?.group(1) ??
        'Thinking';
    return _Expandable(
      icon: Icons.psychology_outlined,
      title: Text(
        heading,
        style: const TextStyle(color: Palette.textDim, fontSize: 13),
      ),
      running: !item.completed,
      child: Padding(
        padding: const EdgeInsets.only(left: 22, top: 4),
        child: Opacity(
          opacity: 0.7,
          child: MarkdownBlock(
            data: parts.join('\n\n'),
            config: _markdownConfig,
          ),
        ),
      ),
    );
  }
}

class _Command extends StatelessWidget {
  const _Command(this.item);

  final ItemState item;

  @override
  Widget build(BuildContext context) {
    final data = item.data;
    final actions = (data['commandActions'] as List? ?? const []).cast<Map>();
    final label =
        _describeActions(actions) ??
        _firstLine(_stripShell(data['command'] as String? ?? ''));
    final status = data['status'] as String?;
    final exit = data['exitCode'] as int?;
    final failed = status == 'failed' || (exit != null && exit != 0);
    final declined = status == 'declined';
    final output = item.commandOutput;
    return _Expandable(
      icon: Icons.terminal,
      running: !item.completed && status == 'inProgress',
      title: Row(
        children: [
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: monoFamily,
                fontSize: 12.5,
                color: Palette.textDim,
              ),
            ),
          ),
          if (failed) _badge('exit ${exit ?? '?'}', Palette.removed),
          if (declined) _badge('declined', Palette.warning),
        ],
      ),
      child: _CodeBox(
        text: '\$ ${_stripShell(data['command'] as String? ?? '')}\n$output',
        maxHeight: 280,
      ),
    );
  }

  static String? _describeActions(List<Map> actions) {
    if (actions.isEmpty) return null;
    final parts = <String>[];
    for (final a in actions) {
      switch (a['type']) {
        case 'read':
          parts.add('Read ${a['name'] ?? a['path']}');
        case 'listFiles':
          parts.add('Listed ${a['path'] ?? 'files'}');
        case 'search':
          parts.add(
            'Searched ${a['query'] ?? ''}${a['path'] != null ? ' in ${a['path']}' : ''}',
          );
        default:
          return null;
      }
    }
    return parts.join(', ');
  }
}

/// A heredoc or multi-line script is shown by its first line in the title.
String _firstLine(String s) {
  final lines = s.split('\n');
  return lines.length == 1 ? s : '${lines.first} …';
}

String _stripShell(String command) {
  final m = RegExp(r'''^\S*(?:ba|z)?sh -lc (["'])([\s\S]*)\1$''')
      .firstMatch(command);
  return m?.group(2)?.replaceAll(r'\"', '"') ?? command;
}

Widget _badge(String text, Color color) => Container(
  margin: const EdgeInsets.only(left: 8),
  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
  decoration: BoxDecoration(
    borderRadius: BorderRadius.circular(4),
    border: Border.all(color: color.withValues(alpha: 0.6)),
  ),
  child: Text(text, style: TextStyle(fontSize: 11, color: color)),
);

class _FileChange extends StatelessWidget {
  const _FileChange(this.item);

  final ItemState item;

  @override
  Widget build(BuildContext context) {
    final changes = (item.data['changes'] as List? ?? const []).cast<Map>();
    final cwd = context.findAncestorWidgetOfExactType<CwdScope>()?.cwd;
    final status = item.data['status'] as String?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final c in changes)
          _Expandable(
            icon: Icons.edit_note,
            running: status == 'inProgress',
            initiallyExpanded: false,
            title: Row(
              children: [
                Text(
                  _kindLabel(c['kind'] as Map?),
                  style: const TextStyle(fontSize: 13, color: Palette.textDim),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    _relativePath(c['path'] as String, cwd),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: monoFamily,
                      fontSize: 12.5,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ..._diffStat(_unifiedDiff(c)),
                if (status == 'declined') _badge('declined', Palette.warning),
                if (status == 'failed') _badge('failed', Palette.removed),
              ],
            ),
            child: DiffView(diff: _unifiedDiff(c)),
          ),
      ],
    );
  }

  static String _kindLabel(Map? kind) => switch (kind?['type']) {
    'add' => 'Created',
    'delete' => 'Deleted',
    _ => 'Edited',
  };
}

/// Provides the thread's cwd so paths can be shown relative to it.
class CwdScope extends InheritedWidget {
  const CwdScope({super.key, required this.cwd, required super.child});

  final String cwd;

  @override
  bool updateShouldNotify(CwdScope oldWidget) => cwd != oldWidget.cwd;
}

String _relativePath(String path, String? cwd) {
  if (cwd != null) {
    for (final root in [
      cwd,
      '/private$cwd',
      cwd.replaceFirst('/private', ''),
    ]) {
      if (path.startsWith('$root/')) return path.substring(root.length + 1);
    }
  }
  final parts = path.split('/');
  return parts.length <= 3
      ? path
      : '…/${parts.sublist(parts.length - 3).join('/')}';
}

/// `add` and `delete` changes carry the file content, `update` a unified diff.
String _unifiedDiff(Map change) {
  final diff = change['diff'] as String? ?? '';
  final prefix = switch ((change['kind'] as Map?)?['type']) {
    'add' => '+',
    'delete' => '-',
    _ => null,
  };
  if (prefix == null) return diff;
  return const LineSplitter().convert(diff).map((l) => '$prefix$l').join('\n');
}

List<Widget> _diffStat(String diff) {
  var added = 0, removed = 0;
  for (final line in const LineSplitter().convert(diff)) {
    if (line.startsWith('+') && !line.startsWith('+++')) added++;
    if (line.startsWith('-') && !line.startsWith('---')) removed++;
  }
  return [
    Text('+$added', style: const TextStyle(fontSize: 12, color: Palette.added)),
    const SizedBox(width: 4),
    Text(
      '-$removed',
      style: const TextStyle(fontSize: 12, color: Palette.removed),
    ),
  ];
}

class DiffView extends StatelessWidget {
  const DiffView({super.key, required this.diff, this.maxHeight = 360});

  final String diff;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final lines = const LineSplitter().convert(diff);
    return Container(
      width: double.infinity,
      constraints: BoxConstraints(maxHeight: maxHeight),
      margin: const EdgeInsets.only(top: 4, bottom: 4),
      decoration: BoxDecoration(
        color: Palette.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Palette.border),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: SelectableText.rich(
          TextSpan(
            children: [
              for (final l in lines)
                TextSpan(
                  text: '$l\n',
                  style: TextStyle(
                    color: l.startsWith('@@')
                        ? Palette.textFaint
                        : l.startsWith('+')
                        ? Palette.added
                        : l.startsWith('-')
                        ? Palette.removed
                        : Palette.textDim,
                    backgroundColor: l.startsWith('+') && !l.startsWith('+++')
                        ? Palette.added.withValues(alpha: 0.08)
                        : l.startsWith('-') && !l.startsWith('---')
                        ? Palette.removed.withValues(alpha: 0.08)
                        : null,
                  ),
                ),
            ],
          ),
          style: const TextStyle(
            fontFamily: monoFamily,
            fontSize: 12,
            height: 1.45,
          ),
        ),
      ),
    );
  }
}

IconData _toolIcon(String? tool) => switch (tool) {
  'Read' => Icons.description_outlined,
  'Glob' || 'Grep' || 'ToolSearch' => Icons.search,
  'WebFetch' => Icons.public,
  'Task' || 'Agent' => Icons.account_tree_outlined,
  'TodoWrite' => Icons.checklist,
  'Skill' => Icons.auto_fix_high_outlined,
  _ => Icons.build_outlined,
};

class _ToolCall extends StatelessWidget {
  const _ToolCall(
    this.item, {
    required this.title,
    required this.icon,
    this.verb = 'Called ',
  });

  final ItemState item;
  final String title;
  final IconData icon;
  final String verb;

  @override
  Widget build(BuildContext context) {
    final d = item.data;
    const encoder = JsonEncoder.withIndent('  ');
    final args = d['arguments'] == null ? '' : encoder.convert(d['arguments']);
    final result = d['result'] ?? d['contentItems'];
    final error = (d['error'] as Map?)?['message'];
    return _Expandable(
      icon: icon,
      running: d['status'] == 'inProgress',
      title: Row(
        children: [
          if (verb.isNotEmpty)
            Text(
              verb,
              style: const TextStyle(fontSize: 13, color: Palette.textDim),
            ),
          Flexible(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontFamily: monoFamily, fontSize: 12.5),
            ),
          ),
          if (error != null) _badge('error', Palette.removed),
        ],
      ),
      child: _CodeBox(
        text: [
          if (args.isNotEmpty) 'arguments:\n$args',
          if (result != null)
            'result:\n${result is String ? result : encoder.convert(result)}',
          if (error != null) 'error: $error',
        ].join('\n\n'),
        maxHeight: 260,
      ),
    );
  }
}

class _CodeBox extends StatelessWidget {
  const _CodeBox({required this.text, this.maxHeight = 240});

  final String text;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      width: double.infinity,
      margin: const EdgeInsets.only(top: 4, bottom: 4),
      decoration: BoxDecoration(
        color: Palette.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Palette.border),
      ),
      child: SingleChildScrollView(
        reverse: true,
        padding: const EdgeInsets.all(10),
        child: SelectableText(
          text.trimRight(),
          style: const TextStyle(
            fontFamily: monoFamily,
            fontSize: 12,
            height: 1.45,
            color: Palette.textDim,
          ),
        ),
      ),
    );
  }
}

/// An image the orchestrator fetched from a body. Click to see it larger.
class _ImageAttachment extends StatefulWidget {
  const _ImageAttachment(this.item);

  final ItemState item;

  @override
  State<_ImageAttachment> createState() => _ImageAttachmentState();
}

class _ImageAttachmentState extends State<_ImageAttachment> {
  // Decoded once; the transcript rebuilds on every streamed delta.
  late final bytes = base64Decode(widget.item.data['data'] as String);

  @override
  Widget build(BuildContext context) {
    final d = widget.item.data;
    final image = Image.memory(bytes, gaplessPlayback: true);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.image_outlined,
                size: 14,
                color: Palette.textDim,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '${d['body']} · ${d['path']} · ${d['width']}×${d['height']}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Palette.textDim),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          MouseRegion(
            cursor: SystemMouseCursors.zoomIn,
            child: GestureDetector(
              onTap: () => showDialog<void>(
                context: context,
                builder: (context) => Dialog(
                  backgroundColor: Palette.surface,
                  insetPadding: const EdgeInsets.all(24),
                  child: InteractiveViewer(maxScale: 6, child: image),
                ),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: image,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.text, this.running = false});

  final IconData icon;
  final String text;
  final bool running;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          _LeadingIcon(icon: icon, running: running),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: Palette.textDim),
            ),
          ),
        ],
      ),
    );
  }
}

class _LeadingIcon extends StatelessWidget {
  const _LeadingIcon({required this.icon, required this.running});

  final IconData icon;
  final bool running;

  @override
  Widget build(BuildContext context) {
    if (running) {
      return const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 1.5,
          color: Palette.textDim,
        ),
      );
    }
    return Icon(icon, size: 14, color: Palette.textFaint);
  }
}

class _Expandable extends StatefulWidget {
  const _Expandable({
    required this.icon,
    required this.title,
    required this.child,
    this.running = false,
    this.initiallyExpanded = false,
  });

  final IconData icon;
  final Widget title;
  final Widget child;
  final bool running;
  final bool initiallyExpanded;

  @override
  State<_Expandable> createState() => _ExpandableState();
}

class _ExpandableState extends State<_Expandable> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  _LeadingIcon(icon: widget.icon, running: widget.running),
                  const SizedBox(width: 8),
                  Flexible(child: widget.title),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 14,
                    color: Palette.textFaint,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) widget.child,
        ],
      ),
    );
  }
}
