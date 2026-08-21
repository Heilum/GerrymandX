import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:gerrymanderx/core/constants/app_constants.dart';
import 'package:gerrymanderx/core/theme/app_theme.dart';
import 'package:gerrymanderx/modules/auth/auth_gate.dart';
import 'package:gerrymanderx/providers/app_settings_store.dart';

class GerrymanderXApp extends StatelessWidget {
  const GerrymanderXApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeMode = context.watch<AppSettingsStore>().themeMode;
    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      home: const AuthGate(),
    );
  }
}
