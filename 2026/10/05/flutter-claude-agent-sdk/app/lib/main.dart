import 'package:flutter/material.dart';

import 'state/app_controller.dart';
import 'ui/home_page.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final app = AppController()..start();
  runApp(ClaudeApp(app: app));
}

class ClaudeApp extends StatelessWidget {
  const ClaudeApp({super.key, required this.app});

  final AppController app;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Claude (Flutter)',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: HomePage(app: app),
    );
  }
}
