import 'package:flutter/material.dart';

import '../core/routing/app_router.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/theme_controller.dart';
import '../features/messages/urgent_ack_gate.dart';

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
          // The mandatory-acknowledgment gate sits inside the MaterialApp so it
          // inherits its theme and overlay semantics, but *above* the router so
          // it covers every route — including the splash screen, where a user
          // with an outstanding urgent message would otherwise get a moment of
          // usable app before being blocked.
          builder: (context, child) =>
              UrgentAckGate(child: child ?? const SizedBox.shrink()),
          routerConfig: appRouter,
        );
      },
    );
  }
}
