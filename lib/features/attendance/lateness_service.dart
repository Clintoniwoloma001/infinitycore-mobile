import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/diagnostics/auth_trace.dart';
import '../../core/security/role_guard.dart';
import '../../core/services/supabase_service.dart';
import '../messages/messaging_service.dart';
import '../messages/communication_service.dart';

/// Lateness reason categories offered on the clock-in modal. The values are
/// the CHECK constraint's vocabulary in `public.lateness_reasons` — see
/// `supabase/migrations/20261112000000_messaging_receipts_lateness_rls.sql`.
enum LatenessCategory {
  traffic('traffic', 'Traffic'),
  transportIssue('transport_issue', 'Transport issue'),
  health('health', 'Health'),
  familyEmergency('family_emergency', 'Family emergency'),
  officialAssignment('official_assignment', 'Official assignment'),
  others('others', 'Others');

  const LatenessCategory(this.value, this.label);

  final String value;
  final String label;

  static LatenessCategory? fromValue(String? value) {
    for (final c in values) {
      if (c.value == value) return c;
    }
    return null;
  }
}

/// The date ranges offered on the Lateness Reasons screen.
enum LatenessRange { today, week, month, custom }

/// Resolves a range to its inclusive `[from, to]` work-date window.
///
/// `today` is the current local date; `week` is Monday-start; `month` starts on
/// the 1st; `custom` falls back to today when no range has been picked yet.
/// Pure so the filter behaviour is testable without a device.
({DateTime from, DateTime to}) latenessWindow(
  LatenessRange range, {
  DateTime? customFrom,
  DateTime? customTo,
  DateTime? now,
}) {
  final moment = now ?? DateTime.now();
  final today = DateTime(moment.year, moment.month, moment.day);
  switch (range) {
    case LatenessRange.today:
      return (from: today, to: today);
    case LatenessRange.week:
      final monday = today.subtract(Duration(days: today.weekday - 1));
      return (from: monday, to: today);
    case LatenessRange.month:
      return (from: DateTime(moment.year, moment.month, 1), to: today);
    case LatenessRange.custom:
      final from = customFrom ?? today;
      return (from: from, to: customTo ?? from);
  }
}

/// A lateness reason row as the HR review screen reads it.
class LatenessReason {
  const LatenessReason({
    required this.id,
    required this.userId,
    required this.employeeName,
    required this.branch,
    required this.workDate,
    required this.clockedInAt,
    required this.minutesLate,
    required this.category,
    required this.text,
  });

  factory LatenessReason.fromJson(Map<String, dynamic> row) {
    final employee = row['employee'];
    final name = '${(employee is Map ? employee['full_name'] : null) ?? ''}'
        .trim();
    return LatenessReason(
      id: '${row['id'] ?? ''}',
      userId: '${row['user_id'] ?? ''}',
      employeeName: name.isEmpty ? 'Unknown employee' : name,
      branch: '${row['branch_name'] ?? ''}'.trim(),
      workDate: DateTime.tryParse('${row['work_date'] ?? ''}'),
      clockedInAt: DateTime.tryParse('${row['clocked_in_at'] ?? ''}'),
      minutesLate: int.tryParse('${row['minutes_late'] ?? 0}') ?? 0,
      category: '${row['reason_category'] ?? ''}',
      text: '${row['reason_text'] ?? ''}'.trim(),
    );
  }

  final String id;
  final String userId;
  final String employeeName;
  final String branch;
  final DateTime? workDate;
  final DateTime? clockedInAt;
  final int minutesLate;
  final String category;
  final String text;

  String get categoryLabel =>
      LatenessCategory.fromValue(category)?.label ?? category;
}

/// Submitting and reviewing lateness reasons.
///
/// Writes go through `public.lateness_reasons`, whose RLS lets a user insert
/// and read ONLY their own row (see the migration). When the device is offline
/// the submission is queued locally and flushed on the next app resume, so the
/// reason is never lost and the clock-in itself is never blocked by it.
class LatenessService {
  LatenessService._();

  static final LatenessService instance = LatenessService._();

  static const _queueKey = 'lateness_reason_queue_v1';

  /// Submits the reason for the signed-in user, queueing it locally when the
  /// network is unavailable. Returns true when it reached the server.
  Future<bool> submit({
    required int minutesLate,
    required DateTime clockedInAt,
    DateTime? workDate,
    String? attendanceId,
    String? branchId,
    String? branchName,
    required LatenessCategory category,
    required String text,
  }) async {
    final me = SupabaseService.client.auth.currentUser?.id;
    if (me == null) return false;
    final payload = <String, dynamic>{
      'user_id': me,
      'work_date': (workDate ?? DateTime.now()).toIso8601String(),
      'clocked_in_at': clockedInAt.toUtc().toIso8601String(),
      'minutes_late': minutesLate,
      'branch_id': branchId,
      'branch_name': branchName,
      'reason_category': category.value,
      // 'others' requires free text (>= 5 chars); other categories may also
      // carry a note. The table stores either.
      'reason_text': text.trim().isEmpty ? null : text.trim(),
    };
    if (attendanceId != null && attendanceId.isNotEmpty) {
      payload['attendance_id'] = attendanceId;
    }
    try {
      await SupabaseService.client.from('lateness_reasons').insert(payload);
      AuthTrace.log('lateness', 'reason submitted minutes_late=$minutesLate');
      await _notifyReviewers();
      return true;
    } catch (e) {
      AuthTrace.log('lateness', 'submit failed, queueing: $e');
      await _enqueue(payload);
      return false;
    }
  }

  /// Flushes queued submissions. Called on app resume and after a successful
  /// clock-in, so an offline reason lands as soon as the network returns.
  Future<int> syncQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_queueKey) ?? const <String>[];
    if (raw.isEmpty) return 0;
    final remaining = <String>[];
    var sent = 0;
    for (final entry in raw) {
      try {
        final payload = Map<String, dynamic>.from(
          jsonDecode(entry) as Map,
        );
        await SupabaseService.client.from('lateness_reasons').insert(payload);
        sent++;
        await _notifyReviewers();
      } catch (_) {
        remaining.add(entry);
      }
    }
    await prefs.setStringList(_queueKey, remaining);
    return sent;
  }

  Future<void> _enqueue(Map<String, dynamic> payload) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_queueKey) ?? <String>[];
    raw.add(jsonEncode(payload));
    await prefs.setStringList(_queueKey, raw);
  }

  /// Notifies the HR-head audience through the EXISTING in-app notification
  /// mechanism (the `notifications` table, delivered by realtime while the app
  /// is alive and read on next open). No push transport exists yet.
  ///
  /// Recipients are resolved through the SECURITY DEFINER
  /// `get_messaging_directory` RPC — the same staff directory the messaging
  /// pickers use — because a plain `profiles` query cannot list other users'
  /// roles.
  Future<void> _notifyReviewers() async {
    try {
      final me = SupabaseService.client.auth.currentUser?.id;
      final directory = await CommunicationService.instance.messagingDirectory();
      final reviewerIds = directory
          .where((p) => canReviewLateness('${p['role'] ?? ''}'))
          .map((p) => '${p['user_id'] ?? ''}')
          .where((id) => id.isNotEmpty && id != me)
          .toSet();
      if (reviewerIds.isEmpty) return;
      final name = await _myName();
      for (final id in reviewerIds) {
        await SupabaseService.client.from('notifications').insert({
          'user_id': id,
          'title': 'New lateness reason',
          'message': '$name submitted a reason for being late.',
          'type': 'lateness',
          'link': latenessReasonsRoute,
        });
      }
    } catch (e) {
      // The reason row is already saved; a missed notification is never worth
      // failing the clock-in flow.
      AuthTrace.log('lateness', 'reviewer notification failed: $e');
    }
  }

  Future<String> _myName() async {
    try {
      final me = SupabaseService.client.auth.currentUser?.id ?? '';
      if (me.isEmpty) return 'An employee';
      final dir = await MessagingService.instance.resolveDirectory([me]);
      final row = dir[me];
      return '${row?['full_name'] ?? row?['email'] ?? 'An employee'}';
    } catch (_) {
      return 'An employee';
    }
  }

  /// Lists lateness reasons for the review screen, newest first.
  ///
  /// The date window, the total count and the ordering come from the SERVER;
  /// the name/branch search and pagination are applied over that window in the
  /// client. RLS restricts the result to the caller's own rows unless they are
  /// an HR reviewer, so this needs no extra client-side role check.
  Future<List<LatenessReason>> list({
    required DateTime from,
    required DateTime to,
    String? query,
    String? branch,
    int limit = 25,
    int offset = 0,
  }) async {
    final rows = await SupabaseService.client
        .from('lateness_reasons')
        .select('*, employee:profiles!inner(full_name)')
        .gte('work_date', _dateOnly(from))
        .lte('work_date', _dateOnly(to))
        .order('work_date', ascending: false)
        .order('clocked_in_at', ascending: false)
        .limit(1000);
    final all = (rows as List? ?? const [])
        .whereType<Map>()
        .map((e) => LatenessReason.fromJson(Map<String, dynamic>.from(e)))
        .toList(growable: false);

    final q = query?.trim().toLowerCase() ?? '';
    var filtered = all.where((r) {
      if (branch != null && branch.isNotEmpty && r.branch != branch) {
        return false;
      }
      if (q.isEmpty) return true;
      return r.employeeName.toLowerCase().contains(q) ||
          r.branch.toLowerCase().contains(q);
    }).toList(growable: false);

    if (offset >= filtered.length) return const [];
    final end = (offset + limit).clamp(0, filtered.length);
    return filtered.sublist(offset, end);
  }

  /// Total rows for the window after the name/branch filter, so the screen can
  /// show "N reasons" and know when to stop paging.
  Future<int> count({
    required DateTime from,
    required DateTime to,
    String? query,
    String? branch,
  }) async {
    final rows = await list(from: from, to: to, query: query, branch: branch);
    return rows.length >= 1000 ? 1000 : rows.length;
  }

  /// Distinct branch names present in the current window, for the branch
  /// filter. Falls back to an empty list rather than failing the screen.
  Future<List<String>> branches({
    required DateTime from,
    required DateTime to,
  }) async {
    try {
      final rows = await SupabaseService.client
          .from('lateness_reasons')
          .select('branch_name')
          .gte('work_date', _dateOnly(from))
          .lte('work_date', _dateOnly(to))
          .not('branch_name', 'is', null);
      final names = <String>{};
      for (final row in (rows as List? ?? const [])) {
        final name = '${(row as Map)['branch_name'] ?? ''}'.trim();
        if (name.isNotEmpty) names.add(name);
      }
      final sorted = names.toList()..sort();
      return sorted;
    } catch (_) {
      return const [];
    }
  }

  static String _dateOnly(DateTime d) =>
      DateTime(d.year, d.month, d.day).toIso8601String();
}

/// Convenience: the friendly copy for a submission that had to be queued.
String latenessQueuedNotice() =>
    'You are offline, so your reason is saved on this device and will be '
    'sent automatically when you are back online. Your clock-in is already '
    'recorded.';
