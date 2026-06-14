import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/navigation/screen_refresh.dart';
import '../../core/theme/app_theme.dart';
import 'data/campus_presence_repository.dart';
import 'kiu_admin_ui.dart';
import 'models/campus_presence_models.dart';

/// KIU administrator's own campus check-in / check-out history.
class KiuAdminCheckInRecordsScreen extends StatefulWidget {
  const KiuAdminCheckInRecordsScreen({super.key});

  @override
  State<KiuAdminCheckInRecordsScreen> createState() =>
      _KiuAdminCheckInRecordsScreenState();
}

class _KiuAdminCheckInRecordsScreenState
    extends State<KiuAdminCheckInRecordsScreen> {
  bool _loading = true;
  List<CampusPresenceEvent> _events = const [];
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
      final uid = AuthRepository.instance.currentFirebaseUid;
      if (uid == null || uid.isEmpty) {
        setState(() {
          _error = 'You must be signed in.';
          _loading = false;
        });
        return;
      }
      final events =
          await CampusPresenceRepository.instance.fetchRecentEventsForAdmin(
        adminUid: uid,
        limit: 120,
      );
      if (!mounted) return;
      setState(() {
        _events = events;
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

  Map<String, List<CampusPresenceEvent>> _groupByDate() {
    final grouped = <String, List<CampusPresenceEvent>>{};
    for (final event in _events) {
      final key = localDateKeyFor(event.capturedAt.toLocal());
      grouped.putIfAbsent(key, () => []).add(event);
    }
    final keys = grouped.keys.toList()..sort((a, b) => b.compareTo(a));
    return {for (final k in keys) k: grouped[k]!};
  }

  String _formatDateHeader(String key) {
    final parts = key.split('-');
    if (parts.length != 3) return key;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return key;
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final month = m >= 1 && m <= 12 ? months[m - 1] : parts[1];
    final today = localDateKeyFor(DateTime.now());
    if (key == today) return 'Today · $d $month $y';
    return '$d $month $y';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final grouped = _groupByDate();

    return Scaffold(
      backgroundColor: AppTheme.surface,
      appBar: AppBar(
        title: const Text('My check-in records'),
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
                    children: [Text(_error!)],
                  )
                : _events.isEmpty
                    ? ListView(
                        physics: kRefreshScrollPhysics,
                        padding: const EdgeInsets.all(24),
                        children: [
                          KiuAdminSurfaceCard(
                            child: Column(
                              children: [
                                Icon(
                                  Icons.history_rounded,
                                  size: 40,
                                  color: AppTheme.primary.withValues(alpha: 0.7),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'No campus check-ins yet',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Your arrival and departure history will appear here.',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: AppTheme.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      )
                    : ListView.builder(
                        physics: kRefreshScrollPhysics,
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        itemCount: grouped.length,
                        itemBuilder: (context, sectionIndex) {
                          final key = grouped.keys.elementAt(sectionIndex);
                          final dayEvents = grouped[key]!;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(
                                    left: 4,
                                    bottom: 10,
                                  ),
                                  child: Text(
                                    _formatDateHeader(key),
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.w800,
                                      color: AppTheme.secondary,
                                    ),
                                  ),
                                ),
                                for (var i = 0; i < dayEvents.length; i++)
                                  KiuAdminRecordTimelineTile(
                                    event: dayEvents[i],
                                    isFirst: i == 0,
                                    isLast: i == dayEvents.length - 1,
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
      ),
    );
  }
}
