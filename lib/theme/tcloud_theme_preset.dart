import 'package:flutter/material.dart';

class TCloudThemePreset {
  const TCloudThemePreset({
    required this.id,
    required this.name,
    required this.dark,
    required this.background,
    required this.surface,
    required this.accent,
  });
  final String id;
  final String name;
  final bool dark;
  final Color background;
  final Color surface;
  final Color accent;
}

const tcloudThemePresets = <TCloudThemePreset>[
  TCloudThemePreset(
    id: 'default-dark',
    name: 'TCloud Escuro',
    dark: true,
    background: Color(0xFF0B0D13),
    surface: Color(0xFF161922),
    accent: Color(0xFF1D4ED8),
  ),
  TCloudThemePreset(
    id: 'midnight-blue',
    name: 'Azul Meia-noite',
    dark: true,
    background: Color(0xFF080D18),
    surface: Color(0xFF101827),
    accent: Color(0xFF3B82F6),
  ),
  TCloudThemePreset(
    id: 'charcoal',
    name: 'Carvão',
    dark: true,
    background: Color(0xFF17171D),
    surface: Color(0xFF23232D),
    accent: Color(0xFF7067D9),
  ),
  TCloudThemePreset(
    id: 'nord',
    name: 'Nord',
    dark: true,
    background: Color(0xFF2E3440),
    surface: Color(0xFF3B4252),
    accent: Color(0xFF88C0D0),
  ),
  TCloudThemePreset(
    id: 'graphite',
    name: 'Grafite',
    dark: true,
    background: Color(0xFF111315),
    surface: Color(0xFF1A1D20),
    accent: Color(0xFF8BA3BD),
  ),
  TCloudThemePreset(
    id: 'ocean',
    name: 'Oceano',
    dark: true,
    background: Color(0xFF07151C),
    surface: Color(0xFF0D222D),
    accent: Color(0xFF2F9FC2),
  ),
  TCloudThemePreset(
    id: 'cyber-teal',
    name: 'Cyber Teal',
    dark: true,
    background: Color(0xFF0A1628),
    surface: Color(0xFF112240),
    accent: Color(0xFF00BFA5),
  ),
  TCloudThemePreset(
    id: 'default-light',
    name: 'TCloud Claro',
    dark: false,
    background: Color(0xFFF5F7FA),
    surface: Color(0xFFFFFFFF),
    accent: Color(0xFF245FAE),
  ),
  TCloudThemePreset(
    id: 'cloud-light',
    name: 'Cloud Light',
    dark: false,
    background: Color(0xFFF3F6FA),
    surface: Color(0xFFFFFFFF),
    accent: Color(0xFF245FAE),
  ),
  TCloudThemePreset(
    id: 'solarized-light',
    name: 'Solarized',
    dark: false,
    background: Color(0xFFFDF6E3),
    surface: Color(0xFFEEE8D5),
    accent: Color(0xFF9B7600),
  ),
];

TCloudThemePreset presetById(String id) => tcloudThemePresets.firstWhere(
  (preset) => preset.id == id,
  orElse: () => tcloudThemePresets.first,
);
