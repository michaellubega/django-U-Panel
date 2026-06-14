import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'attendance_list_hierarchy.dart';
import 'attendance_screen.dart';
import 'data/attendance_repository.dart';
import 'models/attendance_models.dart';
import 'today_attendance_list_filter.dart';

/// Opens the weekday → program → list hierarchy filtered to today's roll rows.
void openTodayRollClassLists(
  BuildContext context, {
  required TodayRollPresenceFilter filter,
  String? studentId,
}) {
  Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => TodayAttendanceListsHubScreen(
        filter: filter,
        studentId: studentId,
      ),
    ),
  );
}

/// Hub: class days that have present/absent roll activity today.
class TodayAttendanceListsHubScreen extends StatelessWidget {
  const TodayAttendanceListsHubScreen({
    super.key,
    required this.filter,
    this.studentId,
  });

  final TodayRollPresenceFilter filter;
  final String? studentId;

  List<AttendanceList> _scopedLists() => scopedListsForTodayRollFilter(
        filter: filter,
        studentId: studentId,
      );

  Color get _accent => switch (filter) {
        TodayRollPresenceFilter.present => AppTheme.success,
        TodayRollPresenceFilter.absent => AppTheme.error,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: AttendanceRepository.instance,
      builder: (context, _) {
        final scoped = _scopedLists();
        final weekdays = weekdaysWithLists(scoped);

        return Scaffold(
          backgroundColor: AppTheme.surface,
          appBar: AppBar(
            elevation: 0,
            title: Text(filter.title),
            flexibleSpace: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    _accent.withValues(alpha: 0.92),
                    AppTheme.primary,
                  ],
                ),
              ),
            ),
            backgroundColor: Colors.transparent,
            foregroundColor: Colors.white,
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 32),
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  color: _accent.withValues(alpha: 0.08),
                  border: Border.all(color: _accent.withValues(alpha: 0.28)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          filter == TodayRollPresenceFilter.present
                              ? Icons.how_to_reg_rounded
                              : Icons.person_off_rounded,
                          color: _accent,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            filter.title,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      studentId == null
                          ? 'Class lists with ${filter == TodayRollPresenceFilter.present ? 'present' : 'absent'} '
                              'check-ins recorded today. Pick a class day, then program, to open a list.'
                          : 'Your class lists where you were marked '
                              '${filter == TodayRollPresenceFilter.present ? 'present' : 'absent'} today.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '${scoped.length} ${scoped.length == 1 ? 'list' : 'lists'}',
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: _accent,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (scoped.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    filter.emptyMessage,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: AppTheme.textSecondary,
                      height: 1.45,
                    ),
                  ),
                )
              else
                ...weekdays.map((weekday) {
                  final n = listCountOnWeekday(scoped, weekday);
                  return QaWeekdayHubTile(
                    weekday: weekday,
                    listCount: n,
                    onTap: () {
                      Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (ctx) => AttendanceDayProgramsScreen(
                            weekday: weekday,
                            scopedLists: scoped,
                            hubTitle: filter.title,
                          ),
                        ),
                      );
                    },
                  );
                }),
            ],
          ),
        );
      },
    );
  }
}
