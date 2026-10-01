import 'package:flutter/material.dart';

import 'state/app_controller.dart';
import 'ui/home_page.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final app = AppController()..start();
  runApp(CodexApp(app: app));
}

class CodexApp extends StatelessWidget {
  const CodexApp({super.key, required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Codex (Flutter)',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: HomePage(app: app),
    );
  }
}
