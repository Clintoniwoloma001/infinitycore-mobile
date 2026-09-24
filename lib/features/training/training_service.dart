import '../../core/services/supabase_service.dart';

/// Typed client for the Training & Development backend. Mirrors
/// `trainingService.js` from infinitycore-sara — identical RPC/table names and
/// payload shapes. No business logic is re-derived here; the server remains
/// authoritative for question-set generation, participant assignment and
/// assessment grading.
class TrainingService {
  TrainingService._();
  static final TrainingService instance = TrainingService._();

  static List<Map<String, dynamic>> _rows(List<Map<String, dynamic>>? rows) =>
      rows ?? const [];

  static Map<String, dynamic> _map(dynamic v) {
    if (v == null) return const {};
    return v is Map<String, dynamic> ? v : Map<String, dynamic>.from(v as Map);
  }

  String userId() => SupabaseService.client.auth.currentUser?.id ?? '';

  Future<List<Map<String, dynamic>>> listSessions() async {
    final res = await SupabaseService.client
        .from('training_sessions')
        .select('*, branches!branch_id(id, branch_name)')
        .order('training_date', ascending: false)
        .order('created_at', ascending: false);
    return _rows(res);
  }

  /// Every non-archived employee — the authoritative source for participant
  /// pickers (the server checks each id again inside `assign_training_participants`).
  Future<List<Map<String, dynamic>>> listEmployees() async {
    final res = await SupabaseService.client
        .from('employees')
        .select(
          'id, full_name, employee_number, employee_code, staff_id, department, area, branch, branch_id, position, employment_status',
        )
        .eq('is_archived', false)
        .order('full_name')
        .limit(1000);
    return _rows(res);
  }

  Future<List<Map<String, dynamic>>> listVenues() async {
    final res = await SupabaseService.client
        .from('branches')
        .select('id, branch_name, location')
        .eq('status', 'active')
        .order('branch_name');
    return _rows(res);
  }

  /// Filter options used across the platform: areas, branches, departments,
  /// employees. Named the same as the web RPC so both apps stay aligned.
  Future<Map<String, dynamic>> getFilterOptions() async {
    final data = await SupabaseService.client.rpc(
      'get_dashboard_filter_options',
      params: const {'p_branch_id': null, 'p_department': null, 'p_area': null},
    );
    return _map(data);
  }

  Future<Map<String, dynamic>> createSession(
    Map<String, dynamic> payload,
  ) async {
    final res = await SupabaseService.client
        .from('training_sessions')
        .insert({
          ...payload,
          'created_by': userId(),
          'updated_by': userId(),
          'status': payload['status'] ?? 'scheduled',
        })
        .select()
        .single();
    return _map(res);
  }

  Future<Map<String, dynamic>> generateQuestionSets(
    String sessionId,
    List<Map<String, dynamic>> sets,
  ) async {
    final data = await SupabaseService.client.rpc(
      'generate_kss_question_sets',
      params: {'p_session_id': sessionId, 'p_sets': sets},
    );
    return _map(data);
  }

  Future<Map<String, dynamic>> assignParticipants(
    String sessionId,
    List<String> employeeIds,
  ) async {
    final data = await SupabaseService.client.rpc(
      'assign_training_participants',
      params: {'p_session_id': sessionId, 'p_employee_ids': employeeIds},
    );
    return _map(data);
  }

  Future<Map<String, dynamic>> getDashboard(
    Map<String, dynamic> filters,
  ) async {
    final data = await SupabaseService.client.rpc(
      'get_training_dashboard',
      params: {
        'p_start_date': filters['startDate'],
        'p_end_date': filters['endDate'],
        'p_area': filters['area'],
        'p_branch_id': filters['branchId'],
        'p_department': filters['department'],
        'p_employee_id': filters['employeeId'],
      },
    );
    return _map(data);
  }

  /// The logged-in user's assigned training (participant rows + session).
  Future<List<Map<String, dynamic>>> myAssignments() async {
    final res = await SupabaseService.client
        .from('training_participants')
        .select(
          'id, status, assigned_at, opened_at, submitted_at, completed_at, '
          'training_sessions(id, title, training_type, description, facilitator, '
          'training_date, start_time, end_time, duration_minutes, delivery_type, '
          'location, venue_name, assessment_required, certificate_enabled, is_mandatory)',
        )
        .order('assigned_at', ascending: false);
    return _rows(res);
  }

  /// The three assigned questions for one participant attempt. Question set is
  /// fixed server-side and stays stable for the whole attempt.
  Future<Map<String, dynamic>> myAssignment(String participantId) async {
    final data = await SupabaseService.client.rpc(
      'get_my_training_assignment',
      params: {'p_participant_id': participantId},
    );
    return _map(data);
  }

  Future<Map<String, dynamic>> submitAssessment({
    required String participantId,
    required List<Map<String, dynamic>> answers,
    required String signaturePath,
    String declarationText = 'I declare that I completed this training and submitted these answers myself.',
  }) async {
    final data = await SupabaseService.client.rpc(
      'submit_training_assessment',
      params: {
        'p_participant_id': participantId,
        'p_answers': answers,
        'p_signature_path': signaturePath,
        'p_declaration_accepted': true,
        'p_declaration_text': declarationText,
      },
    );
    return _map(data);
  }

  Future<Map<String, dynamic>> verifyCertificate(String certNumber) async {
    final data = await SupabaseService.client.rpc(
      'verify_training_certificate',
      params: {'p_certificate_number': certNumber},
    );
    return _map(data);
  }

  Future<Map<String, dynamic>> employeeTrainingRecords(
    String employeeId,
  ) async {
    final res = await SupabaseService.client
        .from('employee_training_records')
        .select(
          '*, training_certificates(id, certificate_number, verification_status, pdf_path, issued_at)',
        )
        .eq('employee_id', employeeId)
        .order('training_date', ascending: false);
    return {'records': _rows(res)};
  }
}

/// Mimics `parseQuestionBank` / `buildQuestionSets` + `trainingCalculations.js`.
/// A KSS question set is built by rotating the manual question bank so each
/// participant receives a different one of up to three internally-edited sets;
/// the rotation itself is applied by the server RPC (`generate_kss_question_sets`).
class TrainingQuestions {
  TrainingQuestions._();

  static List<Map<String, dynamic>> parseQuestionBank(String text) {
    final lines = text.split('\n');
    final questions = <Map<String, dynamic>>[];
    for (var line in lines) {
      final parts = line
          .split('|')
          .map((p) => p.trim())
          .where((p) => p.isNotEmpty)
          .toList();
      if (parts.length < 2) continue;
      final options = switch (parts.length >= 3) {
        true =>
          parts[2]
              .split(',')
              .map((o) => o.trim())
              .where((o) => o.isNotEmpty)
              .toList(),
        false => const <String>[],
      };
      questions.add({
        'prompt': parts[0],
        'correct_answer': parts[1],
        'options': options,
        'question_type': options.length > 1 ? 'multiple_choice' : 'short_text',
        'marks': 1,
      });
    }
    return questions;
  }

  /// Returns the question sets payload the RPC requires. KSS always wants 3
  /// sets; a standard assessment wants 1.
  static List<Map<String, dynamic>> buildSets(List<Map<String, dynamic>> bank) {
    if (bank.isEmpty) return const [];
    final sets = <Map<String, dynamic>>[];
    for (var i = 0; i < 3; i++) {
      final rotated = <Map<String, dynamic>>[];
      for (var j = 0; j < bank.length; j++) {
        rotated.add(bank[(j + i) % bank.length]);
      }
      sets.add({'set_number': i + 1, 'questions': rotated});
    }
    return sets;
  }
}
