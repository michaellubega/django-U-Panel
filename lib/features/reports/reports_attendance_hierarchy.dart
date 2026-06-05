import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../attendance/attendance_list_hierarchy.dart';
import '../attendance/models/attendance_models.dart';
import '../attendance/attendance_list_title.dart';
import '../attendance/qa_program_session_ui.dart';
import 'attendance_list_roll.dart';
import 'attendance_list_roll_screen.dart';
import 'report_print.dart';

/// Generic hierarchy tile (year / semester).
class ReportsHierarchyTile extends StatelessWidget {
  const ReportsHierarchyTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.count,
    required this.accent,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final int count;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                          colors: [accent, AppTheme.primary],
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
                                    accent.withValues(alpha: 0.92),
                                    AppTheme.primary,
                                  ],
                                ),
                              ),
                              child: Icon(icon, color: Colors.white, size: 28),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    style: theme.textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: -0.2,
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
                                '$count',
                                style: theme.textTheme.labelLarge?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: AppTheme.primary,
                                ),
                              ),
                            ),
                            const Icon(Icons.chevron_right_rounded,
                                color: AppTheme.textSecondary, size: 28),
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

/// Day → program → year → semester → class lists.
class ReportsDayHubSection extends StatelessWidget {
  const ReportsDayHubSection({super.key, required this.lists});

  final List<AttendanceList> lists;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...weekdaysWithLists(lists).map((weekday) {
          final n = listCountOnWeekday(lists, weekday);
          return QaWeekdayHubTile(
            weekday: weekday,
            listCount: n,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (ctx) => ReportsDayProgramsScreen(
                    weekday: weekday,
                    lists: lists,
                  ),
                ),
              );
            },
          );
        }),
      ],
    );
  }
}

class ReportsDayProgramsScreen extends StatelessWidget {
  const ReportsDayProgramsScreen({
    super.key,
    required this.weekday,
    required this.lists,
  });

  final int weekday;
  final List<AttendanceList> lists;

  @override
  Widget build(BuildContext context) {
    final dayLabel = weekdayFullLabel(weekday);
    final programs = programsWithListsForWeekday(lists, weekday);

    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(
        title: Text(dayLabel),
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: qaWeekdayAppBarGradient(weekday)),
          ),
        ),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 32),
        children: [
          if (programs.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text('No programs with lists on $dayLabel.'),
            )
          else
            ...programs.map((program) {
              final n = listCountOnWeekdayProgram(lists, weekday, program);
              return QaProgramHubTile(
                program: program,
                listCount: n,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (ctx) => ReportsProgramYearScreen(
                        weekday: weekday,
                        program: program,
                        lists: listsForWeekdayAndProgram(
                          lists,
                          weekday,
                          program,
                        ),
                      ),
                    ),
                  );
                },
              );
            }),
        ],
      ),
    );
  }
}

class ReportsProgramYearScreen extends StatelessWidget {
  const ReportsProgramYearScreen({
    super.key,
    required this.weekday,
    required this.program,
    required this.lists,
  });

  final int weekday;
  final AttendanceProgram program;
  final List<AttendanceList> lists;

  @override
  Widget build(BuildContext context) {
    final yearMap = groupListsByYearSem(lists);
    final dayLabel = weekdayFullLabel(weekday);
    final years = yearMap.keys.toList()
      ..sort((a, b) => int.tryParse(a)?.compareTo(int.tryParse(b) ?? 0) ?? a.compareTo(b));

    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(
        title: Text('$dayLabel · ${program.label} · Year'),
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: qaProgramAppBarGradient(program),
            ),
          ),
        ),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 32),
        children: [
          if (years.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No class lists here yet.'),
            )
          else
            ...years.map((year) {
              final semMap = yearMap[year] ?? {};
              var count = 0;
              for (final semLists in semMap.values) {
                count += semLists.length;
              }
              return ReportsHierarchyTile(
                title: 'Year $year',
                subtitle: count == 0
                    ? 'No lists'
                    : '$count ${count == 1 ? 'class list' : 'class lists'}',
                icon: Icons.school_rounded,
                count: count,
                accent: qaProgramAccent(program),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (ctx) => ReportsProgramSemesterScreen(
                        weekday: weekday,
                        program: program,
                        year: year,
                        semMap: semMap,
                      ),
                    ),
                  );
                },
              );
            }),
        ],
      ),
    );
  }
}

class ReportsProgramSemesterScreen extends StatelessWidget {
  const ReportsProgramSemesterScreen({
    super.key,
    required this.weekday,
    required this.program,
    required this.year,
    required this.semMap,
  });

  final int weekday;
  final AttendanceProgram program;
  final String year;
  final Map<String, List<AttendanceList>> semMap;

  @override
  Widget build(BuildContext context) {
    final dayLabel = weekdayFullLabel(weekday);
    final sems = semMap.keys.toList()
      ..sort((a, b) => int.tryParse(a)?.compareTo(int.tryParse(b) ?? 0) ?? a.compareTo(b));

    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(
        title: Text('$dayLabel · ${program.label} · Y$year · Semester'),
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: qaProgramAppBarGradient(program),
            ),
          ),
        ),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 32),
        children: [
          if (sems.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No semesters with lists for this year.'),
            )
          else
            ...sems.map((sem) {
              final classLists = semMap[sem] ?? const [];
              return ReportsHierarchyTile(
                title: 'Semester $sem',
                subtitle: classLists.isEmpty
                    ? 'No lists'
                    : '${classLists.length} ${classLists.length == 1 ? 'class' : 'classes'}',
                icon: Icons.calendar_month_rounded,
                count: classLists.length,
                accent: qaProgramAccent(program),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (ctx) => ReportsClassListsScreen(
                        weekday: weekday,
                        program: program,
                        year: year,
                        sem: sem,
                        lists: classLists,
                      ),
                    ),
                  );
                },
              );
            }),
        ],
      ),
    );
  }
}

class ReportsClassListsScreen extends StatelessWidget {
  const ReportsClassListsScreen({
    super.key,
    required this.weekday,
    required this.program,
    required this.year,
    required this.sem,
    required this.lists,
  });

  final int weekday;
  final AttendanceProgram program;
  final String year;
  final String sem;
  final List<AttendanceList> lists;

  @override
  Widget build(BuildContext context) {
    final dayLabel = weekdayFullLabel(weekday);
    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(
        title: Text('$dayLabel · ${program.label} · Y$year · Sem $sem'),
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: qaProgramAppBarGradient(program),
            ),
          ),
        ),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 32),
        children: [
          if (lists.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('No class lists here.'),
            )
          else
            ...lists.map(
              (list) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: ReportsClassListCard(list: list),
              ),
            ),
        ],
      ),
    );
  }
}

/// Summary card for one class list inside reports hierarchy.
class ReportsClassListCard extends StatelessWidget {
  const ReportsClassListCard({super.key, required this.list});

  final AttendanceList list;

  @override
  Widget build(BuildContext context) {
    final roll = buildAttendanceListRoll(list);
    final theme = Theme.of(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (ctx) => AttendanceListRollReportScreen(list: list),
            ),
          );
        },
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          decoration: BoxDecoration(
            color: AppTheme.background,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.softGrey.withValues(alpha: 0.9)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AttendanceListTitleColumn(
                            list: list,
                            titleStyle: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${list.courseSummaryLine} · ${list.time}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.print_outlined),
                      tooltip: 'Print this list',
                      onPressed: () async {
                        final plain = buildAttendanceListRollPlainText(roll);
                        await printAttendanceRollText(
                          title: attendanceListRollPrintTitle(roll),
                          plainText: plain,
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Print started or roll copied.'),
                            ),
                          );
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _MiniStat(label: '${roll.rosterCount} roster'),
                    _MiniStat(
                      label: '${roll.presentRollRows} present',
                      color: AppTheme.primary,
                    ),
                    _MiniStat(
                      label: '${roll.absentRollRows} absent',
                      color: AppTheme.error,
                    ),
                    _MiniStat(label: '${roll.sessions.length} sessions'),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: (color ?? AppTheme.primary).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: color ?? AppTheme.primary,
            ),
      ),
    );
  }
}
