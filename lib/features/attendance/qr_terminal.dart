import 'dart:convert';

/// A QR payload expected by the mobile app's attendance-terminal scanner.
///
/// The web platform renders attendance-terminal links of the form
/// `…/#/attendance-terminal?token=<token>` (see AttendanceManagement.jsx), so
/// the scanner accepts either the full URL or the bare token (which the
/// terminal QR encodes directly).
class QrTerminalPayload {
  const QrTerminalPayload({required this.token, this.source = 'raw'});

  final String token;

  /// 'url' when parsed from a web link, 'raw' when the value stood alone.
  final String source;

  static final _tokenParam = RegExp(r'([?&#])?(token|terminal)=([^&#\s]+)');

  static QrTerminalPayload tryParse(String raw) {
    final input = raw.trim();
    if (input.isEmpty) {
      throw const FormatException('The QR code was empty.');
    }

    final match = _tokenParam.firstMatch(input);
    if (match != null) {
      final value = Uri.decodeComponent(match.group(3) ?? '').trim();
      if (value.isNotEmpty) {
        return QrTerminalPayload(token: value, source: 'url');
      }
    }

    if (input.contains('/') || input.contains('http')) {
      throw FormatException('Not an attendance terminal token.');
    }

    return QrTerminalPayload(token: input, source: 'raw');
  }
}

/// Result of `mobile_qr_terminal_inspect` — the server's verdict on a scanned
/// terminal token before any attendance write is attempted.
class TerminalInfo {
  const TerminalInfo({
    required this.valid,
    this.message = '',
    this.terminalId,
    this.terminalName,
    this.status,
    this.active = false,
    this.area,
    this.latitude,
    this.longitude,
    this.geofenceStatus,
  });

  final bool valid;
  final String message;
  final String? terminalId;
  final String? terminalName;
  final String? status;
  final bool active;
  final String? area;
  final double? latitude;
  final double? longitude;
  final String? geofenceStatus;

  factory TerminalInfo.fromJson(Map<String, dynamic> json) {
    final lat = json['latitude'];
    final lng = json['longitude'];
    return TerminalInfo(
      valid: json['valid'] == true,
      message: '${json['message'] ?? ''}',
      terminalId: json['terminal_id']?.toString(),
      terminalName: '${json['terminal_name'] ?? ''}',
      status: json['status']?.toString(),
      active: json['active'] == true,
      area: '${json['area'] ?? ''}',
      latitude: lat is num ? lat.toDouble() : null,
      longitude: lng is num ? lng.toDouble() : null,
      geofenceStatus: json['geofence_status']?.toString(),
    );
  }
}

/// Navigation payload returned by the scanner screen.
class TerminalScanResult {
  const TerminalScanResult({required this.token, required this.terminal});

  final String token;
  final TerminalInfo terminal;

  Map<String, dynamic> toJson() => {
    'token': token,
    'terminal': {
      'valid': terminal.valid,
      'message': terminal.message,
      'terminal_id': terminal.terminalId,
      'terminal_name': terminal.terminalName,
      'status': terminal.status,
      'active': terminal.active,
    },
  };

  static TerminalScanResult fromJson(Map<String, dynamic> json) {
    final t = json['terminal'];
    return TerminalScanResult(
      token: '${json['token'] ?? ''}',
      terminal: TerminalInfo.fromJson(
        t is Map<String, dynamic> ? t : const <String, dynamic>{'valid': false},
      ),
    );
  }

  String encode() => jsonEncode(toJson());
}
