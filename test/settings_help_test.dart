import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gerrymanderx/core/theme/app_theme.dart';
import 'package:gerrymanderx/modules/help/help_tab.dart';
import 'package:gerrymanderx/modules/settings/settings_tab.dart';
import 'package:gerrymanderx/providers/app_settings_store.dart';

Widget _wrap(AppSettingsStore store, Widget child) {
  return ChangeNotifierProvider.value(
    value: store,
    child: Builder(
      builder: (context) => MaterialApp(
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: context.watch<AppSettingsStore>().themeMode,
        home: child,
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppSettingsStore', () {
    test('defaults to system and persists the chosen theme', () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppSettingsStore();
      await store.load();
      expect(store.themeMode, ThemeMode.system);

      await store.setThemeMode(ThemeMode.dark);
      expect(store.themeMode, ThemeMode.dark);

      final reloaded = AppSettingsStore();
      await reloaded.load();
      expect(reloaded.themeMode, ThemeMode.dark);
    });
  });

  group('SettingsTab', () {
    testWidgets('shows theme segments and About & Legal rows',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = AppSettingsStore();
      await store.load();
      await tester.pumpWidget(_wrap(store, const SettingsTab()));
      await tester.pumpAndSettle();

      expect(find.text('APPEARANCE'), findsOneWidget);
      expect(find.text('ABOUT & LEGAL'), findsOneWidget);
      expect(find.text('Theme'), findsOneWidget);
      expect(find.text('System'), findsOneWidget);
      expect(find.text('Light'), findsOneWidget);
      expect(find.text('Dark'), findsOneWidget);
      expect(find.text('Feedback'), findsOneWidget);
      expect(find.text('Privacy Policy'), findsOneWidget);
      expect(find.text('About'), findsOneWidget);
      expect(find.textContaining('Version'), findsOneWidget);
    });

    testWidgets('tapping Light switches the app theme', (tester) async {
      SharedPreferences.setMockInitialValues({'themeMode': ThemeMode.dark.index});
      final store = AppSettingsStore();
      await store.load();
      await tester.pumpWidget(_wrap(store, const SettingsTab()));
      await tester.pumpAndSettle();

      final ctx = tester.element(find.text('Theme'));
      expect(Theme.of(ctx).brightness, Brightness.dark);

      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();
      expect(store.themeMode, ThemeMode.light);
      final ctx2 = tester.element(find.text('Theme'));
      expect(Theme.of(ctx2).brightness, Brightness.light);
    });
  });

  group('HelpTab', () {
    testWidgets('renders bundled help.md as markdown', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = AppSettingsStore();
      await store.load();
      await tester.pumpWidget(_wrap(store, const HelpTab()));
      await tester.pumpAndSettle();

      expect(find.byType(Markdown), findsOneWidget);
      expect(find.text('GerrymanderX Help'), findsOneWidget);
    });
  });
}
