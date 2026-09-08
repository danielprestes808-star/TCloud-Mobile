import 'package:flutter/material.dart';

import '../theme/tcloud_theme_controller.dart';
import '../theme/tcloud_theme_preset.dart';

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
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final columns = constraints.maxWidth >= 520 ? 3 : 2;
                      return GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          childAspectRatio: 1.65,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                        ),
                        itemCount: tcloudThemePresets.length,
                        itemBuilder: (context, index) {
                          final preset = tcloudThemePresets[index];
                          final selected = controller.presetId == preset.id;
                          return Semantics(
                            button: true,
                            selected: selected,
                            label: 'Tema ${preset.name}',
                            child: InkWell(
                              onTap: () => controller.setPreset(preset.id),
                              borderRadius: BorderRadius.circular(7),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 160),
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(7),
                                  border: Border.all(
                                    color: selected
                                        ? preset.accent
                                        : Theme.of(context).dividerColor,
                                    width: selected ? 2 : 1,
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(4),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: ColoredBox(
                                                color: preset.background,
                                              ),
                                            ),
                                            Expanded(
                                              child: ColoredBox(
                                                color: preset.surface,
                                              ),
                                            ),
                                            Expanded(
                                              child: ColoredBox(
                                                color: preset.accent,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 7),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            preset.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                        if (selected)
                                          Icon(
                                            Icons.check_circle,
                                            size: 16,
                                            color: preset.accent,
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      );
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
