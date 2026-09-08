import 'package:flutter/material.dart';

import '../theme/tcloud_brand_theme.dart';
import '../theme/tcloud_theme_controller.dart';

/// Bridge de compatibilidade para telas antigas.
///
/// As telas novas devem preferir Theme.of(context).colorScheme.
/// Este bridge existe para que componentes legados que ainda usam
/// TCloudTheme.* acompanhem Claro / Escuro / Sistema sem precisar
/// de uma migracao agressiva de todos os widgets de uma vez.
abstract final class TCloudTheme {
  static bool get _dark {
    final mode = TCloudThemeController.instance.mode;

    if (mode == ThemeMode.dark) return true;
    if (mode == ThemeMode.light) return false;

    return WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.dark;
  }

  static Color get primary =>
      _dark ? const Color(0xFFA78BFA) : TCloudBrandTheme.azul;

  static Color get background =>
      _dark ? TCloudBrandTheme.darkBackground : const Color(0xFFF8FAFD);

  static Color get surface =>
      _dark ? TCloudBrandTheme.darkSurface : const Color(0xFFFFFCF7);

  static Color get surfaceSoft =>
      _dark ? TCloudBrandTheme.darkSurfaceAlt : const Color(0xFFF1F4F9);

  static Color get border =>
      _dark ? TCloudBrandTheme.darkBorder : const Color(0xFFDDE3EA);

  static Color get textPrimary =>
      _dark ? TCloudBrandTheme.darkText : TCloudBrandTheme.marinho;

  static Color get textSecondary =>
      _dark ? const Color(0xFFAAB2BF) : const Color(0xFF657083);

  static Color get success =>
      _dark ? const Color(0xFF93A78E) : TCloudBrandTheme.salvia;

  static Color get warning => TCloudBrandTheme.milho;

  static ThemeData get dark => TCloudBrandTheme.dark;
  static ThemeData get light => TCloudBrandTheme.light;
}
