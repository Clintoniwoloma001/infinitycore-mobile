import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'profile_service.dart';

/// One editable field in the personal-details form.
class _Field {
  const _Field(this.key, this.label, {this.hint, this.type = _FieldType.text});

  final String key;
  final String label;
  final String? hint;
  final _FieldType type;
}

enum _FieldType { text, date, email, phone, dropdown, multiline }

/// Form groups mirroring the web `OnboardingForm.jsx` sections, so an employee
/// who filled the web onboarding form recognises the same layout here.
const _sections = <(String, List<_Field>)>[
  (
    'Contact',
    [
      _Field('full_name', 'Full name'),
      _Field('email', 'Email', type: _FieldType.email),
      _Field('phone', 'Phone', type: _FieldType.phone),
      _Field(
        'residential_address',
        'Residential address',
        type: _FieldType.multiline,
      ),
    ],
  ),
  (
    'Origin & location',
    [
      _Field('state_of_origin', 'State of origin'),
      _Field('lga', 'LGA'),
      _Field('town', 'Town / City'),
    ],
  ),
  (
    'Personal',
    [
      _Field('date_of_birth', 'Date of birth', type: _FieldType.date),
      _Field(
        'sex',
        'Sex',
        type: _FieldType.dropdown,
        hint: 'Select',
      ),
      _Field('nationality', 'Nationality'),
      _Field('religion', 'Religion'),
      _Field('denomination', 'Denomination'),
      _Field(
        'marital_status',
        'Marital status',
        type: _FieldType.dropdown,
        hint: 'Select',
      ),
    ],
  ),
  (
    'Spouse',
    [
      _Field('spouse_name', 'Spouse name'),
      _Field('spouse_occupation', 'Spouse occupation'),
      _Field('spouse_phone', 'Spouse phone', type: _FieldType.phone),
      _Field('spouse_email', 'Spouse email', type: _FieldType.email),
    ],
  ),
  (
    'Emergency contact',
    [
      _Field('emergency_contact_name', 'Contact name'),
      _Field(
        'emergency_contact_phone',
        'Contact phone',
        type: _FieldType.phone,
      ),
    ],
  ),
];

/// Editor for the self-service personal fields.
///
/// Saves through `update_profile_personal`, the same SECURITY DEFINER RPC the
/// web profile uses, so a change made here is immediately visible in the web
/// app and in any report that reads the `employees` row.
class PersonalDetailsSheet extends StatefulWidget {
  const PersonalDetailsSheet({super.key, required this.profile});

  final PersonalProfile profile;

  @override
  State<PersonalDetailsSheet> createState() => _PersonalDetailsSheetState();
}

class _PersonalDetailsSheetState extends State<PersonalDetailsSheet> {
  late final Map<String, dynamic> _draft = widget.profile.toDraft();
  bool _saving = false;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await ProfileService.instance.savePersonal(widget.profile, _draft);
      if (!mounted) return;
      navigator.pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(
        SnackBar(content: Text('$e'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Personal details',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                // A non-flex child in a Row that contains an `Expanded` is laid
                // out with an *infinite* main-axis constraint, which
                // `FilledButton.icon` cannot size itself against — it throws
                // "BoxConstraints forces an infinite width". Bounding it
                // explicitly is the fix.
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.accent(context),
                    ),
                    icon: _saving
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.save_outlined, size: 18),
                    label: const Text('Save'),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Text(
              'These details are shared with HR and appear on the web platform. '
              'Employment fields such as department, branch and salary are '
              'managed by HR and cannot be changed here.',
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: AppColors.textSecondary(context),
              ),
            ),
          ),
          Flexible(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              children: [
                for (final (title, fields) in _sections) ...[
                  _SectionLabel(title: title),
                  for (final f in fields) _buildField(f),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
  Widget _buildField(_Field f) {
    final value = '${_draft[f.key] ?? ''}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            f.label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.textSecondary(context),
            ),
          ),
          const SizedBox(height: 5),
          switch (f.type) {
            _FieldType.multiline => TextFormField(
              initialValue: value,
              maxLines: 3,
              minLines: 2,
              onChanged: (v) => _draft[f.key] = v,
              decoration: _decoration(f),
            ),
            _FieldType.dropdown => _DropdownField(
              value: value,
              hint: f.hint ?? 'Select',
              options: f.key == 'sex'
                  ? const ['Male', 'Female', 'Other']
                  : const ['Single', 'Married', 'Divorced', 'Widowed'],
              onChanged: (v) => setState(() => _draft[f.key] = v),
            ),
            _FieldType.date => _DateField(
              value: value,
              onChanged: (v) => setState(() => _draft[f.key] = v),
            ),
            _ => TextFormField(
              initialValue: value,
              keyboardType: switch (f.type) {
                _FieldType.email => TextInputType.emailAddress,
                _FieldType.phone => TextInputType.phone,
                _ => TextInputType.text,
              },
              textCapitalization: f.key.endsWith('email')
                  ? TextCapitalization.none
                  : TextCapitalization.words,
              onChanged: (v) => _draft[f.key] = v,
              decoration: _decoration(f),
            ),
          },
        ],
      ),
    );
  }
  /// Shared input chrome for the text fields.
  InputDecoration _decoration(_Field f) => InputDecoration(
    isDense: true,
    hintText: f.hint,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: AppColors.border(context)),
    ),
  );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 10),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.9,
          color: AppColors.accent(context),
        ),
      ),
    );
  }
}

/// Compact dropdown that keeps the free-text value if the server already holds
/// something outside the preset list (e.g. a legacy "Separated" marital status).
class _DropdownField extends StatelessWidget {
  const _DropdownField({
    required this.value,
    required this.hint,
    required this.options,
    required this.onChanged,
  });

  final String value;
  final String hint;
  final List<String> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final items = <String>{
      if (value.isNotEmpty) value,
      ...options,
    }.toList();
    return DropdownButtonFormField<String>(
      initialValue: value.isEmpty ? null : value,
      isExpanded: true,
      items: [
        for (final o in items)
          DropdownMenuItem(
            value: o,
            child: Text(o.isEmpty ? hint : o, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: AppColors.border(context)),
        ),
      ),
    );
  }
}

/// Date-of-birth picker.
///
/// Sends an ISO `yyyy-MM-dd` string, which is exactly what the server's
/// `coalesce(nullif(p_fields ->> 'date_of_birth','')::date, …)` expects.
class _DateField extends StatelessWidget {
  const _DateField({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final parsed = DateTime.tryParse(value);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: parsed ?? DateTime(1990),
          // Nobody is born in the future; the web form enforces the same bound.
          firstDate: DateTime(1920),
          lastDate: DateTime.now(),
        );
        if (picked != null) {
          onChanged(
            '${picked.year.toString().padLeft(4, '0')}-'
            '${picked.month.toString().padLeft(2, '0')}-'
            '${picked.day.toString().padLeft(2, '0')}',
          );
        }
      },
      child: InputDecorator(
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 12,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: AppColors.border(context)),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                parsed == null ? 'Select a date' : value,
                style: TextStyle(
                  fontSize: 14,
                  color: parsed == null
                      ? AppColors.textTertiary(context)
                      : AppColors.textPrimary(context),
                ),
              ),
            ),
            Icon(
              Icons.calendar_today_outlined,
              size: 16,
              color: AppColors.iconMuted(context),
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens the editor. Resolves to `true` when a change was saved, so the caller
/// can refresh the profile it is showing.
Future<bool?> showPersonalDetailsSheet(
  BuildContext context, {
  required PersonalProfile profile,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => FractionallySizedBox(
      // `widthFactor` must be set explicitly. Without it the box only constrains
      // height, leaving width unbounded — the header Row and the ListView then
      // receive infinite-width constraints and fail to lay out.
      widthFactor: 1,
      heightFactor: 0.92,
      child: PersonalDetailsSheet(profile: profile),
    ),
  );
}
