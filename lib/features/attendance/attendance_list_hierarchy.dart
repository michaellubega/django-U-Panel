import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/theme/app_theme.dart';
import 'models/attendance_models.dart';
import 'qa_program_session_ui.dart';

/// Saturday / Sunday ([DateTime.weekday] 6 and 7).
bool isWeekendWeekday(int weekday) =>
    weekday == DateTime.saturday || weekday == DateTime.sunday;

/// Weekend program is only shown on Saturday and Sunday.
bool attendanceProgramAllowedOnWeekday(
  AttendanceProgram program,
  int weekday,
) {
  if (program == AttendanceProgram.weekend) {
    return isWeekendWeekday(weekday);
  }
  return true;
}

/// Drops weekend-program lists stored on Mon–Fri (legacy / mis-tagged data).
bool attendanceListVisibleInHierarchy(AttendanceList list) {
  return attendanceProgramAllowedOnWeekday(
    list.program,
    list.date.weekday.clamp(1, 7),
  );
}

List<AttendanceList> filterListsForHierarchy(Iterable<AttendanceList> lists) {
  return lists.where(attendanceListVisibleInHierarchy).toList();
}

/// Lecturer may manage lists they created or that QA assigned to their account.
bool attendanceListAccessibleToLecturer(AttendanceList list, String lecturerUid) {
  final uid = lecturerUid.trim();
  if (uid.isEmpty) return false;
  if (list.lecturerUid?.trim() == uid) return true;
  if (list.createdBy?.trim() == uid) return true;
  return false;
}

/// In-memory filter for lecturer-scoped UI (after [AttendanceRepository.loadAll]).
List<AttendanceList> attendanceListsForCurrentStaff() {
  final auth = AuthRepository.instance;
  final sorted = List<AttendanceList>.from(AttendanceStore.lists)
    ..sort(compareAttendanceListsNewestFirst);
  if (auth.adminCheckDone && auth.isAdmin) {
    return filterListsForHierarchy(sorted);
  }
  if (auth.lecturerCheckDone && auth.isLecturer && !auth.isAdmin) {
    final uid = auth.currentFirebaseUid?.trim();
    if (uid == null || uid.isEmpty) return [];
    return filterListsForHierarchy(
      sorted.where((l) => attendanceListAccessibleToLecturer(l, uid)),
    );
  }
  return [];
}

/// Weekday (1 = Mon … 7 = Sun) → lists on that class day.
Map<int, List<AttendanceList>> groupListsByWeekday(Iterable<AttendanceList> lists) {
  final map = <int, List<AttendanceList>>{};
  for (final l in filterListsForHierarchy(lists)) {
    final w = l.date.weekday.clamp(1, 7);
    (map[w] ??= []).add(l);
  }
  for (final sub in map.values) {
    sub.sort(compareAttendanceListsNewestFirst);
  }
  return map;
}

/// Weekdays that have at least one list, Monday first.
List<int> weekdaysWithLists(Iterable<AttendanceList> lists) {
  final byDay = groupListsByWeekday(lists);
  return [for (var w = 1; w <= 7; w++) if ((byDay[w]?.length ?? 0) > 0) w];
}

int listCountOnWeekday(Iterable<AttendanceList> lists, int weekday) {
  return lists
      .where(
        (l) =>
            attendanceListVisibleInHierarchy(l) &&
            l.date.weekday == weekday,
      )
      .length;
}

int listCountOnWeekdayProgram(
  Iterable<AttendanceList> lists,
  int weekday,
  AttendanceProgram program,
) {
  if (!attendanceProgramAllowedOnWeekday(program, weekday)) return 0;
  return lists
      .where(
        (l) =>
            attendanceListVisibleInHierarchy(l) &&
            l.date.weekday == weekday &&
            l.program == program,
      )
      .length;
}

/// Programs that may appear on [weekday] and have at least one list that day.
List<AttendanceProgram> programsWithListsForWeekday(
  Iterable<AttendanceList> lists,
  int weekday,
) {
  final out = <AttendanceProgram>[];
  for (final p in AttendanceProgram.values) {
    if (!attendanceProgramAllowedOnWeekday(p, weekday)) continue;
    if (listCountOnWeekdayProgram(lists, weekday, p) > 0) {
      out.add(p);
    }
  }
  return out;
}

List<AttendanceList> listsForWeekdayAndProgram(
  Iterable<AttendanceList> lists,
  int weekday,
  AttendanceProgram program,
) {
  if (!attendanceProgramAllowedOnWeekday(program, weekday)) {
    return [];
  }
  return List<AttendanceList>.from(
    lists.where(
      (l) =>
          attendanceListVisibleInHierarchy(l) &&
          l.date.weekday == weekday &&
          l.program == program,
    ),
  )..sort(compareAttendanceListsNewestFirst);
}

/// Year → semester → lists (caller should pre-filter by day/program).
Map<String, Map<String, List<AttendanceList>>> groupListsByYearSem(
  Iterable<AttendanceList> lists,
) {
  final out = <String, Map<String, List<AttendanceList>>>{};
  for (final l in lists) {
    final semMap = out.putIfAbsent(l.year, () => {});
    semMap.putIfAbsent(l.sem, () => []).add(l);
  }
  for (final semMap in out.values) {
    for (final bucket in semMap.values) {
      bucket.sort(compareAttendanceListsNewestFirst);
    }
  }
  return out;
}

String weekdayFullLabel(int weekday) =>
    kAttendanceWeekdayFullNames[weekday.clamp(1, 7) - 1];

String weekdayShortLabel(int weekday) =>
    kAttendanceWeekdayShortLabels[weekday.clamp(1, 7) - 1];

List<Color> qaWeekdayAppBarGradient(int weekday) {
  final mix = isWeekendWeekday(weekday)
      ? qaProgramAccent(AttendanceProgram.weekend)
      : AppTheme.primaryLight;
  return [
    AppTheme.primary,
    Color.lerp(AppTheme.primary, mix, 0.28)!,
    AppTheme.secondary,
  ];
}

/// First hub level: Monday … Sunday.
class QaWeekdayHubTile extends StatelessWidget {
  const QaWeekdayHubTile({
    super.key,
    required this.weekday,
    required this.listCount,
    required this.onTap,
  });

  final int weekday;
  final int listCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = weekdayFullLabel(weekday);
    final short = weekdayShortLabel(weekday);
    final subtitle = listCount == 0
        ? 'No lists on $label'
        : '$listCount ${listCount == 1 ? 'class list' : 'class lists'} · Day → Program';

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: AppTheme.background,
              border: Border.all(
                color: AppTheme.softGrey.withValues(alpha: 0.95),
              ),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primary.withValues(alpha: 0.06),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      width: 5,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            AppTheme.primaryLight,
                            AppTheme.primary,
                          ],
                        ),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
                        child: Row(
                          children: [
                            Container(
                              width: 54,
                              height: 54,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    AppTheme.primary.withValues(alpha: 0.85),
                                    AppTheme.primary,
                                  ],
                                ),
                              ),
                              child: Center(
                                child: Text(
                                  short,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    label,
                                    style: theme.textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: -0.2,
                                      color: AppTheme.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    subtitle,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: AppTheme.textSecondary,
                                      height: 1.35,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: AppTheme.surface,
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: AppTheme.softGrey.withValues(alpha: 0.9),
                                ),
                              ),
                              child: Text(
                                '$listCount',
                                style: theme.textTheme.labelLarge?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: AppTheme.primary,
                                ),
                              ),
                            ),
                            const Icon(
                              Icons.chevron_right_rounded,
                              color: AppTheme.textSecondary,
                              size: 28,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
