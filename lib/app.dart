import 'package:flutter/material.dart';

import 'screens/login_screen.dart';

import 'theme/tcloud_brand_theme.dart';

import 'theme/tcloud_theme_controller.dart';
import 'widgets/biometric_app_lock.dart';

// TCLOUD_ECOSYSTEM_THEME_BOUND_200
class TCloudApp extends StatelessWidget {
  const TCloudApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      // TCLOUD_THEME_ROOT_EXACT_203
      animation: TCloudThemeController.instance,
      builder: (context, _) {
        final controller = TCloudThemeController.instance;
        return MaterialApp(
          darkTheme: TCloudBrandTheme.fromPreset(controller.preset),
          themeMode: controller.mode,
          title: 'TCloud',
          debugShowCheckedModeBanner: false,
          theme: TCloudBrandTheme.fromPreset(controller.preset),
          home: const BiometricAppLock(child: LoginScreen()),
        );
      },
    );
  }
}
