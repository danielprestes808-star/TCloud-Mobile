import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'tcloud_theme_preset.dart';

class TCloudThemeController extends ChangeNotifier {
  TCloudThemeController._();

  static final instance = TCloudThemeController._();
  static const _key = 'tcloud_theme_mode_v2';
  static const _presetKey = 'tcloud_theme_preset_v3';

  ThemeMode _mode = ThemeMode.system;
  String _presetId = 'default-dark';

  ThemeMode get mode => _mode;
  String get presetId => _presetId;
  TCloudThemePreset get preset => presetById(_presetId);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_key);
    _presetId = prefs.getString(_presetKey) ?? 'default-dark';

    _mode = switch (saved) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

    notifyListeners();
  }

  Future<void> setPreset(String id) async {
    final selected = presetById(id);
    _presetId = selected.id;
    _mode = selected.dark ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_presetKey, _presetId);
    await prefs.setString(_key, selected.dark ? 'dark' : 'light');
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
