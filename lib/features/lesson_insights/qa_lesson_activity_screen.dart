import 'dart:async';



import 'package:flutter/material.dart';



import '../../core/navigation/screen_refresh.dart';
import '../../core/theme/app_theme.dart';

import '../attendance/data/attendance_repository.dart';

import '../attendance/roll_cell_status.dart';

import 'lesson_insights_models.dart';

import 'lesson_insights_service.dart';

import 'lesson_period_filter.dart';

import 'lecturer_period_lessons_screen.dart';

import 'qa_lecturers_on_day_screen.dart';



/// QA / admin: lesson counts per lecturer with period filter.

class QaLessonActivityScreen extends StatefulWidget {

  const QaLessonActivityScreen({super.key});



  @override

  State<QaLessonActivityScreen> createState() => _QaLessonActivityScreenState();

}



class _QaLessonActivityScreenState extends State<QaLessonActivityScreen> {

  bool _loading = true;

  LessonPeriodFilter _filter = LessonPeriodFilter.day;

  DateTime _anchor = DateTime.now();

  RollPendingContext _pending = const RollPendingContext.empty();

  List<LessonSessionInsight> _insights = const [];

  List<LecturerLessonAggregate> _aggregates = const [];

  List<LessonsPerDayBucket> _buckets = const [];



  @override

  void initState() {

    super.initState();

    unawaited(_reload());

  }



  Future<void> _reload() async {

    setState(() => _loading = true);

    try {

      await AttendanceRepository.instance.loadAll(

        force: !AttendanceRepository.instance.hasCachedStore,

        scopeToLecturerUid: AttendanceRepository.currentLecturerLoadScopeUid(),

      );

      _pending = await RollPendingContext.load();

      _insights = LessonInsightsService.insightsInPeriod(

        _pending,

        filter: _filter,

        anchor: _anchor,

      );

      _aggregates = LessonInsightsService.lecturerAggregates(_insights);

      _buckets = LessonInsightsService.lessonsPerDayBuckets(

        _insights,

        _filter,

        _anchor,

      );

    } finally {

      if (mounted) setState(() => _loading = false);

    }

  }



  void _openDay(DateTime day) {

    Navigator.of(context).push<void>(

      MaterialPageRoute<void>(

        builder: (_) => QaLecturersOnDayScreen(day: day),

      ),

    );

  }



  void _openLecturer(LecturerLessonAggregate agg) {

    Navigator.of(context).push<void>(

      MaterialPageRoute<void>(

        builder: (_) => LecturerPeriodLessonsScreen(

          lecturerName: agg.lecturerName,

          filter: _filter,

          anchor: _anchor,

        ),

      ),

    );

  }



  void _openDayLecturers() {

    Navigator.of(context).push<void>(

      MaterialPageRoute<void>(

        builder: (_) => QaLecturersOnDayScreen(day: _anchor),

      ),

    );

  }



  @override

  Widget build(BuildContext context) {

    final showDayBuckets = _filter != LessonPeriodFilter.day;



    return Scaffold(

      appBar: AppBar(

        title: const Text('Lecturer lessons'),

        actions: [

          RefreshIconButton(onRefresh: _reload),

        ],

      ),

      body: RefreshIndicator(

        onRefresh: _reload,

        child: ListView(

          physics: kRefreshScrollPhysics,

          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),

          children: [

            Text(

              'Lessons = sessions run for classes with enrolled students',

              style: Theme.of(context).textTheme.bodyMedium?.copyWith(

                    color: AppTheme.textSecondary,

                  ),

            ),

            const SizedBox(height: 16),

            LessonPeriodFilterBar(

              filter: _filter,

              anchorDate: _anchor,

              onFilterChanged: (f) {

                setState(() => _filter = f);

                unawaited(_reload());

              },

              onAnchorChanged: (d) {

                setState(() => _anchor = d);

                unawaited(_reload());

              },

            ),

            const SizedBox(height: 16),

            if (_loading)

              const Padding(

                padding: EdgeInsets.symmetric(vertical: 48),

                child: Center(child: CircularProgressIndicator()),

              )

            else ...[

              _totalLessonsCard(_insights.length),

              const SizedBox(height: 20),

              Text(

                'By lecturer',

                style: Theme.of(context).textTheme.titleSmall?.copyWith(

                      fontWeight: FontWeight.w700,

                    ),

              ),

              const SizedBox(height: 8),

              if (_aggregates.isEmpty)

                Padding(

                  padding: const EdgeInsets.symmetric(vertical: 24),

                  child: Text(

                    'No lecturer lessons in this period.',

                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(

                          color: AppTheme.textSecondary,

                        ),

                  ),

                )

              else

                for (final agg in _aggregates) _lecturerTile(agg),

              if (_filter == LessonPeriodFilter.day && _aggregates.isNotEmpty) ...[

                const SizedBox(height: 12),

                FilledButton.tonalIcon(

                  onPressed: _openDayLecturers,

                  icon: const Icon(Icons.groups_rounded),

                  label: Text(

                    'All lecturers on ${_filter.describeRange(_anchor)}',

                  ),

                ),

              ],

              if (showDayBuckets) ...[

                const SizedBox(height: 24),

                Text(

                  'Lessons per day',

                  style: Theme.of(context).textTheme.titleSmall?.copyWith(

                        fontWeight: FontWeight.w700,

                      ),

                ),

                const SizedBox(height: 8),

                ..._buckets.map((b) => _dayBucketTile(b)),

              ],

            ],

          ],

        ),

      ),

    );

  }



  Widget _totalLessonsCard(int total) {

    return Container(

      width: double.infinity,

      padding: const EdgeInsets.all(18),

      decoration: BoxDecoration(

        gradient: LinearGradient(

          colors: [

            AppTheme.primary.withValues(alpha: 0.9),

            AppTheme.secondary,

          ],

        ),

        borderRadius: BorderRadius.circular(16),

      ),

      child: Column(

        crossAxisAlignment: CrossAxisAlignment.start,

        children: [

          Text(

            'Total lessons',

            style: Theme.of(context).textTheme.labelLarge?.copyWith(

                  color: Colors.white.withValues(alpha: 0.9),

                ),

          ),

          const SizedBox(height: 4),

          Text(

            '$total',

            style: Theme.of(context).textTheme.displaySmall?.copyWith(

                  color: Colors.white,

                  fontWeight: FontWeight.w800,

                ),

          ),

          Text(

            _filter.describeRange(_anchor),

            style: Theme.of(context).textTheme.bodySmall?.copyWith(

                  color: Colors.white.withValues(alpha: 0.85),

                ),

          ),

        ],

      ),

    );

  }



  Widget _dayBucketTile(LessonsPerDayBucket bucket) {

    final label =

        '${bucket.date.day.toString().padLeft(2, '0')}/${bucket.date.month.toString().padLeft(2, '0')}';

    return Card(

      margin: const EdgeInsets.only(bottom: 8),

      child: ListTile(

        leading: CircleAvatar(

          backgroundColor: bucket.sessionCount > 0

              ? AppTheme.primary.withValues(alpha: 0.15)

              : AppTheme.softGrey,

          child: Text(

            label,

            style: TextStyle(

              fontSize: 11,

              fontWeight: FontWeight.w700,

              color: bucket.sessionCount > 0

                  ? AppTheme.primary

                  : AppTheme.textSecondary,

            ),

          ),

        ),

        title: Text(

          bucket.sessionCount == 0

              ? 'No lessons'

              : '${bucket.sessionCount} ${bucket.sessionCount == 1 ? 'lesson' : 'lessons'}',

          style: const TextStyle(fontWeight: FontWeight.w600),

        ),

        subtitle: bucket.lecturerNames.isEmpty

            ? null

            : Text(

                bucket.lecturerNames.join(' · '),

                maxLines: 2,

                overflow: TextOverflow.ellipsis,

              ),

        trailing: bucket.sessionCount > 0

            ? const Icon(Icons.chevron_right_rounded)

            : null,

        onTap: bucket.sessionCount > 0 ? () => _openDay(bucket.date) : null,

      ),

    );

  }



  Widget _lecturerTile(LecturerLessonAggregate agg) {

    return Card(

      margin: const EdgeInsets.only(bottom: 8),

      child: InkWell(

        onTap: () => _openLecturer(agg),

        borderRadius: BorderRadius.circular(AppTheme.cardRadius),

        child: Padding(

          padding: const EdgeInsets.all(14),

          child: Row(

            children: [

              Expanded(

                child: Column(

                  crossAxisAlignment: CrossAxisAlignment.start,

                  children: [

                    Text(

                      agg.lecturerName,

                      style: Theme.of(context).textTheme.titleMedium?.copyWith(

                            fontWeight: FontWeight.w700,

                          ),

                    ),

                    const SizedBox(height: 6),

                    Text(

                      '${agg.sessionCount} lessons · ${agg.classCount} classes',

                      style: Theme.of(context).textTheme.bodySmall?.copyWith(

                            color: AppTheme.textSecondary,

                          ),

                    ),

                    const SizedBox(height: 8),

                    Wrap(

                      spacing: 8,

                      children: [

                        _mini('Present', agg.totalPresent, AppTheme.success),

                        _mini('Absent', agg.totalAbsent, AppTheme.error),

                        _mini('Pending', agg.totalPending, AppTheme.warning),

                      ],

                    ),

                  ],

                ),

              ),

              const Icon(Icons.chevron_right_rounded,

                  color: AppTheme.textSecondary),

            ],

          ),

        ),

      ),

    );

  }



  Widget _mini(String label, int n, Color c) {

    return Text(

      '$label $n',

      style: TextStyle(

        fontSize: 12,

        fontWeight: FontWeight.w700,

        color: c,

      ),

    );

  }

}


