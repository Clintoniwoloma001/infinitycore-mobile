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

  // I-MEET.
  //
  // OWNERSHIP: shared, like Training above. Recording a meeting and reading
  // one's OWN meetings is a capability of every employee, and I-Meet has no
  // module owner that should gate it departmentally.
  //
  // This is NOT a weaker security posture than a department tag would be: the
  // gate here is per-MEETING rather than per-ROLE. RLS admits a caller only if
  // they own the meeting or were a frozen participant on it, so a shared menu
  // entry still cannot surface another person's audio. The list query only ever
  // returns meetings the caller may read.
  AppDestination(
    id: 'imeet',
    label: 'I-Meet',
    subtitle: 'Record meetings, transcripts, summaries and action items',
    icon: Icons.graphic_eq,
    route: '/imeet',
  ),

  // --- Departmental -------------------------------------------------------

  // Automation Command Centre.
  //
  // OWNERSHIP: on web this lives in the Audit & Compliance group. Mobile keeps
  // the AUDIT tag so the department filter still governs it, but the executive
  // viewer family is granted an explicit override in [visibleDestinations] -
  // see the note there for why mirroring the web filter exactly was not enough.
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
/// The Audit department tag alone was not enough for the executive audience: a
/// Director, Chairman or MD/CEO is tagged `department: executive`, so
/// `canSeeDepartment` filtered the Audit-owned Automation destination out of
/// their menu entirely. That is why the Command Centre was unreachable from the
/// director shell even though the route exists and the server would serve it.
///
/// This screen is READ-ONLY on mobile (status changes are web-only), so the
/// executives need it for oversight, which is exactly the use the MD/CEO has of
/// department automation completion. [AppRoles.isExecutiveViewer] is used rather
/// than listing the three roles so no future executive variant is forgotten.
bool canViewAutomation(String? role) =>
    const [
      AppRoles.superAdmin,
      AppRoles.admin,
      AppRoles.headOfAudit,
      AppRoles.headOfHumanResources,
      AppRoles.headOfEBusiness,
    ].contains(role) ||
    (role != null && AppRoles.isExecutiveViewer(role));

/// The destinations a user may see, in menu order.
///
/// [AppDestination.department] is applied first, then any destination that
/// needs a capability check of its own. Both filters are UX only.
///
/// AUTOMATION is the one exception to the department-first order. It is owned
/// by Audit, but the executive viewer family (Director, Chairman, MD/CEO) is
/// stored under the `executive` department and so never matches `audit`. Those
/// roles are granted it explicitly through [canViewAutomation] - which is
/// checked first - because the Command Centre is read-only on mobile and
/// department oversight is precisely what an MD/CEO needs it for. Without this
/// the destination was routed and authorised but permanently invisible.
List<AppDestination> visibleDestinations() {
  final auth = AuthService.instance;
  final role = auth.role;

  return appDestinations()
      .where(
        (d) =>
            (d.id == 'automation' && canViewAutomation(role)) ||
            canSeeDepartment(role, d.department, auth.department),
      )
      .where(
        (d) => switch (d.id) {
          'automation' => canViewAutomation(role),
          'branch-performance' => canOpenExecutiveWorkspace(role),
          _ => true,
        },
      )
      .toList(growable: false);
}
