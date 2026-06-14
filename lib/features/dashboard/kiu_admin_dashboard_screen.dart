import 'package:flutter/material.dart';

import '../../core/auth/auth_repository.dart';
import '../../core/navigation/app_section.dart';
import '../../core/navigation/screen_refresh.dart';
import '../../core/theme/app_theme.dart';
import '../campus_presence/admin_campus_presence_card.dart';
import '../campus_presence/campus_presence_check_actions.dart';
import '../campus_presence/kiu_admin_check_in_records_screen.dart';
import '../campus_presence/kiu_admin_ui.dart';
import '../campus_presence/models/campus_presence_models.dart';
import '../dashboard/dashboard_shared_widgets.dart';

/// Home for KIU administrators — campus check-in first, then attendance shortcuts.
class KiuAdminDashboardScreen extends StatefulWidget {
  const KiuAdminDashboardScreen({
    super.key,
    this.shellSection = AppSection.dashboard,
  });

  final AppSection shellSection;

  @override
  State<KiuAdminDashboardScreen> createState() =>
      _KiuAdminDashboardScreenState();
}

class _KiuAdminDashboardScreenState extends State<KiuAdminDashboardScreen> {
  final _campusCardKey = GlobalKey<AdminCampusPresenceCardState>();

  bool _submitting = false;
  CampusPresenceKind? _submittingKind;

  Future<void> _refreshDashboard() async {
    await _campusCardKey.currentState?.reload();
    if (mounted) setState(() {});
  }

  AdminCampusPresenceCardState? get _campusCard => _campusCardKey.currentState;

  Future<void> _performCheckIn() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _submittingKind = CampusPresenceKind.arrival;
    });
    final ok = await CampusPresenceCheckActions.perform(
      context: context,
      kind: CampusPresenceKind.arrival,
    );
    if (mounted) {
      setState(() {
        _submitting = false;
        _submittingKind = null;
      });
    }
    if (ok) await _refreshDashboard();
  }

  Future<void> _performCheckOut() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _submittingKind = CampusPresenceKind.departure;
    });
    final ok = await CampusPresenceCheckActions.perform(
      context: context,
      kind: CampusPresenceKind.departure,
    );
    if (mounted) {
      setState(() {
        _submitting = false;
        _submittingKind = null;
      });
    }
    if (ok) await _refreshDashboard();
  }

  void _openRecords() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const KiuAdminCheckInRecordsScreen(),
      ),
    );
  }

  Widget _buildBottomActions({
    required bool canCheckIn,
    required bool canCheckOut,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.background,
        border: Border(
          top: BorderSide(color: AppTheme.softGrey.withValues(alpha: 0.9)),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              KiuAdminCheckInRecordsButton(onPressed: _openRecords),
              const SizedBox(height: 10),
              const KiuAdminInfoBanner(
                message: 'Check in by 8:30 AM (later counts as Late). Check out '
                    'before midnight. Leave before 5:00 PM is early; after 5:30 PM '
                    'is overwork.',
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: KiuAdminCheckInActionButton(
                      compact: true,
                      greenWhenEnabled: true,
                      primary: true,
                      label: 'Check in',
                      subtitle: 'Arrived on campus',
                      icon: Icons.login_rounded,
                      busy: _submittingKind == CampusPresenceKind.arrival,
                      onPressed:
                          _submitting || !canCheckIn ? null : _performCheckIn,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: KiuAdminCheckInActionButton(
                      compact: true,
                      greenWhenEnabled: true,
                      primary: false,
                      label: 'Check out',
                      subtitle: 'Leaving campus for the day',
                      icon: Icons.logout_rounded,
                      busy: _submittingKind == CampusPresenceKind.departure,
                      onPressed:
                          _submitting || !canCheckOut ? null : _performCheckOut,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthRepository.instance;
    final name = auth.currentFullName?.trim();
    final jobTitle = auth.currentKiuAdminJobTitle?.trim();
    final campusCard = _campusCard;
    final canCheckIn = campusCard?.canCheckIn ?? false;
    final canCheckOut = campusCard?.canCheckOut ?? false;

    return ScreenRefreshRegistrar(
      section: widget.shellSection,
      onRefresh: _refreshDashboard,
      child: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refreshDashboard,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                children: [
                  DashboardLiveHeader(
                    title: 'KIU administrator',
                    welcomeName: name,
                    roleLabel: jobTitle?.isNotEmpty == true
                        ? jobTitle
                        : 'Campus administrator',
                    subtitle: 'Check in at campus each working day.',
                    compact: true,
                    onRefresh: _refreshDashboard,
                  ),
                  const SizedBox(height: 20),
                  AdminCampusPresenceCard(
                    key: _campusCardKey,
                    onStatusChanged: () {
                      if (mounted) setState(() {});
                    },
                  ),
                ],
              ),
            ),
          ),
          _buildBottomActions(
            canCheckIn: canCheckIn,
            canCheckOut: canCheckOut,
          ),
        ],
      ),
    );
  }
}
