import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/theme/app_theme.dart';
import 'campus_check_in_screen.dart';
import '../../core/connectivity/app_connectivity.dart';
import 'data/campus_presence_repository.dart';
import 'data/pending_campus_presence_queue.dart';
import 'models/campus_presence_models.dart';

/// Dashboard card: today's campus status + shortcut to check in / out.
class AdminCampusPresenceCard extends StatefulWidget {
  const AdminCampusPresenceCard({super.key});

  @override
  State<AdminCampusPresenceCard> createState() =>
      _AdminCampusPresenceCardState();
}

class _AdminCampusPresenceCardState extends State<AdminCampusPresenceCard> {
  AdminCampusDayStatus? _status;
  bool _loading = true;
  int _pendingUploadCount = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    if (!AuthRepository.instance.isKiuAdmin) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    final uid = AuthRepository.instance.currentFirebaseUid;
    final status =
        await CampusPresenceRepository.instance.fetchTodayStatusForCurrentAdmin();
    final pendingCount = uid == null
        ? 0
        : await PendingCampusPresenceQueue.pendingCountForAdmin(uid);
    if (!mounted) return;
    setState(() {
      _status = status;
      _pendingUploadCount = pendingCount;
      _loading = false;
    });
  }

  void _openCheckIn() {
    Navigator.of(context)
        .push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const CampusCheckInScreen(),
          ),
        )
        .then((_) => unawaited(_refresh()));
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthRepository.instance.isKiuAdmin) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final onCampus = _status?.isOnCampus ?? false;
    final last = _status?.lastEvent;

    return Card(
      child: InkWell(
        onTap: _openCheckIn,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    onCampus ? Icons.place_rounded : Icons.place_outlined,
                    color: onCampus ? AppTheme.success : AppTheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Campus presence',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (_loading)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Icon(
                      Icons.chevron_right_rounded,
                      color: AppTheme.textSecondary.withValues(alpha: 0.7),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _loading
                    ? 'Loading today\'s status…'
                    : onCampus
                        ? 'You are checked in on campus.'
                        : 'Tap to check in when you arrive or out when you leave.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textSecondary,
                ),
              ),
              if (last != null && !_loading) ...[
                const SizedBox(height: 6),
                Text(
                  'Last: ${last.kind.label} · '
                  '${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(last.capturedAt))}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
              if (_pendingUploadCount > 0 && !_loading) ...[
                const SizedBox(height: 6),
                Text(
                  AppConnectivity.instance.isOnline
                      ? '$_pendingUploadCount campus record(s) uploading…'
                      : '$_pendingUploadCount campus record(s) saved offline — '
                          'will upload when online.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppTheme.warning,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
