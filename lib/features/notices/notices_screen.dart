import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/auth/auth_repository.dart';
import '../../core/theme/app_theme.dart';
import '../attendance/attendance_list_hierarchy.dart';
import '../attendance/data/attendance_repository.dart';
import '../attendance/models/attendance_models.dart';
import 'create_notice_screen.dart';
import 'data/notices_repository.dart';

class NoticesScreen extends StatefulWidget {
  const NoticesScreen({super.key});

  @override
  State<NoticesScreen> createState() => _NoticesScreenState();
}

class _NoticesScreenState extends State<NoticesScreen>
    with WidgetsBindingObserver {
  static const Duration _autoRefreshInterval = Duration(seconds: 30);
  Timer? _autoRefreshTimer;

  List<NoticeRecord> _notices = [];
  bool _loadingNotices = false;
  String? _noticesError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshRemoteData());
    _autoRefreshTimer = Timer.periodic(
      _autoRefreshInterval,
      (_) => unawaited(_loadNotices()),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoRefreshTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshRemoteData());
    }
  }

  /// Refreshes notices immediately. Attendance [loadAll] runs in parallel so
  /// the notices query is not blocked behind five large collection reads (the
  /// main cause of slow notice loads).
  Future<void> _refreshRemoteData() async {
    try {
      unawaited(
        AttendanceRepository.instance
            .loadAll(
              force: !AttendanceRepository.instance.hasCachedStore,
              scopeToLecturerUid:
                  AttendanceRepository.currentLecturerLoadScopeUid(),
            )
            .whenComplete(() {
          if (mounted) setState(() {});
        }),
      );
    } catch (_) {}
    await _loadNotices();
  }

  Future<void> _loadNotices() async {
    if (!mounted) return;
    final blocking = _notices.isEmpty;
    setState(() {
      if (blocking) _loadingNotices = true;
      _noticesError = null;
    });
    try {
      final list = await NoticesRepository.instance.fetchRecent(limit: 50);
      if (!mounted) return;
      final visible = _visibleNoticesFor(list);
      if (visible.isNotEmpty) {
        var newest = visible.first.createdAt;
        for (final n in visible) {
          if (n.createdAt.isAfter(newest)) newest = n.createdAt;
        }
        await NoticesRepository.instance.markSeenAt(_userSeenKey(), newest);
      }
      setState(() {
        _notices = list;
        _loadingNotices = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _notices = [];
        _noticesError = '$e';
        _loadingNotices = false;
      });
    }
  }

  bool _noticeVisibleToUser(NoticeRecord n) {
    final reg = AuthRepository.instance.currentRegistrationNumber;
    final student = reg == null || reg.trim().isEmpty
        ? null
        : AttendanceStore.findStudentByReg(reg);
    final signedListIds = <String>{
      if (student != null)
        ...AttendanceStore.signIns
            .where((s) => s.studentId == student.id)
            .map((s) => s.listId),
    };
    return noticeVisibleToUser(
      n,
      admin: _isAdminUser(),
      lecturer: _isLecturerUser(),
      lecturerListIds: _lecturerListIds(),
      studentId: student?.id,
      signedListIds: signedListIds,
    );
  }

  bool _isAdminUser() =>
      AuthRepository.instance.adminCheckDone && AuthRepository.instance.isAdmin;

  bool _isLecturerUser() {
    final auth = AuthRepository.instance;
    return auth.lecturerCheckDone && auth.isLecturer && !auth.isAdmin;
  }

  bool _canCreateNotice() => _isAdminUser() || _isLecturerUser();

  Set<String> _lecturerListIds() {
    if (!_isLecturerUser()) return const {};
    return attendanceListsForCurrentStaff().map((l) => l.id).toSet();
  }

  String _userSeenKey() {
    final uid = AuthRepository.instance.currentFirebaseUid?.trim();
    if (uid != null && uid.isNotEmpty) return uid;
    final reg = AuthRepository.instance.currentRegistrationNumber?.trim();
    if (reg != null && reg.isNotEmpty) return 'reg:${reg.toUpperCase()}';
    return 'anon';
  }

  List<NoticeRecord> _visibleNoticesFor(List<NoticeRecord> source) {
    return source.where(_noticeVisibleToUser).toList();
  }

  List<NoticeRecord> _visibleNotices() {
    return _visibleNoticesFor(_notices);
  }

  Widget _notificationsLogo() {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF16A34A), Color(0xFF15803D)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Icon(
        Icons.notifications_active_rounded,
        color: Colors.white,
        size: 22,
      ),
    );
  }

  Future<void> _openCreateNoticeScreen() async {
    final draft = await Navigator.of(context).push<NoticeCreationResult>(
      MaterialPageRoute(
        builder: (ctx) => const CreateNoticeScreen(),
      ),
    );
    if (!mounted || draft == null) return;

    var author = AuthRepository.instance.currentFullName?.trim() ?? '';
    if (author.isEmpty) {
      author = AuthRepository.instance.currentEmail?.trim() ?? '';
    }
    if (author.isEmpty) {
      author = _isLecturerUser() ? 'Lecturer' : 'Admin';
    }

    final err = await NoticesRepository.instance.publish(
      draft: draft,
      author: author,
    );
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not save notice: $err'),
          duration: const Duration(seconds: 6),
        ),
      );
      return;
    }

    await _loadNotices();

    final audienceBit = draft.audience == NoticeAudienceKind.allAppUsers
        ? 'All app users'
        : 'Class list: ${draft.targetListTitle ?? 'list'}';
    final msg = draft.scheduledFor == null
        ? (draft.sendPush
            ? 'Notice sent ($audienceBit). People subscribed to notices will get an alert.'
            : 'Notice published ($audienceBit).')
        : (draft.sendPush
            ? 'Notice scheduled ($audienceBit). An alert will go out at the scheduled time.'
            : 'Notice scheduled ($audienceBit).');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  String _formatNoticeTime(BuildContext context, NoticeRecord item) {
    final localizations = MaterialLocalizations.of(context);
    final now = DateTime.now();
    final date = item.scheduledFor ?? item.createdAt;
    final dateText = localizations.formatShortDate(date);
    final timeText = localizations.formatTimeOfDay(TimeOfDay.fromDateTime(date));

    if (item.scheduledFor != null && item.scheduledFor!.isAfter(now)) {
      return 'Scheduled: $dateText, $timeText';
    }

    final sameDay =
        now.year == date.year && now.month == date.month && now.day == date.day;
    final yesterday = now.subtract(const Duration(days: 1));
    final isYesterday = yesterday.year == date.year &&
        yesterday.month == date.month &&
        yesterday.day == date.day;

    if (sameDay) return 'Today, $timeText';
    if (isYesterday) return 'Yesterday, $timeText';
    return '$dateText, $timeText';
  }

  Future<void> _copySessionCode(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied session code $code'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.of(context).size.width < 400;
    return ListenableBuilder(
      listenable: AuthRepository.instance,
      builder: (context, _) {
        final admin = _isAdminUser();
        final canCreate = _canCreateNotice();
        final visible = _visibleNotices();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (narrow)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _notificationsLogo(),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Notices',
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    admin
                        ? 'Broadcast to all users, or target a class list'
                        : _isLecturerUser()
                            ? 'Campus notices and alerts for your class lists'
                            : 'Official notices for you and your classes.',
                    style: Theme.of(context).textTheme.bodyMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (canCreate) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _openCreateNoticeScreen,
                        icon: const Icon(Icons.add_rounded, size: 20),
                        label: const Text('Create notice'),
                      ),
                    ),
                  ],
                ],
              )
            else
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            _notificationsLogo(),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Notices',
                                style: Theme.of(context).textTheme.headlineMedium,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          admin
                              ? 'Broadcast to all users, or target a class list'
                              : _isLecturerUser()
                                  ? 'Campus notices and alerts for your class lists'
                                  : 'Official notices for you and your classes.',
                          style: Theme.of(context).textTheme.bodyMedium,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (canCreate) ...[
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: _openCreateNoticeScreen,
                      icon: const Icon(Icons.add_rounded, size: 20),
                      label: const Text('Create notice'),
                    ),
                  ],
                ],
              ),
            const SizedBox(height: 24),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text('Active notices',
                              style: Theme.of(context).textTheme.titleLarge),
                        ),
                        IconButton(
                          tooltip: 'Refresh',
                          onPressed: () => unawaited(_refreshRemoteData()),
                          icon: const Icon(Icons.refresh_rounded),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (_loadingNotices && _notices.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (_noticesError != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          _noticesError!,
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(color: AppTheme.error),
                        ),
                      )
                    else if (visible.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          admin
                              ? 'No notices yet. Create one to reach your audience.'
                              : 'No notices for you right now.',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: AppTheme.textSecondary,
                              ),
                        ),
                      )
                    else
                      for (var i = 0; i < visible.length; i++) ...[
                        _NoticeTile(
                          title: visible[i].title,
                          body: visible[i].body,
                          author: visible[i].author,
                          time: _formatNoticeTime(context, visible[i]),
                          scheduled: visible[i].scheduledFor != null,
                          audienceLine:
                              visible[i].audience == NoticeAudienceKind.allAppUsers
                                  ? 'All app users'
                                  : visible[i].audience == NoticeAudienceKind.student
                                      ? 'Personal notice'
                                      : 'Class list: ${visible[i].targetListTitle ?? 'List'}',
                          sessionCode: visible[i].sessionCode,
                          onCopyCode: visible[i].sessionCode == null ||
                                  visible[i].sessionCode!.trim().isEmpty
                              ? null
                              : () => _copySessionCode(visible[i].sessionCode!),
                          expiresAt: visible[i].expiresAt,
                          compactSessionCard:
                              (visible[i].kind ?? '').toLowerCase() ==
                                  'sessioncode',
                          missedSession: (visible[i].kind ?? '').toLowerCase() ==
                              'missedsession',
                        ),
                        if (i != visible.length - 1) const Divider(height: 24),
                      ],
                  ],
                ),
              ),
            ),
                    const SizedBox(height: 20),
                    if (admin)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.campaign_rounded,
                                      color: AppTheme.accent),
                                  const SizedBox(width: 12),
                                  Text('Send push notification',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Use the full-screen composer to broadcast to all users, '
                                'or pick an attendance class list so only students who signed into that list see it.',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _NoticeTileStyle {
  const _NoticeTileStyle({
    required this.tileBg,
    required this.tileBorder,
    required this.icon,
    required this.iconColor,
    required this.titleColor,
    required this.badgeBg,
    required this.badgeTextColor,
    required this.badgeLabel,
    required this.bodyColor,
    required this.footerColor,
    required this.codeStripBg,
    required this.codeTextColor,
  });

  final Color tileBg;
  final Color tileBorder;
  final IconData icon;
  final Color iconColor;
  final Color titleColor;
  final Color badgeBg;
  final Color badgeTextColor;
  final String badgeLabel;
  final Color bodyColor;
  final Color footerColor;
  final Color codeStripBg;
  final Color codeTextColor;

  static _NoticeTileStyle resolve({
    required bool missed,
    required bool hasCode,
    required bool scheduled,
  }) {
    if (missed) {
      return const _NoticeTileStyle(
        tileBg: Color(0xFFFFF1F2),
        tileBorder: Color(0xFFF87171),
        icon: Icons.warning_amber_rounded,
        iconColor: AppTheme.error,
        titleColor: Color(0xFF991B1B),
        badgeBg: Color(0xFFFEE2E2),
        badgeTextColor: Color(0xFFB91C1C),
        badgeLabel: 'Missed class',
        bodyColor: Color(0xFF7F1D1D),
        footerColor: Color(0xFFB91C1C),
        codeStripBg: Color(0xFFFEE2E2),
        codeTextColor: Color(0xFF991B1B),
      );
    }
    if (hasCode) {
      return const _NoticeTileStyle(
        tileBg: Color(0xFFF0FDF4),
        tileBorder: Color(0xFF86EFAC),
        icon: Icons.qr_code_2_rounded,
        iconColor: Color(0xFF166534),
        titleColor: Color(0xFF14532D),
        badgeBg: Color(0xFFDCFCE7),
        badgeTextColor: Color(0xFF14532D),
        badgeLabel: 'Session',
        bodyColor: Color(0xFF166534),
        footerColor: Color(0xFF166534),
        codeStripBg: Color(0xFFDCFCE7),
        codeTextColor: Color(0xFF166534),
      );
    }
    if (scheduled) {
      return const _NoticeTileStyle(
        tileBg: AppTheme.surface,
        tileBorder: Color(0xFFE2E8F0),
        icon: Icons.event_repeat_rounded,
        iconColor: Color(0xFF15803D),
        titleColor: Color(0xFF166534),
        badgeBg: Color(0xFFBBF7D0),
        badgeTextColor: Color(0xFF166534),
        badgeLabel: 'Scheduled',
        bodyColor: Color(0xFF166534),
        footerColor: Color(0xFF166534),
        codeStripBg: Color(0xFFDCFCE7),
        codeTextColor: Color(0xFF166534),
      );
    }
    return const _NoticeTileStyle(
      tileBg: AppTheme.surface,
      tileBorder: Color(0xFFE2E8F0),
      icon: Icons.notifications_active_rounded,
      iconColor: Color(0xFF16A34A),
      titleColor: Color(0xFF14532D),
      badgeBg: Color(0xFFDCFCE7),
      badgeTextColor: Color(0xFF14532D),
      badgeLabel: 'Announcement',
      bodyColor: Color(0xFF166534),
      footerColor: Color(0xFF166534),
      codeStripBg: Color(0xFFDCFCE7),
      codeTextColor: Color(0xFF166534),
    );
  }
}

class _NoticeTile extends StatelessWidget {
  const _NoticeTile({
    required this.title,
    required this.body,
    required this.author,
    required this.time,
    required this.scheduled,
    required this.audienceLine,
    this.sessionCode,
    this.onCopyCode,
    this.expiresAt,
    this.compactSessionCard = false,
    this.missedSession = false,
  });

  final String title;
  final String body;
  final String author;
  final String time;
  final bool scheduled;
  final String audienceLine;
  final String? sessionCode;
  final VoidCallback? onCopyCode;
  final DateTime? expiresAt;
  final bool compactSessionCard;
  final bool missedSession;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.of(context).size.width < 460;
    final code = sessionCode?.trim() ?? '';
    final hasCode = code.isNotEmpty;
    final expiryText = expiresAt == null
        ? null
        : 'Expires ${MaterialLocalizations.of(context).formatShortDate(expiresAt!)} '
            '${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(expiresAt!))}';
    final st = _NoticeTileStyle.resolve(
      missed: missedSession,
      hasCode: hasCode,
      scheduled: scheduled,
    );

    if (narrow) {
      return Container(
        padding: compactSessionCard
            ? const EdgeInsets.fromLTRB(6, 4, 6, 4)
            : const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: st.tileBg,
          borderRadius: BorderRadius.circular(compactSessionCard ? 10 : 14),
          border: Border.all(
            color: st.tileBorder,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(st.icon, size: compactSessionCard ? 15 : 20, color: st.iconColor),
                SizedBox(width: compactSessionCard ? 6 : 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: compactSessionCard ? 6 : 8,
                          vertical: compactSessionCard ? 1 : 2,
                        ),
                        decoration: BoxDecoration(
                          color: st.badgeBg,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          st.badgeLabel,
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: st.badgeTextColor,
                                fontWeight: FontWeight.w700,
                                fontSize: compactSessionCard ? 10 : null,
                              ),
                        ),
                      ),
                      SizedBox(height: compactSessionCard ? 2 : 4),
                      Text(
                        title,
                        style: Theme.of(context)
                            .textTheme
                            .titleSmall
                            ?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: st.titleColor,
                              fontSize: compactSessionCard ? 13 : null,
                            ),
                        maxLines: compactSessionCard ? 1 : 2,
                        overflow:
                            compactSessionCard ? TextOverflow.ellipsis : null,
                      ),
                      SizedBox(height: compactSessionCard ? 1 : 6),
                      if (!compactSessionCard)
                        Text(
                          audienceLine,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: AppTheme.textSecondary,
                              ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (!compactSessionCard) ...[
              SizedBox(height: compactSessionCard ? 4 : 8),
              Text(
                body,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: st.bodyColor,
                      fontSize: compactSessionCard ? 12 : null,
                    ),
                maxLines: compactSessionCard ? 1 : 3,
                overflow: compactSessionCard ? TextOverflow.ellipsis : null,
              ),
            ],
            if (hasCode) ...[
              SizedBox(height: compactSessionCard ? 4 : 8),
              Container(
                width: double.infinity,
                padding: EdgeInsets.symmetric(
                  horizontal: compactSessionCard ? 6 : 10,
                  vertical: compactSessionCard ? 4 : 7,
                ),
                decoration: BoxDecoration(
                  color: st.codeStripBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: compactSessionCard
                    ? Row(
                        children: [
                          Expanded(
                            child: Text(
                              code,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: st.codeTextColor,
                                    fontSize: 12,
                                  ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Copy code',
                            onPressed: onCopyCode,
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 36,
                            ),
                            icon: Icon(
                              Icons.copy_rounded,
                              size: 18,
                              color: st.codeTextColor,
                            ),
                          ),
                        ],
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Text(
                              code,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: st.codeTextColor,
                                  ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          OutlinedButton.icon(
                            onPressed: onCopyCode,
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                            ),
                            icon: const Icon(Icons.copy_rounded, size: 16),
                            label: const Text('Copy'),
                          ),
                        ],
                      ),
              ),
            ],
            SizedBox(height: compactSessionCard ? 4 : 8),
            if (expiryText != null && !compactSessionCard)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  expiryText,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                ),
              ),
            Text(
              compactSessionCard ? time : '$author · $time',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: st.footerColor,
                    fontSize: compactSessionCard ? 11 : null,
                  ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: st.tileBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: st.tileBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(st.icon, size: 22, color: st.iconColor),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (missedSession) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: st.badgeBg,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            st.badgeLabel,
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                  color: st.badgeTextColor,
                                  fontWeight: FontWeight.w800,
                                ),
                          ),
                        ),
                        const SizedBox(height: 6),
                      ],
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: st.titleColor,
                            ),
                      ),
                      if (compactSessionCard) const SizedBox(height: 2),
                      const SizedBox(height: 4),
                      if (!compactSessionCard)
                        Text(
                          audienceLine,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: AppTheme.textSecondary,
                              ),
                        ),
                      const SizedBox(height: 4),
                      if (!compactSessionCard)
                        Text(
                          body,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: st.bodyColor,
                                height: 1.4,
                              ),
                          maxLines: compactSessionCard ? 2 : null,
                          overflow: compactSessionCard
                              ? TextOverflow.ellipsis
                              : null,
                        ),
                      if (hasCode) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            Text(
                              code,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: st.codeTextColor,
                                  ),
                            ),
                            OutlinedButton.icon(
                              onPressed: onCopyCode,
                              icon: const Icon(Icons.copy_rounded, size: 16),
                              label: const Text('Copy code'),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 4),
                      if (expiryText != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Text(
                            expiryText,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: AppTheme.textSecondary,
                                ),
                          ),
                        ),
                      Text(
                        '$author · $time',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontSize: 12,
                              color: st.footerColor,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
