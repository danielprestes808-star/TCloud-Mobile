import 'package:flutter/material.dart';

/// TCloud Design System 1.0
/// Fonte semantica compartilhada com Desktop e Web.
/// Pode coexistir com TCloudTheme durante a migracao.
abstract final class TCloudDesign {
  static const background = Color(0xFF0F1115);
  static const surface = Color(0xFF171A20);
  static const surfaceSoft = Color(0xFF1D2129);
  static const surfaceRaised = Color(0xFF242933);

  static const border = Color(0xFF2C333F);
  static const borderStrong = Color(0xFF3A4351);

  static const text = Color(0xFFF5F7FA);
  static const textSecondary = Color(0xFFAAB3C0);
  static const textMuted = Color(0xFF7F8996);

  static const primary = Color(0xFF2F81F7);
  static const primaryHover = Color(0xFF4B93FA);
  static const primarySoft = Color(0x242F81F7);

  static const success = Color(0xFF3FB950);
  static const warning = Color(0xFFD29922);
  static const danger = Color(0xFFF85149);
  static const info = Color(0xFF58A6FF);

  static const radiusXs = 6.0;
  static const radiusSm = 8.0;
  static const radiusMd = 10.0;
  static const radiusLg = 12.0;
  static const radiusXl = 16.0;

  static const spaceXs = 4.0;
  static const spaceSm = 8.0;
  static const spaceMd = 12.0;
  static const spaceLg = 16.0;
  static const spaceXl = 24.0;
  static const spaceXxl = 32.0;

  static const controlHeight = 48.0;
  static const minTouchTarget = 48.0;

  static ThemeData darkTheme() {
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.dark,
      surface: surface,
      error: danger,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      dividerColor: border,
      cardColor: surface,
      navigationBarTheme: const NavigationBarThemeData(
        height: 68,
        backgroundColor: surface,
        indicatorColor: primarySoft,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceSoft,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: const BorderSide(color: primary, width: 1.5),
        ),
      ),
    );
  }
}

abstract final class TCloudLabels {
  static const files = 'Arquivos';
  static const recent = 'Recentes';
  static const favorites = 'Favoritos';
  static const offline = 'Disponível offline';
  static const trash = 'Lixeira';
  static const forums = 'Fóruns';
  static const settings = 'Configurações';

  static const newFolder = 'Nova pasta';
  static const upload = 'Enviar';
  static const newForum = 'Novo fórum';
  static const rename = 'Renomear';
  static const share = 'Compartilhar';
  static const download = 'Baixar';
  static const delete = 'Excluir';
}

enum TCloudSyncState {
  online,
  offline,
  syncing,
  uploading,
  downloading,
  attention,
  paused,
}

extension TCloudSyncStateUi on TCloudSyncState {
  String get label => switch (this) {
    TCloudSyncState.online => 'Somente online',
    TCloudSyncState.offline => 'Disponível neste dispositivo',
    TCloudSyncState.syncing => 'Sincronizando',
    TCloudSyncState.uploading => 'Enviando',
    TCloudSyncState.downloading => 'Baixando',
    TCloudSyncState.attention => 'Precisa de atenção',
    TCloudSyncState.paused => 'Pausado',
  };

  IconData get icon => switch (this) {
    TCloudSyncState.online => Icons.cloud_outlined,
    TCloudSyncState.offline => Icons.check_circle_outline,
    TCloudSyncState.syncing => Icons.sync,
    TCloudSyncState.uploading => Icons.upload_outlined,
    TCloudSyncState.downloading => Icons.download_outlined,
    TCloudSyncState.attention => Icons.warning_amber_rounded,
    TCloudSyncState.paused => Icons.pause_circle_outline,
  };
}
