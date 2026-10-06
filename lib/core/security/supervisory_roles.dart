/// The canonical set of supervisory / executive roles that may be chosen in a
/// "Supervisor", "Department Head" or "Approver" field.
///
/// WHY THIS IS A SHARED LIST AND NOT A PER-SCREEN LIST
/// Dropdowns scattered across the app each re-typed their own idea of "who
/// counts as management", and they drifted. This is the single definition, and
/// it is mirrored by the SQL role list in migration
/// `20261101000009_supervisory_directory.sql`. Change one, change both.
///
/// ROLE MAPPING — the product spec named these offices; the database stores
/// these role keys:
///   Head of Credit & Marketing -> `head_of_business` (the nearest stored
///     role; there is no `head_of_credit` key in the schema)
///   Head of FINCON              -> `financial_controller`
///   Board of Directors          -> `director` AND `chairman` (two stored
///     keys, one office)
library;

import '../../core/services/supabase_service.dart';
import 'role_guard.dart';

/// A person who may be selected as a supervisor.
class SupervisoryPerson {
  const SupervisoryPerson({
    required this.id,
    required this.fullName,
    required this.role,
    this.department = '',
    this.branch = '',
    this.employeeId,
  });

  factory SupervisoryPerson.fromJson(Map<String, dynamic> j) =>
      SupervisoryPerson(
        id: (j['id'] ?? '').toString(),
        fullName: (j['full_name'] ?? '').toString(),
        role: (j['role'] ?? '').toString(),
        department: (j['department'] ?? '').toString(),
        branch: (j['branch'] ?? '').toString(),
        employeeId: (j['employee_id'] ?? '') == ''
            ? null
            : (j['employee_id'] ?? '').toString(),
      );

  final String id;
  final String fullName;
  final String role;
  final String department;
  final String branch;

  /// Null for office holders (Director, Chairman, MD/CEO), who are profiles
  /// without a roster line. Their absence is NOT an error.
  final String? employeeId;

  String get roleLabel => AppRoles.label(role);

  /// "Ada Okafor · Head of Human Resources" — the combobox search label.
  String get searchLabel =>
      fullName.isEmpty ? roleLabel : '$fullName · $roleLabel';

  /// Secondary line for the option row, so two people with the same name are
  /// still distinguishable.
  String? get subtitle {
    final parts = [
      if (department.isNotEmpty) department,
      if (branch.isNotEmpty) branch,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

class SupervisoryRoles {
  const SupervisoryRoles._();

  /// Every role key that may be selected in a supervisory field.
  ///
  /// Deliberately EXCLUDES `super_admin` and `admin`. Those are system
  /// administrators, not line-management offices, and offering them in a
  /// "Department Head" picker would invite routing a staff appraisal to
  /// someone who has no department.
  static const Set<String> supervisory = {
    AppRoles.headOfHumanResources,
    AppRoles.headOfEBusiness,
    AppRoles.headOfBusiness,
    AppRoles.headOfOperations,
    AppRoles.financialController,
    AppRoles.headOfAudit,
    AppRoles.areaManager,
    AppRoles.branchManager,
    AppRoles.mdCeo,
    AppRoles.director,
    AppRoles.chairman,
  };

  static bool isSupervisory(String role) => supervisory.contains(role);

  /// Roles a user may themselves take on, for a "pick my supervisor" field.
  /// A branch manager's supervisor is an area manager or above, never another
  /// branch manager in a different branch.
  static const Set<String> supervisoryAboveBranchManager = {
    AppRoles.mdCeo,
    AppRoles.chairman,
    AppRoles.director,
    AppRoles.headOfBusiness,
    AppRoles.headOfOperations,
    AppRoles.headOfEBusiness,
    AppRoles.headOfHumanResources,
    AppRoles.financialController,
    AppRoles.headOfAudit,
    AppRoles.areaManager,
  };
}

/// Server-authoritative directory of selectable supervisors.
///
/// The role filter is applied by the DATABASE, not here. This client simply
/// renders whatever the server is willing to return, so a tampered client
/// cannot widen the list — the same principle the tracking screen follows.
class SupervisorService {
  const SupervisorService._();

  static final SupervisorService instance = SupervisorService._();

  Future<List<SupervisoryPerson>> directory({String? query}) async {
    final res = await SupabaseService.client.rpc(
      'rpc_get_supervisory_directory',
      params: {'p_query': query},
    );
    final j = res is Map ? Map<String, dynamic>.from(res) : null;
    if (j == null) {
      throw SupervisorException('The server returned an unexpected response.');
    }
    if (j['ok'] != true) {
      throw SupervisorException(
        '${j['message'] ?? 'Unable to load the supervisory directory'}',
      );
    }
    final raw = j['people'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => SupervisoryPerson.fromJson(Map<String, dynamic>.from(e)))
        .toList(growable: false);
  }

  /// Filters an already-loaded list down to the supervisory set.
  ///
  /// Used as a defence-in-depth pass over data fetched from a broader source,
  /// and to keep the dropdown honest if it is ever fed from a cache.
  static List<SupervisoryPerson> onlySupervisory(
    Iterable<SupervisoryPerson> people,
  ) =>
      people
          .where((p) => SupervisoryRoles.isSupervisory(p.role))
          .toList(growable: false);
}

class SupervisorException implements Exception {
  const SupervisorException(this.message);
  final String message;
  @override
  String toString() => message;
}
