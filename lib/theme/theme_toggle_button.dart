import 'package:flutter/material.dart';

import 'theme_controller.dart';

class ThemeToggleButton extends StatelessWidget {
  const ThemeToggleButton({super.key, this.color});

  final Color? color;

  @override
  Widget build(BuildContext context) {
    final controller = AppThemeScope.of(context);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final isDark = controller.value == ThemeMode.dark;

        return IconButton(
          tooltip: isDark ? 'Switch to light mode' : 'Switch to dark mode',
          onPressed: controller.toggle,
          icon: Icon(isDark ? Icons.light_mode : Icons.dark_mode),
          color: color,
        );
      },
    );
  }
}
