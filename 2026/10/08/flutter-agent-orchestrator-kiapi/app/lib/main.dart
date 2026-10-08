import 'package:flutter/material.dart';

import 'orchestrator/hub.dart';
import 'ui/home_page.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final hub = Hub()..start();
  runApp(OrchestratorApp(hub: hub));
}

class OrchestratorApp extends StatelessWidget {
  const OrchestratorApp({super.key, required this.hub});

  final Hub hub;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Agent Orchestrator',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: HomePage(hub: hub),
    );
  }
}
