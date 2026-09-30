// ============================================================================
// Mobile mirror of the web platform's centralised navigation config.
//
// SOURCE OF TRUTH: infinitycore-sara/src/config/navigationConfig.js
//                 (module "Task B, Phase 3")
//
// WHY THIS IS A COPY AND NOT A FETCH
// The web config is a FRONTEND-ONLY module. It is a plain JS object with no
// backing table, view or RPC, so there is nothing for mobile to read and no
// server endpoint to add without changing the web platform's schema. The web
// file anticipates exactly this and instructs, in its own header:
//
//     "MIRRORING FOR MOBILE: Flutter should copy ROLE_DEPARTMENT verbatim
//      rather than inventing its own mapping; if the two ever disagree, this
//      file is correct."
//
// So [roleDepartment] below is a deliberate, line-for-line copy. When the web
// mapping changes, THIS FILE is what must change with it, and the parity test
// in test/navigation_config_test.dart is what makes the two drift loudly rather
// than silently.
//
// SECURITY: this is a UX LAYER, NOT A SECURITY BOUNDARY.
// Hiding a menu item is a convenience. The real boundaries are the RLS policies
// and the SECURITY DEFINER RPCs, each of which re-checks the caller's role on
// every call. A user who deep-links to a module their department does not own
// still gets refused by the server. Nothing here may ever be treated as the
// thing that protects a record.
// ============================================================================

import 'role_guard.dart';

/// Department keys.
///
/// Deliberately NOT the free-text `employees.department` (web
/// `constants/departments.js`): that field contains executive titles and is
/// typed by data-entry staff, so it cannot be trusted as a routing key. Role is
/// the reliable signal; department is only ever a refinement.
class AppDepartments {
  const AppDepartments._();

  static const hr = 'hr';
  static const audit = 'audit';
  static const risk = 'risk';
  static const admin = 'admin';
  static const operations = 'operations';
  static const eBusiness = 'e_business';
  static const finance = 'finance';
  static const executive = 'executive';

  static const all = <String>[
    hr,
    audit,
    risk,
    admin,
    operations,
    eBusiness,
    finance,
    executive,
  ];
}

/// Roles deliberately shown everything, regardless of department.
const List<String> kUnrestrictedRoles = <String>[
  AppRoles.superAdmin,
  AppRoles.admin,
];

/// Role -> department. This is the whole mapping, in one readable table.
///
/// Verbatim copy of the web `ROLE_DEPARTMENT`.
///
/// NOTE ON COMPLETENESS: the web parity test asserts that every role in the web
/// `ROLES` catalogue has an explicit entry here, so a new role can never fall
/// through to "shared tabs only" by accident. Two mobile-only legacy roles
/// (`hr_manager`, `operations_manager`) exist in [AppRoles] as compatibility
/// aliases for the Comm Admin gate; they are intentionally absent here, and
/// they therefore resolve to shared-only, which is the safe direction to fail.
const Map<String, List<String>> kRoleDepartment = <String, List<String>>{
  // Leadership is not scoped to one department; it may inspect any of them.
  AppRoles.superAdmin: AppDepartments.all,
  AppRoles.admin: AppDepartments.all,
  AppRoles.mdCeo: <String>[AppDepartments.executive],
  AppRoles.chairman: <String>[AppDepartments.executive],
  AppRoles.director: <String>[AppDepartments.executive],

  // Human Resources
  AppRoles.headOfHumanResources: <String>[AppDepartments.hr],
  AppRoles.hrOfficer: <String>[AppDepartments.hr],

  // Audit & Compliance
  AppRoles.headOfAudit: <String>[AppDepartments.audit],

  // Risk, Compliance & Legal
  AppRoles.headOfRiskCompliance: <String>[AppDepartments.risk],
  AppRoles.headOfLegal: <String>[AppDepartments.risk],

  // Admin & Corporate Services
  AppRoles.headOfBusiness: <String>[AppDepartments.admin],
  AppRoles.headOfOperations: <String>[AppDepartments.operations],

  // E-Business
  AppRoles.headOfEBusiness: <String>[AppDepartments.eBusiness],

  // Finance
  AppRoles.financialController: <String>[AppDepartments.finance],

  // Front line - their own world, plus the shared tabs.
  AppRoles.areaManager: <String>[AppDepartments.operations],
  AppRoles.branchManager: <String>[AppDepartments.operations],
  AppRoles.loanOfficer: <String>[AppDepartments.operations],
  AppRoles.relationshipManager: <String>[AppDepartments.operations],
  AppRoles.customerService: <String>[AppDepartments.operations],

  // Everyone else is a plain employee: shared tabs only.
  AppRoles.staff: <String>[],
  AppRoles.customer: <String>[],
};

/// The departments a user belongs to. Empty means "shared tabs only".
List<String> departmentsForRole(String? role) {
  if (role == null || role.isEmpty) return const [];
  if (kUnrestrictedRoles.contains(role)) return AppDepartments.all;
  return kRoleDepartment[role] ?? const [];
}

/// True when the user has no departmental workspace.
bool isSharedOnly(String? role) => departmentsForRole(role).isEmpty;

/// True when the user may see a destination owned by [ownedBy].
///
/// Ported from the web `filterSectionsByDepartment`. A destination with a null
/// department is SHARED and always passes; otherwise the user's departments
/// must include it.
///
/// A stored department may REFINE the role mapping but never replace it, since
/// the column is free text and may hold an executive title instead. An
/// unrecognised string therefore grants nothing.
///
/// This composes with - and does not replace - the existing permission check.
/// The permission check remains the stricter of the two.
///
/// Kept as a pure predicate so this file stays free of any Flutter import and
/// the mapping can be exercised by plain unit tests.
bool canSeeDepartment(String? role, String? ownedBy, String? storedDepartment) {
  if (role != null && kUnrestrictedRoles.contains(role)) return true;
  final mine = departmentsForRole(role).toSet();
  if (storedDepartment != null) {
    final normalised = storedDepartment.trim().toLowerCase().replaceAll(
      RegExp(r'[\s-]+'),
      '_',
    );
    if (AppDepartments.all.contains(normalised)) mine.add(normalised);
  }
  return ownedBy == null || mine.contains(ownedBy);
}
