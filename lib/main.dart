import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';
import 'app.dart';
import 'services/tcloud_foundation5_bridge.dart';

import 'theme/tcloud_theme_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  TCloudFoundation5Bridge.instance.start();
  // TCloud gallery memory guard.
  PaintingBinding.instance.imageCache
    ..maximumSize = 72
    ..maximumSizeBytes = 32 * 1024 * 1024;

  VideoPlayerMediaKit.ensureInitialized(android: true);
  runApp(const TCloudApp());
  unawaited(TCloudThemeController.instance.load());
}
