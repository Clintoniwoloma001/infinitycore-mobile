import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/auth_service.dart';
import '../../core/services/supabase_service.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/utils/formatters.dart';
import '../../shared/widgets/common.dart';
import '../dashboard/home_shell.dart';
import 'signature_pad.dart';
import 'training_service.dart';

const _trainingTypes = <String, String>{
  'internal': 'Internal training',
  'external': 'External training',
  'compliance': 'Compliance',
  'induction': 'Induction',
  'refresher': 'Refresher',
  'workshop': 'Workshop',
  'seminar': 'Seminar',
  'technical': 'Technical training',
  'management': 'Management training',
  'kss': 'Knowledge Sharing Session (KSS)',
};

String _typeLabel(String v) => _trainingTypes[v] ?? v.replaceAll('_', ' ');

class TrainingScreen extends StatefulWidget {
  const TrainingScreen({super.key});

  @override
  State<TrainingScreen> createState() => _TrainingScreenState();
}

class _TrainingScreenState extends State<TrainingScreen> {
  int _tab = 0;
  bool _canManage = false;

  List<Map<String, dynamic>> _assignments = [];
  List<Map<String, dynamic>> _sessions = [];
  List<Map<String, dynamic>> _venues = [];
  List<Map<String, dynamic>> _employees = [];
  Map<String, dynamic> _options = const {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _canManage = AuthService.instance.access.any([
      'hr.training.manage',
      'admin.manage_users',
      'hr.onboarding.manage',
    ]);
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final results = await Future.wait([
        TrainingService.instance.myAssignments(),
        TrainingService.instance.listSessions(),
        TrainingService.instance.listVenues().catchError(
          (_) => <Map<String, dynamic>>[],
        ),
        TrainingService.instance.getFilterOptions().catchError(
          (_) => const <String, dynamic>{},
        ),
        _canManage
            ? TrainingService.instance.listEmployees().catchError(
                (_) => <Map<String, dynamic>>[],
              )
            : Future.value(<Map<String, dynamic>>[]),
      ]);
      if (!mounted) return;
      setState(() {
        _assignments = List<Map<String, dynamic>>.from(results[0] as List);
        _sessions = List<Map<String, dynamic>>.from(results[1] as List);
        _venues = List<Map<String, dynamic>>.from(results[2] as List);
        _options = results[3] is Map
            ? Map<String, dynamic>.from(results[3] as Map)
            : const <String, dynamic>{};
        _employees = List<Map<String, dynamic>>.from(results[4] as List);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canManage = _canManage;
    return Scaffold(
      appBar: shellAppBar(context, title: 'Training & Development'),
      body: _loading
          ? const PageLoadingView(label: 'Loading training…')
          : _error != null
          ? PageErrorView(message: _error!, onRetry: _load)
          : Column(
              children: [
                SizedBox(
                  height: 46,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      for (final (label, idx) in [
                        ('My training', 0),
                        ('Sessions', 1),
                        if (canManage) ('Create', 2),
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(
                              label,
                              style: const TextStyle(fontSize: 13),
                            ),
                            selected: _tab == idx,
                            onSelected: (_) => setState(() => _tab = idx),
                            selectedColor: AppColors.green,
                            labelStyle: TextStyle(
                              color: _tab == idx
                                  ? Colors.white
                                  : AppColors.textPrimary(context),
                              fontWeight: FontWeight.w600,
                            ),
                            showCheckmark: false,
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: switch (_tab) {
                    0 => _MyTrainingList(
                      assignments: _assignments,
                      onRefresh: _load,
                    ),
                    1 => _SessionsList(sessions: _sessions),
                    _ => _CreateAllTab(
                      employees: _employees,
                      venues: _venues,
                      options: _options,
                      onCreated: _load,
                    ),
                  },
                ),
              ],
            ),
    );
  }
}

/// Lightweight access helper so screens can read module access without
/// importing the whole auth layer on every widget build.
class AuthServiceRef {
  AuthServiceRef._();
  static dynamic get instance => _instance;
  static dynamic _instance;
}

class AuthAccess {
  static dynamic of(BuildContext context) => null;
}

class _MyTrainingList extends StatelessWidget {
  const _MyTrainingList({required this.assignments, required this.onRefresh});

  final List<Map<String, dynamic>> assignments;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    if (assignments.isEmpty) {
      return const PageEmptyView(
        title: 'No training assigned yet',
        description:
            'Assignments from HR appear here. Complete an assessment '
            'once your training session is delivered.',
      );
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        itemCount: assignments.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          final a = assignments[i];
          final sessionRows = _mapRows(a['training_sessions']);
          final s = sessionRows.isEmpty
              ? <String, dynamic>{}
              : sessionRows.first;
          final status = '${a['status'] ?? 'assigned'}';
          final done = status == 'completed';
          return Card(
            margin: EdgeInsets.zero,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: done || status == 'failed' || status == 'in_progress'
                  ? null
                  : () => _openAssessment(context, '${a['id']}'),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.green.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.menu_book,
                        color: AppColors.green,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${s['title'] ?? 'Training session'}',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${Fmt.titleCase(_typeLabel('${s['training_type'] ?? ''}'))}'
                                        ' · ${Fmt.dateShort('${s['training_date']}')}'
                                        ' · ${s['facilitator']?.toString() ?? '—'}'
                                    .isEmpty
                                ? ''
                                : '${_typeLabel('${s['training_type'] ?? ''}')} · ${Fmt.dateShort('${s['training_date']}')}',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                    StatusBadge(label: status),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _openAssessment(BuildContext context, String participantId) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TrainingAssessmentScreen(
          participantId: participantId,
          sessionTitle: '',
        ),
      ),
    );
  }
}

List<Map<String, dynamic>> _mapRows(dynamic v) {
  if (v is! List) return const [];
  return v.map((e) {
    final m = e is Map<String, dynamic>
        ? e
        : Map<String, dynamic>.from(e as Map);
    return m;
  }).toList();
}

class _SessionsList extends StatelessWidget {
  const _SessionsList({required this.sessions});

  final List<Map<String, dynamic>> sessions;

  @override
  Widget build(BuildContext context) {
    if (sessions.isEmpty) {
      return const PageEmptyView(
        title: 'No training sessions',
        description: 'Scheduled training events appear here once created.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: sessions.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final s = sessions[i];
        final branch = s['branches'] is Map
            ? (s['branches'] as Map)['branch_name']
            : null;
        return Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${s['title'] ?? ''}',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    StatusBadge(label: '${s['status'] ?? 'scheduled'}'),
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _tag(context, _typeLabel('${s['training_type'] ?? ''}')),
                    _tag(context, Fmt.dateShort('${s['training_date']}')),
                    _tag(
                      context,
                      '${branch ?? s['venue_name'] ?? s['location'] ?? 'All branches'}',
                    ),
                    if (s['delivery_type'] == 'virtual')
                      _tag(context, 'Virtual')
                    else
                      _tag(context, 'Physical'),
                    _tag(context, '${s['duration_minutes'] ?? 0} min'),
                  ],
                ),
                if ('${s['description'] ?? ''}'.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${s['description']}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary(context)),
                  ),
                ],
                if (s['assessment_required'] == true) ...[
                  const SizedBox(height: 8),
                  const Row(
                    children: [
                      Icon(
                        Icons.quiz_outlined,
                        size: 14,
                        color: AppColors.green,
                      ),
                      SizedBox(width: 4),
                      Text(
                        'Assessment required',
                        style: TextStyle(fontSize: 11, color: AppColors.green),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _tag(BuildContext context, String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: const Color(0xFFF1F5F9),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, color: AppColors.textSecondary(context)),
    ),
  );
}

// ---------------------------------------------------------------------------
// Create session tab
// ---------------------------------------------------------------------------

class _CreateAllTab extends StatefulWidget {
  const _CreateAllTab({
    required this.employees,
    required this.venues,
    required this.options,
    required this.onCreated,
  });

  final List<Map<String, dynamic>> employees;
  final List<Map<String, dynamic>> venues;
  final Map<String, dynamic> options;
  final Future<void> Function() onCreated;

  @override
  State<_CreateAllTab> createState() => _CreateAllTabState();
}

class _CreateAllTabState extends State<_CreateAllTab> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _facilitator = TextEditingController();
  final _questionBank = TextEditingController();
  final _duration = TextEditingController(text: '60');
  final _formKey = GlobalKey<FormState>();

  String _type = 'internal';
  String _delivery = 'physical';
  String? _venueId;
  String? _venueName;
  String? _department;
  String? _area;

  DateTime? _date;
  TimeOfDay? _start;
  TimeOfDay? _end;

  final _selectedBranches = <String>{};
  final _selectedRoles = <String>{};
  final _participants = <String>[]; // employee ids

  bool _mandatory = false;
  bool _assessment = false;
  bool _certificate = false;
  bool _busy = false;
  String? _error;
  String? _message;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _facilitator.dispose();
    _questionBank.dispose();
    _duration.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _branchOptions =>
      _optionList(widget.options['branches']);

  List<Map<String, dynamic>> get _deptOptions =>
      _optionList(widget.options['departments']);

  List<Map<String, dynamic>> get _areaOptions =>
      _optionList(widget.options['areas']);

  static List<Map<String, dynamic>> _optionList(dynamic value) {
    if (value is! List) return const [];
    return value.map((e) {
      if (e is Map<String, dynamic>) return e;
      return Map<String, dynamic>.from(e as Map);
    }).toList();
  }

  List<String> get _roleOptions {
    final roles = <String>{};
    for (final e in widget.employees) {
      final pos = '${e['position'] ?? ''}'.trim();
      if (pos.isNotEmpty) roles.add(pos);
    }
    final list = roles.toList()..sort();
    return list;
  }

  List<Map<String, dynamic>> get _filteredEmployees {
    return widget.employees.where((e) {
      final role = '${e['position'] ?? ''}';
      final branch = '${e['branch'] ?? ''}';
      final dept = '${e['department'] ?? ''}';
      final area = '${e['area'] ?? ''}';
      if (_selectedBranches.isNotEmpty &&
          !_selectedBranches.any(
            (b) =>
                branch.toLowerCase() == b.toLowerCase() ||
                '${e['branch_id']}' == b,
          )) {
        return false;
      }
      if (_selectedRoles.isNotEmpty && !_selectedRoles.contains(role)) {
        return false;
      }
      if (_department != null &&
          _department!.isNotEmpty &&
          dept != _department) {
        return false;
      }
      if (_area != null && _area!.isNotEmpty && area != _area) {
        return false;
      }
      return true;
    }).toList();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickTime(bool isStart) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: isStart
          ? (_start ?? const TimeOfDay(hour: 9, minute: 0))
          : (_end ?? const TimeOfDay(hour: 17, minute: 0)),
    );
    if (picked != null) {
      setState(() {
        if (isStart) {
          _start = picked;
        } else {
          _end = picked;
        }
      });
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_delivery == 'physical' &&
        _venueId == null &&
        (_venueName ?? '').isEmpty) {
      setState(() => _error = 'Select a venue for physical training.');
      return;
    }
    if (_participants.isEmpty) {
      setState(() => _error = 'Assign at least one participant.');
      return;
    }
    final bank = TrainingQuestions.parseQuestionBank(_questionBank.text);
    final needsAssessment = _type == 'kss' || _assessment;
    if (needsAssessment && bank.length < 3) {
      setState(
        () => _error = 'Add at least three KSS questions so the three sets are meaningfully different.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      final svc = TrainingService.instance;
      final isVirtual = _delivery == 'virtual';
      Map<String, dynamic>? venue;
      for (final v in widget.venues) {
        if ('${v['id']}' == (_venueId ?? '')) {
          venue = v;
          break;
        }
      }
      final payload = <String, dynamic>{
        'title': _title.text.trim(),
        'training_type': _type,
        'description': _description.text.trim().isEmpty
            ? null
            : _description.text.trim(),
        'facilitator': _facilitator.text.trim(),
        'training_date': (_date ?? DateTime.now()).toIso8601String().substring(
          0,
          10,
        ),
        'start_time': _start?.format(context),
        'end_time': _end?.format(context),
        'duration_minutes': int.tryParse(_duration.text) ?? 60,
        'delivery_type': _delivery,
        'venue_id': _venueId,
        'venue_name': isVirtual ? null : (venue?['branch_name'] ?? _venueName),
        'venue_address': isVirtual ? null : venue?['location'],
        'location': isVirtual ? null : (venue?['branch_name'] ?? _venueName),
        'department': _department,
        'area': _area,
        'assessment_required': needsAssessment,
        'certificate_enabled': _certificate,
        'is_mandatory': _mandatory,
        'status': 'scheduled',
      };
      final created = await svc.createSession(payload);
      if (needsAssessment) {
        final sets = TrainingQuestions.buildSets(bank);
        await svc.generateQuestionSets('${created['id']}', sets);
      }
      await svc.assignParticipants('${created['id']}', _participants);
      await widget.onCreated();
      if (!mounted) return;
      setState(() {
        _message =
            'Session created and assigned to ${_participants.length} employees.';
        _busy = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceAll('Exception: ', '');
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async {},
      child: Form(
        key: _formKey,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            if (_error != null)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.rose.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(color: AppColors.rose, fontSize: 13),
                ),
              ),
            if (_message != null)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.green.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _message!,
                  style: const TextStyle(
                    color: AppColors.greenDark,
                    fontSize: 13,
                  ),
                ),
              ),
            SectionCard(
              title: 'Training details',
              children: [
                TextFormField(
                  controller: _title,
                  decoration: const InputDecoration(labelText: 'Title'),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Title is required'
                      : null,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _type,
                  decoration: const InputDecoration(labelText: 'Training type'),
                  items: [
                    for (final e in _trainingTypes.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) => setState(() => _type = v ?? _type),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _delivery,
                  decoration: const InputDecoration(
                    labelText: 'Training delivery',
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'physical',
                      child: Text('Physical'),
                    ),
                    DropdownMenuItem(value: 'virtual', child: Text('Virtual')),
                  ],
                  onChanged: (v) => setState(() => _delivery = v ?? _delivery),
                ),
                const SizedBox(height: 12),
                if (_delivery == 'physical') ...[
                  DropdownButtonFormField<String?>(
                    initialValue: _venueId,
                    decoration: const InputDecoration(labelText: 'Venue'),
                    items: [
                      for (final v in widget.venues)
                        DropdownMenuItem(
                          value: '${v['id']}',
                          child: Text(
                            '${v['branch_name']}'
                            '${v['location'] != null ? ' — ${v['location']}' : ''}',
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() => _venueId = v),
                  ),
                  const SizedBox(height: 12),
                ],
                TextFormField(
                  controller: _facilitator,
                  decoration: const InputDecoration(labelText: 'Facilitator'),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Facilitator is required'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _description,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Description (optional)',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SectionCard(
              title: 'Schedule',
              children: [
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _pickDate,
                        icon: const Icon(Icons.calendar_today, size: 16),
                        label: Text(
                          _date == null
                              ? 'Pick date'
                              : DateFormat('MMM d, yyyy').format(_date!),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _pickTime(true),
                        icon: const Icon(Icons.schedule, size: 16),
                        label: Text(
                          _start == null ? 'Start' : _start!.format(context),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _pickTime(false),
                        icon: const Icon(Icons.schedule, size: 16),
                        label: Text(
                          _end == null ? 'End' : _end!.format(context),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _duration,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Duration (minutes)',
                    suffixText: 'min',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SectionCard(
              title: 'Organisation & participants',
              children: [
                DropdownButtonFormField<String?>(
                  initialValue: _department,
                  decoration: const InputDecoration(
                    labelText: 'Department (optional)',
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('All departments'),
                    ),
                    for (final d in _deptOptions)
                      DropdownMenuItem<String?>(
                        value: '${d['label'] ?? d['name'] ?? ''}',
                        child: Text('${d['label'] ?? d['name'] ?? ''}'),
                      ),
                  ],
                  onChanged: (v) => setState(() => _department = v),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  initialValue: _area,
                  decoration: const InputDecoration(
                    labelText: 'Area (optional)',
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('All areas'),
                    ),
                    for (final a in _areaOptions)
                      DropdownMenuItem<String?>(
                        value: '${a['label'] ?? a['name'] ?? ''}',
                        child: Text('${a['label'] ?? a['name'] ?? ''}'),
                      ),
                  ],
                  onChanged: (v) => setState(() => _area = v),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Branches (multi-select)',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final b in _branchOptions)
                      FilterChip(
                        label: Text('${b['branch_name'] ?? b['label'] ?? ''}'),
                        selected: _selectedBranches.contains(
                          '${b['branch_name'] ?? ''}',
                        ),
                        onSelected: (sel) => setState(() {
                          final name = '${b['branch_name'] ?? ''}';
                          if (sel) {
                            _selectedBranches.add(name);
                          } else {
                            _selectedBranches.remove(name);
                          }
                        }),
                        showCheckmark: false,
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Roles (multi-select)',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final r in _roleOptions)
                      FilterChip(
                        label: Text(r),
                        selected: _selectedRoles.contains(r),
                        onSelected: (sel) => setState(() {
                          if (sel) {
                            _selectedRoles.add(r);
                          } else {
                            _selectedRoles.remove(r);
                          }
                        }),
                        showCheckmark: false,
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                _participants.isEmpty
                    ? Text(
                        'No participants selected yet.',
                        style: TextStyle(fontSize: 12, color: AppColors.textTertiary(context)),
                      )
                    : Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final e in widget.employees)
                            if (_participants.contains('${e['id']}'))
                              Chip(
                                label: Text(
                                  '${e['full_name']} (${e['position'] ?? e['branch'] ?? ''})',
                                ),
                                deleteIcon: const Icon(Icons.close, size: 16),
                                onDeleted: () => setState(
                                  () => _participants.remove('${e['id']}'),
                                ),
                              ),
                        ],
                      ),
                if (_filteredEmployees.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(
                    '${_filteredEmployees.length} matching employee(s) — tap to add',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ..._filteredEmployees.map((e) {
                    final id = '${e['id']}';
                    final selected = _participants.contains(id);
                    return Card(
                      margin: const EdgeInsets.only(bottom: 6),
                      elevation: 0,
                      child: CheckboxListTile(
                        dense: true,
                        value: selected,
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            if (!_participants.contains(id)) {
                              _participants.add(id);
                            }
                          } else {
                            _participants.remove(id);
                          }
                        }),
                        controlAffinity: ListTileControlAffinity.trailing,
                        secondary: AvatarCircle(
                          name: '${e['full_name'] ?? ''}',
                          size: 34,
                        ),
                        title: Text(
                          '${e['full_name'] ?? ''}',
                          style: const TextStyle(fontSize: 13),
                        ),
                        subtitle: Text(
                          [
                            if ('${e['position'] ?? ''}'.isNotEmpty)
                              '${e['position']}',
                            if ('${e['branch'] ?? ''}'.isNotEmpty)
                              '${e['branch']}',
                          ].join(' · '),
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    );
                  }),
                ] else if (_selectedBranches.isNotEmpty ||
                    _selectedRoles.isNotEmpty ||
                    (_department ?? '').isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    'No employees match the current filters.',
                    style: TextStyle(fontSize: 12, color: AppColors.textTertiary(context)),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            SectionCard(
              title: 'Assessment & certificate',
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Mandatory training',
                    style: TextStyle(fontSize: 14),
                  ),
                  value: _mandatory,
                  onChanged: (v) => setState(() => _mandatory = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Assessment required',
                    style: TextStyle(fontSize: 14),
                  ),
                  subtitle: const Text(
                    'KSS sessions always generate three rotated question sets.',
                    style: TextStyle(fontSize: 11),
                  ),
                  value: _assessment,
                  activeThumbColor: AppColors.green,
                  onChanged: (v) => setState(() => _assessment = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Issue certificate',
                    style: TextStyle(fontSize: 14),
                  ),
                  value: _certificate,
                  activeThumbColor: AppColors.green,
                  onChanged: (v) => setState(() => _certificate = v),
                ),
                if (_type == 'kss' || _assessment) ...[
                  const SizedBox(height: 4),
                  Text(
                    'KSS question bank — one question per line:\n'
                    'Question | Correct answer | Option 1, Option 2, Option 3',
                    style: TextStyle(fontSize: 11, color: AppColors.textSecondary(context)),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _questionBank,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      hintText: 'What is the confidentiality rule? | All customer data is confidential | We can share internally, It should not be shared, Only managers may access',
                      alignLabelWithHint: true,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _busy ? null : _submit,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.check),
              label: Text(_busy ? 'Creating…' : 'Create & assign training'),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Assessment
// ---------------------------------------------------------------------------

class TrainingAssessmentScreen extends StatefulWidget {
  const TrainingAssessmentScreen({
    super.key,
    required this.participantId,
    required this.sessionTitle,
  });

  final String participantId;
  final String sessionTitle;

  @override
  State<TrainingAssessmentScreen> createState() =>
      _TrainingAssessmentScreenState();
}

class _TrainingAssessmentScreenState extends State<TrainingAssessmentScreen> {
  Map<String, dynamic> _assignment = const {};
  bool _loading = true;
  bool _submitting = false;
  String? _error;
  String? _doneMessage;
  final _answers = <String, String>{};
  bool _declaration = false;
  final _signKey = GlobalKey<SignaturePadState>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await TrainingService.instance.myAssignment(
        widget.participantId,
      );
      if (!mounted) return;
      setState(() => _assignment = data);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _questions {
    final qs = _assignment['questions'];
    if (qs is! List) return const [];
    return qs
        .map(
          (e) => e is Map<String, dynamic>
              ? e
              : Map<String, dynamic>.from(e as Map),
        )
        .toList();
  }

  String _title() {
    final s = _assignment['session'];
    if (s is Map) return '${s['title'] ?? 'Training'}';
    return widget.sessionTitle.isEmpty
        ? 'Training assessment'
        : widget.sessionTitle;
  }

  Future<void> _submit() async {
    if (_questions.isEmpty) {
      setState(
        () =>
            _error = 'No questions are assigned. Contact HR if this persists.',
      );
      return;
    }
    for (final q in _questions) {
      if ((_answers['${q['id']}'] ?? '').trim().isEmpty) {
        setState(() => _error = 'Answer every question before submitting.');
        return;
      }
    }
    if (!_declaration) {
      setState(() => _error = 'Accept the declaration before submitting.');
      return;
    }
    final png = await _signKey.currentState?.capture();
    if (png == null || png.isEmpty) {
      setState(() => _error = 'Sign the declaration before submitting.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final participantId = widget.participantId;
      final path =
          'training-signatures/$participantId/'
          '${DateTime.now().millisecondsSinceEpoch}.png';
      await SupabaseService.client.storage
          .from('documents')
          .uploadBinary(
            path,
            png,
            fileOptions: FileOptions(contentType: 'image/png'),
          );
      final payload = [
        for (final q in _questions)
          {'question_id': '${q['id']}', 'answer': _answers['${q['id']}']},
      ];
      final result = await TrainingService.instance.submitAssessment(
        participantId: participantId,
        answers: payload,
        signaturePath: path,
      );
      try {
        await SupabaseService.client.storage.from('documents').remove([path]);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _doneMessage =
            'Submitted. Result: ${result['result'] ?? result['status'] ?? 'received'}.';
        _submitting = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceAll('Exception: ', '');
          _submitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: shellAppBar(context, title: _title()),
      body: _loading
          ? const PageLoadingView(label: 'Loading assessment…')
          : _error != null && _assignment.isEmpty
          ? PageErrorView(message: _error!, onRetry: _load)
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_error != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.rose.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        color: AppColors.rose,
                        fontSize: 13,
                      ),
                    ),
                  ),
                if (_doneMessage != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.green.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _doneMessage!,
                      style: const TextStyle(
                        color: AppColors.greenDark,
                        fontSize: 13,
                      ),
                    ),
                  ),
                SectionCard(
                  title: 'Your assigned questions',
                  trailing: _questions.isEmpty
                      ? null
                      : Text(
                          '${_questions.length} questions',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textTertiary(context),
                          ),
                        ),
                  children: [
                    Text(
                      'Your question set is fixed by HR for this attempt.',
                      style: TextStyle(fontSize: 12, color: AppColors.textSecondary(context)),
                    ),
                    for (final (i, q) in _questions.indexed) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Q${i + 1}. ${q['prompt'] ?? ''}',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _QuestionInput(
                        question: q,
                        value: _answers['${q['id']}'] ?? '',
                        onChanged: (v) =>
                            setState(() => _answers['${q['id']}'] = v),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                SectionCard(
                  title: 'Declaration & signature',
                  children: [
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _declaration,
                      activeColor: AppColors.green,
                      onChanged: (v) =>
                          setState(() => _declaration = v ?? false),
                      title: const Text(
                        'I completed this training and submitted these answers myself.',
                        style: TextStyle(fontSize: 12.5),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SignaturePad(
                      key: _signKey,
                      onChanged: (png) => setState(() {}),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _submitting ? null : _submit,
                  icon: _submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send),
                  label: Text(
                    _submitting ? 'Submitting…' : 'Submit assessment',
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}

class _QuestionInput extends StatelessWidget {
  const _QuestionInput({
    required this.question,
    required this.value,
    required this.onChanged,
  });

  final Map<String, dynamic> question;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final options = question['options'];
    final hasOptions =
        options is List && options.any((o) => '${o ?? ''}'.trim().isNotEmpty);
    if (hasOptions) {
      return Column(
        children: [
          for (final o in options)
            Card(
              margin: const EdgeInsets.only(bottom: 6),
              color: value == '$o'
                  ? AppColors.green.withValues(alpha: 0.08)
                  : null,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => onChanged('$o'),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('$o', style: const TextStyle(fontSize: 13)),
                      ),
                      Icon(
                        value == '$o'
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        size: 18,
                        color: value == '$o' ? AppColors.green : AppColors.textTertiary(context),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
    }
    return TextFormField(
      initialValue: value,
      maxLines: 2,
      onChanged: onChanged,
      decoration: const InputDecoration(hintText: 'Your answer'),
    );
  }
}
