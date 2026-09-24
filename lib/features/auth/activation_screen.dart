import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/auth_service.dart';
import '../../core/services/supabase_service.dart';
import '../../shared/widgets/common.dart';

/// Account activation / invitation flow.
///
/// Invite and password-reset emails from Supabase carry a `code` or
/// `token_hash`. When the app is opened through a link that carries those,
/// they are exchanged for a session here. Without parameters, the screen
/// explains the expected flow.
class ActivationScreen extends StatefulWidget {
  const ActivationScreen({
    super.key,
    this.initCode,
    this.initTokenHash,
    this.isRecovery = false,
  });

  final String? initCode;
  final String? initTokenHash;
  final bool isRecovery;

  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  bool _busy = false;
  String _message = '';
  bool _done = false;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    final code = widget.initCode;
    final tokenHash = widget.initTokenHash;
    if (code != null || tokenHash != null) {
      _process(code, tokenHash);
    }
  }

  Future<void> _process(String? code, String? tokenHash) async {
    setState(() {
      _busy = true;
      _message = 'Verifying your link…';
    });
    try {
      if (code != null && code.isNotEmpty) {
        await SupabaseService.client.auth.exchangeCodeForSession(code);
      } else if (tokenHash != null && tokenHash.isNotEmpty) {
        await SupabaseService.client.auth.verifyOTP(
          tokenHash: tokenHash,
          type: widget.isRecovery ? OtpType.recovery : OtpType.invite,
        );
      } else {
        throw AuthException('Link does not contain a verification token.');
      }
      if (mounted) {
        setState(() {
          _busy = false;
          _done = true;
          _message = 'Account activated. You can now sign in to InfinityCore.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = true;
          _message = e.toString().replaceAll('Exception: ', '');
        });
      }
    }
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
                  const AppLogo(size: 64),
                  const SizedBox(height: 18),
                  const Text(
                    'Activate your account',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: _done
                        ? Column(
                            children: [
                              const Icon(
                                Icons.check_circle_outline,
                                size: 48,
                                color: Color(0xFF009944),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _message,
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 14),
                              ),
                              const SizedBox(height: 16),
                              FilledButton(
                                onPressed: () {
                                  AuthService.instance.bootstrap();
                                  context.go('/login');
                                },
                                child: const Text('Go to Sign In'),
                              ),
                            ],
                          )
                        : _error
                        ? Column(
                            children: [
                              const Icon(
                                Icons.error_outline,
                                size: 48,
                                color: Color(0xFFB42318),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _message,
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 14),
                              ),
                              const SizedBox(height: 16),
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('Back'),
                              ),
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Text(
                                'Activation links from Infinity HR contain a '
                                'secure token. Open this screen through your '
                                'invitation email so it can be verified.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.black54,
                                ),
                              ),
                              const SizedBox(height: 16),
                              if (_busy)
                                const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                )
                              else
                                OutlinedButton.icon(
                                  onPressed: () async {
                                    final link = await _promptLink();
                                    if (link != null) {
                                      _parse(link);
                                    }
                                  },
                                  icon: const Icon(Icons.link),
                                  label: const Text('Paste invite link'),
                                ),
                              const SizedBox(height: 8),
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('Back to Sign In'),
                              ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<String?> _promptLink() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Paste your invite link'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Paste the full link from your email',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Verify'),
          ),
        ],
      ),
    );
    return result;
  }

  void _parse(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) {
      setState(() {
        _error = true;
        _message = 'That does not look like a valid link.';
      });
      return;
    }
    final code = uri.queryParameters['code'];
    final tokenHash = uri.queryParameters['token_hash'];
    _process(code, tokenHash);
  }
}
