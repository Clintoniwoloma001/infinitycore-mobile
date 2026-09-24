import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/diagnostics/auth_trace.dart';
import '../../core/routing/auth_gate.dart';
import '../../core/services/auth_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/infinity_logo.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    AuthTrace.log('splash', 'boot() entered');
    await AuthService.instance.bootstrap();
    if (!mounted) return;

    // Navigation has a single authority: the router guard. This is only a
    // post-resolution nudge, and it deliberately reads the RESOLVED status —
    // never a raw session — so the splash screen can never hand the user to
    // Home on a partial read. While the state is still unknown/resolving the
    // screen simply keeps showing the loading indicator.
    final auth = AuthService.instance;
    AuthTrace.log(
      'splash',
      'resolution complete: status=${auth.status.name} '
          'isAuthenticated=${auth.isAuthenticated}',
    );
    switch (auth.status) {
      case AuthStatus.authenticated:
        final next = auth.biometricEnabled ? '/lock' : '/home';
        AuthTrace.log('splash', '-> go($next) (resolved + valid session)');
        context.go(next);
      case AuthStatus.unauthenticated:
        AuthTrace.log('splash', '-> go(/login) (resolved, no valid session)');
        context.go('/login');
      case AuthStatus.unknown:
      case AuthStatus.resolving:
        // Keep the neutral loading screen; the guard will move us on resolve.
        AuthTrace.log('splash', 'staying on the loading screen (unresolved)');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SurfaceColors.splashDark,
      body: Center(
        child: AnimatedBuilder(
          animation: _animation,
          builder: (context, child) {
            final t = Curves.easeInOut.transform(_animation.value);
            return Transform.scale(
              scale: 0.95 + 0.13 * t,
              child: Opacity(opacity: 0.85 + 0.15 * t, child: child),
            );
          },
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              InfinityCoreLogo(light: true, showTagline: true),
              SizedBox(height: 32),
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
