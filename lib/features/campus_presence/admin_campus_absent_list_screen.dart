import 'package:flutter/material.dart';

import '../../core/navigation/screen_refresh.dart';
import '../../core/theme/app_theme.dart';
import 'data/campus_presence_repository.dart';
import 'models/campus_presence_models.dart';

/// Lists admins who have not checked in on campus today.
class AdminCampusAbsentListScreen extends StatefulWidget {
  const AdminCampusAbsentListScreen({super.key});

  @override
  State<AdminCampusAbsentListScreen> createState() =>
      _AdminCampusAbsentListScreenState();
}

class _AdminCampusAbsentListScreenState extends State<AdminCampusAbsentListScreen> {
  bool _loading = true;
  List<AdminCampusRosterEntry> _absent = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final absent =
          await CampusPresenceRepository.instance.fetchTodayAbsentAdmins();
      if (!mounted) return;
      setState(() {
        _absent = absent;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  String get _todayLabel {
    final now = DateTime.now();
    return '${now.day.toString().padLeft(2, '0')}/'
        '${now.month.toString().padLeft(2, '0')}/'
        '${now.year}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('KIU administrators absent today'),
        actions: [
          RefreshIconButton(onRefresh: _load),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? ListView(
                physics: kRefreshScrollPhysics,
                children: const [
                  SizedBox(height: 120),
                  Center(child: CircularProgressIndicator()),
                ],
              )
            : _error != null
                ? ListView(
                    physics: kRefreshScrollPhysics,
                    padding: const EdgeInsets.all(24),
                    children: [
                      Text(
                        _error!,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: AppTheme.error,
                        ),
                      ),
                    ],
                  )
                : _absent.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(24),
                        children: [
                          Icon(
                            Icons.check_circle_outline_rounded,
                            size: 48,
                            color: AppTheme.success.withValues(alpha: 0.85),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'All admins checked in',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Every admin on the roster has a campus check-in for $_todayLabel.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: AppTheme.textSecondary,
                              height: 1.4,
                            ),
                          ),
                        ],
                      )
                    : ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                        itemCount: _absent.length + 1,
                        separatorBuilder: (_, index) {
                          if (index == 0) return const SizedBox(height: 12);
                          return const SizedBox(height: 8);
                        },
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '$_todayLabel · ${_absent.length} '
                                  '${_absent.length == 1 ? 'admin' : 'admins'} '
                                  'without a campus check-in',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: AppTheme.textSecondary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            );
                          }
                          final admin = _absent[index - 1];
                          return _AbsentAdminTile(admin: admin);
                        },
                      ),
      ),
    );
  }
}

class _AbsentAdminTile extends StatelessWidget {
  const _AbsentAdminTile({required this.admin});

  final AdminCampusRosterEntry admin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitleParts = <String>[];
    if (admin.jobTitle?.isNotEmpty == true) {
      subtitleParts.add(admin.jobTitle!);
    }
    if (admin.staffNumber?.isNotEmpty == true) {
      subtitleParts.add(admin.staffNumber!);
    }
    if (admin.email?.isNotEmpty == true) {
      subtitleParts.add(admin.email!);
    }
    subtitleParts.add('No check-in today');

    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: AppTheme.warning.withValues(alpha: 0.15),
          child: const Icon(
            Icons.person_off_rounded,
            color: AppTheme.warning,
            size: 22,
          ),
        ),
        title: Text(
          admin.displayName,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          subtitleParts.join(' · '),
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppTheme.textSecondary,
          ),
        ),
      ),
    );
  }
}
