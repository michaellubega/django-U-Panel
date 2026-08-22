import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import 'data/campus_presence_repository.dart';
import 'data/pending_campus_presence_queue.dart';
import 'kiu_admin_ui.dart';
import 'models/campus_presence_models.dart';

/// Dashboard card: today's campus presence status for KIU administrators.
class AdminCampusPresenceCard extends StatefulWidget {
  const AdminCampusPresenceCard({super.key, this.onStatusChanged});

  final VoidCallback? onStatusChanged;

  @override
  State<AdminCampusPresenceCard> createState() => AdminCampusPresenceCardState();
}

class AdminCampusPresenceCardState extends State<AdminCampusPresenceCard> {
  AdminCampusDayStatus? _status;
  bool _loading = true;
  int _pendingUploadCount = 0;

  AdminCampusDayStatus? get todayStatus => _status;

  bool get canCheckIn => _status?.canCheckIn ?? false;

  bool get canCheckOut => _status?.canCheckOut ?? false;

  /// Reloads today's campus status for the dashboard card / shell refresh.
  Future<void> reload() => _refresh();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    final auth = AuthRepository.instance;
    if (!auth.isKiuAdministratorAccount && !auth.isKiuAdmin) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    final uid = AuthRepository.instance.currentUserId;
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
    widget.onStatusChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthRepository.instance;
    if (!auth.isKiuAdministratorAccount && !auth.isKiuAdmin) {
      return const SizedBox.shrink();
    }

    return KiuAdminPresenceHero(
      status: _status,
      loading: _loading,
      pendingUpload: _pendingUploadCount > 0,
      compact: true,
    );
  }
}
