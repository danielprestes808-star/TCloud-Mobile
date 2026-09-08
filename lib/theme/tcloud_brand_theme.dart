import 'package:flutter/material.dart';
import 'tcloud_theme_preset.dart';

/// Identidade visual oficial TCloud 2.0.
abstract final class TCloudBrandTheme {
  static const marinho = Color(0xFF17243A);
  static const azul = Color(0xFF7C5CFC);
  static const azulEscuro = Color(0xFF6546E8);
  static const terracota = Color(0xFFC36B4C);
  static const salvia = Color(0xFF82917F);
  static const milho = Color(0xFFE6C46A);
  static const marfim = Color(0xFFF6F1E8);

  static const darkBackground = Color(0xFF090A0F);
  static const darkSurface = Color(0xFF12141B);
  static const darkSurfaceAlt = Color(0xFF191C25);
  static const darkBorder = Color(0xFF2A2D37);
  static const darkText = Color(0xFFE9EAF0);

  static ThemeData fromPreset(TCloudThemePreset preset) {
    final base = preset.dark ? dark : light;
    final foreground = preset.dark
        ? const Color(0xFFF1F5F9)
        : const Color(0xFF172033);
    final muted = preset.dark
        ? const Color(0xFFA7B0C0)
        : const Color(0xFF627087);
    final border = Color.alphaBlend(
      foreground.withValues(alpha: .14),
      preset.surface,
    );
    final scheme = ColorScheme.fromSeed(
      seedColor: preset.accent,
      brightness: preset.dark ? Brightness.dark : Brightness.light,
      primary: preset.accent,
      surface: preset.surface,
    );
    final radius = BorderRadius.circular(7);
    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: preset.background,
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: preset.background,
        foregroundColor: foreground,
      ),
      cardTheme: CardThemeData(
        color: preset.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: border),
        ),
      ),
      navigationBarTheme: base.navigationBarTheme.copyWith(
        backgroundColor: preset.surface,
        indicatorColor: preset.accent.withValues(alpha: .18),
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        fillColor: Color.alphaBlend(
          foreground.withValues(alpha: .045),
          preset.surface,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: preset.accent, width: 1.4),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: preset.accent,
          foregroundColor: preset.dark ? Colors.white : const Color(0xFFFFFFFF),
          shape: RoundedRectangleBorder(borderRadius: radius),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: preset.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      ),
      bottomSheetTheme: base.bottomSheetTheme.copyWith(
        backgroundColor: preset.surface,
      ),
      dividerColor: border,
      textTheme: base.textTheme
          .apply(bodyColor: foreground, displayColor: foreground)
          .copyWith(
            bodySmall: base.textTheme.bodySmall?.copyWith(color: muted),
          ),
    );
  }

  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: azul,
      brightness: Brightness.light,
      primary: azul,
      secondary: salvia,
      surface: const Color(0xFFFFFCF7),
      error: const Color(0xFFB5483D),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFFF8FAFD),
      fontFamily: 'SourceSans3',
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFFF8FAFD),
        foregroundColor: marinho,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 60,
      ),
      cardTheme: CardThemeData(
        color: const Color(0xFFFFFCF7),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: Color(0xFFDDE3EA)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        backgroundColor: const Color(0xFFFFFCF7),
        indicatorColor: azul.withValues(alpha: .12),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          return TextStyle(
            color: states.contains(WidgetState.selected) ? azul : marinho,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w500,
          );
        }),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFF1F4F9),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: const BorderSide(color: azul, width: 1.4),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 50),
          backgroundColor: azul,
          foregroundColor: const Color(0xFFFFF9F4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        ),
      ),
      searchBarTheme: SearchBarThemeData(
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: const WidgetStatePropertyAll(Color(0xFFF1F4F9)),
        side: const WidgetStatePropertyAll(BorderSide.none),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 16),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: const Color(0xFFFFFCF7),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Color(0xFFFFFCF7),
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        minTileHeight: 56,
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        iconColor: marinho,
        textColor: marinho,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(7)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: azul,
        linearTrackColor: Color(0xFFDDE3EA),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: const Color(0xFFFFFCF7),
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: const Color(0xFFF1F4F9),
        selectedColor: azul.withValues(alpha: .14),
        side: const BorderSide(color: Color(0xFFDDE3EA)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      dividerColor: const Color(0xFFDDE3EA),
    );
  }

  static ThemeData get dark {
    final scheme = ColorScheme.fromSeed(
      seedColor: azul,
      brightness: Brightness.dark,
      primary: const Color(0xFFA78BFA),
      secondary: const Color(0xFF93A78E),
      surface: darkSurface,
      error: const Color(0xFFFF8879),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: darkBackground,
      fontFamily: 'SourceSans3',
      appBarTheme: const AppBarTheme(
        backgroundColor: darkBackground,
        foregroundColor: darkText,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 64,
      ),
      cardTheme: CardThemeData(
        color: darkSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: darkBorder),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        backgroundColor: darkSurface,
        indicatorColor: azul.withValues(alpha: .28),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: darkSurface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: const BorderSide(color: darkBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: const BorderSide(color: darkBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: const BorderSide(color: Color(0xFFA78BFA), width: 1.4),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 50),
          backgroundColor: const Color(0xFF8B5CF6),
          foregroundColor: const Color(0xFF071529),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        ),
      ),
      searchBarTheme: SearchBarThemeData(
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: const WidgetStatePropertyAll(darkSurface),
        side: const WidgetStatePropertyAll(BorderSide(color: darkBorder)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 16),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: darkSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: darkSurface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        minTileHeight: 56,
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        iconColor: darkText,
        textColor: darkText,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(7)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: Color(0xFFA78BFA),
        linearTrackColor: darkBorder,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: darkSurfaceAlt,
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: darkSurfaceAlt,
        selectedColor: azul.withValues(alpha: .28),
        side: const BorderSide(color: darkBorder),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      dividerColor: darkBorder,
    );
  }
}
