import '../../core/services/supabase_service.dart';

const kMaxHistoryTurns = 8;
const kMaxTextLength = 1200;

// Every code the server can return gets its own honest sentence. The previous
// map collapsed `ai_not_configured`, `rate_limited` and `timeout` into one
// generic line and turned EVERY other code into `ai_unavailable` — so an
// invalid provider credential, exhausted credit and a plain outage all read
// identically, and a permission refusal was indistinguishable from a crash.
//
// Kept in step with src/services/saraChatService.js (ERROR_MESSAGES) so web and
// mobile report the same reason for the same cause.
const saraErrorMessages = <String, String>{
  // The operator's own standing / permissions.
  'forbidden': 'You do not have access to that information. Ask an administrator to grant it in Access Control.',
  'unauthorized': 'Please sign in again — SARA could not verify your session.',
  // Genuine service problems.
  'rate_limited': 'SARA is handling a lot of requests right now. Wait a moment and try again.',
  'timeout': 'SARA is taking too long to answer. Please try again in a moment.',
  'ai_empty': 'SARA did not manage to put together an answer for that. Please try rephrasing it.',
  // Provider configuration — an administrator can fix these.
  'ai_not_configured': 'SARA is not fully set up yet. An administrator needs to finish the configuration.',
  'ai_invalid_key': 'SARA could not sign in to the AI service. An administrator needs to check the server credential.',
  'ai_billing': 'SARA has run out of AI credit. An administrator needs to top it up or switch provider.',
  'ai_rate_limited': 'The AI service is rate-limiting SARA. Please try again in a moment.',
  'ai_timeout': 'The AI service took too long to answer. Please try again.',
  'ai_network': 'SARA could not reach the AI service. Please check your connection and try again.',
  'ai_unsupported': 'SARA cannot answer that kind of question yet.',
  'ai_bad_response': 'SARA received a response she could not read. Please try again.',
  'ai_invalid_json': 'SARA received a response she could not read. Please try again.',
  'ai_provider_error': 'The AI service reported an error. Please try again.',
  // Request shape / deployment.
  'invalid_request': 'That request could not be sent. Please try again.',
  'method_not_allowed': 'That request could not be sent. Please try again.',
  'env_missing': 'SARA is not configured on this deployment. An administrator needs to add the server credential.',
  // Last resort only — nothing better is known.
  'ai_unavailable': 'Something went wrong on our side and SARA could not answer that just now. Your commands and reports are unaffected — please try again.',
};

/// Shown ONLY when nothing better is known, i.e. SARA is genuinely broken.
final String saraUnknownFailure = saraErrorMessages['ai_unavailable']!;

class SaraAiError implements Exception {
  final String code;
  final String message;

  SaraAiError([this.code = 'ai_unavailable'])
      : message = saraErrorMessages[code] ?? saraUnknownFailure;

  @override
  String toString() => message;
}

class SaraMessage {
  final String role; // 'user' | 'assistant'
  final String content;

  const SaraMessage({required this.role, required this.content});

  Map<String, dynamic> toRoleJson() => {'role': role, 'content': content};
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
    } on SaraAiError {
      rethrow; // the server already told us the reason
    } on Exception {
      throw SaraAiError('ai_unavailable');
    }
  }

  /// The server's own reason, passed through.
  ///
  /// The old version whitelisted four codes and rewrote everything else to
  /// 'ai_unavailable', which is precisely why every failure looked identical.
  String _errorCode(dynamic explicit) {
    final code = explicit?.toString().trim();
    if (code != null && code.isNotEmpty) return code;
    return 'ai_unavailable';
  }

  Future<
      ({
        String reply,
        Map<String, dynamic> raw,
        bool degraded,
        String? notice,
      })> requestReply({
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
    final degraded = data['degraded'] == true;
    final notice = '${data['notice'] ?? ''}'.trim();
    return (
      reply: reply,
      raw: data,
      degraded: degraded,
      // The first sentence of the router's notice is the reason the primary
      // provider did not answer; the rest is noise.
      notice: degraded && notice.isNotEmpty ? notice.split(RegExp(r'\.\s+|\.\$')).first : null,
    );
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
