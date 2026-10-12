import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/diagnostics/auth_trace.dart';
import '../../core/services/supabase_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/infinity_logo.dart';

/// Create account — the mobile mirror of the web (SARA) sign-up mode.
///
/// The web `Login.jsx` carries a Sign In / Sign Up mode toggle; this screen is
/// the sign-up half of it as a standalone destination, reached from the login
/// screen's "Create account" link. Mirrored from the web: field order (Email,
/// then Password), the six-character minimum password, the green primary
/// button, the pending-customer notice, and the Supabase `auth.signUp` payload
/// — email and password only. No role, permission or other privileged metadata
/// is sent from the client; role assignment is the server-side trigger in
/// `schema_phase5_role_security.sql`.
class CreateAccountScreen extends StatefulWidget {
  const CreateAccountScreen({super.key});

  @override
  State<CreateAccountScreen> createState() => _CreateAccountScreenState();
}

class _CreateAccountScreenState extends State<CreateAccountScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;
  bool _created = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _createAccount() async {
    final email = _email.text.trim();
    final password = _password.text;
    // The web form enforces these with HTML `required` + `minLength={6}`;
    // mobile has no browser validation, so they are enforced here instead.
    if (email.isEmpty) {
      setState(() => _error = 'Enter your email address.');
      return;
    }
    if (password.isEmpty) {
      setState(() => _error = 'Enter a password.');
      return;
    }
    if (password.length < 6) {
      setState(() => _error = 'Password must be at least 6 characters.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Same payload shape as the web sign-up call: email + password only.
      final res = await SupabaseService.client.auth.signUp(
        email: email,
        password: password,
      );
      AuthTrace.log('signUp', 'response user=${res.user?.id ?? 'null'}');
      if (!mounted) return;
      if (res.session != null) {
        // Email confirmation is off and the account is signed in already: the
        // auth stream and router guard take over, matching the web's
        // post-signup navigation to the app root.
        return;
      }
      // Confirmation required — the web returns the user to sign in once the
      // emailed link is opened, so say so instead of dumping them on login.
      setState(() => _created = true);
    } catch (e) {
      AuthTrace.log('signUp', 'FAILED: $e');
      if (mounted) setState(() => _error = _friendlySignUpError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Maps a raw Supabase failure onto copy a user can act on, in the same
  /// spirit as the login screen's error mapping.
  String _friendlySignUpError(Object e) {
    final raw = e.toString().toLowerCase();
    if (raw.contains('already registered') ||
        raw.contains('already been registered')) {
      return 'An account with this email already exists. '
          'Try signing in instead.';
    }
    if (raw.contains('password should be at least')) {
      return 'Password must be at least 6 characters.';
    }
    if (raw.contains('unable to validate email') ||
        raw.contains('invalid format')) {
      return 'That email address does not look valid. '
          'Please check and try again.';
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
    if (e is AuthException) return e.message;
    return 'Could not create your account. Please try again, or contact HR if '
        'this persists.';
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
                  const Text(
                    'Create account',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 18),
                  LightPanel(
                    child: _created ? _successState() : _form(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _form() {
    return Column(
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
          onSubmitted: (_) => _busy ? null : _createAccount(),
          decoration: InputDecoration(
            labelText: 'Password',
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              icon: Icon(
                _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
              ),
              onPressed: () => setState(() => _obscure = !_obscure),
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
          onPressed: _busy ? null : _createAccount,
          child: _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Create Account'),
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: _busy ? null : () => context.go('/login'),
          child: const Text('Back to Sign In'),
        ),
        const SizedBox(height: 8),
        Text(
          'New accounts start as pending customers. An administrator must '
          'approve your account before you can access the system.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11,
            color: AppColors.textSecondary(context),
          ),
        ),
      ],
    );
  }

  Widget _successState() {
    return Column(
      children: [
        const Icon(
          Icons.mark_email_read_outlined,
          size: 48,
          color: Color(0xFF009944),
        ),
        const SizedBox(height: 12),
        const Text(
          'Account created. Check your email to confirm your address, '
          'then sign in.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () => context.go('/login'),
          child: const Text('Back to Sign In'),
        ),
      ],
    );
  }
}
