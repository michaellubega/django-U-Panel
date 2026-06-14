import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'roll_cell_status.dart';

/// Large live check-in percentage for the lecturer session screen.
class LiveSessionCheckInMeter extends StatefulWidget {
  const LiveSessionCheckInMeter({
    super.key,
    required this.snapshot,
  });

  final LiveSessionCheckInSnapshot snapshot;

  @override
  State<LiveSessionCheckInMeter> createState() =>
      _LiveSessionCheckInMeterState();
}

class _LiveSessionCheckInMeterState extends State<LiveSessionCheckInMeter>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Animation<double> _percentAnim;
  late Animation<double> _progressAnim;
  int _displayPercent = 0;
  double _displayProgress = 0;

  @override
  void initState() {
    super.initState();
    _displayPercent = widget.snapshot.percentCheckedIn;
    _displayProgress = widget.snapshot.progress;
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _percentAnim = AlwaysStoppedAnimation(_displayPercent.toDouble());
    _progressAnim = AlwaysStoppedAnimation(_displayProgress);
    _controller.addListener(() {
      if (!mounted) return;
      setState(() {
        _displayPercent = _percentAnim.value.round();
        _displayProgress = _progressAnim.value;
      });
    });
  }

  @override
  void didUpdateWidget(covariant LiveSessionCheckInMeter oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextPercent = widget.snapshot.percentCheckedIn;
    final nextProgress = widget.snapshot.progress;
    if (nextPercent == _displayPercent && nextProgress == _displayProgress) {
      return;
    }
    _percentAnim = Tween<double>(
      begin: _displayPercent.toDouble(),
      end: nextPercent.toDouble(),
    ).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _progressAnim = Tween<double>(
      begin: _displayProgress,
      end: nextProgress,
    ).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snapshot = widget.snapshot;

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.22)),
      ),
      child: Column(
        children: [
          Text(
            '$_displayPercent%',
            style: theme.textTheme.displaySmall?.copyWith(
              fontWeight: FontWeight.w900,
              color: AppTheme.primary,
              height: 1,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            snapshot.subtitle,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (snapshot.pending > 0) ...[
            const SizedBox(height: 4),
            Text(
              '${snapshot.pending} syncing…',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppTheme.warning,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              minHeight: 10,
              value: _displayProgress,
              backgroundColor: AppTheme.softGrey,
              color: AppTheme.success,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '${snapshot.present} present · ${snapshot.absent} absent',
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppTheme.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
