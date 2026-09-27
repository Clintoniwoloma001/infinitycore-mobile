import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/supabase_service.dart';

/// The personal fields a signed-in employee is allowed to change themselves.
///
/// This list is a 1:1 copy of the `v_allowed` allowlist inside
/// `public.update_profile_personal` (see
/// `infinitycore-sara/schema_phase12_employee_lifecycle.sql`). The server
/// silently drops anything outside the allowlist, so mirroring it here is what
/// lets the UI keep HR-controlled fields out of the editor instead of offering
/// a Save that would appear to succeed and change nothing.
const personalEditableFields = <String>[
  'full_name',
  'email',
  'phone',
  'residential_address',
  'town',
  'lga',
  'state_of_origin',
  'emergency_contact_name',
  'emergency_contact_phone',
  'date_of_birth',
  'sex',
  'religion',
  'denomination',
  'nationality',
  'marital_status',
  'spouse_name',
  'spouse_occupation',
  'spouse_phone',
  'spouse_email',
];

/// The full employee record behind the profile screen, including the personal
/// and staff-card fields that [EmployeeRef] does not model.
///
/// Every read goes through the SECURITY DEFINER `mobile_get_my_employee` RPC
/// rather than a direct `employees` select. That is not a style choice: the
/// `employees_read` RLS policy admits only HR roles, so an ordinary employee
/// cannot read their own row directly, while the RPC is granted to
/// `authenticated` and returns the whole row via `to_jsonb(v_employee)`.
class PersonalProfile {
  const PersonalProfile({required this.employeeId, required this.row});

  final String employeeId;

  /// The complete row as returned by `mobile_get_my_employee`.
  final Map<String, dynamic> row;

  String _s(String key) => '${row[key] ?? ''}'.trim();

  String get fullName => _s('full_name');
  String get email => _s('email');
  String get phone => _s('phone');
  String get department => _s('department');
  String get position => _s('position');
  String get branch => _s('branch');
  String get employmentStatus => _s('employment_status');

  /// `employee_number` is the canonical staff identifier; `staff_id` and
  /// `employee_code` are older fallbacks the web card still honours, so the
  /// card shows the first one that exists rather than insisting on a new one.
  String get staffNumber {
    for (final key in const ['employee_number', 'staff_id', 'employee_code']) {
      final v = _s(key);
      if (v.isNotEmpty) return v;
    }
    return '';
  }

  bool get hasStaffNumber => staffNumber.isNotEmpty;

  String get staffIdIssuedAt => _s('staff_id_issued_at');
  String get staffIdExpiry => _s('staff_id_expiry');
  String get staffIdStatus {
    final v = _s('staff_id_status');
    return v.isEmpty ? 'active' : v;
  }

  String get staffIdIssuedBy {
    final v = _s('staff_id_issued_by');
    return v.isEmpty ? 'Human Resources' : v;
  }

  /// How complete the onboarding-style personal details are, 0..1.
  ///
  /// A *display* metric only — it is never sent to the server and is not a
  /// gate on saving. The server decides what it will accept; this just tells
  /// the user which boxes are still empty.
  double get personalCompleteness {
    var filled = 0;
    for (final key in personalEditableFields) {
      // Name and email are always populated, so counting them would inflate the
      // percentage and hide the fields that are genuinely still blank.
      if (key == 'full_name' || key == 'email') continue;
      if (_s(key).isNotEmpty) filled++;
    }
    final total = personalEditableFields.length - 2;
    return total == 0 ? 1 : (filled / total).clamp(0.0, 1.0);
  }

  /// The editable fields as a flat map, ready to seed a form.
  Map<String, dynamic> toDraft() => {
    for (final key in personalEditableFields) key: _s(key),
  };

  /// Only the fields that actually changed.
  ///
  /// The RPC treats every supplied key as an update, so posting the whole form
  /// would rewrite untouched columns and bloat the `audit_logs` row with
  /// fields the user never edited.
  static Map<String, dynamic> diff(
    PersonalProfile before,
    Map<String, dynamic> draft,
  ) {
    final patch = <String, dynamic>{};
    for (final key in personalEditableFields) {
      if (!draft.containsKey(key)) continue;
      final next = '${draft[key] ?? ''}'.trim();
      if (next != '${before.row[key] ?? ''}'.trim()) patch[key] = next;
    }
    return patch;
  }
}

/// Why a profile write failed, in terms a normal employee can act on.
enum ProfileError { notSignedIn, noEmployeeRecord, failed }

class ProfileException implements Exception {
  const ProfileException(this.kind, this.message);

  final ProfileError kind;
  final String message;

  @override
  String toString() => message;
}

/// Typed client for the employee profile, backed by the same RPCs the web
/// `Profile.jsx` and `ProfilePhotoModal.jsx` call.
///
/// There is no mobile-only profile store: every read and write lands in the
/// shared `employees` / `profiles` / `documents` tables, which is what makes a
/// change made on the phone appear on the web (and vice versa) immediately.
class ProfileService {
  ProfileService._();
  static final ProfileService instance = ProfileService._();

  /// Matches the web `uploadProfilePicture` limit exactly, so the two clients
  /// reject the same files.
  static const maxPhotoBytes = 8 * 1024 * 1024;

  SupabaseClient get _db => SupabaseService.client;

  /// Loads the signed-in employee's full record.
  Future<PersonalProfile> load() async {
    final user = _db.auth.currentUser;
    if (user == null) {
      throw const ProfileException(
        ProfileError.notSignedIn,
        'Sign in before opening your profile.',
      );
    }
    try {
      final row = await _db.rpc<Map<String, dynamic>>('mobile_get_my_employee');
      final id = '${row['id'] ?? ''}'.trim();
      if (id.isEmpty) {
        throw const ProfileException(
          ProfileError.noEmployeeRecord,
          'No employee record is linked to this account yet.',
        );
      }
      return PersonalProfile(employeeId: id, row: row);
    } on ProfileException {
      rethrow;
    } catch (e) {
      debugPrint('[ProfileService] load failed: $e');
      throw const ProfileException(
        ProfileError.failed,
        'Your profile could not be loaded. Pull to refresh and try again.',
      );
    }
  }

  /// Writes the changed personal fields through `update_profile_personal`.
  ///
  /// The RPC is SECURITY DEFINER and scopes the write to `auth.uid()`, so this
  /// cannot touch another employee, and it writes an `audit_logs` row naming
  /// exactly which fields changed.
  Future<void> savePersonal(
    PersonalProfile before,
    Map<String, dynamic> draft,
  ) async {
    final patch = PersonalProfile.diff(before, draft);
    if (patch.isEmpty) return;
    try {
      await _db.rpc('update_profile_personal', params: {'p_fields': patch});
    } catch (e) {
      debugPrint('[ProfileService] savePersonal failed: $e');
      throw const ProfileException(
        ProfileError.failed,
        'Your details could not be saved. Check your connection and try again.',
      );
    }
  }

  /// Assigns the employee number when the record does not have one yet.
  ///
  /// Idempotent on the server, so calling it whenever the card is opened is
  /// safe — it returns the existing number when there already is one.
  Future<String> ensureEmployeeNumber(String employeeId) async {
    if (employeeId.isEmpty) {
      throw const ProfileException(
        ProfileError.noEmployeeRecord,
        'No employee record is linked to this account yet.',
      );
    }
    try {
      final data = await _db.rpc<Map<String, dynamic>>(
        'generate_employee_number',
        params: {'p_employee_id': employeeId},
      );
      final number = '${data['employee_number'] ?? ''}'.trim();
      if (number.isEmpty) {
        throw const ProfileException(
          ProfileError.failed,
          'A staff number could not be assigned yet. Please contact HR.',
        );
      }
      return number;
    } on ProfileException {
      rethrow;
    } catch (e) {
      debugPrint('[ProfileService] ensureEmployeeNumber failed: $e');
      throw const ProfileException(
        ProfileError.failed,
        'Staff ID assignment is not available on this server yet.',
      );
    }
  }

  /// Uploads a new profile picture and returns a signed URL to it.
  ///
  /// Object path and `documents` row are identical to the web
  /// `documentService.uploadProfilePicture`, so the newest photo resolves the
  /// same way on both platforms (latest `uploaded_at` wins).
  Future<String> uploadProfilePhoto({
    required String employeeId,
    required File file,
  }) async {
    if (employeeId.isEmpty) {
      throw const ProfileException(
        ProfileError.noEmployeeRecord,
        'No employee record is linked to this account yet.',
      );
    }
    final bytes = await file.length();
    if (bytes > maxPhotoBytes) {
      throw ProfileException(
        ProfileError.failed,
        'That photo is larger than 8 MB. Choose a smaller one.',
      );
    }
    final ext = _extensionOf(file.path);
    final objectPath =
        'profile-photo/$employeeId/'
        '${DateTime.now().millisecondsSinceEpoch}-photo.$ext';

    try {
      await _db.storage.from('documents').uploadBinary(
        objectPath,
        await file.readAsBytes(),
        fileOptions: const FileOptions(upsert: false),
      );
      await _db.from('documents').insert({
        'entity_type': 'employee',
        'entity_id': employeeId,
        'document_type': 'profile_picture',
        'file_name': 'profile-photo.$ext',
        'file_path': objectPath,
        'file_size': bytes,
      });
    } catch (e) {
      debugPrint('[ProfileService] uploadProfilePhoto failed: $e');
      throw const ProfileException(
        ProfileError.failed,
        'The photo could not be uploaded. Please try again.',
      );
    }

    final url = await signedUrl(objectPath);
    if (url == null) {
      throw const ProfileException(
        ProfileError.failed,
        'The photo was uploaded but could not be loaded. Pull to refresh.',
      );
    }
    return url;
  }

  /// Removes the caller's profile picture.
  ///
  /// The storage object is deleted first and the metadata row second, so a
  /// storage failure leaves the record intact and retryable instead of
  /// pointing at an object that no longer exists.
  Future<void> removeProfilePhoto(String employeeId) async {
    if (employeeId.isEmpty) return;
    try {
      final rows = await _db
          .from('documents')
          .select('id, file_path')
          .eq('entity_type', 'employee')
          .eq('entity_id', employeeId)
          .eq('document_type', 'profile_picture')
          .order('uploaded_at', ascending: false);
      for (final row in (rows as List<dynamic>? ?? const [])) {
        if (row is! Map) continue;
        final path = '${row['file_path'] ?? ''}'.trim();
        if (path.isNotEmpty) {
          try {
            await _db.storage.from('documents').remove([path]);
          } catch (e) {
            debugPrint('[ProfileService] storage remove failed: $e');
          }
        }
        await _db.from('documents').delete().eq('id', row['id']);
      }
    } catch (e) {
      debugPrint('[ProfileService] removeProfilePhoto failed: $e');
      throw const ProfileException(
        ProfileError.failed,
        'The photo could not be removed. Please try again.',
      );
    }
  }

  /// Signed URL for a storage object in the private `documents` bucket.
  Future<String?> signedUrl(String path) async {
    if (path.isEmpty) return null;
    try {
      return await _db.storage.from('documents').createSignedUrl(path, 3600);
    } catch (_) {
      return null;
    }
  }

  String _extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return 'jpg';
    final ext = path.substring(dot + 1).toLowerCase();
    // Constrain to something a photo viewer will actually render.
    const allowed = {'jpg', 'jpeg', 'png', 'webp'};
    return allowed.contains(ext) ? ext : 'jpg';
  }
}
