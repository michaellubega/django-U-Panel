import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../attendance/attendance_list_hierarchy.dart';
import '../attendance/attendance_list_title.dart';
import '../attendance/data/attendance_repository.dart';
import '../attendance/models/attendance_models.dart';
import '../../core/theme/app_theme.dart';

/// Who should receive and see the notice in their personal feed.
enum NoticeAudienceKind {
  /// Visible to all signed-in app users; push targets the broadcast topic.
  allAppUsers,

  /// Visible only to students who have signed into the chosen attendance list.
  classList,

  /// Visible only to one roster student (server-created, e.g. missed check-in).
  student,

  /// Visible only to KIU administrators ([AuthRepository.isKiuAdmin]).
  kiuAdmins,
}

class NoticeCreationResult {
  const NoticeCreationResult({
    required this.title,
    required this.body,
    required this.sendPush,
    required this.audience,
    this.scheduledFor,
    this.targetListId,
    this.targetListTitle,
    this.validFor,
  });

  final String title;
  final String body;
  final bool sendPush;
  final DateTime? scheduledFor;
  final NoticeAudienceKind audience;
  final String? targetListId;
  final String? targetListTitle;
  final Duration? validFor;
}

class CreateNoticeScreen extends StatefulWidget {
  const CreateNoticeScreen({super.key});

  @override
  State<CreateNoticeScreen> createState() => _CreateNoticeScreenState();
}

class _CreateNoticeScreenState extends State<CreateNoticeScreen> {
  final _titleC = TextEditingController();
  final _bodyC = TextEditingController();
  final _listSearchC = TextEditingController();
  bool _sendPush = true;
  bool _scheduleForLater = false;
  DateTime? _scheduledFor;
  bool _setValidity = true;
  Duration _validFor = const Duration(hours: 24);
  NoticeAudienceKind _audience = NoticeAudienceKind.allAppUsers;
  AttendanceList? _selectedList;

  bool get _lecturerOnly {
    final auth = AuthRepository.instance;
    return auth.lecturerCheckDone && auth.isLecturer && !auth.isAdmin;
  }

  bool get _staffPublisher {
    final auth = AuthRepository.instance;
    return auth.adminCheckDone && auth.isAdmin && !_lecturerOnly;
  }

  bool get _kiuAdminPublisher {
    final auth = AuthRepository.instance;
    return auth.isKiuAdmin && !_staffPublisher;
  }

  bool get _canPickAudience => !_lecturerOnly && (_staffPublisher || _kiuAdminPublisher);

  @override
  void initState() {
    super.initState();
    if (_lecturerOnly) {
      _audience = NoticeAudienceKind.classList;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_ensureAttendanceListsLoaded());
    });
  }

  Future<void> _ensureAttendanceListsLoaded() async {
    final repo = AttendanceRepository.instance;
    if (repo.hasCachedStore || repo.isLoaded) return;
    try {
      if (AttendanceRepository.isStudentScopedUser()) return;
      await repo.loadAttendanceListsFirst(force: false);
      if (mounted) setState(() {});
    } catch (_) {}
  }

  AttendanceList? _dropdownValue(List<AttendanceList> filtered) {
    final id = _selectedList?.id;
    if (id == null) return null;
    for (final list in filtered) {
      if (list.id == id) return list;
    }
    return null;
  }

  @override
  void dispose() {
    _titleC.dispose();
    _bodyC.dispose();
    _listSearchC.dispose();
    super.dispose();
  }

  List<AttendanceList> get _listsSorted {
    final source = _lecturerOnly
        ? attendanceListsForCurrentStaff()
        : List<AttendanceList>.from(AttendanceStore.lists);
    final copy = List<AttendanceList>.from(source);
    copy.sort(compareAttendanceListsNewestFirst);
    return copy;
  }

  List<AttendanceList> _filterLists(List<AttendanceList> lists) {
    final q = _listSearchC.text.trim().toLowerCase();
    if (q.isEmpty) return lists;
    return lists.where((l) {
      final title = l.displayTitle.toLowerCase();
      final who = l.whoTaught.toLowerCase();
      final room = l.room.toLowerCase();
      final courses = l.coursesSafe.join(' ').toLowerCase();
      return title.contains(q) ||
          who.contains(q) ||
          room.contains(q) ||
          courses.contains(q);
    }).toList();
  }

  Future<void> _pickDateTime() async {
    final now = DateTime.now();
    final current = _scheduledFor ?? now.add(const Duration(hours: 1));

    final pickedDate = await showDatePicker(
      context: context,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      initialDate: current,
    );
    if (!mounted || pickedDate == null) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    if (!mounted || pickedTime == null) return;

    setState(() {
      _scheduledFor = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        pickedTime.hour,
        pickedTime.minute,
      );
    });
  }

  void _submit() {
    final title = _titleC.text.trim();
    final body = _bodyC.text.trim();
    if (title.isEmpty || body.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add both title and notice body.')),
      );
      return;
    }
    if (_scheduleForLater) {
      final target = _scheduledFor;
      if (target == null || !target.isAfter(DateTime.now())) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Choose a future date and time.')),
        );
        return;
      }
    }
    if (_audience == NoticeAudienceKind.classList) {
      if (_selectedList == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _lecturerOnly
                  ? 'Choose one of your class lists.'
                  : 'Choose a class list, or pick another audience.',
            ),
          ),
        );
        return;
      }
    }

    Navigator.of(context).pop(
      NoticeCreationResult(
        title: title,
        body: body,
        sendPush: _sendPush,
        scheduledFor: _scheduleForLater ? _scheduledFor : null,
        audience: _audience,
        targetListId: _audience == NoticeAudienceKind.classList
            ? _selectedList!.id
            : null,
        targetListTitle: _audience == NoticeAudienceKind.classList
            ? _selectedList!.displayTitle
            : null,
        validFor: _setValidity ? _validFor : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final scheduled = _scheduledFor;
    final scheduledLabel = scheduled == null
        ? 'Pick date and time'
        : '${localizations.formatShortDate(scheduled)} ${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(scheduled))}';

    final lists = _listsSorted;
    final filteredLists = _filterLists(lists);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Create notice'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _submit,
              child: Text(_scheduleForLater ? 'Schedule' : 'Publish'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 980;
            final leftColumn = <Widget>[
              Text(
                'Send to',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                _lecturerOnly
                    ? 'This notice is sent to students who have signed into the '
                        'class list you choose (your assigned or created lists only).'
                    : _staffPublisher
                        ? 'QA staff can broadcast to all app users, one class list, '
                            'or KIU administrators only.'
                        : _kiuAdminPublisher
                            ? 'Broadcast a notice to everyone in the app, or target '
                                'students on one class list.'
                            : 'Notices sent to all app users appear in every account. Class-list '
                                'notices only appear for students who have signed into that list.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppTheme.textSecondary,
                    ),
              ),
              const SizedBox(height: 12),
              if (_canPickAudience)
                SegmentedButton<NoticeAudienceKind>(
                  segments: _kiuAdminPublisher
                      ? const [
                          ButtonSegment<NoticeAudienceKind>(
                            value: NoticeAudienceKind.allAppUsers,
                            label: Text('All users'),
                            icon: Icon(Icons.public_outlined, size: 18),
                          ),
                          ButtonSegment<NoticeAudienceKind>(
                            value: NoticeAudienceKind.classList,
                            label: Text('Class list'),
                            icon: Icon(Icons.groups_outlined, size: 18),
                          ),
                        ]
                      : const [
                          ButtonSegment<NoticeAudienceKind>(
                            value: NoticeAudienceKind.allAppUsers,
                            label: Text('All users'),
                            icon: Icon(Icons.public_outlined, size: 18),
                          ),
                          ButtonSegment<NoticeAudienceKind>(
                            value: NoticeAudienceKind.classList,
                            label: Text('Class list'),
                            icon: Icon(Icons.groups_outlined, size: 18),
                          ),
                          ButtonSegment<NoticeAudienceKind>(
                            value: NoticeAudienceKind.kiuAdmins,
                            label: Text('KIU admins'),
                            icon: Icon(Icons.admin_panel_settings_outlined, size: 18),
                          ),
                        ],
                  selected: {_audience},
                  onSelectionChanged: (s) {
                    setState(() {
                      _audience = s.single;
                      if (_audience != NoticeAudienceKind.classList) {
                        _selectedList = null;
                      }
                    });
                  },
                ),
              if (_lecturerOnly || _audience == NoticeAudienceKind.classList) ...[
                const SizedBox(height: 8),
                if (lists.isEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        _lecturerOnly
                            ? 'No class lists assigned to you yet. Create or get assigned '
                                'a list under Attendance first.'
                            : 'No attendance lists yet. Create one under Attendance, '
                                'or choose “All users”.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  )
                else
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _listSearchC,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: 'Search class list',
                          hintText: 'Type list name, lecturer, room or course',
                          prefixIcon: Icon(Icons.search_rounded),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Class list',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<AttendanceList>(
                            isExpanded: true,
                            value: _dropdownValue(filteredLists),
                            hint: Text(
                              filteredLists.isEmpty
                                  ? 'No lists match your search'
                                  : 'Choose a list',
                            ),
                            selectedItemBuilder: (context) => [
                              for (final list in filteredLists)
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    list.displayTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            items: [
                              for (final list in filteredLists)
                                DropdownMenuItem(
                                  value: list,
                                  child: AttendanceListTitleColumn(
                                    list: list,
                                    titleStyle:
                                        Theme.of(context).textTheme.bodyLarge,
                                    titleMaxLines: 1,
                                    subtitleMaxLines: 1,
                                  ),
                                ),
                            ],
                            onChanged: filteredLists.isEmpty
                                ? null
                                : (list) => setState(() => _selectedList = list),
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
              const SizedBox(height: 28),
              TextField(
                controller: _titleC,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Title',
                  hintText: 'Example: Semester schedule update',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _bodyC,
                maxLines: 8,
                minLines: 5,
                decoration: const InputDecoration(
                  labelText: 'Notice body',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ];

            final rightControls = Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Delivery options',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 10),
                    SwitchListTile.adaptive(
                      value: _sendPush,
                      onChanged: (v) => setState(() => _sendPush = v),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Push notification'),
                      subtitle: Text(
                        switch (_audience) {
                          NoticeAudienceKind.allAppUsers =>
                            'Notify all app users who receive broadcasts.',
                          NoticeAudienceKind.classList =>
                            'Notify members on that list who use the app.',
                          NoticeAudienceKind.kiuAdmins =>
                            'Notify KIU administrators only.',
                          NoticeAudienceKind.student =>
                            'Notify one student.',
                        },
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    SwitchListTile.adaptive(
                      value: _scheduleForLater,
                      onChanged: (v) async {
                        setState(() => _scheduleForLater = v);
                        if (v && _scheduledFor == null) {
                          await _pickDateTime();
                        }
                      },
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Schedule for later'),
                    ),
                    if (_scheduleForLater) ...[
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _pickDateTime,
                        icon: const Icon(Icons.schedule_rounded, size: 20),
                        label: Text(scheduledLabel),
                      ),
                    ],
                    const SizedBox(height: 8),
                    SwitchListTile.adaptive(
                      value: _setValidity,
                      onChanged: (v) => setState(() => _setValidity = v),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Auto delete'),
                      subtitle: const Text(
                        'Default is 24 hours.',
                      ),
                    ),
                    if (_setValidity) ...[
                      const SizedBox(height: 8),
                      DropdownButtonFormField<Duration>(
                        value: _validFor,
                        decoration: const InputDecoration(
                          labelText: 'Valid for',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: Duration(hours: 1),
                            child: Text('1 hour'),
                          ),
                          DropdownMenuItem(
                            value: Duration(hours: 3),
                            child: Text('3 hours'),
                          ),
                          DropdownMenuItem(
                            value: Duration(hours: 12),
                            child: Text('12 hours'),
                          ),
                          DropdownMenuItem(
                            value: Duration(hours: 24),
                            child: Text('24 hours'),
                          ),
                          DropdownMenuItem(
                            value: Duration(days: 3),
                            child: Text('3 days'),
                          ),
                          DropdownMenuItem(
                            value: Duration(days: 7),
                            child: Text('7 days'),
                          ),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() => _validFor = v);
                        },
                      ),
                    ],
                  ],
                ),
              ),
            );

            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: wide ? 1100 : 720),
                  child: wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: leftColumn,
                              ),
                            ),
                            const SizedBox(width: 20),
                            SizedBox(
                              width: 340,
                              child: rightControls,
                            ),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ...leftColumn,
                            const SizedBox(height: 20),
                            rightControls,
                          ],
                        ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
