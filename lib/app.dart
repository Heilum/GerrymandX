import 'package:flutter/material.dart';
import 'package:gerrymanderx/modules/main_shell.dart';
import 'package:gerrymanderx/core/theme/app_theme.dart';

class GerrymanderXApp extends StatelessWidget {
  const GerrymanderXApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GerrymanderX',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.dark,
      home: const MainShell(),
    );
  }
}
