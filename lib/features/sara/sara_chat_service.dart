import '../../core/services/supabase_service.dart';

const kMaxHistoryTurns = 8;
const kMaxTextLength = 1200;

const saraErrorMessages = <String, String>{
  'ai_not_configured': 'SARA AI is not configured yet. An administrator needs to add the server-side OpenAI key.',
  'rate_limited': 'SARA has reached its usage limit for now. Please wait a little and try again.',
  'timeout': 'SARA took too long to respond. Please try again.',
  'ai_unavailable': 'SARA is temporarily unavailable. You can still use the existing typed commands.',
  'ai_empty':
      'SARA returned an empty response. Please try asking in a different way.',
};

class SaraMessage {
  final String role; // 'user' | 'assistant'
  final String content;

  const SaraMessage({required this.role, required this.content});

  Map<String, dynamic> toRoleJson() => {'role': role, 'content': content};
}

class SaraAiError implements Exception {
  final String code;
  final String message;

  SaraAiError([this.code = 'ai_unavailable'])
    : message = saraErrorMessages[code] ?? saraErrorMessages['ai_unavailable']!;

  @override
  String toString() => message;
}

/// SARA assistant client. Mirrors `saraChatService.js`: the heavyweight
/// reasoning lives in the `sara-chat` Edge Function; this client only sends
/// the request and surfaces real server errors — no fake AI responses.
class SaraChatService {
  SaraChatService._();
  static final SaraChatService instance = SaraChatService._();

  String _trim(String? value) {
    final s = (value ?? '').trim();
    return s.length > kMaxTextLength
        ? s.substring(0, kMaxTextLength).trim()
        : s;
  }

  List<Map<String, dynamic>> boundHistory(List<SaraMessage> history) {
    return history
        .where((m) => m.role == 'user' || m.role == 'assistant')
        .toList()
        .reversed
        .take(kMaxHistoryTurns)
        .toList()
        .reversed
        .where((m) => m.content.trim().isNotEmpty)
        .map((m) => m.toRoleJson())
        .toList();
  }

  Future<Map<String, dynamic>> _invoke(Map<String, dynamic> body) async {
    try {
      final response = await SupabaseService.client.functions.invoke(
        'sara-chat',
        body: body,
      );
      final data = response.data is Map
          ? Map<String, dynamic>.from(response.data as Map)
          : null;
      if (data == null || data['ok'] != true) {
        throw SaraAiError(_errorCode(data?['error']));
      }
      return data;
    } on Exception {
      throw SaraAiError('ai_unavailable');
    }
  }

  String _errorCode(dynamic explicit) {
    const known = {
      'ai_not_configured',
      'rate_limited',
      'timeout',
      'ai_empty',
      'ai_unavailable',
    };
    final code = explicit?.toString();
    if (code != null && known.contains(code)) return code;
    return 'ai_unavailable';
  }

  Future<({String reply, Map<String, dynamic> raw})> requestReply({
    required String message,
    List<SaraMessage> history = const [],
    String route = '',
  }) async {
    final data = await _invoke({
      'mode': 'chat',
      'message': _trim(message),
      'history': boundHistory(history),
      'route': route.substring(0, route.length.clamp(0, 120)),
    });
    final reply = '${data['reply'] ?? ''}'.trim();
    if (reply.isEmpty) throw SaraAiError('ai_empty');
    return (reply: reply, raw: data);
  }

  Future<
    ({
      List<String> bullets,
      String generatedAt,
      Map<String, dynamic>? sourceMetrics,
    })
  >
  requestSummary({String route = ''}) async {
    final data = await _invoke({
      'mode': 'summary',
      'route': route.substring(0, route.length.clamp(0, 120)),
    });
    final List<String> bullets =
        (data['bullets'] is List ? (data['bullets'] as List) : const [])
            .map((b) => _trim('$b'))
            .where((b) => b.isNotEmpty)
            .take(4)
            .toList();
    if (bullets.isEmpty) throw SaraAiError('ai_empty');
    return (
      bullets: bullets,
      generatedAt:
          '${data['generated_at'] ?? DateTime.now().toIso8601String()}',
      sourceMetrics: data['source_metrics'] is Map
          ? Map<String, dynamic>.from(data['source_metrics'] as Map)
          : null,
    );
  }
}
