import '../../shared/models/models.dart';

/// Role metadata mirrors `src/constants/roles.js` in infinitycore-sara.
///
/// Client role checks are a UI convenience only — the backend (RLS + roles in
/// the `profiles` row) remains the authoritative security boundary.

class AppRoles {
  static const superAdmin = 'super_admin';
  static const admin = 'admin';
  static const hrManager = 'hr_manager';
  static const operationsManager = 'operations_manager';
  static const branchManager = 'branch_manager';
  static const areaManager = 'area_manager';
  static const headOfBusiness = 'head_of_business';
  static const headOfOperations = 'head_of_operations';
  static const headOfEBusiness = 'head_of_e_business';
  static const financialController = 'financial_controller';
  static const headOfRiskCompliance = 'head_of_risk_compliance';
  static const headOfLegal = 'head_of_legal';
  static const headOfAudit = 'head_of_audit';
  static const loanOfficer = 'loan_officer';
  static const relationshipManager = 'relationship_manager';
  static const customerService = 'customer_service';
  static const headOfHumanResources = 'head_of_human_resources';
  static const hrOfficer = 'hr_officer';
  static const staff = 'staff';
  static const customer = 'customer';

  // Executive viewer family (Phase 70). These three share ONE read-only
  // executive access profile, exactly as they do on the web
  // (src/constants/roles.js EXECUTIVE_VIEWER_ROLES). They are gated through
  // [isExecutiveViewer] rather than being checked role-by-role at each call
  // site, so no surface can forget one of them.
  static const director = 'director';
  static const chairman = 'chairman';
  static const mdCeo = 'md_ceo';

  /// True for the roles that share the read-only executive workspace.
  static bool isExecutiveViewer(String role) =>
      role == director || role == chairman || role == mdCeo;

  static const hierarchy = <String, int>{
    superAdmin: 100,
    admin: 90,
    mdCeo: 98,
    chairman: 96,
    director: 95,
    headOfEBusiness: 80,
    headOfOperations: 79,
    headOfBusiness: 78,
    areaManager: 77,
    branchManager: 76,
    financialController: 75,
    headOfRiskCompliance: 74,
    headOfLegal: 73,
    headOfAudit: 72,
    loanOfficer: 60,
    relationshipManager: 60,
    headOfHumanResources: 60,
    customerService: 50,
    hrOfficer: 50,
    staff: 40,
    customer: 10,
  };

  static String label(String role) {
    switch (role) {
      case superAdmin:
        return 'Super Admin';
      case admin:
        return 'Admin';
      case hrManager:
        return 'HR Manager';
      case operationsManager:
        return 'Operations Manager';
      case branchManager:
        return 'Branch Manager';
      case areaManager:
        return 'Area Manager';
      case headOfBusiness:
        return 'Head of Business';
      case headOfOperations:
        return 'Head of Operations';
      case headOfEBusiness:
        return 'Head of e-Business';
      case financialController:
        return 'Financial Controller';
      case headOfRiskCompliance:
        return 'Head of Risk & Compliance';
      case headOfLegal:
        return 'Head of Legal';
      case headOfAudit:
        return 'Head of Audit';
      case loanOfficer:
        return 'Loan Officer';
      case relationshipManager:
        return 'Relationship Manager';
      case customerService:
        return 'Customer Service';
      case headOfHumanResources:
        return 'Head of Human Resources';
      case hrOfficer:
        return 'HR Officer';
      case staff:
        return 'Staff';
      case customer:
        return 'Customer';
      case director:
        return 'Director';
      case chairman:
        return 'Chairman';
      case mdCeo:
        return 'MD/CEO';
      default:
        return role.isEmpty ? 'Staff' : role;
    }
  }
}

/// The route an executive-viewer role lands on, and the one Super Admin can
/// also open. Kept here (not inline in the router) so the routing rule is
/// unit-testable on its own.
const String executiveRoute = '/director';

/// The staff analytics workspace. Same audience as [canManageAttendance] — it
/// reads the same server-authoritative summary RPC.
const String staffAnalyticsRoute = '/staff-analytics';

/// Employee Tracking. Super Admin + Head of HR + executive family on mobile —
/// see [canAccessEmployeeTracking]. Kept as a constant so the router, the menu
/// and the auth gate cannot drift apart on the path string.
const String employeeTrackingRoute = '/employee-tracking';

/// Geofence Settings / Management (fence list + the interactive coverage
/// tester). Kept as a constant for the same reason as
/// [employeeTrackingRoute]; see [canManageGeofences].
const String geofenceManagementRoute = '/geofences';

/// True when this role gets the executive workspace as its HOME experience.
///
/// Super Admin is deliberately EXCLUDED. It keeps its own dashboard and may
/// also open the executive workspace, exactly as the web does.
bool usesExecutiveWorkspace(String role) => AppRoles.isExecutiveViewer(role);

/// True when this role may open the executive workspace at all.
bool canOpenExecutiveWorkspace(String role) =>
    AppRoles.isExecutiveViewer(role) || role == AppRoles.superAdmin;

/// Permission keys copied verbatim from the web permission system so screen
/// visibility matches the platform's own role matrix.
class Permissions {
  static const customersRead = 'customers.read';
  static const hrJobsCreate = 'hr.jobs.create';
  static const hrApplicationsRead = 'hr.applications.read';
  static const hrAssessmentsCreate = 'hr.assessments.create';
  static const hrInterviewsSchedule = 'hr.interviews.schedule';
  static const hrHire = 'hr.hire';
  static const hrLeaveManage = 'hr.leave.manage';
  static const hrPayrollRead = 'hr.payroll.read';
  static const hrOfferLettersRead = 'hr.offer_letters.read';
  static const hrOnboardingRead = 'hr.onboarding.read';
  static const hrOnboardingManage = 'hr.onboarding.manage';
  static const hrEmployeeRead = 'hr.employee.read';
  static const hrEmployeeUpdate = 'hr.employee.update';
  static const hrAttendanceSelf = 'hr.attendance.self';
  static const hrAttendanceManage = 'hr.attendance.manage';
  static const hrSettingsManage = 'hr.settings.manage';
  static const hrOrgManage = 'hr.org.manage';
  static const hrTrainingRead = 'hr.training.read';
  static const hrTrainingManage = 'hr.training.manage';
  static const payrollManage = 'payroll.manage';
  static const payrollPush = 'payroll.push';
  static const payrollApprove = 'payroll.approve';
  static const reportsRead = 'reports.read';
  static const bankoneRead = 'bankone.read';
  static const reconciliationRead = 'reconciliation.read';
  static const adminManageUsers = 'admin.manage_users';
  static const adminViewAudit = 'admin.view_audit';
  static const adminManageConfig = 'admin.manage_config';
  static const workforceManhourRead = 'workforce.manhour.read';
  static const medicalRead = 'medical.read';
  static const medicalManage = 'medical.manage';
}

/// Role → permitted permission list (web `ROLE_PERMISSIONS`).
class RolePermissions {
  static const Map<String, List<String>> matrix = {
    AppRoles.superAdmin: [
      Permissions.customersRead,
      Permissions.hrJobsCreate,
      Permissions.hrApplicationsRead,
      Permissions.hrAssessmentsCreate,
      Permissions.hrInterviewsSchedule,
      Permissions.hrHire,
      Permissions.hrLeaveManage,
      Permissions.hrPayrollRead,
      Permissions.hrOfferLettersRead,
      Permissions.hrOnboardingRead,
      Permissions.hrOnboardingManage,
      Permissions.hrEmployeeRead,
      Permissions.hrEmployeeUpdate,
      Permissions.hrAttendanceSelf,
      Permissions.hrAttendanceManage,
      Permissions.hrSettingsManage,
      Permissions.payrollManage,
      Permissions.payrollPush,
      Permissions.payrollApprove,
      Permissions.reportsRead,
      Permissions.bankoneRead,
      Permissions.reconciliationRead,
      Permissions.adminManageUsers,
      Permissions.adminViewAudit,
      Permissions.adminManageConfig,
      Permissions.hrOrgManage,
      Permissions.medicalRead,
      Permissions.medicalManage,
      Permissions.hrTrainingRead,
      Permissions.hrTrainingManage,
      Permissions.workforceManhourRead,
    ],
    AppRoles.admin: [
      Permissions.customersRead,
      Permissions.hrJobsCreate,
      Permissions.hrApplicationsRead,
      Permissions.hrAssessmentsCreate,
      Permissions.hrInterviewsSchedule,
      Permissions.hrHire,
      Permissions.hrLeaveManage,
      Permissions.hrPayrollRead,
      Permissions.hrOfferLettersRead,
      Permissions.hrOnboardingRead,
      Permissions.hrOnboardingManage,
      Permissions.hrEmployeeRead,
      Permissions.hrEmployeeUpdate,
      Permissions.hrAttendanceSelf,
      Permissions.hrAttendanceManage,
      Permissions.hrSettingsManage,
      Permissions.payrollManage,
      Permissions.payrollPush,
      Permissions.payrollApprove,
      Permissions.reportsRead,
      Permissions.bankoneRead,
      Permissions.reconciliationRead,
      Permissions.adminManageUsers,
      Permissions.adminViewAudit,
      Permissions.adminManageConfig,
      Permissions.hrOrgManage,
      Permissions.medicalRead,
      Permissions.medicalManage,
      Permissions.hrTrainingRead,
      Permissions.hrTrainingManage,
      Permissions.workforceManhourRead,
    ],
    AppRoles.branchManager: [
      Permissions.customersRead,
      Permissions.hrAttendanceSelf,
      Permissions.hrAttendanceManage,
      Permissions.hrTrainingRead,
      Permissions.workforceManhourRead,
      Permissions.reportsRead,
    ],
    AppRoles.areaManager: [
      Permissions.customersRead,
      Permissions.hrLeaveManage,
      Permissions.hrAttendanceSelf,
      Permissions.hrTrainingRead,
      Permissions.workforceManhourRead,
      Permissions.reportsRead,
    ],
    AppRoles.headOfBusiness: [
      Permissions.customersRead,
      Permissions.hrLeaveManage,
      Permissions.hrAttendanceSelf,
      Permissions.hrTrainingRead,
      Permissions.workforceManhourRead,
      Permissions.reportsRead,
    ],
    AppRoles.headOfOperations: [
      Permissions.hrAttendanceSelf,
      Permissions.hrAttendanceManage,
      Permissions.reportsRead,
      Permissions.workforceManhourRead,
    ],
    AppRoles.headOfEBusiness: [
      Permissions.hrAttendanceSelf,
      Permissions.hrTrainingRead,
      Permissions.workforceManhourRead,
      Permissions.reportsRead,
    ],
    AppRoles.financialController: [
      Permissions.hrAttendanceSelf,
      Permissions.hrPayrollRead,
      Permissions.payrollApprove,
      Permissions.hrTrainingRead,
      Permissions.workforceManhourRead,
      Permissions.reportsRead,
    ],
    AppRoles.headOfRiskCompliance: [
      Permissions.hrAttendanceSelf,
      Permissions.hrTrainingRead,
      Permissions.workforceManhourRead,
      Permissions.reportsRead,
    ],
    AppRoles.headOfLegal: [
      Permissions.hrAttendanceSelf,
      Permissions.hrTrainingRead,
      Permissions.workforceManhourRead,
      Permissions.reportsRead,
    ],
    AppRoles.headOfAudit: [
      Permissions.hrAttendanceSelf,
      Permissions.hrTrainingRead,
      Permissions.workforceManhourRead,
      Permissions.reportsRead,
      Permissions.adminViewAudit,
    ],
    AppRoles.loanOfficer: [Permissions.hrAttendanceSelf],
    AppRoles.relationshipManager: [Permissions.hrAttendanceSelf],
    AppRoles.customerService: [Permissions.hrAttendanceSelf],
    AppRoles.headOfHumanResources: [
      Permissions.hrJobsCreate,
      Permissions.hrApplicationsRead,
      Permissions.hrAssessmentsCreate,
      Permissions.hrInterviewsSchedule,
      Permissions.hrHire,
      Permissions.hrLeaveManage,
      Permissions.hrPayrollRead,
      Permissions.hrOfferLettersRead,
      Permissions.hrOnboardingRead,
      Permissions.hrOnboardingManage,
      Permissions.hrEmployeeRead,
      Permissions.hrEmployeeUpdate,
      Permissions.hrAttendanceSelf,
      Permissions.hrAttendanceManage,
      Permissions.hrSettingsManage,
      Permissions.payrollManage,
      Permissions.payrollPush,
      Permissions.payrollApprove,
      Permissions.reportsRead,
      Permissions.bankoneRead,
      Permissions.reconciliationRead,
      Permissions.hrOrgManage,
      Permissions.medicalRead,
      Permissions.medicalManage,
      Permissions.hrTrainingRead,
      Permissions.hrTrainingManage,
      Permissions.workforceManhourRead,
    ],
    AppRoles.hrOfficer: [
      Permissions.hrApplicationsRead,
      Permissions.hrAssessmentsCreate,
      Permissions.hrInterviewsSchedule,
      Permissions.hrOfferLettersRead,
      Permissions.hrOnboardingRead,
      Permissions.hrEmployeeRead,
      Permissions.hrAttendanceSelf,
      Permissions.hrAttendanceManage,
      Permissions.hrPayrollRead,
      Permissions.payrollPush,
      Permissions.bankoneRead,
      Permissions.reconciliationRead,
      Permissions.medicalRead,
      Permissions.hrTrainingRead,
    ],
    AppRoles.staff: [Permissions.hrAttendanceSelf],
    AppRoles.customer: [Permissions.hrAttendanceSelf],
  };

  static List<String> forRole(String role) =>
      matrix[role] ?? matrix[AppRoles.staff] ?? const [];
}

class AccessProfile {
  final Profile profile;
  final List<String> permissions;
  final List<String> accessModules;

  const AccessProfile({
    required this.profile,
    this.permissions = const [],
    this.accessModules = const [],
  });

  bool can(String permission) =>
      permissions.contains(permission) || accessModules.contains(permission);

  bool any(List<String> required) =>
      required.any((p) => permissions.contains(p) || accessModules.contains(p));

  bool get canReadEmployees => any([
    Permissions.hrEmployeeRead,
    Permissions.hrEmployeeUpdate,
    Permissions.hrApplicationsRead,
    Permissions.adminManageUsers,
  ]);
}

AccessProfile buildAccess(Profile profile, List<String>? accessModules) {
  return AccessProfile(
    profile: profile,
    permissions: RolePermissions.forRole(profile.role),
    accessModules: accessModules ?? const [],
  );
}

/// Screens allowed for a role (web `ROLE_MODULES`), used to build the drawer.
List<String> roleModules(String role) {
  switch (role) {
    case AppRoles.superAdmin:
    case AppRoles.admin:
      return const [
        'dashboard',
        'employees',
        'attendance',
        'sara',
        'messages',
        'notifications',
        'settings',
        'profile',
        'hr',
        'payroll',
        'training',
      ];
    case AppRoles.headOfHumanResources:
      return const [
        'dashboard',
        'employees',
        'attendance',
        'sara',
        'messages',
        'notifications',
        'settings',
        'profile',
        'hr',
        'onboarding',
        'recruitment',
        'payroll',
        'training',
      ];
    case AppRoles.hrOfficer:
      return const [
        'dashboard',
        'employees',
        'attendance',
        'sara',
        'messages',
        'notifications',
        'profile',
        'hr',
        'recruitment',
        'payroll',
        'training',
      ];
    case AppRoles.branchManager:
    case AppRoles.headOfOperations:
    case AppRoles.areaManager:
    case AppRoles.headOfBusiness:
    case AppRoles.headOfEBusiness:
    case AppRoles.financialController:
    case AppRoles.headOfRiskCompliance:
    case AppRoles.headOfLegal:
    case AppRoles.headOfAudit:
      return const [
        'dashboard',
        'attendance',
        'sara',
        'messages',
        'notifications',
        'profile',
        'payroll',
        'training',
      ];
    default:
      return const [
        'dashboard',
        'attendance',
        'sara',
        'messages',
        'notifications',
        'profile',
        'training',
      ];
  }
}

/// Battle-tested with the server-side `mobile_attendance_summary` role gate:
/// super_admin, admin, head_of_human_resources, hr_officer, branch_manager.
bool canManageAttendance(String role) => const [
  AppRoles.superAdmin,
  AppRoles.admin,
  AppRoles.headOfHumanResources,
  AppRoles.hrOfficer,
  AppRoles.branchManager,
].contains(role);

/// Employee Tracking — Super Admin, Head of HR and the executive family
/// (MD/CEO, Chairman, Director) on mobile.
///
/// The mobile audience is a fixed ROLE LIST rather than the web's
/// `trackingGate`, which consults the server's `employee_tracking_access()`
/// and therefore also admits a time-boxed grantee. Mobile opts out of that
/// delegation deliberately: precise staff location is the most sensitive data
/// the bank holds, and a phone is a device that is far easier to lose, lend or
/// share than a managed desktop.
///
/// The consequence is intentional and worth stating: a tracking grant issued on
/// web does NOT open this screen on mobile. If a delegated viewer needs mobile
/// access, that is a decision to make explicitly, not a side effect of the two
/// platforms disagreeing.
///
/// The five roles here are exactly the baseline roles added to
/// `employee_tracking_access()` in
/// `supabase/migrations/20261102000001_geofence_management_rbac.sql`, so the
/// server now admits precisely the same baseline audience this gate admits.
/// `hr_manager` is carried too for the same rename-tolerance reason as
/// [canManageGeofences]: it is the legacy spelling of the Head of HR role.
///
/// This is a NAVIGATION gate. The real boundary is still the server: every
/// tracking RPC checks `employee_tracking_access()` and refuses regardless of what
/// the client believes.
bool canAccessEmployeeTracking(String role) => const [
  AppRoles.superAdmin,
  AppRoles.headOfHumanResources,
  AppRoles.hrManager,
  AppRoles.mdCeo,
  AppRoles.chairman,
  AppRoles.director,
].contains(role);

/// Geofence Settings / Management — Super Admin and Head of HR.
///
/// Mirrors `public.is_geofence_admin()` in
/// `supabase/migrations/20261102000001_geofence_management_rbac.sql`, which is
/// the real authority behind every geofence RPC (it raises SQLSTATE 42501 for
/// anyone else). `hr_manager` is accepted alongside
/// `head_of_human_resources` for the same rename-tolerance reason as
/// [canAccessCommAdmin]: the legacy `hr_manager` spelling still exists in
/// `profiles.role` and in the database helper.
///
/// This is a NAVIGATION gate only. Editing a fence through a deep link still
/// hits `save_branch_geofence` / `delete_branch_geofence`, which call
/// `require_geofence_admin()` and refuse.
bool canManageGeofences(String role) => const [
  AppRoles.superAdmin,
  AppRoles.headOfHumanResources,
  AppRoles.hrManager,
].contains(role);

/// Communication Administration access.
///
/// Mirrors the web `CommunicationAdmin` page gate (`ADMIN_ROLES`) and the
/// database helper `public.is_communication_admin()`, which is the real
/// authority behind every Comm Admin RPC/RLS policy. The web list uses
/// `head_of_human_resources`; the database helper uses `hr_manager`; both are
/// accepted so a rename on either side does not silently strand a user.
///
/// This is a *navigation/UI* gate only. An unauthorized user who deep-links to
/// `/comm-admin` is redirected away, and even bypassing the client still hits
/// RLS/SECURITY DEFINER RPCs that refuse the read.
bool canAccessCommAdmin(String role) => const [
  AppRoles.superAdmin,
  AppRoles.admin,
  AppRoles.hrManager,
  AppRoles.headOfHumanResources,
  AppRoles.hrOfficer,
].contains(role);

/// Announcement authoring — mirrors `public.can_author_announcement()`.
///
/// Deliberately broader than [canAccessCommAdmin]: branch/area managers and
/// heads of business may publish to their own audience even though they cannot
/// open the administration centre.
bool canAuthorAnnouncement(String role) => const [
  AppRoles.superAdmin,
  AppRoles.admin,
  AppRoles.hrManager,
  AppRoles.headOfHumanResources,
  AppRoles.hrOfficer,
  AppRoles.branchManager,
  AppRoles.areaManager,
  AppRoles.operationsManager,
  AppRoles.headOfBusiness,
].contains(role);
