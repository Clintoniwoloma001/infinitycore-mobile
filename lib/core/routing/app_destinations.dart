// ============================================================================
// Mobile destination registry
// ============================================================================
// The single place that decides WHICH destinations exist and WHICH department
// owns each one. Adding a future module means appending one entry here; the
// bottom bar, the hamburger menu and the parity tests all read from this list,
// so a destination cannot appear in one place and be forgotten in another.
//
// Department tags mirror the web `src/config/navigation.jsx` route groups:
//
//   Training            -> HR group              (department: DEPARTMENTS.HR)
//   Automation Command  -> Audit & Compliance    (department: DEPARTMENTS.AUDIT)
//   Branch Performance  -> shared, permission-gated (not a departmental group)
//
// A user should never see a destination in EITHER navigation surface that they
// cannot actually open. Filtering happens once, in [visibleDestinations], and
// both surfaces render that result.
//
// THIS IS NOT A SECURITY BOUNDARY. Every destination here is also protected
// server-side by RLS / role-gated RPCs, which is what actually refuses an
// unauthorised read. See navigation_config.dart for the full reasoning.
import 'package:flutter/material.dart';

import '../security/navigation_config.dart';
import '../security/role_guard.dart';
import '../services/auth_service.dart';

/// One navigable destination, tagged with the department that owns it.
///
/// A `null` [department] means SHARED: every authenticated user keeps it. This
/// mirrors the web `routeConfig` group, where an untagged group is shared.
class AppDestination {
  const AppDestination({
    required this.id,
    required this.label,
    required this.icon,
    required this.route,
    this.department,
    this.subtitle,
  });

  final String id;
  final String label;
  final String? subtitle;
  final IconData icon;
  final String route;

  /// Owning department, or null when the destination is shared by everyone.
  final String? department;
}

/// Builds the full destination catalogue.
List<AppDestination> appDestinations() => const [
  // --- Shared: every authenticated user keeps these -----------------------
  AppDestination(
    id: 'profile',
    label: 'Profile',
    subtitle: 'Personal details, documents and device security',
    icon: Icons.person_outline,
    route: '/profile',
  ),
  AppDestination(
    id: 'notifications',
    label: 'Notifications',
    subtitle: 'Updates, approvals and operational alerts',
    icon: Icons.notifications_none,
    route: '/notifications',
  ),

  // Training & Development.
  //
  // OWNERSHIP: on web this lives in the HR group and is gated on
  // `hr.training.read`. An employee still needs to reach their OWN training,
  // so the destination is shared and the screen itself separates "my
  // training" from HR authoring controls - the same split the web makes
  // between its shared `my-training` destination and the HR-group
  // `training` route. Hiding it from non-HR staff would strand employees who
  // are required to attend sessions.
  AppDestination(
    id: 'training',
    label: 'Training',
    subtitle: 'Sessions, enrolment and completion tracking',
    icon: Icons.school_outlined,
    route: '/training',
  ),

  // --- Departmental -------------------------------------------------------

  // Automation Command Centre.
  //
  // OWNERSHIP: on web this lives in the Audit & Compliance group, so it is
  // tagged AUDIT here and mirrors the web filtering exactly.
  //
  // KNOWN WEB INCONSISTENCY, mirrored deliberately so the two platforms keep
  // agreeing: the `automation.portfolio.read` permission is also granted to
  // head_of_human_resources and head_of_e_business, but the web tags the
  // Command Centre as Audit-only, so those roles are filtered OUT of the
  // menu even though the server would let them read it. Mirrored rather than
  // "fixed", because the web file is declared authoritative; reported to the
  // web team rather than quietly diverging.
  AppDestination(
    id: 'automation',
    label: 'Automation Command Centre',
    subtitle: 'Department automation completion tracking',
    icon: Icons.speed_outlined,
    route: '/automation',
    department: AppDepartments.audit,
  ),

  // Branch Performance.
  //
  // OWNERSHIP: there is no standalone Branch Performance module on web. The
  // figures come from the executive snapshot, so this is shared and gated by
  // the executive-workspace permission instead of a department.
  //
  // NOTE: this gate is NOT the same axis as kUnrestrictedRoles. Being
  // unrestricted waives the DEPARTMENT filter (Admin and Super Admin); reaching
  // the executive workspace needs `director.executive.read`, which the backend
  // seeds for director / super_admin / md_ceo / chairman only. Admin is
  // therefore unrestricted for navigation but does not see this destination -
  // and the server would refuse its RPC call regardless, so hiding it is the
  // honest rendering rather than a stricter-than-backend client.
  AppDestination(
    id: 'branch-performance',
    label: 'Branch Performance',
    subtitle: 'Attendance, KPI and target completion by branch',
    icon: Icons.account_balance_outlined,
    route: '/branch-performance',
  ),
];

/// True when [role] may open the Automation Command Centre.
///
/// Mirrors the `automation.portfolio.read` grants seeded in the web migration
/// 20260927000001 (super_admin, admin, head_of_audit, head_of_human_resources,
/// head_of_e_business). This narrows what the MENU shows; the RPC is the real
/// authority and currently does not enforce it on reads - see the final report.
bool canViewAutomation(String? role) => const [
  AppRoles.superAdmin,
  AppRoles.admin,
  AppRoles.headOfAudit,
  AppRoles.headOfHumanResources,
  AppRoles.headOfEBusiness,
].contains(role);

/// The destinations a user may see, in menu order.
///
/// [AppDestination.department] is applied first, then any destination that
/// needs a capability check of its own. Both filters are UX only.
List<AppDestination> visibleDestinations() {
  final auth = AuthService.instance;
  final role = auth.role;

  return appDestinations()
      .where(
        (d) => canSeeDepartment(role, d.department, auth.department),
      )
      .where((d) => switch (d.id) {
        'automation' => canViewAutomation(role),
        'branch-performance' => canOpenExecutiveWorkspace(role),
        _ => true,
      })
      .toList(growable: false);
}
