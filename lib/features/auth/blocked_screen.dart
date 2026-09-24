import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/security/role_guard.dart';
import '../../core/services/auth_service.dart';
import '../../shared/widgets/common.dart';

/// Shown when a signed-in user's profile status does not allow access
/// (pending approval, suspended, or rejected) — mirrors the web blocked
/// screen in App.jsx.
class BlockedScreen extends StatelessWidget {
  const BlockedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = AuthService.instance;
    final status = auth.profile?.status ?? 'pending';
    final role = AppRoles.label(auth.profile?.role ?? '');

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const AppLogo(size: 60),
                  const SizedBox(height: 20),
                  Icon(
                    status == 'rejected'
                        ? Icons.cancel_outlined
                        : status == 'suspended'
                        ? Icons.pause_circle_outline
                        : Icons.hourglass_empty,
                    size: 46,
                    color: status == 'rejected'
                        ? const Color(0xFFB42318)
                        : Colors.amber,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    status == 'rejected'
                        ? 'Account not approved'
                        : status == 'suspended'
                        ? 'Account suspended'
                        : 'Awaiting approval',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Your InfinityCore account is currently ${status.replaceAll('_', ' ')} '
                    '($role). An administrator must approve your role and access '
                    'before you can use the platform.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white60, fontSize: 13),
                  ),
                  const SizedBox(height: 24),
                  OutlinedButton(
                    onPressed: () async {
                      await auth.signOut();
                      if (context.mounted) context.go('/login');
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white30),
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: const Text('Sign out'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
