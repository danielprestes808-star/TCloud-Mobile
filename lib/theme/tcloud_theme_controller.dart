import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TCloudThemeController extends ChangeNotifier {
  TCloudThemeController._();

  static final instance = TCloudThemeController._();
  static const _key = 'tcloud_theme_mode_v2';

  ThemeMode _mode = ThemeMode.system;

  ThemeMode get mode => _mode;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_key);

    _mode = switch (saved) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

    notifyListeners();
  }

  Future<void> setMode(ThemeMode value) async {
    _mode = value;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(_key, switch (value) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    });
  }
}
