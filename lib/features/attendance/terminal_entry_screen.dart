import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../shared/widgets/common.dart';
import '../dashboard/home_shell.dart';
import 'attendance_service.dart';

/// Authenticated entry point to generate a public attendance-terminal QR.
/// Mirrors the web `TerminalEntry` page: creates a disposable token via
/// `create_attendance_terminal_token` then renders the terminal URL as QR.
class AttendanceTerminalEntryScreen extends StatefulWidget {
  const AttendanceTerminalEntryScreen({super.key});

  @override
  State<AttendanceTerminalEntryScreen> createState() =>
      _AttendanceTerminalEntryScreenState();
}

class _AttendanceTerminalEntryScreenState
    extends State<AttendanceTerminalEntryScreen> {
  String? _token;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _generate();
  }

  Future<void> _generate() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await AttendanceService.instance.generateTerminalToken();
      final token = result['token']?.toString() ?? result['id']?.toString();
      if (token == null) throw StateError('Device token was not returned.');
      if (mounted) setState(() => _token = token);
    } catch (e) {
      if (mounted) setState(() => _error = AttendanceService.normalizeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: shellAppBar(context, title: 'Attendance Terminal QR'),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _busy && _token == null
              ? const PageLoadingView(label: 'Preparing terminal QR…')
              : _error != null && _token == null
              ? PageErrorView(message: _error!, onRetry: _generate)
              : Column(
                  children: [
                    SectionCard(
                      title: 'Public terminal QR',
                      children: [
                        Text(
                          'Employees without InfinityCore access can scan '
                          'this code to reach the attendance terminal, enter '
                          'their employee number and clock in/out securely.',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.black54,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Center(
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: const Color(0xFFE8EDF4),
                              ),
                            ),
                            child: QrImageView(
                              data: AttendanceService.instance.terminalUrl(
                                _token!,
                              ),
                              size: 220,
                              backgroundColor: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Center(
                          child: Text(
                            AttendanceService.instance.terminalUrl(_token!),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.black45,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _generate,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Generate a fresh code'),
                    ),
                  ],
                ),
        ],
      ),
    );
  }
}
