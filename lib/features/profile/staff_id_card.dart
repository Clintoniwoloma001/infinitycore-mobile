import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/infinity_logo.dart';
import '../../shared/utils/formatters.dart';
import 'profile_service.dart';

/// The staff ID card, a 1:1 port of the web `StaffIdCard.jsx`.
///
/// This is a *branded artefact*, not a themed widget: the web renders it as a
/// white `.idcard` in every mode, so the Flutter version does the same and is
/// wrapped in [LightPanel]. Inheriting the ambient dark theme here would put
/// white ink on a white card — the "card looks fine in the screenshot but you
/// cannot read it" failure.
///
/// Layout, in order, matching the web component:
///   header (logo + "Staff ID Card / Identity & Access")
///   orange divider
///   profile block (photo + name + position)
///   2-column meta grid (Staff ID, Department, Branch, Status, Issue Date)
///   orange divider
///   Human Resources block
///   footer disclaimer
/// and then the reverse side with the emergency contact and signature areas.
class StaffIdCardSheet extends StatelessWidget {
  const StaffIdCardSheet({super.key, required this.profile, this.photoUrl});

  final PersonalProfile profile;
  final String? photoUrl;

  @override
  Widget build(BuildContext context) {
    final status = profile.staffIdStatus.trim().isEmpty
        ? 'active'
        : profile.staffIdStatus.trim().toLowerCase();
    final isExpired = status == 'expired';

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Explicit close control. The sheet is dismissible by swipe and by
            // the system back button, but neither is discoverable while looking
            // at a card, so the affordance is shown rather than assumed.
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back),
                tooltip: 'Close',
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  foregroundColor: AppColors.textPrimary(context),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Staff ID Card',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                ),
                Text(
                  Fmt.titleCase(status),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                    color: isExpired
                        ? AppColors.rose
                        : AppColors.accent(context),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // The card is a fixed light artefact, so front and back are both
            // pinned to the light theme via LightPanel.
            LightPanel(
              padding: EdgeInsets.zero,
              color: const Color(0xFFFFFFFF),
              radius: 14,
              border: const Color(0xFFE2E8F0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _frontCard(context, isExpired: isExpired),
                  const SizedBox(height: 24),
                  _backCard(context),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Field sources. These mirror the JSX fallbacks exactly.
  // ---------------------------------------------------------------------
  String get _name => profile.fullName.isEmpty ? '—' : profile.fullName;
  String get _number => profile.hasStaffNumber ? profile.staffNumber : '—';
  String get _position => profile.position.isEmpty ? 'Staff' : profile.position;
  String get _department =>
      profile.department.isEmpty ? '—' : profile.department;
  String get _branch => profile.branch.isEmpty ? 'Head Office' : profile.branch;

  /// Web: `employee?.emergency_contact_phone || '—'`
  String get _emergency {
    final v = '${profile.row['emergency_contact_phone'] ?? ''}'.trim();
    return v.isEmpty ? '—' : v;
  }

  /// Web renders dates as `dd/MM/yyyy` (`toLocaleDateString('en-GB')`).
  String get _issueDate => Fmt.dateShort(profile.staffIdIssuedAt);

  String? get _expiryLabel => profile.staffIdExpiry.isEmpty
      ? null
      : Fmt.dateShort(profile.staffIdExpiry);

  // ---------------------------------------------------------------------
  // FRONT
  // ---------------------------------------------------------------------
  Widget _frontCard(BuildContext context, {required bool isExpired}) {
    final status = profile.staffIdStatus.trim().isEmpty
        ? 'active'
        : profile.staffIdStatus.trim().toLowerCase();
    final statusLabel = isExpired ? 'EXPIRED' : status;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Green brand banner.
        Container(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF009944), Color(0xFF007A36)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const InfinityCoreLogo(size: 26, light: true),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Text(
                    'Staff ID Card',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 2,
                    ),
                  ),
                  Text(
                    'Identity & Access',
                    style: TextStyle(color: Color(0xFFD1FAE5), fontSize: 10),
                  ),
                ],
              ),
            ],
          ),
        ),
        const _OrangeDivider(height: 3),
        // Profile block: portrait + name/position.
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _portrait(),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text(
                        'FULL NAME',
                        style: TextStyle(
                          color: Color(0xFF94A3B8),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _name,
                      style: const TextStyle(
                        color: Color(0xFF0F172A),
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _position,
                      style: const TextStyle(
                        color: Color(0xFF64748B),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // 2-column meta grid.
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _MetaCell(
                      label: 'Staff ID',
                      value: _number,
                      valueColor: const Color(0xFF009944),
                      bold: true,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _MetaCell(label: 'Department', value: _department),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _MetaCell(label: 'Branch', value: _branch),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _MetaCell(
                      label: 'Status',
                      value: statusLabel.toUpperCase(),
                      valueColor: isExpired
                          ? const Color(0xFFE11D48)
                          : const Color(0xFF059669),
                      bold: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _MetaCell(label: 'Issue Date', value: _issueDate),
                  ),
                  const SizedBox(width: 16),
                  if (_expiryLabel != null)
                    Expanded(
                      child: _MetaCell(
                        label: 'Expiry Date',
                        value: _expiryLabel!,
                      ),
                    )
                  else
                    const Expanded(child: SizedBox.shrink()),
                ],
              ),
            ],
          ),
        ),
        const _OrangeDivider(
          height: 2,
          horizontalMargin: 20,
          verticalMargin: 12,
        ),
        // Human Resources block.
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'HUMAN RESOURCES',
                style: TextStyle(
                  color: Color(0xFF1E293B),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                ),
              ),
              SizedBox(height: 4),
              Text(
                'Infinity Microfinance Bank',
                style: TextStyle(color: Color(0xFF64748B), fontSize: 10),
              ),
            ],
          ),
        ),
        // Footer disclaimer.
        Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: Color(0xFFF1F5F9))),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'This card remains the property of Infinity Microfinance Bank. '
                'If found, please return to the nearest branch or HR office.',
                style: TextStyle(
                  color: Color(0xFF4B5563),
                  fontSize: 9,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'This card is issued by Human Resources of Infinity '
                'Microfinance Bank and is valid for identification purposes only.'
                '${_expiryLabel != null ? ' Expires $_expiryLabel.' : ''}',
                style: const TextStyle(
                  color: Color(0xFF374151),
                  fontSize: 9,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // BACK
  // ---------------------------------------------------------------------
  Widget _backCard(BuildContext context) {
    final expiry = _expiryLabel;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _OrangeDivider(height: 3),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Text(
                    'HUMAN RESOURCES',
                    style: TextStyle(
                      color: Color(0xFF1E293B),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                    ),
                  ),
                  Text(
                    _number,
                    style: const TextStyle(
                      color: Color(0xFF0F172A),
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _BackRow(label: 'Employee', value: _name),
              _BackRow(label: 'Emergency Contact', value: _emergency),
              _BackRow(label: 'Branch', value: _branch),
              _BackRow(label: 'Issued By', value: profile.staffIdIssuedBy),
              _BackRow(label: 'Issue Date', value: _issueDate),
              if (expiry != null) _BackRow(label: 'Expiry', value: expiry),
              const SizedBox(height: 16),
              Container(height: 1, color: const Color(0xFFF1F5F9)),
              const SizedBox(height: 12),
              const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _SignatureArea(
                      label: 'MANAGEMENT SIGNATURE',
                      caption: 'Management / HR',
                    ),
                  ),
                  SizedBox(width: 16),
                  Expanded(
                    child: _SignatureArea(
                      label: 'CARD HOLDER SIGNATURE',
                      caption: 'Employee Signature',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(height: 1, color: const Color(0xFFF1F5F9)),
              const SizedBox(height: 12),
              const Text(
                'This card remains the property of Infinity Microfinance Bank . '
                'If found, please return to the nearest branch or HR office.',
                style: TextStyle(
                  color: Color(0xFF4B5563),
                  fontSize: 9,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'This card is issued by Human Resources of Infinity '
                'Microfinance Bank and is valid for identification purposes only.'
                '${expiry != null ? ' Expires $expiry.' : ' This card has no expiry.'}',
                style: const TextStyle(
                  color: Color(0xFF374151),
                  fontSize: 9,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// The 72x88 web photo frame, with the web gradient + initials fallback.
  Widget _portrait() {
    Widget initials() => Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFFF1F5F9), Color(0xFFECFDF5)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Text(
          Fmt.initials(_name),
          style: const TextStyle(
            color: Color(0xFF009944),
            fontSize: 24,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );

    return Container(
      width: 72,
      height: 88,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: photoUrl == null || photoUrl!.isEmpty
          ? initials()
          : Image.network(
              photoUrl!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => initials(),
            ),
    );
  }
}

/// The orange brand rule: `from-[#ff9d00] via-[#FF8C00] to-[#ffb84d]`.
class _OrangeDivider extends StatelessWidget {
  const _OrangeDivider({
    this.height = 3,
    this.horizontalMargin = 0,
    this.verticalMargin = 0,
  });

  final double height;
  final double horizontalMargin;
  final double verticalMargin;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.symmetric(
        horizontal: horizontalMargin,
        vertical: verticalMargin,
      ),
      height: height,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFFFF9D00), Color(0xFFFF8C00), Color(0xFFFFB84D)],
        ),
      ),
    );
  }
}

/// One cell of the front card's 2-column meta grid.
class _MetaCell extends StatelessWidget {
  const _MetaCell({
    required this.label,
    required this.value,
    this.valueColor = const Color(0xFF1E293B),
    this.bold = false,
  });

  final String label;
  final String value;
  final Color valueColor;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFF94A3B8),
            fontSize: 10,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            color: valueColor,
            fontSize: 12,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
            height: 1.3,
          ),
        ),
      ],
    );
  }
}

/// A `justify-between` label/value line from the back of the card.
class _BackRow extends StatelessWidget {
  const _BackRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 14),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: Color(0xFF1E293B),
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Blank signature line. The web card takes signature images as props; the
/// mobile card has no stored signatures yet, so the ruled line is rendered and
/// left empty rather than faking a signature.
class _SignatureArea extends StatelessWidget {
  const _SignatureArea({required this.label, required this.caption});

  final String label;
  final String caption;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFF94A3B8),
            fontSize: 8,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 4),
        Container(height: 32),
        Container(height: 1, color: const Color(0xFF94A3B8)),
        const SizedBox(height: 4),
        Text(
          caption,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFF64748B), fontSize: 8),
        ),
      ],
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
