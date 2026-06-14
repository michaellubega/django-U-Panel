import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'models/campus_presence_models.dart';

enum CampusPresenceCheckStep {
  preparing,
  locating,
  loadingCampusArea,
  verifyingRadius,
  saving,
  done,
  failed,
}

class CampusPresenceCheckProgressController {
  CampusPresenceCheckProgressController._(this._state);

  final _CampusPresenceCheckProgressDialogState _state;

  void setStep(
    CampusPresenceCheckStep step, {
    String? detail,
  }) {
    _state._update(step: step, detail: detail);
  }

  void fail(String message) {
    _state._fail(message);
  }

  void succeed(String message) {
    _state._update(
      step: CampusPresenceCheckStep.done,
      detail: message,
    );
  }

  Future<void> close({Duration delay = Duration.zero}) async {
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    _state._close();
  }
}

Future<CampusPresenceCheckProgressController> showCampusPresenceCheckProgress(
  BuildContext context, {
  required CampusPresenceKind kind,
}) {
  final completer = Completer<CampusPresenceCheckProgressController>();
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (ctx) {
        return _CampusPresenceCheckProgressDialog(
          kind: kind,
          onReady: (controller) {
            if (!completer.isCompleted) {
              completer.complete(controller);
            }
          },
        );
      },
    ),
  );
  return completer.future;
}

class _CampusPresenceCheckProgressDialog extends StatefulWidget {
  const _CampusPresenceCheckProgressDialog({
    required this.kind,
    required this.onReady,
  });

  final CampusPresenceKind kind;
  final ValueChanged<CampusPresenceCheckProgressController> onReady;

  @override
  State<_CampusPresenceCheckProgressDialog> createState() =>
      _CampusPresenceCheckProgressDialogState();
}

class _CampusPresenceCheckProgressDialogState
    extends State<_CampusPresenceCheckProgressDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  CampusPresenceCheckStep _step = CampusPresenceCheckStep.preparing;
  CampusPresenceCheckStep? _failedAt;
  String? _detail;
  bool _closing = false;

  static const _pipeline = [
    CampusPresenceCheckStep.preparing,
    CampusPresenceCheckStep.locating,
    CampusPresenceCheckStep.loadingCampusArea,
    CampusPresenceCheckStep.verifyingRadius,
    CampusPresenceCheckStep.saving,
  ];

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onReady(
        CampusPresenceCheckProgressController._(this),
      );
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  void _update({
    required CampusPresenceCheckStep step,
    String? detail,
  }) {
    if (!mounted) return;
    setState(() {
      _step = step;
      if (detail != null) {
        _detail = detail;
      }
    });
    if (step == CampusPresenceCheckStep.done) {
      _pulseController.stop();
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _failedAt = _step;
      _step = CampusPresenceCheckStep.failed;
      _detail = message;
    });
    _pulseController.stop();
  }

  void _close() {
    if (!mounted || _closing) return;
    _closing = true;
    Navigator.of(context, rootNavigator: true).pop();
  }

  String get _title {
    final action =
        widget.kind == CampusPresenceKind.arrival ? 'Check in' : 'Check out';
    return switch (_step) {
      CampusPresenceCheckStep.done => '$action complete',
      CampusPresenceCheckStep.failed => '$action failed',
      _ => action,
    };
  }

  String _labelFor(CampusPresenceCheckStep step) {
    return switch (step) {
      CampusPresenceCheckStep.preparing => 'Preparing',
      CampusPresenceCheckStep.locating => 'Getting your location',
      CampusPresenceCheckStep.loadingCampusArea => 'Loading campus area',
      CampusPresenceCheckStep.verifyingRadius =>
        'Verifying you are on campus',
      CampusPresenceCheckStep.saving => 'Recording presence',
      CampusPresenceCheckStep.done => 'Finished',
      CampusPresenceCheckStep.failed => 'Could not continue',
    };
  }

  int _stepIndex(CampusPresenceCheckStep step) => _pipeline.indexOf(step);

  _StepVisual _visualFor(CampusPresenceCheckStep step) {
    final index = _stepIndex(step);
    if (index < 0) return _StepVisual.pending;

    if (_step == CampusPresenceCheckStep.failed) {
      final failedIndex = _failedAt == null ? index : _stepIndex(_failedAt!);
      if (index < failedIndex) return _StepVisual.done;
      if (index == failedIndex) return _StepVisual.failed;
      return _StepVisual.pending;
    }
    if (_step == CampusPresenceCheckStep.done) {
      return _StepVisual.done;
    }

    final activeIndex = _stepIndex(_step);
    if (index < activeIndex) return _StepVisual.done;
    if (index == activeIndex) return _StepVisual.active;
    return _StepVisual.pending;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = _step == CampusPresenceCheckStep.failed;
    final done = _step == CampusPresenceCheckStep.done;
    final steps = _pipeline;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Material(
          color: Colors.transparent,
          child: Card(
            margin: const EdgeInsets.symmetric(horizontal: 24),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      _HeaderPulse(
                        controller: _pulseController,
                        done: done,
                        failed: failed,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          _title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: Column(
                      children: [
                        for (var i = 0; i < steps.length; i++) ...[
                          if (i > 0) const SizedBox(height: 10),
                          _ProgressStepRow(
                            label: _labelFor(steps[i]),
                            visual: _visualFor(steps[i]),
                            pulse: _pulseController,
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (_detail != null &&
                      (_step == CampusPresenceCheckStep.failed ||
                          _step == CampusPresenceCheckStep.done ||
                          _step == CampusPresenceCheckStep.verifyingRadius ||
                          _step == CampusPresenceCheckStep.saving)) ...[
                    const SizedBox(height: 14),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: Text(
                        _detail!,
                        key: ValueKey(_detail),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: failed
                              ? AppTheme.error
                              : AppTheme.textSecondary,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                  if (failed || done) ...[
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _close,
                        child: Text(failed ? 'Close' : 'Done'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _StepVisual { pending, active, done, failed }

class _HeaderPulse extends StatelessWidget {
  const _HeaderPulse({
    required this.controller,
    required this.done,
    required this.failed,
  });

  final AnimationController controller;
  final bool done;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    if (done) {
      return Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: AppTheme.success.withValues(alpha: 0.14),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.check_rounded, color: AppTheme.success),
      );
    }
    if (failed) {
      return Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: AppTheme.error.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.close_rounded, color: AppTheme.error),
      );
    }

    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final scale = 0.92 + (controller.value * 0.08);
        return Transform.scale(
          scale: scale,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  AppTheme.primary.withValues(alpha: 0.85),
                  AppTheme.primary,
                ],
              ),
              shape: BoxShape.circle,
            ),
            child: const Padding(
              padding: EdgeInsets.all(10),
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: Colors.white,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ProgressStepRow extends StatelessWidget {
  const _ProgressStepRow({
    required this.label,
    required this.visual,
    required this.pulse,
  });

  final String label;
  final _StepVisual visual;
  final AnimationController pulse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color) = switch (visual) {
      _StepVisual.done => (
          Icons.check_circle_rounded,
          AppTheme.success,
        ),
      _StepVisual.failed => (
          Icons.cancel_rounded,
          AppTheme.error,
        ),
      _StepVisual.active => (
          Icons.radio_button_checked_rounded,
          AppTheme.primary,
        ),
      _StepVisual.pending => (
          Icons.circle_outlined,
          AppTheme.textSecondary.withValues(alpha: 0.45),
        ),
    };

    Widget leading = Icon(icon, size: 22, color: color);
    if (visual == _StepVisual.active) {
      leading = AnimatedBuilder(
        animation: pulse,
        builder: (context, child) {
          return Opacity(
            opacity: 0.55 + (pulse.value * 0.45),
            child: child,
          );
        },
        child: leading,
      );
    }

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 220),
      opacity: visual == _StepVisual.pending ? 0.55 : 1,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          leading,
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: visual == _StepVisual.active
                    ? FontWeight.w700
                    : FontWeight.w500,
                color: visual == _StepVisual.pending
                    ? AppTheme.textSecondary
                    : AppTheme.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
