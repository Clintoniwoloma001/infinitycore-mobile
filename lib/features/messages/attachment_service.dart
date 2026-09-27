import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions;
import 'package:uuid/uuid.dart';

import '../../core/services/supabase_service.dart';

/// Lifecycle of a single attachment while it sits in the composer.
///
/// The composer renders one row per attachment and drives its visual state
/// straight from this enum, so a failed upload is never silently dropped — the
/// user can retry or remove it explicitly.
enum AttachmentStage { queued, uploading, uploaded, failed }

/// A file the user attached, together with its upload progress and the exact
/// metadata the `send_rich_message` RPC expects.
///
/// This mirrors the web `uploadChatAttachment` helper in
/// `infinitycore-sara/src/services/corporateChatService.js` byte for byte: the
/// same `documents` bucket, the same
/// `chat/<type>/<context>/<user>/<uuid>-<name>` object key, and the same
/// SHA-256 checksum column. Keeping both clients byte-compatible means a file
/// sent from the phone opens unmodified on the web platform and vice versa.
class PendingAttachment {
  PendingAttachment({
    required this.path,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    this.durationMs,
  }) : localId = const Uuid().v4();

  /// Client-side identity so list rebuilds stay stable.
  final String localId;

  /// Absolute path on the device. Never leaves the device directly — it is
  /// uploaded to the private `documents` bucket first.
  final String path;

  final String fileName;
  final String mimeType;
  final int sizeBytes;

  /// Voice notes only: length in milliseconds, used to render the waveform and
  /// the "0:07" label without decoding the audio container.
  final int? durationMs;

  AttachmentStage stage = AttachmentStage.queued;

  /// 0..1 while [stage] is [AttachmentStage.uploading]; `-1` means the upload
  /// is running but the bucket did not report a byte count.
  double progress = 0;

  String? error;

  /// Storage object path, set once [stage] is [AttachmentStage.uploaded].
  String? uploadedPath;

  String? checksum;

  bool get isVoiceNote => attachmentTypeFor(fileName, mimeType) == 'voice_note';

  bool get isImage => attachmentTypeFor(fileName, mimeType) == 'image';

  bool get isPending =>
      stage == AttachmentStage.queued || stage == AttachmentStage.uploading;

  /// The row shape `send_rich_message(p_files => …)` expects.
  Map<String, dynamic> toRpcFile() => {
    'file_name': fileName,
    'file_type': mimeType,
    'attachment_type': attachmentTypeFor(fileName, mimeType),
    'file_size': sizeBytes,
    'file_path': uploadedPath,
    'checksum': checksum,
  };
}

/// Mirrors `attachmentTypeFor` on the web so both clients bucket a given file
/// into the same `attachment_type` enum value.
///
/// Voice notes win over the mime sniff: the recorder writes
/// `voice-note-<timestamp>.m4a`, and an m4a sniffed as `audio/mp4` would lose
/// the dedicated voice-note player.
String attachmentTypeFor(String fileName, String mimeType) {
  final name = fileName.toLowerCase();
  if (name.startsWith('voice-note-')) return 'voice_note';
  final type = mimeType.toLowerCase();
  if (type.startsWith('image/')) return 'image';
  if (type.startsWith('audio/')) return 'audio';
  if (type.startsWith('video/')) return 'video';
  if (type == 'application/pdf') return 'pdf';
  if (type.contains('spreadsheet') ||
      type.contains('excel') ||
      type == 'text/csv') {
    return 'spreadsheet';
  }
  if (type.contains('presentation') || type.contains('powerpoint')) {
    return 'presentation';
  }
  if (type.contains('word') ||
      type.contains('document') ||
      type == 'text/plain') {
    return 'document';
  }
  if (type.contains('zip') || type.contains('compressed')) return 'archive';
  return 'file';
}

/// A conservative, human-friendly mime type for a picked file.
///
/// The Android picker does not always report a mime type, and the stored
/// `file_type` is what decides whether the recipient sees an inline preview, a
/// document card or a raw download link. Guessing from the extension keeps the
/// web client's `attachmentTypeFor` branching meaningful.
String mimeTypeForPath(String path) {
  const byExtension = <String, String>{
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.png': 'image/png',
    '.gif': 'image/gif',
    '.webp': 'image/webp',
    '.heic': 'image/heic',
    '.pdf': 'application/pdf',
    '.txt': 'text/plain',
    '.csv': 'text/csv',
    '.doc': 'application/msword',
    '.docx':
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    '.xls': 'application/vnd.ms-excel',
    '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    '.ppt': 'application/vnd.ms-powerpoint',
    '.pptx':
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    '.zip': 'application/zip',
    '.m4a': 'audio/mp4',
    '.mp3': 'audio/mpeg',
    '.mp4': 'video/mp4',
  };
  final lower = path.toLowerCase();
  for (final entry in byExtension.entries) {
    if (lower.endsWith(entry.key)) return entry.value;
  }
  return 'application/octet-stream';
}

const _uuid = Uuid();

/// Strips anything the storage bucket or the send RPC would choke on, and caps
/// the length so the object key stays inside PostgREST's URL budget. Mirrors
/// `SAFE_NAME_RE` on the web.
String safeAttachmentName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[^\w.\- ]'), '_');
  return cleaned.isEmpty
      ? 'file'
      : cleaned.substring(0, cleaned.length.clamp(0, 120));
}

/// Uploads attachments to the private `documents` bucket and returns the
/// metadata the send RPC needs.
///
/// Uploads land under `chat/<contextType>/<contextId>/<userId>/…`, exactly
/// where the web client writes, so the existing `chat_attachment_read` storage
/// policy applies unchanged: a signed URL is only minted for a caller who may
/// read the message that references the object.
class AttachmentUploadService {
  AttachmentUploadService._();
  static final AttachmentUploadService instance = AttachmentUploadService._();

  /// Uploads [attachment], mutating its progress in place so the composer can
  /// animate a real percentage.
  ///
  /// [onProgress] receives 0..1, or `-1` when the platform cannot report bytes
  /// for the upload. Failures are recorded on the attachment rather than
  /// thrown, because one bad file must not discard a carefully composed
  /// message.
  Future<bool> upload({
    required PendingAttachment attachment,
    required String contextType,
    String? contextId,
    void Function(double progress)? onProgress,
  }) async {
    final userId = SupabaseService.client.auth.currentUser?.id;
    if (userId == null) {
      attachment
        ..stage = AttachmentStage.failed
        ..error = 'Sign in before uploading an attachment.';
      return false;
    }

    attachment
      ..stage = AttachmentStage.uploading
      ..progress = 0
      ..error = null;

    try {
      final safeName = safeAttachmentName(attachment.fileName);
      final bucket = contextId?.isNotEmpty == true ? contextId : 'direct';
      final objectPath =
          'chat/$contextType/$bucket/$userId/${_uuid.v4()}-$safeName';

      final file = File(attachment.path);
      if (!await file.exists()) {
        attachment
          ..stage = AttachmentStage.failed
          ..error = 'That file is no longer on this device.';
        return false;
      }

      final bytes = await file.readAsBytes();
      onProgress?.call(0);

      await SupabaseService.client.storage.from('documents').uploadBinary(
        objectPath,
        bytes,
        fileOptions: const FileOptions(upsert: false),
      );

      onProgress?.call(1);
      attachment
        ..stage = AttachmentStage.uploaded
        ..progress = 1
        ..uploadedPath = objectPath
        // The web client hashes with SubtleCrypto and stores NULL when it
        // cannot; matching that keeps the column consistent across clients.
        ..checksum = _sha256Hex(bytes);
      return true;
    } catch (e) {
      debugPrint('[AttachmentUploadService] $e');
      attachment
        ..stage = AttachmentStage.failed
        ..error = 'Upload failed. Tap to retry.';
      return false;
    }
  }

  String? _sha256Hex(List<int> bytes) {
    try {
      return sha256.convert(bytes).toString();
    } catch (e) {
      debugPrint('[AttachmentUploadService] checksum failed: $e');
      return null;
    }
  }
}
