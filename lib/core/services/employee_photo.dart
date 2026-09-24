import 'supabase_service.dart';

/// Employee profile-photo lookup.
///
/// Photos live in the `documents` storage bucket registered under
/// `document_type = 'profile_picture'`. The URL is a short-lived signed URL so
/// the image streams through Supabase without exposing the storage API key.
class EmployeePhoto {
  EmployeePhoto._();

  /// Returns a short-lived signed URL for the employee's most recent profile
  /// picture, or `null` when none exists (or the lookup fails).
  static Future<String?> signedUrlFor(String employeeId) async {
    if (employeeId.isEmpty) return null;
    try {
      final rows = await SupabaseService.client
          .from('documents')
          .select('file_path')
          .eq('entity_type', 'employee')
          .eq('entity_id', employeeId)
          .eq('document_type', 'profile_picture')
          .order('uploaded_at', ascending: false)
          .limit(1);
      final list = rows as List<dynamic>? ?? const [];
      if (list.isEmpty) return null;
      final path = (list.first is Map ? list.first['file_path'] : null)
          .toString()
          .trim();
      if (path.isEmpty) return null;
      return await SupabaseService.client.storage
          .from('documents')
          .createSignedUrl(path, 3600);
    } catch (_) {
      return null;
    }
  }
}
