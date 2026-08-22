import 'package:flutter/material.dart';

import '../../core/navigation/app_section.dart';
import '../../core/navigation/app_shell.dart';
import '../../core/navigation/screen_refresh.dart';
import '../../core/theme/app_theme.dart';

/// Dashboard [Card] typography aligned with Ant Design (14px base).
abstract final class DashboardCardText {
  static const double titleSize = 16;
  static const double sectionSize = 14;
  static const double itemTitleSize = 14;
  static const double bodySize = 14;
  static const double captionSize = 12;
  static const double labelSize = 12;
  static const double metricValueSize = 24;
  static const double metricValueLargeSize = 30;
  static const double metricLabelDenseSize = 12;
  static const double metricLabelSize = 14;

  static TextStyle cardTitle(TextTheme theme) =>
      theme.titleLarge!.copyWith(fontWeight: FontWeight.w600, fontSize: titleSize);

  static TextStyle cardSection(TextTheme theme) =>
      theme.titleMedium!.copyWith(fontWeight: FontWeight.w600, fontSize: sectionSize);

  static TextStyle itemTitle(TextTheme theme) =>
      theme.titleSmall!.copyWith(fontWeight: FontWeight.w600, fontSize: itemTitleSize);

  static TextStyle bodySecondary(TextTheme theme) =>
      theme.bodyMedium!.copyWith(color: AppTheme.textSecondary, fontSize: bodySize);

  static TextStyle captionSecondary(TextTheme theme) =>
      theme.bodySmall!.copyWith(color: AppTheme.textSecondary, fontSize: captionSize);

  static TextStyle label(TextTheme theme, {FontWeight? fontWeight}) =>
      theme.labelSmall!.copyWith(
        fontSize: labelSize,
        fontWeight: fontWeight ?? FontWeight.w600,
      );
}

/// Lets dashboard tiles switch main shell tabs.
class DashboardShellNav {
  static void go(BuildContext context, AppSection section) {
    AppShellScope.of(context).goToSection(section);
  }
}

/// Header with optional live pulse and last-updated line.
class DashboardLiveHeader extends StatelessWidget {
  const DashboardLiveHeader({
    super.key,
    required this.title,
    this.subtitle = '',
    this.welcomeName,
    this.roleLabel,
    this.compact = false,
    this.liveCount = 0,
    this.lastUpdated,
    this.onRefresh,
    this.refreshing = false,
  });

  final String title;
  final String subtitle;
  final String? welcomeName;
  final String? roleLabel;
  final bool compact;
  final int liveCount;
  final DateTime? lastUpdated;
  final VoidCallback? onRefresh;
  final bool refreshing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final updated = lastUpdated;
    String? updatedLabel;
    if (updated != null) {
      final diff = DateTime.now().difference(updated);
      if (diff.inSeconds < 15) {
        updatedLabel = 'Updated just now';
      } else if (diff.inMinutes < 60) {
        updatedLabel = 'Updated ${diff.inMinutes} min ago';
      } else {
        updatedLabel =
            'Updated ${updated.hour.toString().padLeft(2, '0')}:${updated.minute.toString().padLeft(2, '0')}';
      }
    }

    final greeting = welcomeName?.trim();
    final headlineText =
        greeting != null && greeting.isNotEmpty
            ? 'Welcome back, $greeting'
            : title;
    final titleStyle = (compact || greeting != null)
        ? theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
            height: AppTheme.lineHeightLg / AppTheme.fontSizeLg,
          )
        : theme.textTheme.headlineMedium;
    final subtitleText = subtitle.trim();
    final metaGap = compact ? 4.0 : 6.0;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      headlineText,
                      style: titleStyle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (liveCount > 0) ...[
                    const SizedBox(width: 8),
                    _LivePulseBadge(count: liveCount),
                  ],
                ],
              ),
              if (subtitleText.isNotEmpty && greeting == null) ...[
                SizedBox(height: metaGap),
                Text(
                  subtitleText,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: AppTheme.textSecondary,
                    height: 1.3,
                  ),
                ),
              ],
              if (roleLabel != null || updatedLabel != null) ...[
                SizedBox(height: metaGap),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (roleLabel != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          roleLabel!,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: AppTheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    if (updatedLabel != null)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.sync_rounded,
                            size: 14,
                            color: AppTheme.textSecondary.withValues(alpha: 0.8),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            updatedLabel,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: AppTheme.textSecondary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        if (onRefresh != null && showToolbarRefreshButtons(context))
          RefreshIconButton(
            onRefresh: () async => onRefresh!(),
            iconColor: theme.colorScheme.primary,
            busy: refreshing,
          ),
      ],
    );
  }
}

class _LivePulseBadge extends StatefulWidget {
  const _LivePulseBadge({required this.count});

  final int count;

  @override
  State<_LivePulseBadge> createState() => _LivePulseBadgeState();
}

class _LivePulseBadgeState extends State<_LivePulseBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        final scale = 1.0 + (t < 0.5 ? t * 0.12 : (1 - t) * 0.12);
        return Transform.scale(
          scale: scale,
          child: child,
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: AppTheme.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppTheme.primary.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: AppTheme.primary,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '${widget.count} live',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: AppTheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tappable metric tile for dashboard grids.
class DashboardStatTile extends StatelessWidget {
  const DashboardStatTile({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.onTap,
    this.highlight = false,
    this.fillHeight = false,
    this.dense = false,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;
  final bool highlight;
  final bool fillHeight;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: highlight
          ? color.withValues(alpha: 0.14)
          : theme.cardColor,
      elevation: highlight ? 2 : 0,
      shadowColor: color.withValues(alpha: 0.25),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(dense ? 10 : 12),
        side: BorderSide(
          color: highlight
              ? color.withValues(alpha: 0.5)
              : AppTheme.softGrey.withValues(alpha: 0.6),
          width: highlight ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(dense ? 10 : 12),
        child: SizedBox(
          width: double.infinity,
          height: fillHeight ? double.infinity : null,
          child: LayoutBuilder(
          builder: (context, constraints) {
            final boundedHeight = constraints.hasBoundedHeight &&
                constraints.maxHeight.isFinite;
            final boundedWidth = constraints.hasBoundedWidth &&
                constraints.maxWidth.isFinite;
            final shortTile = boundedHeight && constraints.maxHeight <= 140;
            final tightHeight =
                boundedHeight && constraints.maxHeight <= 88;
            final autoDense = dense || shortTile;
            final compact = autoDense ||
                constraints.maxHeight < 108 ||
                constraints.maxWidth < 148;
            final pad = autoDense
                ? (tightHeight ? 5.0 : 7.0)
                : (compact ? 10.0 : 16.0);
            final iconBoxPad = autoDense ? 4.0 : (compact ? 6.0 : 10.0);
            final iconSize = autoDense ? 15.0 : (compact ? 18.0 : 22.0);
            final valueStyle = autoDense
                ? theme.textTheme.titleMedium
                : (compact
                    ? theme.textTheme.headlineSmall
                    : theme.textTheme.headlineMedium);
            final labelStyle = theme.textTheme.bodySmall?.copyWith(
              color: AppTheme.textSecondary,
              fontSize: autoDense
                  ? DashboardCardText.metricLabelDenseSize
                  : DashboardCardText.metricLabelSize,
              height: 1.05,
            );
            final valueText = Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: valueStyle?.copyWith(
                fontWeight: FontWeight.w600,
                color: AppTheme.primary,
                height: 1.0,
                fontSize: autoDense
                    ? DashboardCardText.metricValueSize - 4
                    : (compact
                        ? DashboardCardText.metricValueSize
                        : DashboardCardText.metricValueLargeSize - 4),
              ),
            );
            final labelText = Text(
              label,
              style: labelStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            );
            final iconBox = Container(
              padding: EdgeInsets.all(iconBoxPad),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(autoDense ? 7 : 10),
              ),
              child: Icon(icon, size: iconSize, color: color),
            );

            final useHorizontalLayout = autoDense ||
                tightHeight ||
                (shortTile && (!boundedWidth || constraints.maxWidth >= 72));

            Widget body;
            if (useHorizontalLayout) {
              body = Row(
                children: [
                  iconBox,
                  SizedBox(width: autoDense ? 6 : 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        valueText,
                        labelText,
                      ],
                    ),
                  ),
                ],
              );
            } else {
              body = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize:
                    fillHeight ? MainAxisSize.max : MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      iconBox,
                      const Spacer(),
                      if (onTap != null && !autoDense && !shortTile)
                        Icon(
                          Icons.chevron_right_rounded,
                          size: compact ? 18 : 22,
                          color: AppTheme.textSecondary.withValues(alpha: 0.7),
                        ),
                    ],
                  ),
                  if (fillHeight && !shortTile) const Spacer(),
                  SizedBox(height: autoDense ? 3 : (compact ? 6 : 10)),
                  valueText,
                  SizedBox(height: autoDense ? 1 : (compact ? 2 : 4)),
                  labelText,
                ],
              );
            }

            final padded = Padding(
              padding: EdgeInsets.all(pad),
              child: body,
            );

            if (boundedHeight && boundedWidth) {
              return FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                  child: padded,
                ),
              );
            }

            return padded;
          },
        ),
        ),
      ),
    );
  }
}

/// Fixed-size metric tiles: taller and narrower than full-width dashboard cells.
class DashboardMetricTilesStrip extends StatelessWidget {
  const DashboardMetricTilesStrip({
    super.key,
    required this.tiles,
    this.tileWidth = 132,
    this.tileHeight = 124,
  });

  final List<Widget> tiles;
  final double tileWidth;
  final double tileHeight;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: tileHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        clipBehavior: Clip.none,
        itemCount: tiles.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) => SizedBox(
          width: tileWidth,
          height: tileHeight,
          child: tiles[index],
        ),
      ),
    );
  }
}

/// Full-width quick action button row.
class DashboardQuickAction extends StatelessWidget {
  const DashboardQuickAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.filled = false,
    this.subtitle,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final child = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: DashboardCardText.itemTitle(Theme.of(context).textTheme),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: DashboardCardText.captionSecondary(
                      Theme.of(context).textTheme,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, size: 22),
        ],
      ),
    );

    if (filled) {
      return FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          padding: EdgeInsets.zero,
          alignment: Alignment.centerLeft,
        ),
        child: child,
      );
    }
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        padding: EdgeInsets.zero,
        alignment: Alignment.centerLeft,
      ),
      child: child,
    );
  }
}

/// Tappable list row used in dashboard sections.
class DashboardTapTile extends StatelessWidget {
  const DashboardTapTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.icon,
    required this.onTap,
    this.iconColor,
  });

  final String title;
  final String? subtitle;
  final IconData icon;
  final VoidCallback onTap;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppTheme.softGrey.withValues(alpha: 0.7)),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(icon, color: iconColor ?? AppTheme.primary, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: DashboardCardText.itemTitle(Theme.of(context).textTheme),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle!,
                        style: DashboardCardText.captionSecondary(
                          Theme.of(context).textTheme,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 14,
                color: AppTheme.textSecondary.withValues(alpha: 0.6),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Circular icon shortcut used in dashboard quick-action rows.
class DashboardCompactQuickAction extends StatelessWidget {
  const DashboardCompactQuickAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = color ?? AppTheme.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.12),
                shape: BoxShape.circle,
                border: Border.all(color: tint.withValues(alpha: 0.25)),
              ),
              child: Icon(icon, color: tint, size: 24),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: DashboardCardText.label(theme.textTheme),
            ),
          ],
        ),
      ),
    );
  }
}

/// Row of [DashboardCompactQuickAction] tiles that wrap on narrow screens.
class DashboardCompactQuickActionsRow extends StatelessWidget {
  const DashboardCompactQuickActionsRow({super.key, required this.actions});

  final List<DashboardCompactQuickAction> actions;

  static const _wrapBreakpoint = 520.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= _wrapBreakpoint) {
          return Row(
            children: [
              for (var i = 0; i < actions.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: actions[i]),
              ],
            ],
          );
        }
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.spaceBetween,
          children: [
            for (final action in actions)
              SizedBox(
                width: (constraints.maxWidth - 8) / 2,
                child: action,
              ),
          ],
        );
      },
    );
  }
}

/// Donut chart for present vs absent counts (no external chart package).
class DashboardAttendanceDonut extends StatelessWidget {
  const DashboardAttendanceDonut({
    super.key,
    required this.present,
    required this.absent,
    this.size = 120,
  });

  final int present;
  final int absent;
  final double size;

  @override
  Widget build(BuildContext context) {
    final total = present + absent;
    final pct = total <= 0 ? 0 : ((100 * present) / total).round().clamp(0, 100);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size(size, size),
            painter: _DonutChartPainter(
              present: present,
              absent: absent,
              presentColor: AppTheme.success,
              absentColor: AppTheme.error,
              trackColor: AppTheme.softGrey.withValues(alpha: 0.35),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                total <= 0 ? '—' : '$pct%',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primary,
                      fontSize: DashboardCardText.metricValueSize,
                    ),
              ),
              Text(
                'Present',
                style: DashboardCardText.label(Theme.of(context).textTheme).copyWith(
                      color: AppTheme.textSecondary,
                      fontWeight: FontWeight.w500,
                    ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DonutChartPainter extends CustomPainter {
  _DonutChartPainter({
    required this.present,
    required this.absent,
    required this.presentColor,
    required this.absentColor,
    required this.trackColor,
  });

  final int present;
  final int absent;
  final Color presentColor;
  final Color absentColor;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    const stroke = 14.0;
    final rect = Rect.fromCircle(center: center, radius: radius - stroke / 2);
    final track = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, 2 * 3.1415926535, false, track);

    final total = present + absent;
    if (total <= 0) return;

    final presentSweep = (present / total) * 2 * 3.1415926535;
    final absentSweep = (absent / total) * 2 * 3.1415926535;
    const start = -3.1415926535 / 2;

    if (present > 0) {
      final paint = Paint()
        ..color = presentColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(rect, start, presentSweep, false, paint);
    }
    if (absent > 0) {
      final paint = Paint()
        ..color = absentColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(rect, start + presentSweep, absentSweep, false, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DonutChartPainter oldDelegate) {
    return oldDelegate.present != present || oldDelegate.absent != absent;
  }
}

/// Student check-in summary card with donut chart and legend.
class DashboardAttendanceOverviewCard extends StatelessWidget {
  const DashboardAttendanceOverviewCard({
    super.key,
    required this.presentToday,
    required this.absentToday,
    this.onPresentTap,
    this.onAbsentTap,
    this.embeddedInRow = false,
  });

  final int presentToday;
  final int absentToday;
  final VoidCallback? onPresentTap;
  final VoidCallback? onAbsentTap;
  final bool embeddedInRow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = presentToday + absentToday;
    final presentPct =
        total <= 0 ? 0 : ((100 * presentToday) / total).round().clamp(0, 100);
    final absentPct = total <= 0 ? 0 : 100 - presentPct;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 520;
        const squareCardWidth = 360.0;

        final legend = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _LegendRow(
              color: AppTheme.success,
              label: 'Present',
              value: '$presentToday',
              percent: '$presentPct%',
              onTap: onPresentTap,
            ),
            const SizedBox(height: 8),
            _LegendRow(
              color: AppTheme.error,
              label: 'Absent',
              value: '$absentToday',
              percent: '$absentPct%',
              onTap: onAbsentTap,
            ),
            const SizedBox(height: 8),
            _LegendRow(
              color: AppTheme.primary,
              label: 'Total',
              value: '$total',
              percent: total <= 0 ? '—' : '100%',
            ),
          ],
        );

        final chartBody = wide
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AspectRatio(
                    aspectRatio: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppTheme.softGrey.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Center(
                        child: DashboardAttendanceDonut(
                          present: presentToday,
                          absent: absentToday,
                          size: 148,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  legend,
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  DashboardAttendanceDonut(
                    present: presentToday,
                    absent: absentToday,
                  ),
                  const SizedBox(width: 20),
                  Expanded(child: legend),
                ],
              );

        final card = Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Student attendance today',
                        style: DashboardCardText.cardSection(theme.textTheme),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.softGrey.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'Today',
                        style: DashboardCardText.label(theme.textTheme),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                chartBody,
                if (total <= 0) ...[
                  const SizedBox(height: 12),
                  Text(
                    'No student check-ins recorded yet today.',
                    style: DashboardCardText.captionSecondary(theme.textTheme),
                  ),
                ],
              ],
            ),
          ),
        );

        if (!wide || embeddedInRow) return card;

        return Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: squareCardWidth,
            child: card,
          ),
        );
      },
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.color,
    required this.label,
    required this.value,
    required this.percent,
    this.onTap,
  });

  final Color color;
  final String label;
  final String value;
  final String percent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final row = Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: DashboardCardText.captionSecondary(
              Theme.of(context).textTheme,
            ),
          ),
        ),
        Text(
          value,
          style: DashboardCardText.itemTitle(Theme.of(context).textTheme).copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 36,
          child: Text(
            percent,
            textAlign: TextAlign.right,
            style: DashboardCardText.label(Theme.of(context).textTheme).copyWith(
                  color: AppTheme.textSecondary,
                  fontWeight: FontWeight.w500,
                ),
          ),
        ),
        if (onTap != null) ...[
          const SizedBox(width: 4),
          Icon(
            Icons.chevron_right_rounded,
            size: 18,
            color: color.withValues(alpha: 0.85),
          ),
        ],
      ],
    );
    if (onTap == null) return row;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: row,
      ),
    );
  }
}
