import 'package:flutter/material.dart';

import '../theme/tcloud_theme_controller.dart';

class TCloudThemeSelector extends StatelessWidget {
  const TCloudThemeSelector({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = TCloudThemeController.instance;

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Tema',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Escolha a aparência do TCloud.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 14),
                  SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.light,
                        icon: Icon(Icons.light_mode_outlined),
                        label: Text('Claro'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        icon: Icon(Icons.dark_mode_outlined),
                        label: Text('Escuro'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.system,
                        icon: Icon(Icons.devices_outlined),
                        label: Text('Sistema'),
                      ),
                    ],
                    selected: {controller.mode},
                    onSelectionChanged: (selection) {
                      controller.setMode(selection.first);
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
