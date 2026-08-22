import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'campus_geofence_validation.dart';
import 'campus_presence_grouping.dart';
import 'campus_presence_policy.dart';
import 'campus_presence_status_widgets.dart';
import 'models/campus_presence_models.dart';

/// Shared visual language for KIU administrator home and campus check-in flows.
abstract final class KiuAdminUi {
  KiuAdminUi._();

  static const gradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF177245), Color(0xFF0F4D2E)],
  );

  static BoxDecoration surfaceCardDecoration({Color? borderColor}) {
    return BoxDecoration(
      color: AppTheme.background,
      borderRadius: BorderRadius.circular(AppTheme.cardRadius),
      border: Border.all(
        color: borderColor ?? AppTheme.softGrey.withValues(alpha: 0.85),
      ),
      boxShadow: [
        BoxShadow(
          color: AppTheme.primary.withValues(alpha: 0.04),
          blurRadius: 12,
          offset: const Offset(0, 4),
        ),
      ],
    );
  }
}

class KiuAdminSectionTitle extends StatelessWidget {
  const KiuAdminSectionTitle(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class KiuAdminPresenceHero extends StatelessWidget {
  const KiuAdminPresenceHero({
    super.key,
    required this.status,
    this.loading = false,
    this.pendingUpload = false,
    this.compact = false,
    this.onTap,
  });

  final AdminCampusDayStatus? status;
  final bool loading;
  final bool pendingUpload;
  final bool compact;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = status;
    final onCampus = s?.isOnCampus ?? false;
    final failed = s?.failedToCheckOut ?? false;

    final (IconData icon, String title, String subtitle) =
        _heroCopy(context, s, onCampus, failed, loading, compact: compact);

    StaffDayPresenceRow? row;
    CampusDayPresenceFlags? flags;
    if (s != null && s.events.isNotEmpty) {
      CampusPresenceEvent? arrival;
      CampusPresenceEvent? departure;
      for (final ev in s.events) {
        if (ev.kind == CampusPresenceKind.arrival) arrival ??= ev;
        if (ev.kind == CampusPresenceKind.departure) departure ??= ev;
      }
      final first = s.events.first;
      row = StaffDayPresenceRow(
        adminUid: first.adminUid,
        displayName: first.displayName ?? first.adminUid,
        staffNumber: first.staffNumber,
        localDateKey: s.localDateKey,
        arrival: arrival,
        departure: departure,
      );
      flags = row.flags();
    }

    if (compact) {
      return _wrapTap(
        onTap: onTap,
        loading: loading,
        child: _buildCompactHero(
          context,
          icon: icon,
          title: title,
          subtitle: subtitle,
          loading: loading,
          flags: flags,
          pendingUpload: pendingUpload,
          showChevron: onTap != null,
        ),
      );
    }

    final content = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: KiuAdminUi.gradient,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primary.withValues(alpha: 0.22),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: loading
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Icon(icon, color: Colors.white, size: 26),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Campus presence',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.82),
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        height: 1.1,
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.88),
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (onTap != null && !loading)
                Icon(
                  Icons.chevron_right_rounded,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
            ],
          ),
          if (flags != null && !loading) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (flags.statusLabels.isNotEmpty)
                    CampusPresenceStatusChips(
                      flags: flags,
                      compact: true,
                    ),
                  if (row?.arrival != null) ...[
                    if (flags.statusLabels.isNotEmpty) const SizedBox(height: 6),
                    CampusPresenceHoursLine(flags: flags),
                  ],
                ],
              ),
            ),
          ],
          if (pendingUpload && !loading) ...[
            const SizedBox(height: 8),
            Text(
              'Saved on device — syncs when online.',
              style: theme.textTheme.labelSmall?.copyWith(
                color: Colors.white.withValues(alpha: 0.92),
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );

    if (onTap == null) return content;
    return _wrapTap(onTap: onTap, loading: loading, child: content);
  }

  Widget _wrapTap({
    required VoidCallback? onTap,
    required bool loading,
    required Widget child,
  }) {
    if (onTap == null) return child;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: loading ? null : onTap,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        child: child,
      ),
    );
  }

  Widget _buildCompactHero(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool loading,
    required CampusDayPresenceFlags? flags,
    required bool pendingUpload,
    bool showChevron = false,
  }) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 118),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
      decoration: BoxDecoration(
        gradient: KiuAdminUi.gradient,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primary.withValues(alpha: 0.18),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: loading
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Icon(icon, color: Colors.white, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        height: 1.15,
                      ),
                    ),
                    if (subtitle.isNotEmpty && !loading) ...[
                      const SizedBox(height: 6),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white.withValues(alpha: 0.88),
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (showChevron && !loading)
                Icon(
                  Icons.chevron_right_rounded,
                  color: Colors.white.withValues(alpha: 0.8),
                  size: 22,
                ),
            ],
          ),
          if (flags != null &&
              !loading &&
              flags.statusLabels.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final label in flags.statusLabels)
                  CampusPresenceTagChip(label: label, compact: true),
              ],
            ),
          ],
          if (pendingUpload && !loading) ...[
            const SizedBox(height: 8),
            Text(
              'Pending upload',
              style: theme.textTheme.labelSmall?.copyWith(
                color: Colors.white.withValues(alpha: 0.88),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }

  static (IconData, String, String) _heroCopy(
    BuildContext context,
    AdminCampusDayStatus? s,
    bool onCampus,
    bool failed,
    bool loading, {
    bool compact = false,
  }) {
    if (loading) {
      return (
        Icons.place_rounded,
        compact ? 'Loading status…' : 'Loading…',
        compact ? '' : 'Fetching today\'s campus status',
      );
    }
    if (failed) {
      return (
        Icons.error_outline_rounded,
        'Failed to check out',
        compact ? 'Still marked on campus' : 'You were still marked on campus after midnight.',
      );
    }
    if (onCampus) {
      final last = s?.lastEvent;
      if (compact) {
        var subtitle = 'Use Check out below when you leave';
        if (last != null) {
          final t = MaterialLocalizations.of(context).formatTimeOfDay(
            TimeOfDay.fromDateTime(last.capturedAt),
          );
          subtitle = 'Since $t · check out when you leave';
        }
        return (Icons.place_rounded, 'On campus', subtitle);
      }
      var subtitle = 'You are checked in at campus today.';
      if (last != null) {
        final t = MaterialLocalizations.of(context).formatTimeOfDay(
          TimeOfDay.fromDateTime(last.capturedAt),
        );
        subtitle = 'Checked in at $t · check out when you leave.';
      }
      return (Icons.place_rounded, 'On campus', subtitle);
    }
    if (compact) {
      return (
        Icons.place_outlined,
        'Not on campus',
        'Use Check in below when you arrive',
      );
    }
    return (
      Icons.place_outlined,
      'Not on campus',
      'Check in when you arrive at the campus centre.',
    );
  }
}

class KiuAdminSurfaceCard extends StatelessWidget {
  const KiuAdminSurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: KiuAdminUi.surfaceCardDecoration(),
      child: child,
    );
  }
}

class KiuAdminInfoBanner extends StatelessWidget {
  const KiuAdminInfoBanner({
    super.key,
    required this.message,
    this.icon = Icons.info_outline_rounded,
    this.tone = KiuAdminBannerTone.info,
  });

  final String message;
  final IconData icon;
  final KiuAdminBannerTone tone;

  @override
  Widget build(BuildContext context) {
    final (bg, border, fg) = switch (tone) {
      KiuAdminBannerTone.info => (
          AppTheme.primary.withValues(alpha: 0.06),
          AppTheme.primary.withValues(alpha: 0.18),
          AppTheme.primary,
        ),
      KiuAdminBannerTone.warning => (
          AppTheme.warning.withValues(alpha: 0.1),
          AppTheme.warning.withValues(alpha: 0.28),
          AppTheme.warning,
        ),
    };

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    height: 1.45,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.textPrimary,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

enum KiuAdminBannerTone { info, warning }

class KiuAdminCampusAreaCard extends StatelessWidget {
  const KiuAdminCampusAreaCard({super.key, required this.geofence});

  final CampusGeofence? geofence;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final configured = geofence != null && geofence!.isConfigured;

    return KiuAdminSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: (configured ? AppTheme.primary : AppTheme.warning)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.map_rounded,
                  color: configured ? AppTheme.primary : AppTheme.warning,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Campus check-in area',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: (configured ? AppTheme.success : AppTheme.warning)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  configured ? 'Active' : 'Not set',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: configured ? AppTheme.success : AppTheme.warning,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (configured) ...[
            Text(
              geofence!.label,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Centre ${geofence!.latitude.toStringAsFixed(5)}, '
              '${geofence!.longitude.toStringAsFixed(5)}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Allowed radius: ${formatCampusRadiusMeters(campusGeofenceMinRadiusMeters)}',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (geofence!.updatedByName?.isNotEmpty == true) ...[
              const SizedBox(height: 6),
              Text(
                'Set by ${geofence!.updatedByName}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
          ] else
            Text(
              'QA staff must set the campus centre before check-in is available.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppTheme.textSecondary,
                height: 1.4,
              ),
            ),
        ],
      ),
    );
  }
}

class KiuAdminCheckInActionButton extends StatelessWidget {
  const KiuAdminCheckInActionButton({
    super.key,
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.onPressed,
    required this.primary,
    this.busy = false,
    this.compact = false,
    this.greenWhenEnabled = false,
  });

  final String label;
  final String subtitle;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool primary;
  final bool busy;
  final bool compact;
  final bool greenWhenEnabled;

  static const _pillShape = StadiumBorder();
  static const _buttonPadding =
      EdgeInsets.symmetric(horizontal: 16, vertical: 16);
  static const _compactPadding =
      EdgeInsets.symmetric(horizontal: 12, vertical: 14);

  Size get _minSize =>
      compact ? const Size(0, 72) : const Size(double.infinity, 58);

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    final padding = compact ? _compactPadding : _buttonPadding;

    if (greenWhenEnabled) {
      final green = primary ? AppTheme.primary : AppTheme.primaryLight;
      return FilledButton(
        onPressed: enabled ? onPressed : null,
        style: FilledButton.styleFrom(
          padding: padding,
          minimumSize: _minSize,
          shape: _pillShape,
          backgroundColor: enabled ? green : AppTheme.softGrey,
          foregroundColor: enabled ? Colors.white : AppTheme.textSecondary,
          disabledBackgroundColor: AppTheme.softGrey,
          disabledForegroundColor: AppTheme.textSecondary,
        ),
        child: _KiuAdminCheckInActionContent(
          label: label,
          subtitle: subtitle,
          icon: icon,
          busy: busy,
          light: enabled,
          compact: compact,
          muted: !enabled,
        ),
      );
    }

    if (primary) {
      return FilledButton(
        onPressed: enabled ? onPressed : null,
        style: FilledButton.styleFrom(
          padding: padding,
          minimumSize: _minSize,
          shape: _pillShape,
        ),
        child: _KiuAdminCheckInActionContent(
          label: label,
          subtitle: subtitle,
          icon: icon,
          busy: busy,
          light: true,
          compact: compact,
        ),
      );
    }

    return OutlinedButton(
      onPressed: enabled ? onPressed : null,
      style: OutlinedButton.styleFrom(
        padding: padding,
        minimumSize: _minSize,
        side: BorderSide(
          color: enabled
              ? AppTheme.primary.withValues(alpha: 0.45)
              : AppTheme.softGrey,
        ),
        shape: _pillShape,
      ),
      child: _KiuAdminCheckInActionContent(
        label: label,
        subtitle: subtitle,
        icon: icon,
        busy: busy,
        light: false,
        compact: compact,
      ),
    );
  }
}

class _KiuAdminCheckInActionContent extends StatelessWidget {
  const _KiuAdminCheckInActionContent({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.busy,
    required this.light,
    this.compact = false,
    this.muted = false,
  });

  final String label;
  final String subtitle;
  final IconData icon;
  final bool busy;
  final bool light;
  final bool compact;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleColor = light
        ? Colors.white
        : muted
            ? AppTheme.textSecondary
            : AppTheme.textPrimary;
    final subtitleColor = light
        ? Colors.white.withValues(alpha: 0.82)
        : AppTheme.textSecondary;
    final iconColor = light
        ? Colors.white
        : muted
            ? AppTheme.textSecondary
            : AppTheme.primary;

    final iconWidget = busy
        ? SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: iconColor,
            ),
          )
        : Icon(
            icon,
            size: compact ? 24 : 26,
            color: iconColor,
          );

    if (compact) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          iconWidget,
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              color: titleColor,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        busy
            ? SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: light ? Colors.white : AppTheme.primary,
                ),
              )
            : Icon(icon, size: 26, color: light ? Colors.white : AppTheme.primary),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: titleColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: subtitleColor,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class KiuAdminCheckInRecordsButton extends StatelessWidget {
  const KiuAdminCheckInRecordsButton({
    super.key,
    required this.onPressed,
  });

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          minimumSize: const Size(double.infinity, 52),
          shape: const StadiumBorder(),
          side: BorderSide(color: AppTheme.primary.withValues(alpha: 0.45)),
          foregroundColor: AppTheme.primary,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.history_rounded, size: 22),
            const SizedBox(width: 10),
            Text(
              'Check-in records',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppTheme.primary,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class KiuAdminRecordTimelineTile extends StatelessWidget {
  const KiuAdminRecordTimelineTile({
    super.key,
    required this.event,
    required this.isFirst,
    required this.isLast,
  });

  final CampusPresenceEvent event;
  final bool isFirst;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final local = event.capturedAt.toLocal();
    final arrival = event.kind == CampusPresenceKind.arrival;
    final color = arrival ? AppTheme.success : AppTheme.secondary;
    final time =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 28,
            child: Column(
              children: [
                Expanded(
                  child: isFirst
                      ? const SizedBox.shrink()
                      : Container(
                          width: 2,
                          color: AppTheme.softGrey,
                        ),
                ),
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: color.withValues(alpha: 0.35),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: isLast
                      ? const SizedBox.shrink()
                      : Container(
                          width: 2,
                          color: AppTheme.softGrey,
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 14),
              child: KiuAdminSurfaceCard(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        arrival ? Icons.login_rounded : Icons.logout_rounded,
                        color: color,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            arrival ? 'Checked in' : 'Checked out',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            time,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      event.kind.label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
