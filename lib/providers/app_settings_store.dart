import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide user preferences (currently just the theme mode), persisted with
/// [SharedPreferences] so they survive relaunches.
class AppSettingsStore extends ChangeNotifier {
  static const _themeModeKey = 'themeMode';

  SharedPreferences? _prefs;
  ThemeMode _themeMode = ThemeMode.system;

  ThemeMode get themeMode => _themeMode;

  /// Loads persisted values. Safe to call before `runApp`.
  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    final index = _prefs!.getInt(_themeModeKey);
    if (index != null && index >= 0 && index < ThemeMode.values.length) {
      _themeMode = ThemeMode.values[index];
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
    await _prefs?.setInt(_themeModeKey, mode.index);
  }
}
