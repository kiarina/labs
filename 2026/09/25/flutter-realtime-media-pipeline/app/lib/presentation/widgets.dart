import 'package:flutter/material.dart';
import 'package:realtime_core/realtime_core.dart';

String fmt(double? v, [int digits = 1]) =>
    v == null ? '-' : v.toStringAsFixed(digits);

String ms(Duration? d) =>
    d == null ? '-' : '${(d.inMicroseconds / 1000).toStringAsFixed(1)} ms';

class Section extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const Section(this.title, this.children, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        ...children,
      ],
    ),
  );
}

class StatusDot extends StatelessWidget {
  final bool on;
  final String label;

  const StatusDot({super.key, required this.on, required this.label});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.circle, size: 10, color: on ? Colors.green : Colors.grey),
      const SizedBox(width: 6),
      Flexible(child: Text(label)),
    ],
  );
}

class LevelBar extends StatelessWidget {
  final double level;

  const LevelBar({super.key, required this.level});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: 200,
        child: LinearProgressIndicator(value: level.clamp(0, 1), minHeight: 8),
      ),
      const SizedBox(width: 8),
      Text('Level ${level.toStringAsFixed(3)}'),
    ],
  );
}

/// Shows the simulated device's cursor that MoveAction moves.
class OperationApiView extends StatelessWidget {
  final OperationApiState state;

  const OperationApiView({super.key, required this.state});

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        width: 96,
        height: 96,
        decoration: BoxDecoration(border: Border.all(color: Colors.grey)),
        child: Align(
          alignment: Alignment(state.x, state.y),
          child: const Icon(Icons.circle, size: 12, color: Colors.orange),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Text(
          'Handled ${state.handled} · last ${state.lastType ?? '-'}\n'
          'cursor (${state.x.toStringAsFixed(2)}, ${state.y.toStringAsFixed(2)})\n'
          '${state.customCounts}',
        ),
      ),
    ],
  );
}
