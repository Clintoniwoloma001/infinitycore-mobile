import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/auth_service.dart';
import '../../core/services/biometrics.dart';
import '../../shared/widgets/common.dart';

/// Quick-unlock screen. After app start with biometrics enabled the splash
/// routes here; the user re-confirms identity before entering the shell. It
/// is a local convenience on top of the server session — never an
/// authorization boundary.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  bool _attempting = false;
  String? _error;
  int _fails = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _unlock();
    });
  }

  Future<void> _unlock() async {
    final auth = AuthService.instance;
    if (!auth.isAuthenticated || !auth.biometricEnabled) {
      context.go('/home');
      return;
    }
    setState(() {
      _attempting = true;
      _error = null;
    });
    final ok = await Biometrics.instance.authenticate(
      reason: 'Unlock InfinityCore with your biometrics',
    );
    if (!mounted) return;
    if (ok) {
      context.go('/home');
      return;
    }
    _fails += 1;
    setState(() {
      _attempting = false;
      _error = _fails >= 3
          ? 'Too many attempts. Sign in with your password instead.'
          : 'Not recognized. Try again or use your password.';
    });
    if (_fails >= 3) {
      await auth.signOut();
      if (mounted) context.go('/login');
    }
  }

  Future<void> _usePassword() async {
    await AuthService.instance.signOut();
    if (mounted) context.go('/login');
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthService.instance;
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const AppLogo(size: 64),
                  const SizedBox(height: 18),
                  const Text(
                    'Welcome back',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    auth.displayName,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white60, fontSize: 13),
                  ),
                  const SizedBox(height: 28),
                  FilledButton.icon(
                    onPressed: _attempting ? null : _unlock,
                    icon: _attempting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.face_outlined),
                    label: Text(
                      _attempting ? 'Checking…' : 'Unlock with biometrics',
                    ),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFFFCA5A5),
                        fontSize: 12,
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  TextButton(
                    onPressed: _attempting ? null : _usePassword,
                    child: const Text(
                      'Use password instead',
                      style: TextStyle(color: Colors.white60),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'InfinityCore Mobile · Infinity Bank',
                    style: TextStyle(color: Colors.white24, fontSize: 11),
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
