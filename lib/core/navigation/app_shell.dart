import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../connectivity/app_connectivity.dart';
import '../theme/app_theme.dart';
import '../widgets/app_brand_logo.dart';
import '../constants/app_constants.dart';
import '../auth/auth_repository.dart';
import '../errors/user_facing_errors.dart';
import '../auth/user_role.dart';
import '../../features/dashboard/dashboard_screen.dart';
import '../../features/dashboard/kiu_admin_dashboard_screen.dart';
import '../../features/dashboard/lecturer_dashboard_screen.dart';
import '../../features/attendance/attendance_list_hierarchy.dart';
import '../../features/attendance/attendance_screen.dart';
import '../../features/attendance/data/attendance_offline_sync.dart';
import '../../features/attendance/data/attendance_repository.dart';
import '../../features/attendance/data/attendance_remote_list_watch.dart';
import '../../features/attendance/data/attendance_remote_record_watch.dart';
import '../../features/attendance/data/attendance_rtd_record_watch.dart';
import '../../features/attendance/student_attendance_live_sync.dart';
import '../../features/attendance/models/attendance_models.dart';
import '../../features/notices/notices_screen.dart';
import '../../features/notices/data/notices_repository.dart';
import '../../features/reports/reports_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/settings/lecturer_settings_screen.dart';
import '../../features/settings/kiu_admin_settings_screen.dart';
import '../../features/settings/staff_admin_hub_screen.dart';
import '../../features/campus_presence/update_campus_location_screen.dart';
import '../../features/campus_presence/campus_presence_log_screen.dart';
import '../../features/lesson_insights/qa_lesson_activity_screen.dart';
import '../push/push_controller.dart';
import '../location/student_location_priming.dart';
import '../offline/pending_offline_coordinator.dart';
import '../notifications/notification_maintenance_coordinator.dart';
import '../platform/web_fast_boot.dart';
import '../widgets/web_app_loading_screen.dart';
import 'app_section.dart';
import 'instant_page_transitions.dart';
import 'screen_refresh.dart';

/// Desktop: fixed left sidebar + top bar + main content.
/// Mobile: bottom nav + top bar + main content.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  late final ValueNotifier<AppSection> _currentSection;
  final _refreshHost = ScreenRefreshHost();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _shellContentNavKey = GlobalKey<NavigatorState>();
  Timer? _noticesCounterTimer;
  int _unseenNotices = 0;
  bool _wasOnline = true;
  bool _roleRulesBannerDismissed = false;
  bool _authProfileBannerDismissed = false;
  String? _lastAuthProfileError;
  bool _lastRoleRulesDenied = false;
  String? _lastStudentAttendanceRegLoaded;
  bool _studentAttendanceReloadInFlight = false;
  DateTime? _lastStudentAttendanceReloadAt;
  bool _staffAttendanceBootstrapAttempted = false;
  Timer? _authRepoSideEffectsDebounce;
  Timer? _staffAttendanceRefreshTimer;
  static const Duration _staffAttendanceRefreshInterval = Duration(seconds: 45);
  UserRole? _sectionCacheRole;
  final Map<AppSection, Widget> _sectionWidgets = {};
  final Set<AppSection> _builtSections = {};
  bool _navPrewarmScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final auth = AuthRepository.instance;
    _currentSection = ValueNotifier(
      auth.roleCheckDone
          ? _defaultSectionForRole(auth.resolvedRole)
          : (auth.isStaffAuthIdentity || auth.isSyntheticStaffAuthIdentity)
              ? AppSection.dashboard
              : auth.isStudentAuthIdentity
                  ? AppSection.attendance
                  : AppSection.dashboard,
    );
    AuthRepository.instance.addListener(_onAuthRepo);
    AppConnectivity.instance.addListener(_onConnectivityChanged);
    _wasOnline = AppConnectivity.instance.isOnline;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _builtSections.add(_currentSection.value);
      _applyDefaultSectionForRole();
      _scheduleNavSectionPrewarm();
      unawaited(AttendanceRepository.instance.warmFromLocalSnapshot());
      unawaited(_bootstrapAttendanceStore());
      WebFastBoot.afterFirstFrame(() {
        unawaited(PushController.instance.initialize());
        unawaited(PushController.instance.syncTopicsForCurrentUser());
        unawaited(AttendanceRemoteListWatch.instance.start());
        unawaited(AttendanceRemoteRecordWatch.instance.start());
        unawaited(StudentLocationPriming.instance.primeOnAppOpen());
        _startStaffAttendanceRefreshTimer();
        Future<void>.delayed(const Duration(milliseconds: 100), () {
          if (!mounted) return;
          PendingOfflineCoordinator.instance.start();
        });
        unawaited(NotificationMaintenanceCoordinator.onSignedIn());
        unawaited(_refreshUnseenNotices());
      });
    });
    _noticesCounterTimer = Timer.periodic(
        const Duration(seconds: 60), (_) => _refreshUnseenNotices());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PendingOfflineCoordinator.instance.stop();
    _authRepoSideEffectsDebounce?.cancel();
    _staffAttendanceRefreshTimer?.cancel();
    _currentSection.dispose();
    _refreshHost.dispose();
    AuthRepository.instance.removeListener(_onAuthRepo);
    AppConnectivity.instance.removeListener(_onConnectivityChanged);
    _noticesCounterTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    PendingOfflineCoordinator.instance.onLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      unawaited(AppConnectivity.instance.probeNow());
      unawaited(PushController.instance.syncTopicsForCurrentUser());
      unawaited(_bootstrapAttendanceStore());
      unawaited(_refreshStaffAttendanceIfNeeded(force: true));
      unawaited(StudentLocationPriming.instance.primeOnAppOpen());
    }
  }

  Future<void> _warmAttendanceForOffline() async {
    final auth = AuthRepository.instance;
    await AttendanceRepository.instance.warmFromLocalSnapshot();
    for (var i = 0; i < 12 && !auth.roleCheckDone; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!auth.roleCheckDone) return;
    if (auth.resolvedRole == UserRole.student) {
      unawaited(
        AttendanceRepository.instance.loadStudentAttendanceForProfile(
          force: false,
        ),
      );
      return;
    }
    if (AttendanceRepository.instance.hasCachedStore) {
      unawaited(AttendanceRepository.instance.syncFromRemoteIfNeeded());
      return;
    }
    await AttendanceRepository.instance.syncFromRemoteIfNeeded();
  }

  Future<void> _bootstrapAttendanceStore() async {
    if (mounted) _precacheCurrentSectionWidget();
    try {
      await AttendanceRepository.instance.warmFromLocalSnapshot();
      final auth = AuthRepository.instance;
      final student = auth.roleCheckDone
          ? auth.resolvedRole == UserRole.student
          : auth.isLikelyStudent;
      if (student) {
        unawaited(StudentAttendanceLiveSync.activate());
        unawaited(
          AttendanceRepository.instance.loadStudentAttendanceForProfile(
            force: false,
          ),
        );
      } else if (AppConnectivity.instance.isOnline) {
        unawaited(AttendanceRepository.instance.loadAttendanceListsFirst());
        unawaited(_backgroundSyncAfterWarm());
      } else if (!AttendanceRepository.instance.hasCachedStore) {
        await _warmAttendanceForOffline();
      }
    } catch (_) {}
  }

  Future<void> _backgroundSyncAfterWarm() async {
    try {
      unawaited(AttendanceOfflineSync.drainAllInOrder());
      await AttendanceRepository.instance.bootstrapLoadIfNeeded();
    } catch (_) {}
  }

  /// Build only the active tab so login does not mount every screen at once.
  void _precacheCurrentSectionWidget() {
    final role = _resolvedRole();
    _ensureSectionCacheForRole(role);
    _sectionWidget(_currentSection.value, role);
  }

  /// Upload pending offline work first, then one [loadAll] inside the drain pipeline.
  Future<void> _onConnectivityRestored() async {
    unawaited(AuthRepository.instance.resumeStudentRegistrationLinkIfOnline());
    await AttendanceOfflineSync.drainSessionValidationFirst();
    unawaited(AttendanceOfflineSync.drainAllInOrder());
  }

  void _onConnectivityChanged() {
    if (!mounted) return;
    final connectivity = AppConnectivity.instance;
    final nowOnline = connectivity.isOnline || connectivity.apiReachable;
    if (nowOnline && !_wasOnline) {
      unawaited(_onConnectivityRestored());
      unawaited(_refreshUnseenNotices());
    } else if (!nowOnline && _wasOnline) {
      unawaited(
        AttendanceRepository.instance.loadStudentAttendanceForProfile(
          force: false,
        ),
      );
    }
    _wasOnline = nowOnline;
  }

  UserRole _resolvedRole() {
    return AuthRepository.instance.resolvedRole;
  }

  AppSection _defaultSectionForRole(UserRole role) {
    switch (role) {
      case UserRole.admin:
      case UserRole.qaStaff:
      case UserRole.lecturer:
      case UserRole.kiuAdmin:
        return AppSection.dashboard;
      case UserRole.student:
        return AppSection.attendance;
    }
  }

  void _applyDefaultSectionForRole() {
    if (!mounted) return;
    final auth = AuthRepository.instance;
    if (!auth.roleCheckDone) return;
    final role = auth.resolvedRole;
    final allowed = _navSectionsForRole(role);
    if (!allowed.contains(_currentSection.value)) {
      _currentSection.value = _defaultSectionForRole(role);
    }
  }

  void _onAuthRepo() {
    if (!mounted) return;
    if (!AuthRepository.instance.isLoggedIn) return;
    final role = _resolvedRole();
    final allowed = _navSectionsForRole(role);
    final roleChanged = _sectionCacheRole != role;
    final roleDenied = AuthRepository.instance.apiRoleCheckDenied;
    if (roleChanged) {
      _sectionWidgets.clear();
      _builtSections
        ..clear()
        ..add(_currentSection.value);
      _sectionCacheRole = role;
      _navPrewarmScheduled = false;
      _scheduleNavSectionPrewarm();
    }
    if (!allowed.contains(_currentSection.value)) {
      _currentSection.value = _defaultSectionForRole(role);
    }
    if (roleChanged || AuthRepository.instance.roleCheckDone) {
      _applyDefaultSectionForRole();
    }
    if (roleChanged || roleDenied != _lastRoleRulesDenied) {
      _lastRoleRulesDenied = roleDenied;
      setState(() {});
      _precacheCurrentSectionWidget();
    }
    final profileErr =
        AuthRepository.instance.authFormErrorMessage?.trim();
    if (profileErr != null &&
        profileErr.isNotEmpty &&
        profileErr != _lastAuthProfileError) {
      _lastAuthProfileError = profileErr;
      _authProfileBannerDismissed = false;
      setState(() {});
    } else if ((profileErr == null || profileErr.isEmpty) &&
        _lastAuthProfileError != null) {
      _lastAuthProfileError = null;
      setState(() {});
    }
    _authRepoSideEffectsDebounce?.cancel();
    _authRepoSideEffectsDebounce = Timer(const Duration(milliseconds: 200), () {
      if (!mounted || !AuthRepository.instance.isLoggedIn) return;
      _refreshUnseenNotices();
      unawaited(PushController.instance.syncTopicsForCurrentUser());
      unawaited(AttendanceRemoteListWatch.instance.start());
      unawaited(AttendanceRemoteRecordWatch.instance.start());
      if (roleChanged) {
        unawaited(StudentLocationPriming.instance.primeOnAppOpen());
      }
      _reloadStudentAttendanceWhenRegistrationReady();
      _reloadStaffAttendanceWhenRoleReady();
      _startStaffAttendanceRefreshTimer();
    });
  }

  /// First bootstrap can run before profile hydration finishes — reload when reg appears.
  void _reloadStudentAttendanceWhenRegistrationReady() {
    final auth = AuthRepository.instance;
    if (!auth.isLoggedIn || auth.needsEmailVerification) return;
    final student = auth.roleCheckDone
        ? auth.resolvedRole == UserRole.student
        : auth.isLikelyStudent;
    if (!student) return;
    final reg = auth.currentRegistrationNumber?.trim();
    if (reg == null || reg.isEmpty) return;
    final repo = AttendanceRepository.instance;
    final hasData = repo.studentProfileHasLocalData(reg);
    if (reg == _lastStudentAttendanceRegLoaded && hasData) {
      return;
    }
    if (_studentAttendanceReloadInFlight) return;
    final lastAt = _lastStudentAttendanceReloadAt;
    if (lastAt != null &&
        DateTime.now().difference(lastAt) < const Duration(seconds: 8)) {
      return;
    }
    _lastStudentAttendanceRegLoaded = reg;
    _studentAttendanceReloadInFlight = true;
    _lastStudentAttendanceReloadAt = DateTime.now();
    unawaited(() async {
      try {
        await repo.loadStudentAttendanceForProfile(force: !hasData);
      } finally {
        _studentAttendanceReloadInFlight = false;
      }
    }());
  }

  /// Staff bootstrap can run before Firestore role reads finish on a new device.
  void _reloadStaffAttendanceWhenRoleReady() {
    final auth = AuthRepository.instance;
    if (!auth.isLoggedIn || auth.needsEmailVerification) return;
    if (!auth.roleCheckDone) return;
    switch (auth.resolvedRole) {
      case UserRole.student:
        return;
      case UserRole.admin:
      case UserRole.qaStaff:
      case UserRole.lecturer:
      case UserRole.kiuAdmin:
        break;
    }
    if (!AppConnectivity.instance.isOnline) return;
    final repo = AttendanceRepository.instance;
    if (repo.hasCachedStore || _staffAttendanceBootstrapAttempted) return;
    _staffAttendanceBootstrapAttempted = true;
    unawaited(repo.bootstrapLoadIfNeeded(force: true));
    unawaited(repo.syncStaffAttendanceForeground(force: !repo.hasCachedStore));
  }

  void _startStaffAttendanceRefreshTimer() {
    final auth = AuthRepository.instance;
    if (!auth.isLoggedIn || !auth.showsStaffAttendanceUi) {
      _staffAttendanceRefreshTimer?.cancel();
      _staffAttendanceRefreshTimer = null;
      return;
    }
    _staffAttendanceRefreshTimer ??= Timer.periodic(
      _staffAttendanceRefreshInterval,
      (_) => unawaited(_refreshStaffAttendanceIfNeeded()),
    );
  }

  Future<void> _refreshStaffAttendanceIfNeeded({bool force = false}) async {
    final auth = AuthRepository.instance;
    if (!auth.isLoggedIn || auth.needsEmailVerification) return;
    if (!auth.showsStaffAttendanceUi) return;
    if (!AppConnectivity.instance.isOnline) return;
    await AttendanceRepository.instance.syncStaffAttendanceForeground(force: force);
  }

  void _ensureSectionCacheForRole(UserRole role) {
    if (_sectionCacheRole == role) return;
    _sectionWidgets.clear();
    _builtSections
      ..clear()
      ..add(_currentSection.value);
    _sectionCacheRole = role;
    _navPrewarmScheduled = false;
  }

  /// Mounts inactive tabs after first paint so switching feels instant.
  void _scheduleNavSectionPrewarm() {
    if (_navPrewarmScheduled) return;
    _navPrewarmScheduled = true;
    WebFastBoot.afterFirstFrame(() {
      Future<void>.delayed(const Duration(milliseconds: 500), () {
        if (!mounted) return;
        _prewarmNavSections();
      });
    });
  }

  void _prewarmNavSections() {
    final auth = AuthRepository.instance;
    if (!auth.roleCheckDone) {
      _navPrewarmScheduled = false;
      return;
    }
    final role = _resolvedRole();
    // Avoid mounting desktop-only / heavy tabs (e.g. Reports) on phones.
    final sections =
        _isDesktop ? _navSectionsForRole(role) : _mobileBottomSections();
    var changed = false;
    for (final s in sections) {
      if (_builtSections.add(s)) changed = true;
      _sectionWidget(s, role);
    }
    if (changed && mounted) setState(() {});
  }

  String _noticeUserKey() {
    final uid = AuthRepository.instance.currentUserId?.trim();
    if (uid != null && uid.isNotEmpty) return uid;
    final reg = AuthRepository.instance.currentRegistrationNumber?.trim();
    if (reg != null && reg.isNotEmpty) return 'reg:${reg.toUpperCase()}';
    return 'anon';
  }

  Future<void> _markNoticesSeenNow() async {
    final admin = _isShellAdmin();
    final lecturer = _isShellLecturer();
    final lecturerListIds = lecturer
        ? attendanceListsForCurrentStaff().map((l) => l.id).toSet()
        : const <String>{};
    final reg = AuthRepository.instance.currentRegistrationNumber?.trim();
    final student = reg == null || reg.isEmpty
        ? null
        : AttendanceStore.findStudentByReg(reg);
    final signedListIds = <String>{
      if (student != null)
        ...AttendanceStore.signIns
            .where((s) => s.studentId == student.id)
            .map((s) => s.listId),
    };
    try {
      final recent = await NoticesRepository.instance.fetchRecent();
      NoticeRecord? newestVisible;
      for (final n in recent) {
        final visible = noticeVisibleToUser(
          n,
          admin: admin,
          kiuAdmin: AuthRepository.instance.isKiuAdmin,
          lecturer: lecturer,
          lecturerListIds: lecturerListIds,
          lecturerUserId: AuthRepository.instance.currentUserId,
          studentId: student?.id,
          signedListIds: signedListIds,
        );
        if (!visible) continue;
        if (!noticeIsLive(n)) continue;
        if (newestVisible == null ||
            noticeEffectiveAt(n).isAfter(noticeEffectiveAt(newestVisible))) {
          newestVisible = n;
        }
      }
      if (newestVisible != null) {
        await NoticesRepository.instance
            .markSeenAt(_noticeUserKey(), noticeEffectiveAt(newestVisible));
      }
      if (mounted) {
        setState(() => _unseenNotices = 0);
      }
    } catch (_) {}
  }

  Future<void> _refreshUnseenNotices() async {
    final admin = _isShellAdmin();
    final lecturer = _isShellLecturer();
    final lecturerListIds = lecturer
        ? attendanceListsForCurrentStaff().map((l) => l.id).toSet()
        : const <String>{};
    final reg = AuthRepository.instance.currentRegistrationNumber?.trim();
    final student = reg == null || reg.isEmpty
        ? null
        : AttendanceStore.findStudentByReg(reg);
    final signedListIds = <String>{
      if (student != null)
        ...AttendanceStore.signIns
            .where((s) => s.studentId == student.id)
            .map((s) => s.listId),
    };
    try {
      final c = await NoticesRepository.instance.unseenCountForUser(
        userKey: _noticeUserKey(),
        admin: admin,
        kiuAdmin: AuthRepository.instance.isKiuAdmin,
        lecturer: lecturer,
        lecturerListIds: lecturerListIds,
        lecturerUserId: AuthRepository.instance.currentUserId,
        studentId: student?.id,
        signedListIds: signedListIds,
      );
      if (mounted) setState(() => _unseenNotices = c);
    } catch (_) {}
  }

  void _setSection(AppSection s) {
    _popShellContentToRoot();
    if (_currentSection.value == s) {
      if (s == AppSection.settings) {
        unawaited(_refreshHost.refresh(s));
      }
      return;
    }
    _builtSections.add(s);
    _currentSection.value = s;
    if (s == AppSection.notices) {
      unawaited(_markNoticesSeenNow());
    }
  }

  void _popShellContentToRoot() {
    _shellContentNavKey.currentState
        ?.popUntil((route) => route.isFirst);
  }

  bool _shouldCloseDrawer(bool closeDrawer) => closeDrawer && !_isDesktop;

  Future<void> _pushShellContentRoute(Widget screen) {
    final nav = _shellContentNavKey.currentState;
    if (nav == null) return Future.value();
    return nav.push<void>(
      UPanelPageRoute<void>(builder: (_) => screen),
    );
  }

  void _openStaffAdminHub(BuildContext context, {required bool closeDrawer}) {
    if (_shouldCloseDrawer(closeDrawer)) {
      Navigator.of(context).pop();
    }
    unawaited(_pushShellContentRoute(const StaffAdminHubScreen()));
  }

  void _pushShellRoute(BuildContext context, {required bool closeDrawer, required Widget screen}) {
    if (_shouldCloseDrawer(closeDrawer)) {
      Navigator.of(context).pop();
    }
    unawaited(_pushShellContentRoute(screen));
  }

  Widget _desktopSidebarLink({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(icon, size: 22, color: Colors.white70),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _desktopSidebarAdminExtras(BuildContext context) {
    if (!_isShellAdmin()) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Divider(color: Colors.white.withValues(alpha: 0.2), height: 1),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(
            'More',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
              color: Colors.white.withValues(alpha: 0.45),
            ),
          ),
        ),
        if (_isShellQaStaff())
          _desktopSidebarLink(
            icon: Icons.my_location_rounded,
            label: 'Campus check-in area',
            onTap: () => _pushShellRoute(
              context,
              closeDrawer: false,
              screen: const UpdateCampusLocationScreen(),
            ),
          ),
        _desktopSidebarLink(
          icon: Icons.history_edu_rounded,
          label: 'Lecturer lessons',
          onTap: () => _pushShellRoute(
            context,
            closeDrawer: false,
            screen: const QaLessonActivityScreen(),
          ),
        ),
        _desktopSidebarLink(
          icon: Icons.place_rounded,
          label: 'KIU administrator presence',
          onTap: () => _pushShellRoute(
            context,
            closeDrawer: false,
            screen: const CampusPresenceLogScreen(),
          ),
        ),
      ],
    );
  }

  List<Widget> _drawerAdminExtraTiles(BuildContext context) {
    if (!_isShellAdmin()) return const [];
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
        child: Text(
          'More',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.6,
            color: Colors.white.withValues(alpha: 0.45),
          ),
        ),
      ),
      if (_isShellQaStaff())
        ListTile(
          leading: const Icon(Icons.my_location_rounded,
              color: Colors.white70, size: 22),
          title: const Text(
            'Campus check-in area',
            style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w500),
          ),
          onTap: () => _pushShellRoute(
            context,
            closeDrawer: true,
            screen: const UpdateCampusLocationScreen(),
          ),
        ),
      ListTile(
        leading: const Icon(Icons.history_edu_rounded,
            color: Colors.white70, size: 22),
        title: const Text(
          'Lecturer lessons',
          style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w500),
        ),
        onTap: () => _pushShellRoute(
          context,
          closeDrawer: true,
          screen: const QaLessonActivityScreen(),
        ),
      ),
      ListTile(
        leading:
            const Icon(Icons.place_rounded, color: Colors.white70, size: 22),
        title: const Text(
          'KIU administrator presence',
          style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w500),
        ),
        onTap: () => _pushShellRoute(
          context,
          closeDrawer: true,
          screen: const CampusPresenceLogScreen(),
        ),
      ),
    ];
  }

  Widget _desktopNoticeBadge() {
    if (_unseenNotices <= 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          _unseenNotices > 99 ? '99+' : '$_unseenNotices',
          style: const TextStyle(
            color: AppTheme.primary,
            fontWeight: FontWeight.w700,
            fontSize: 11,
          ),
        ),
      ),
    );
  }

  Widget _mobileIconWithNoticeBadge(AppSection s, bool selected) {
    final icon = Icon(
      s.icon,
      size: 22,
      color: selected ? AppTheme.primary : AppTheme.textSecondary,
    );
    if (s != AppSection.notices || _unseenNotices <= 0) return icon;
    return Badge(
      label: Text(_unseenNotices > 99 ? '99+' : '$_unseenNotices'),
      child: icon,
    );
  }

  bool _isShellAdmin() =>
      AuthRepository.instance.adminCheckDone && AuthRepository.instance.isAdmin;

  bool _isShellQaStaff() =>
      AuthRepository.instance.adminCheckDone && AuthRepository.instance.isQaStaff;

  bool _isShellLecturer() {
    final auth = AuthRepository.instance;
    return auth.lecturerCheckDone && auth.isLecturer && !auth.isAdmin;
  }

  List<AppSection> _navSectionsForRole(UserRole role) {
    switch (role) {
      case UserRole.admin:
      case UserRole.qaStaff:
        return const [
          AppSection.dashboard,
          AppSection.attendance,
          AppSection.notices,
          AppSection.reports,
          AppSection.settings,
        ];
      case UserRole.lecturer:
        return const [
          AppSection.dashboard,
          AppSection.attendance,
          AppSection.notices,
          AppSection.settings,
        ];
      case UserRole.kiuAdmin:
        return const [
          AppSection.dashboard,
          AppSection.notices,
          AppSection.settings,
        ];
      case UserRole.student:
        return const [
          AppSection.attendance,
          AppSection.notices,
          AppSection.settings,
        ];
    }
  }

  List<AppSection> _navSections() => _navSectionsForRole(_resolvedRole());

  List<AppSection> _mobileBottomSections() {
    switch (_resolvedRole()) {
      case UserRole.admin:
      case UserRole.qaStaff:
        return const [
          AppSection.dashboard,
          AppSection.attendance,
          AppSection.notices,
          AppSection.settings,
        ];
      case UserRole.lecturer:
        return const [
          AppSection.dashboard,
          AppSection.attendance,
          AppSection.notices,
          AppSection.settings,
        ];
      case UserRole.kiuAdmin:
        return const [
          AppSection.dashboard,
          AppSection.notices,
          AppSection.settings,
        ];
      case UserRole.student:
        return const [
          AppSection.attendance,
          AppSection.notices,
          AppSection.settings,
        ];
    }
  }

  String _mobileLabel(AppSection s) {
    switch (s) {
      case AppSection.dashboard:
        return _resolvedRole() == UserRole.lecturer ||
                _resolvedRole() == UserRole.kiuAdmin
            ? 'Home'
            : 'Dashboard';
      case AppSection.settings:
        return 'Profile';
      default:
        return s.label;
    }
  }

  bool get _isDesktop {
    final w = MediaQuery.of(context).size.width;
    return w >= AppConstants.desktopBreakpoint;
  }

  Widget _createSectionWidget(AppSection section, UserRole role) {
    switch (section) {
      case AppSection.dashboard:
        switch (role) {
          case UserRole.admin:
          case UserRole.qaStaff:
            return DashboardScreen(shellSection: section);
          case UserRole.lecturer:
            return LecturerDashboardScreen(shellSection: section);
          case UserRole.kiuAdmin:
            return KiuAdminDashboardScreen(shellSection: section);
          case UserRole.student:
            return AttendanceScreen(shellSection: section);
        }
      case AppSection.attendance:
        return AttendanceScreen(shellSection: section);
      case AppSection.notices:
        return NoticesScreen(shellSection: section);
      case AppSection.reports:
        if (!role.hasStaffOperationalAccess) {
          return const _StaffUnavailablePlaceholder(
            title: 'Reports',
            message: 'Reports are available to QA staff only.',
          );
        }
        return ReportsScreen(shellSection: section);
      case AppSection.settings:
        switch (role) {
          case UserRole.lecturer:
            return LecturerSettingsScreen(shellSection: section);
          case UserRole.kiuAdmin:
            return KiuAdminSettingsScreen(shellSection: section);
          case UserRole.admin:
          case UserRole.qaStaff:
          case UserRole.student:
            return SettingsScreen(shellSection: section);
        }
    }
  }

  Widget _sectionWidget(AppSection section, UserRole role) {
    return _sectionWidgets.putIfAbsent(
      section,
      () => _createSectionWidget(section, role),
    );
  }

  /// Lazily mounts tabs, then keeps them alive so switching back does not replay
  /// heavy [initState] / loading work. All form factors use [IndexedStack] for
  /// instant tab changes (mobile, web, and Windows).
  Widget _buildSectionStack() {
    final role = _resolvedRole();
    _ensureSectionCacheForRole(role);
    final sections = _navSectionsForRole(role);
    return _ShellSectionStack(
      currentSection: _currentSection,
      role: role,
      sections: sections,
      builtSections: _builtSections,
      sectionFor: _sectionWidget,
    );
  }

  Widget _buildMainPane({required EdgeInsets padding}) {
    return Padding(
      padding: padding,
      child: RepaintBoundary(
        child: _buildSectionStack(),
      ),
    );
  }

  /// Keeps pushed sidebar screens inside the main pane so the sidebar stays visible
  /// on desktop (and the mobile drawer can close without popping the whole shell).
  Widget _buildShellContentNavigator({required EdgeInsets padding}) {
    return Navigator(
      key: _shellContentNavKey,
      onGenerateRoute: (settings) {
        return UPanelPageRoute<void>(
          settings: settings,
          builder: (_) => _buildMainPane(padding: padding),
        );
      },
    );
  }

  Widget _buildSidebar() {
    return Container(
      width: 240,
      decoration: BoxDecoration(
        color: AppTheme.primary,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 8,
            offset: const Offset(2, 0),
          ),
        ],
      ),
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  _brandLogoBox(size: 36, radius: 10, iconSize: 22),
                  const SizedBox(width: 12),
                  Text(
                    AppConstants.appName,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                      letterSpacing: -0.3,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            ValueListenableBuilder<AppSection>(
              valueListenable: _currentSection,
              builder: (context, current, _) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _navSections().map((s) {
                    final selected = current == s;
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 2),
                      child: Material(
                        color: selected
                            ? Colors.white.withOpacity(0.12)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(10),
                        child: InkWell(
                          onTap: () => _setSection(s),
                          borderRadius: BorderRadius.circular(10),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                            child: Row(
                              children: [
                                Icon(s.icon,
                                    size: 22,
                                    color: selected
                                        ? Colors.white
                                        : Colors.white70),
                                if (s == AppSection.notices)
                                  _desktopNoticeBadge(),
                                const SizedBox(width: 12),
                                Text(
                                  s.label,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: selected
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                    color: selected
                                        ? Colors.white
                                        : Colors.white70,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
            _desktopSidebarAdminExtras(context),
            if (_isShellAdmin()) ...[
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Divider(
                    color: Colors.white.withValues(alpha: 0.2), height: 1),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                child: Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    onTap: () => _openStaffAdminHub(context, closeDrawer: false),
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      child: Row(
                        children: [
                          Icon(Icons.groups_rounded,
                              size: 22, color: Colors.white70),
                          const SizedBox(width: 12),
                          Text(
                            'Staff & accounts',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _avatarLetter() {
    final name = AuthRepository.instance.currentFullName;
    if (name != null && name.trim().isNotEmpty) {
      return name.trim().substring(0, 1).toUpperCase();
    }
    final email = AuthRepository.instance.currentEmail;
    if (email != null && email.isNotEmpty) {
      return email.substring(0, 1).toUpperCase();
    }
    final reg = AuthRepository.instance.currentRegistrationNumber;
    if (reg == null || reg.isEmpty) return 'U';
    return reg.substring(0, 1).toUpperCase();
  }

  Widget _buildTopBar() {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: _isDesktop ? Colors.white : AppTheme.primary,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          if (!_isDesktop)
            IconButton(
              icon: const Icon(Icons.menu_rounded, color: Colors.white),
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            ),
          if (_isDesktop) ...[
            Expanded(
              child: Container(
                height: 42,
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.softGrey),
                ),
                child: TextField(
                  decoration: InputDecoration(
                    hintText: 'Search...',
                    prefixIcon: Icon(Icons.search_rounded,
                        size: 20, color: AppTheme.textSecondary),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ShellRefreshButton(iconColor: AppTheme.textPrimary),
            const SizedBox(width: 8),
            IconButton(
              icon: Icon(Icons.notifications_outlined,
                  color: AppTheme.textPrimary),
              onPressed: () {},
            ),
            const SizedBox(width: 8),
            CircleAvatar(
              radius: 18,
              backgroundColor: AppTheme.accent,
              child: Text(_avatarLetter(),
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          ] else ...[
            const Spacer(),
            ShellRefreshButton(iconColor: Colors.white),
            IconButton(
              icon:
                  const Icon(Icons.notifications_outlined, color: Colors.white),
              onPressed: () {},
            ),
            const SizedBox(width: 8),
            CircleAvatar(
              radius: 18,
              backgroundColor: AppTheme.accent,
              child: Text(_avatarLetter(),
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBottomNav() {
    final sections = _mobileBottomSections();

    return RepaintBoundary(
      child: Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 12,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: ValueListenableBuilder<AppSection>(
            valueListenable: _currentSection,
            builder: (context, current, _) {
              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: sections.map((s) {
                  final selected = current == s;
                  return Expanded(
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => _setSection(s),
                        borderRadius: BorderRadius.circular(12),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _mobileIconWithNoticeBadge(s, selected),
                            const SizedBox(height: 2),
                            Text(
                              _mobileLabel(s),
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: selected
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: selected
                                    ? AppTheme.primary
                                    : AppTheme.textSecondary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ),
      ),
    ),
    );
  }

  Widget _connectivityBanner({required bool mobile}) {
    if (!AppConnectivity.instance.initialized) {
      return const SizedBox.shrink();
    }
    final online = AppConnectivity.instance.isOnline;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: mobile ? 12 : 16,
        vertical: mobile ? 8 : 10,
      ),
      color: online ? AppTheme.success : AppTheme.warning,
      child: Row(
        children: [
          Icon(
            online ? Icons.wifi_rounded : Icons.wifi_off_rounded,
            color: Colors.white,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              online ? 'You are online' : 'You are offline',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _brandLogoBox({
    required double size,
    required double radius,
    required double iconSize,
  }) {
    return AppBrandLogo(
      size: size,
      borderRadius: radius,
      fallbackIconSize: iconSize,
    );
  }

  bool _awaitingStaffRoleHydration() {
    final auth = AuthRepository.instance;
    if (!auth.isLoggedIn || auth.roleCheckDone) return false;
    return auth.isSyntheticStaffAuthIdentity || auth.isStaffAuthIdentity;
  }

  @override
  Widget build(BuildContext context) {
    if (_awaitingStaffRoleHydration()) {
      return const WebAppLoadingScreen(message: 'Loading your account…');
    }
    return _buildShell(context);
  }

  Widget _shellStatusBanners({required bool mobile}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _authProfileLinkBanner(),
        _roleRulesBanner(),
        ListenableBuilder(
          listenable: AppConnectivity.instance,
          builder: (context, _) {
            return _connectivityBanner(mobile: mobile);
          },
        ),
      ],
    );
  }

  Widget _authProfileLinkBanner() {
    final msg = AuthRepository.instance.authFormErrorMessage?.trim();
    if (msg == null || msg.isEmpty || _authProfileBannerDismissed) {
      return const SizedBox.shrink();
    }
    return Material(
      color: AppTheme.error,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
        child: Row(
          children: [
            const Icon(Icons.error_outline_rounded, color: Colors.white, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                msg,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
              ),
            ),
            IconButton(
              tooltip: 'Dismiss',
              onPressed: () {
                setState(() => _authProfileBannerDismissed = true);
                AuthRepository.instance.clearAuthFormError();
              },
              icon: const Icon(Icons.close_rounded, size: 22),
              color: Colors.white,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
          ],
        ),
      ),
    );
  }

  Widget _roleRulesBanner() {
    if (!AuthRepository.instance.apiRoleCheckDenied ||
        _roleRulesBannerDismissed) {
      return const SizedBox.shrink();
    }
    return Material(
      color: AppTheme.warning,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                UserFacingErrors.staffRoleLoadFailed,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
              ),
            ),
            IconButton(
              tooltip: 'Dismiss',
              onPressed: () => setState(() => _roleRulesBannerDismissed = true),
              icon: const Icon(Icons.close_rounded, size: 22),
              color: Colors.white,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShell(BuildContext context) {
    return ScreenRefreshScope(
      host: _refreshHost,
      currentSection: _currentSection,
      child: AppShellScope(
        goToSection: _setSection,
        child: Scaffold(
        key: _scaffoldKey,
        body: _isDesktop
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildSidebar(),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildTopBar(),
                        Expanded(
                          child: _buildShellContentNavigator(
                            padding: const EdgeInsets.all(24),
                          ),
                        ),
                        _shellStatusBanners(mobile: false),
                      ],
                    ),
                  ),
                ],
              )
            : Scaffold(
                appBar: AppBar(
                  title: ValueListenableBuilder<AppSection>(
                    valueListenable: _currentSection,
                    builder: (context, section, _) => Text(
                      _mobileLabel(section),
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  backgroundColor: AppTheme.primary,
                  actions: [
                    if (showToolbarRefreshButtons(context))
                      const ShellRefreshButton(iconColor: Colors.white),
                  ],
                ),
                drawer: Drawer(
                  backgroundColor: AppTheme.primary,
                  child: SafeArea(
                    child: ListView(
                      padding: EdgeInsets.zero,
                      children: [
                        const SizedBox(height: 24),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Row(
                            children: [
                              _brandLogoBox(size: 40, radius: 10, iconSize: 24),
                              const SizedBox(width: 12),
                              Text(
                                AppConstants.appName,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        ValueListenableBuilder<AppSection>(
                          valueListenable: _currentSection,
                          builder: (context, current, _) {
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: _navSections().map((s) {
                                final selected = current == s;
                                return ListTile(
                                  leading: s == AppSection.notices &&
                                          _unseenNotices > 0
                                      ? Badge(
                                          label: Text(_unseenNotices > 99
                                              ? '99+'
                                              : '$_unseenNotices'),
                                          child: Icon(s.icon,
                                              color: selected
                                                  ? Colors.white
                                                  : Colors.white70,
                                              size: 22),
                                        )
                                      : Icon(s.icon,
                                          color: selected
                                              ? Colors.white
                                              : Colors.white70,
                                          size: 22),
                                  title: Text(
                                    s.label,
                                    style: TextStyle(
                                      color: selected
                                          ? Colors.white
                                          : Colors.white70,
                                      fontWeight: selected
                                          ? FontWeight.w600
                                          : FontWeight.w500,
                                    ),
                                  ),
                                  onTap: () {
                                    _setSection(s);
                                    Navigator.of(context).pop();
                                  },
                                );
                              }).toList(),
                            );
                          },
                        ),
                        if (_isShellAdmin()) ...[
                          const Divider(color: Colors.white24, height: 1),
                          ..._drawerAdminExtraTiles(context),
                          const Divider(color: Colors.white24, height: 1),
                          ListTile(
                            leading: const Icon(Icons.groups_rounded,
                                color: Colors.white70, size: 22),
                            title: const Text(
                              'Staff & accounts',
                              style: TextStyle(
                                color: Colors.white70,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            subtitle: Text(
                              'Register staff, lecturer lists',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.45),
                                fontSize: 12,
                              ),
                            ),
                            onTap: () => _openStaffAdminHub(context,
                                closeDrawer: true),
                          ),
                        ],
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ),
                body: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _buildShellContentNavigator(
                        padding: const EdgeInsets.all(16),
                      ),
                    ),
                    _shellStatusBanners(mobile: true),
                  ],
                ),
                bottomNavigationBar: _buildBottomNav(),
              ),
        ),
      ),
    );
  }
}

/// Instant tab stack shared by mobile, web, and desktop shell layouts.
class _ShellSectionStack extends StatelessWidget {
  const _ShellSectionStack({
    required this.currentSection,
    required this.role,
    required this.sections,
    required this.builtSections,
    required this.sectionFor,
  });

  final ValueNotifier<AppSection> currentSection;
  final UserRole role;
  final List<AppSection> sections;
  final Set<AppSection> builtSections;
  final Widget Function(AppSection section, UserRole role) sectionFor;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: currentSection,
      builder: (context, _) {
        final section = currentSection.value;
        builtSections.add(section);
        final index = sections.indexOf(section);
        if (index < 0) {
          return RepaintBoundary(
            key: ValueKey('tab_${role.name}_${section.name}'),
            child: sectionFor(section, role),
          );
        }

        return IndexedStack(
          index: index,
          sizing: StackFit.expand,
          children: [
            for (final s in sections)
              RepaintBoundary(
                key: ValueKey('tab_${role.name}_${s.name}'),
                child: builtSections.contains(s)
                    ? TickerMode(
                        enabled: s == section,
                        child: sectionFor(s, role),
                      )
                    : const SizedBox.expand(),
              ),
          ],
        );
      },
    );
  }
}

/// Exposes shell tab switching to dashboard and other nested content.
class AppShellScope extends InheritedWidget {
  const AppShellScope({
    super.key,
    required this.goToSection,
    required super.child,
  });

  final void Function(AppSection section) goToSection;

  static AppShellScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppShellScope>();
    assert(scope != null, 'AppShellScope not found');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppShellScope oldWidget) =>
      goToSection != oldWidget.goToSection;
}

class _StaffUnavailablePlaceholder extends StatelessWidget {
  const _StaffUnavailablePlaceholder({
    required this.title,
    required this.message,
  });

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_outline_rounded,
                size: 48, color: AppTheme.textSecondary),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
