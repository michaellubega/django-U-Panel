import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../connectivity/app_connectivity.dart';
import '../theme/app_theme.dart';
import '../constants/app_constants.dart';
import '../auth/auth_repository.dart';
import '../auth/user_role.dart';
import '../../features/dashboard/dashboard_screen.dart';
import '../../features/dashboard/lecturer_dashboard_screen.dart';
import '../../features/attendance/attendance_list_hierarchy.dart';
import '../../features/attendance/attendance_screen.dart';
import '../../features/attendance/data/attendance_offline_sync.dart';
import '../../features/attendance/data/attendance_repository.dart';
import '../../features/attendance/models/attendance_models.dart';
import '../../features/notices/notices_screen.dart';
import '../../features/notices/data/notices_repository.dart';
import '../../features/reports/reports_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/settings/lecturer_settings_screen.dart';
import '../../features/settings/staff_admin_hub_screen.dart';
import '../push/push_controller.dart';

enum AppSection {
  dashboard,
  attendance,
  notices,
  reports,
  settings,
}

extension AppSectionX on AppSection {
  String get label {
    switch (this) {
      case AppSection.dashboard:
        return 'Dashboard';
      case AppSection.attendance:
        return 'Attendance';
      case AppSection.notices:
        return 'Notices';
      case AppSection.reports:
        return 'Reports';
      case AppSection.settings:
        return 'Settings';
    }
  }

  IconData get icon {
    switch (this) {
      case AppSection.dashboard:
        return Icons.dashboard_rounded;
      case AppSection.attendance:
        return Icons.people_alt_rounded;
      case AppSection.notices:
        return Icons.campaign_rounded;
      case AppSection.reports:
        return Icons.analytics_rounded;
      case AppSection.settings:
        return Icons.settings_rounded;
    }
  }
}

/// Desktop: fixed left sidebar + top bar + main content.
/// Mobile: bottom nav + top bar + main content.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final ValueNotifier<AppSection> _currentSection;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  Timer? _noticesCounterTimer;
  int _unseenNotices = 0;
  bool _wasOnline = true;
  UserRole? _sectionCacheRole;
  final Map<AppSection, Widget> _sectionWidgets = {};
  UserRole? _cachedTabStackRole;
  List<Widget>? _cachedTabStackChildren;

  @override
  void initState() {
    super.initState();
    final auth = AuthRepository.instance;
    _currentSection = ValueNotifier(
      auth.roleCheckDone
          ? _defaultSectionForRole(auth.resolvedRole)
          : AppSection.attendance,
    );
    AuthRepository.instance.addListener(_onAuthRepo);
    AppConnectivity.instance.addListener(_onConnectivityChanged);
    _wasOnline = AppConnectivity.instance.isOnline;
    unawaited(AppConnectivity.instance.initialize());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applyDefaultSectionForRole();
      unawaited(_bootstrapAttendanceStore());
      unawaited(PushController.instance.syncTopicsForCurrentUser());
      _refreshUnseenNotices();
    });
    _noticesCounterTimer = Timer.periodic(
        const Duration(seconds: 30), (_) => _refreshUnseenNotices());
  }

  @override
  void dispose() {
    _currentSection.dispose();
    AuthRepository.instance.removeListener(_onAuthRepo);
    AppConnectivity.instance.removeListener(_onConnectivityChanged);
    _noticesCounterTimer?.cancel();
    super.dispose();
  }

  Future<void> _warmAttendanceForOffline() async {
    await AttendanceRepository.instance.loadAll(
      scopeToLecturerUid: AttendanceRepository.currentLecturerLoadScopeUid(),
    );
  }

  Future<void> _bootstrapAttendanceStore() async {
    if (AppConnectivity.instance.isOnline) {
      await AttendanceOfflineSync.drainAllInOrder();
    } else {
      await _warmAttendanceForOffline();
    }
    if (mounted) _precacheSectionWidgets();
  }

  /// Build every tab once so the first switch does not pay [initState] cost.
  void _precacheSectionWidgets() {
    final role = _resolvedRole();
    _ensureSectionCacheForRole(role);
    for (final s in _navSectionsForRole(role)) {
      _sectionWidget(s, role);
    }
    _cachedTabStackChildren = null;
    _cachedTabStackRole = null;
    _tabStackChildren();
  }

  /// Upload pending offline work first, then one [loadAll] inside the drain pipeline.
  Future<void> _onConnectivityRestored() async {
    await AttendanceOfflineSync.drainAllInOrder();
  }

  void _onConnectivityChanged() {
    if (!mounted) return;
    final nowOnline = AppConnectivity.instance.isOnline;
    if (nowOnline && !_wasOnline) {
      unawaited(_onConnectivityRestored());
    }
    _wasOnline = nowOnline;
  }

  UserRole _resolvedRole() {
    return AuthRepository.instance.resolvedRole;
  }

  bool get _rolesPending => !AuthRepository.instance.roleCheckDone;

  AppSection _defaultSectionForRole(UserRole role) {
    switch (role) {
      case UserRole.admin:
      case UserRole.qaStaff:
      case UserRole.lecturer:
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
    if (roleChanged) {
      _sectionWidgets.clear();
      _sectionCacheRole = role;
      _cachedTabStackChildren = null;
      _cachedTabStackRole = null;
    }
    if (!allowed.contains(_currentSection.value)) {
      _currentSection.value = _defaultSectionForRole(role);
    }
    if (roleChanged || AuthRepository.instance.roleCheckDone) {
      _applyDefaultSectionForRole();
    }
    if (roleChanged) {
      setState(() {});
      _precacheSectionWidgets();
    }
    _refreshUnseenNotices();
    unawaited(PushController.instance.syncTopicsForCurrentUser());
  }

  void _ensureSectionCacheForRole(UserRole role) {
    if (_sectionCacheRole == role) return;
    _sectionWidgets.clear();
    _sectionCacheRole = role;
    _cachedTabStackChildren = null;
    _cachedTabStackRole = null;
  }

  List<Widget> _tabStackChildren() {
    final role = _resolvedRole();
    _ensureSectionCacheForRole(role);
    if (_cachedTabStackRole == role && _cachedTabStackChildren != null) {
      return _cachedTabStackChildren!;
    }
    final sections = _navSectionsForRole(role);
    _cachedTabStackChildren = [
      for (final s in sections)
        RepaintBoundary(
          key: ValueKey('tab_${role.name}_${s.name}'),
          child: _sectionWidget(s, role),
        ),
    ];
    _cachedTabStackRole = role;
    return _cachedTabStackChildren!;
  }

  String _noticeUserKey() {
    final uid = AuthRepository.instance.currentFirebaseUid?.trim();
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
          lecturer: lecturer,
          lecturerListIds: lecturerListIds,
          studentId: student?.id,
          signedListIds: signedListIds,
        );
        if (!visible) continue;
        if (newestVisible == null ||
            n.createdAt.isAfter(newestVisible.createdAt)) {
          newestVisible = n;
        }
      }
      if (newestVisible != null) {
        await NoticesRepository.instance
            .markSeenAt(_noticeUserKey(), newestVisible.createdAt);
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
        lecturer: lecturer,
        lecturerListIds: lecturerListIds,
        studentId: student?.id,
        signedListIds: signedListIds,
      );
      if (mounted) setState(() => _unseenNotices = c);
    } catch (_) {}
  }

  void _setSection(AppSection s) {
    if (_currentSection.value == s) return;
    _currentSection.value = s;
    if (s == AppSection.notices) {
      unawaited(_markNoticesSeenNow());
    }
  }

  void _openStaffAdminHub(BuildContext context, {required bool closeDrawer}) {
    final nav = Navigator.of(context);
    if (closeDrawer) nav.pop();
    unawaited(
      nav.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const StaffAdminHubScreen(),
        ),
      ),
    );
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
        return _resolvedRole() == UserRole.lecturer ? 'Home' : 'Dashboard';
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
            return const DashboardScreen();
          case UserRole.lecturer:
            return const LecturerDashboardScreen();
          case UserRole.student:
            return const AttendanceScreen();
        }
      case AppSection.attendance:
        return const AttendanceScreen();
      case AppSection.notices:
        return const NoticesScreen();
      case AppSection.reports:
        if (!role.hasStaffOperationalAccess) {
          return const _StaffUnavailablePlaceholder(
            title: 'Reports',
            message: 'Reports are available to QA staff only.',
          );
        }
        return const ReportsScreen();
      case AppSection.settings:
        switch (role) {
          case UserRole.lecturer:
            return const LecturerSettingsScreen();
          case UserRole.admin:
          case UserRole.qaStaff:
          case UserRole.student:
            return const SettingsScreen();
        }
    }
  }

  Widget _sectionWidget(AppSection section, UserRole role) {
    return _sectionWidgets.putIfAbsent(
      section,
      () => _createSectionWidget(section, role),
    );
  }

  /// Tab bodies stay mounted; only [IndexedStack.index] updates on section change.
  Widget _buildSectionStack() {
    final tabs = _tabStackChildren();
    final sections = _navSections();
    return ValueListenableBuilder<AppSection>(
      valueListenable: _currentSection,
      builder: (context, section, _) {
        var index = sections.indexOf(section);
        if (index < 0) index = 0;
        return IndexedStack(
          index: index,
          sizing: StackFit.expand,
          children: tabs,
        );
      },
    );
  }

  Widget _buildMainPane({required EdgeInsets padding}) {
    return Padding(
      padding: padding,
      child: _buildSectionStack(),
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
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
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
            const SizedBox(width: 16),
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

    return Container(
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
    );
  }

  String _offlineBannerMessage() {
    final repo = AttendanceRepository.instance;
    final synced = repo.localSnapshotSyncedAt;
    if (repo.isUsingLocalSnapshot && synced != null) {
      final local = synced.toLocal();
      final stamp =
          '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
          '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
      return 'Offline — showing attendance saved at $stamp. '
          'Check-ins queue until you are back online.';
    }
    return 'You are offline. Actions will sync automatically when internet returns.';
  }

  Widget _offlineBanner({required bool mobile}) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
        horizontal: mobile ? 12 : 16,
        vertical: mobile ? 8 : 10,
      ),
      color: AppTheme.warning,
      child: Row(
        children: [
          const Icon(Icons.wifi_off_rounded, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _offlineBannerMessage(),
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
    final logoAsset = switch (defaultTargetPlatform) {
      TargetPlatform.iOS || TargetPlatform.macOS => 'kiu/appstore.png',
      _ => 'kiu/playstore.png',
    };
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: Image.asset(
          logoAsset,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            color: AppTheme.accent,
            alignment: Alignment.center,
            child:
                Icon(Icons.school_rounded, color: Colors.white, size: iconSize),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AuthRepository.instance,
      builder: (context, _) {
        if (_rolesPending) {
          return const Scaffold(
            body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Loading your account…'),
                ],
              ),
            ),
          );
        }
        return _buildShell(context);
      },
    );
  }

  Widget _shellStatusBanners({required bool mobile}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _roleRulesBanner(),
        ListenableBuilder(
          listenable: AppConnectivity.instance,
          builder: (context, _) {
            if (AppConnectivity.instance.isOnline) {
              return const SizedBox.shrink();
            }
            return _offlineBanner(mobile: mobile);
          },
        ),
      ],
    );
  }

  Widget _roleRulesBanner() {
    if (!AuthRepository.instance.firestoreRoleCheckDenied) {
      return const SizedBox.shrink();
    }
    return Material(
      color: AppTheme.warning,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Could not load your staff role from Firestore (permission denied). '
                'Deploy firestore.rules to the upanel database, then restart the app. '
                'Until then you may only see the student menu.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShell(BuildContext context) {
    return AppShellScope(
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
                          child: _buildMainPane(
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
                ),
                drawer: Drawer(
                  backgroundColor: AppTheme.primary,
                  child: SafeArea(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
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
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
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
                      ],
                    ),
                  ),
                ),
                body: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _buildMainPane(
                        padding: const EdgeInsets.all(16),
                      ),
                    ),
                    _shellStatusBanners(mobile: true),
                  ],
                ),
                bottomNavigationBar: _buildBottomNav(),
              ),
      ),
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
