import 'package:flutter/material.dart';

import '../core/routing/app_router.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/theme_controller.dart';

class InfinityCoreApp extends StatelessWidget {
  const InfinityCoreApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeController.instance,
      builder: (context, _) {
        return MaterialApp.router(
          title: 'InfinityCore',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: ThemeController.instance.mode,
          routerConfig: appRouter,
        );
      },
    );
  }
}
