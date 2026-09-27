import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../shared/utils/formatters.dart';
import 'profile_service.dart';

/// The staff ID card, mirroring the web `StaffIdCard.jsx` field for field.
///
/// The web card falls back through `employee_number → staff_id →
/// employee_code`; [PersonalProfile.staffNumber] does the same, so a card
/// opened on the phone and one opened in a browser show the same identifier.
class StaffIdCardSheet extends StatelessWidget {
  const StaffIdCardSheet({super.key, required this.profile, this.photoUrl});

  final PersonalProfile profile;
  final String? photoUrl;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Staff ID Card',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Text(
                  Fmt.titleCase(profile.staffIdStatus),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                    color: profile.staffIdStatus.toLowerCase() == 'active'
                        ? AppColors.accent(context)
                        : AppColors.warn(context),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _card(context),
            const SizedBox(height: 18),
            _IssueRow(
              label: 'Issued',
              value: profile.staffIdIssuedAt.isEmpty
                  ? 'Not recorded'
                  : Fmt.dateShort(profile.staffIdIssuedAt),
            ),
            _IssueRow(
              label: 'Expires',
              value: profile.staffIdExpiry.isEmpty
                  ? 'No expiry'
                  : Fmt.dateShort(profile.staffIdExpiry),
            ),
            _IssueRow(label: 'Issued by', value: profile.staffIdIssuedBy),
          ],
        ),
      ),
    );
  }

  Widget _card(BuildContext context) {
    final dark = AppColors.isDark(context);
    final name = profile.fullName.isEmpty ? 'Staff member' : profile.fullName;
    final emergency = '${profile.row['emergency_contact_phone'] ?? ''}'.trim();
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          // The card is a branded artefact, so it keeps the green→orange
          // InfinityCore pairing in both themes instead of inverting with the
          // system brightness.
          colors: dark
              ? const [Color(0xFF0B2E1F), Color(0xFF1A1207)]
              : const [
                  AppColors.greenDark,
                  Color(0xFF0A5C33),
                  Color(0xFF7A3B00),
                ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.4 : 0.16),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'INFINITYCORE',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.6,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.orange,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Text(
                  'STAFF',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CardPhoto(url: photoUrl, name: name),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      profile.position.isEmpty
                          ? 'Staff'
                          : Fmt.titleCase(profile.position),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      profile.department.isEmpty
                          ? '—'
                          : Fmt.titleCase(profile.department),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(height: 1, color: Colors.white24),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _CardField(
                  label: 'Staff number',
                  value: profile.staffNumber.isEmpty
                      ? 'Not assigned'
                      : profile.staffNumber,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _CardField(
                  label: 'Branch',
                  value: profile.branch.isEmpty
                      ? 'Head Office'
                      : Fmt.titleCase(profile.branch),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _CardField(
            label: 'Emergency contact',
            value: emergency.isEmpty ? '—' : emergency,
          ),
        ],
      ),
    );
  }
}

class _CardPhoto extends StatelessWidget {
  const _CardPhoto({required this.url, required this.name});

  final String? url;
  final String name;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 76,
        height: 92,
        child: url == null || url!.isEmpty
            ? Container(
                color: Colors.white12,
                child: Center(
                  child: Text(
                    name.isEmpty ? '—' : name.characters.first.toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              )
            : Image.network(
                url!,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(
                  color: Colors.white12,
                  child: const Icon(
                    Icons.person,
                    color: Colors.white54,
                    size: 34,
                  ),
                ),
                loadingBuilder: (context, child, progress) => progress == null
                    ? child
                    : Container(
                        color: Colors.white12,
                        child: const Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white54,
                            ),
                          ),
                        ),
                      ),
              ),
      ),
    );
  }
}

class _CardField extends StatelessWidget {
  const _CardField({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 8,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _IssueRow extends StatelessWidget {
  const _IssueRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textSecondary(context),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows the card as a modal sheet.
Future<void> showStaffIdCard(
  BuildContext context, {
  required PersonalProfile profile,
  String? photoUrl,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => StaffIdCardSheet(profile: profile, photoUrl: photoUrl),
  );
}
