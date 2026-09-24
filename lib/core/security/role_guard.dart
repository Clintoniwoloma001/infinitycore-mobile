import '../../shared/models/models.dart';

/// Role metadata mirrors `src/constants/roles.js` in infinitycore-sara.
///
/// Client role checks are a UI convenience only — the backend (RLS + roles in
/// the `profiles` row) remains the authoritative security boundary.

class AppRoles {
  static const superAdmin = 'super_admin';
  static const admin = 'admin';
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

  static const hierarchy = <String, int>{
    superAdmin: 100,
    admin: 90,
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
      default:
        return role.isEmpty ? 'Staff' : role;
    }
  }
}

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
