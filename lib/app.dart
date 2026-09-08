import 'package:flutter/material.dart';

import 'screens/login_screen.dart';

import 'theme/tcloud_brand_theme.dart';

import 'theme/tcloud_theme_controller.dart';

// TCLOUD_ECOSYSTEM_THEME_BOUND_200
class TCloudApp extends StatelessWidget {
  const TCloudApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      // TCLOUD_THEME_ROOT_EXACT_203
      animation: TCloudThemeController.instance,
      builder: (context, _) => MaterialApp(
        darkTheme: TCloudBrandTheme.dark,
        themeMode: TCloudThemeController.instance.mode,
        title: 'TCloud',
        debugShowCheckedModeBanner: false,
        theme: TCloudBrandTheme.light,
        home: const LoginScreen(),
      ),
    );
  }
}
