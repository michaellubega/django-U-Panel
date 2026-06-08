import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/navigation/screen_refresh.dart';
import '../../core/theme/app_theme.dart';
import 'data/campus_presence_repository.dart';
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
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
                          Text(
                            'No campus check-ins recorded yet.',
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ],
                      )
                    : ListView.separated(
                        physics: kRefreshScrollPhysics,
                        padding: const EdgeInsets.all(16),
                        itemCount: _events.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, i) {
                          final e = _events[i];
                          final local = e.capturedAt.toLocal();
                          final label = e.kind == CampusPresenceKind.arrival
                              ? 'Check in'
                              : 'Check out';
                          return Card(
                            child: ListTile(
                              leading: Icon(
                                e.kind == CampusPresenceKind.arrival
                                    ? Icons.login_rounded
                                    : Icons.logout_rounded,
                                color: AppTheme.primary,
                              ),
                              title: Text(label),
                              subtitle: Text(
                                '${local.day.toString().padLeft(2, '0')}/'
                                '${local.month.toString().padLeft(2, '0')}/'
                                '${local.year} · '
                                '${local.hour.toString().padLeft(2, '0')}:'
                                '${local.minute.toString().padLeft(2, '0')}',
                              ),
                            ),
                          );
                        },
                      ),
      ),
    );
  }
}
