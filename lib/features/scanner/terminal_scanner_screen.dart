import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/theme/app_theme.dart';
import '../attendance/attendance_service.dart';
import '../attendance/qr_terminal.dart';

/// Full-screen QR scanner for attendance terminals.
///
/// Scans the web platform's `#/attendance-terminal?token=…` QR (or a bare
/// token), asks the server to inspect the terminal, then returns a
/// [TerminalScanResult] to the caller so the clock action can proceed through
/// the exact same biometric + device-day + geofence path as a normal mobile
/// clock.
class TerminalScannerScreen extends StatefulWidget {
  const TerminalScannerScreen({super.key});

  @override
  State<TerminalScannerScreen> createState() => _TerminalScannerScreenState();
}

class _TerminalScannerScreenState extends State<TerminalScannerScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _handling = false;
  bool _scanning = true;
  bool _torch = false;

  /// Debug-only simulated QR detection for emulators/CI where the camera
  /// feed cannot display a real QR. Never active unless compiled with
  /// `--dart-define=DEV_QR_TOKEN=<64-hex>` (asserts in debug builds only).
  static const String _devToken = String.fromEnvironment('DEV_QR_TOKEN');

  @override
  void initState() {
    super.initState();
    if (_devToken.isNotEmpty &&
        const bool.fromEnvironment('dart.vm.product') == false) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (!mounted || _handling) return;
        debugPrint('DEV_QR_INJECT: feeding synthetic terminal token scan');
        await _onRaw('http://localhost/#/attendance-terminal?token=$_devToken');
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handling || !_scanning) return;
    final raw = capture.barcodes
        .map((b) => b.rawValue)
        .whereType<String>()
        .firstWhere((v) => v.trim().isNotEmpty, orElse: () => '');
    if (raw.isEmpty) return;
    await _onRaw(raw);
  }

  Future<void> _onRaw(String raw) async {
    if (raw.isEmpty) return;

    _handling = true;
    try {
      final payload = QrTerminalPayload.tryParse(raw);
      await _controller.stop();
      setState(() => _scanning = false);

      final terminal = await AttendanceService.instance.inspectTerminal(
        payload.token,
      );
      if (!mounted) return;
      if (!terminal.valid || !terminal.active) {
        await _resumeAfterBadCode(
          terminal.message.isNotEmpty
              ? terminal.message
              : 'This terminal is not available for attendance.',
        );
        return;
      }
      await _confirm(payload, terminal);
    } on FormatException catch (e) {
      _resumeAfterBadCode(e.message);
    } catch (e) {
      _resumeAfterBadCode(AttendanceService.normalizeError(e));
    }
  }

  Future<void> _resumeAfterBadCode(String message) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.rose,
      ),
    );
    _handling = false;
    setState(() => _scanning = true);
    try {
      await _controller.start();
    } catch (_) {}
  }

  Future<void> _confirm(
    QrTerminalPayload payload,
    TerminalInfo terminal,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(
          Icons.qr_code_scanner,
          size: 32,
          color: AppColors.green,
        ),
        title: const Text('Attendance terminal found'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _title(terminal),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            if (terminal.area?.isNotEmpty == true) ...[
              const SizedBox(height: 4),
              Text(
                terminal.area!,
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary(context),
                ),
              ),
            ],
            const SizedBox(height: 8),
            const Text(
              'Your device, biometric identity and GPS will be verified against '
              'this terminal when you clock in or out.',
              style: TextStyle(fontSize: 13, height: 1.4),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Use this terminal'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (confirmed == true) {
      Navigator.of(context)
          .pop(TerminalScanResult(token: payload.token, terminal: terminal));
    } else {
      setState(() => _scanning = true);
      _handling = false;
      try {
        await _controller.start();
      } catch (_) {}
    }
  }

  String _title(TerminalInfo t) => t.terminalName?.isNotEmpty == true
      ? t.terminalName!
      : 'InfinityCore Terminal';

  void _toggleTorch() {
    setState(() => _torch = !_torch);
    _controller.toggleTorch();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan terminal QR'),
        actions: [
          IconButton(
            onPressed: _toggleTorch,
            tooltip: 'Torch',
            icon: Icon(
              _torch ? Icons.flash_on : Icons.flash_off,
              color: Colors.white,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(
                  controller: _controller,
                  onDetect: _onDetect,
                  errorBuilder: (context, error) => _ScannerError(
                    error: error,
                    onRetry: () => _controller.start(),
                  ),
                ),
                const _ScanOverlay(),
                if (_handling && !_scanning)
                  Container(
                    color: Colors.black.withValues(alpha: 0.6),
                    alignment: Alignment.center,
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: Colors.white),
                        SizedBox(height: 12),
                        Text(
                          'Contacting terminal…',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            color: Colors.black,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
            child: const Column(
              children: [
                Icon(Icons.qr_code_scanner, size: 22, color: Colors.white38),
                SizedBox(height: 8),
                Text(
                  'Point the camera at the terminal\u2019s QR code. The code is '
                  'validated against the attendance server before any clock '
                  'action is offered.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white60,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanOverlay extends StatelessWidget {
  const _ScanOverlay();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.35)),
        child: Center(
          child: Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.green, width: 2),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: AppColors.green.withValues(alpha: 0.4),
                  blurRadius: 30,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ScannerError extends StatelessWidget {
  const _ScannerError({required this.error, required this.onRetry});

  final dynamic error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final denied =
        error != null &&
        '${error.errorCode}'.toLowerCase().contains('permission');
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                denied ? Icons.no_photography_outlined : Icons.error_outline,
                size: 40,
                color: Colors.white38,
              ),
              const SizedBox(height: 12),
              Text(
                denied
                    ? 'Camera permission is required to scan terminal QR codes.'
                    : 'The camera is not available on this device.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onRetry,
                icon: Icon(denied ? Icons.camera_alt : Icons.refresh),
                label: Text(denied ? 'Grant camera access' : 'Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
