import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:local_auth/local_auth.dart';

import '../../core/diagnostics/auth_trace.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/supabase_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/infinity_logo.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // NOTE: this screen deliberately does NOT listen to AuthService and does
    // NOT navigate on auth changes. It used to call `context.go('/home')` as
    // soon as `isAuthenticated && sessionSettled` was true, which raced the
    // router guard and let Home render before the mobile-device check had
    // finished (then bounce back to Login). The router guard in
    // `core/routing/auth_gate.dart` is now the single navigation authority: it
    // moves `/login` -> `/home` only once the session is *resolved*.
    _tryBiometric(); // convenience only — does not replace server auth
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<bool> _tryBiometric() async {
    if (!AuthService.instance.biometricEnabled) return false;
    try {
      final localAuth = LocalAuthentication();
      final canCheck = await localAuth.canCheckBiometrics;
      if (!canCheck) return false;
      final ok = await localAuth.authenticate(
        localizedReason: 'Unlock with your biometrics to open InfinityCore',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
      if (!ok || !mounted) return false;
      AuthTrace.log('login', 'biometric ok -> re-resolving persisted session');
      // Re-resolve the persisted session. `bootstrap()` publishes a *resolved*
      // verdict, and the guard then moves `/login` -> `/home` if, and only if,
      // a valid session exists. No speculative navigation here.
      await AuthService.instance.bootstrap();
      return AuthService.instance.isAuthenticated;
    } catch (_) {
      return false;
    }
  }

  Future<void> _login() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Enter your Infinity email and password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AuthService.instance.signIn(email, password);
      // Navigation to /home is handled by the router once the sign-in
      // pipeline settles; if the device check rejects (unauthorized device),
      // signIn throws here so the error surfaces without a Home flash.
    } catch (e) {
      setState(() {
        _error = _friendlyAuthError(e);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Maps a raw Supabase/PostgreSQL failure onto copy a user can act on.
  /// The technical detail is still logged for debugging, but never rendered.
  String _friendlyAuthError(Object e) {
    AuthTrace.log('login', 'FAILED: $e');
    final raw = e.toString().toLowerCase();
    if (raw.contains('moobile_unauthorized_device') ||
        raw.contains('mobile_unauthorized_device')) {
      return 'This account is already linked to another mobile device. '
          'Please contact HR or Super Admin to authorize this device.';
    }
    if (raw.contains('invalid_login_credentials') ||
        raw.contains('invalid_credentials')) {
      return 'That email and password combination was not recognised. '
          'Please check and try again.';
    }
    if (raw.contains('email_not_confirmed')) {
      return 'This account has not been activated yet. '
          'Please use "Activate account" first.';
    }
    if (raw.contains('too_many_requests') ||
        raw.contains('rate_limit') ||
        raw.contains('email_rate_limit')) {
      return 'Too many attempts. Please wait a minute and try again.';
    }
    if (raw.contains('failed to fetch') ||
        raw.contains('socket') ||
        raw.contains('connection') ||
        raw.contains('network')) {
      return 'Cannot reach InfinityCore right now. '
          'Check your connection and try again.';
    }
    return 'Sign-in failed. Please try again, or contact HR if this persists.';
  }

  Future<void> _forgotPassword() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Enter your email address first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final redirect = _redirectTo();
      await SupabaseService.client.auth.resetPasswordForEmail(
        email,
        redirectTo: redirect,
      );
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            icon: const Icon(
              Icons.mark_email_read_outlined,
              color: Color(0xFF009944),
            ),
            title: const Text('Reset link sent'),
            content: Text(
              'If $email belongs to an InfinityCore account, a password '
              'reset link has been sent. Check your inbox.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _redirectTo() {
    final uri = Uri.base;
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      return uri.toString();
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const InfinityCoreLogo(light: true, showTagline: true),
                  const SizedBox(height: 26),
                  LightPanel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.email],
                          decoration: const InputDecoration(
                            labelText: 'Email',
                            prefixIcon: Icon(Icons.mail_outline),
                          ),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: _password,
                          obscureText: _obscure,
                          onSubmitted: (_) => _busy ? null : _login(),
                          decoration: InputDecoration(
                            labelText: 'Password',
                            prefixIcon: const Icon(Icons.lock_outline),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscure
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                              onPressed: () =>
                                  setState(() => _obscure = !_obscure),
                            ),
                          ),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            _error!,
                            style: const TextStyle(
                              color: Color(0xFFB42318),
                              fontSize: 12,
                            ),
                          ),
                        ],
                        const SizedBox(height: 18),
                        FilledButton(
                          onPressed: _busy ? null : _login,
                          child: _busy
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text('Sign In'),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            TextButton(
                              onPressed: _busy ? null : _forgotPassword,
                              child: const Text('Forgot password?'),
                            ),
                            TextButton(
                              onPressed: () => context.go('/activate-account'),
                              child: const Text('Activate account'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Secured connection to Infinity Supabase.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
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
