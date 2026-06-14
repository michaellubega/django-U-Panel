import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';

import '../constants/app_constants.dart';
import 'app_section.dart';

/// Toolbar refresh controls are desktop-only; mobile uses pull-to-refresh.
bool showToolbarRefreshButtons(BuildContext context) {
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS)) {
    return false;
  }
  return MediaQuery.sizeOf(context).width >= AppConstants.desktopBreakpoint;
}

/// [ListView]/[SingleChildScrollView] physics so [RefreshIndicator] works on short content.
const AlwaysScrollableScrollPhysics kRefreshScrollPhysics =
    AlwaysScrollableScrollPhysics();

/// Per-tab refresh callbacks registered by main shell screens.
class ScreenRefreshHost extends ChangeNotifier {
  final Map<AppSection, Future<void> Function()> _handlers = {};
  final Set<AppSection> _refreshingSections = {};
  final Map<AppSection, Future<void>> _inFlight = {};
  Future<void> Function()? _overlayHandler;
  bool _overlayRefreshing = false;
  Future<void>? _overlayInFlight;

  bool get refreshing =>
      _refreshingSections.isNotEmpty || _overlayRefreshing;

  bool isRefreshing(AppSection section) =>
      _refreshingSections.contains(section);

  bool get isOverlayRefreshing => _overlayRefreshing;

  bool hasHandler(AppSection section) => _handlers.containsKey(section);

  bool get hasOverlayHandler => _overlayHandler != null;

  void register(AppSection section, Future<void> Function() onRefresh) {
    _handlers[section] = onRefresh;
  }

  void unregister(AppSection section) {
    _handlers.remove(section);
    _refreshingSections.remove(section);
    _inFlight.remove(section);
  }

  void registerOverlay(Future<void> Function() onRefresh) {
    _overlayHandler = onRefresh;
    notifyListeners();
  }

  void unregisterOverlay(Future<void> Function() onRefresh) {
    if (_overlayHandler == onRefresh) {
      _overlayHandler = null;
      _overlayRefreshing = false;
      _overlayInFlight = null;
      notifyListeners();
    }
  }

  Future<void> refresh(AppSection section) async {
    if (_overlayHandler != null) {
      return refreshOverlay();
    }
    final handler = _handlers[section];
    if (handler == null) return;
    final existing = _inFlight[section];
    if (existing != null) return existing;
    _refreshingSections.add(section);
    notifyListeners();
    final future = handler().whenComplete(() {
      _refreshingSections.remove(section);
      _inFlight.remove(section);
      notifyListeners();
    });
    _inFlight[section] = future;
    return future;
  }

  Future<void> refreshOverlay() async {
    final handler = _overlayHandler;
    if (handler == null) return;
    final existing = _overlayInFlight;
    if (existing != null) return existing;
    _overlayRefreshing = true;
    notifyListeners();
    final future = handler().whenComplete(() {
      _overlayRefreshing = false;
      _overlayInFlight = null;
      notifyListeners();
    });
    _overlayInFlight = future;
    return future;
  }
}

class ScreenRefreshScope extends InheritedWidget {
  const ScreenRefreshScope({
    super.key,
    required this.host,
    required this.currentSection,
    required super.child,
  });

  final ScreenRefreshHost host;
  final ValueNotifier<AppSection> currentSection;

  static ScreenRefreshScope of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<ScreenRefreshScope>();
    assert(scope != null, 'ScreenRefreshScope not found');
    return scope!;
  }

  static ScreenRefreshScope? maybeOf(BuildContext context) {
    if (!context.mounted) return null;
    return context
        .dependOnInheritedWidgetOfExactType<ScreenRefreshScope>();
  }

  @override
  bool updateShouldNotify(ScreenRefreshScope oldWidget) =>
      host != oldWidget.host || currentSection != oldWidget.currentSection;
}

/// Registers [onRefresh] for the active shell tab so the app bar button works.
class ScreenRefreshRegistrar extends StatefulWidget {
  const ScreenRefreshRegistrar({
    super.key,
    required this.section,
    required this.onRefresh,
    required this.child,
  });

  final AppSection section;
  final Future<void> Function() onRefresh;
  final Widget child;

  @override
  State<ScreenRefreshRegistrar> createState() => _ScreenRefreshRegistrarState();
}

class _ScreenRefreshRegistrarState extends State<ScreenRefreshRegistrar> {
  ScreenRefreshHost? _registeredHost;
  AppSection? _registeredSection;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _register());
  }

  @override
  void didUpdateWidget(covariant ScreenRefreshRegistrar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.section != widget.section) {
      _unregister(oldWidget.section);
      _register();
    } else {
      _register();
    }
  }

  Future<void> _onRefresh() => widget.onRefresh();

  void _register() {
    if (!mounted) return;
    final host = ScreenRefreshScope.maybeOf(context)?.host;
    if (host == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _register());
      return;
    }
    _registeredHost = host;
    _registeredSection = widget.section;
    host.register(widget.section, _onRefresh);
  }

  void _unregister(AppSection section) {
    final host = _registeredHost;
    if (host != null && _registeredSection == section) {
      host.unregister(section);
      _registeredHost = null;
      _registeredSection = null;
    }
  }

  @override
  void dispose() {
    final host = _registeredHost;
    final section = _registeredSection;
    if (host != null && section != null) {
      host.unregister(section);
    }
    _registeredHost = null;
    _registeredSection = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Lets a pushed screen take over the shell refresh button while visible.
class NestedScreenRefreshBridge extends StatefulWidget {
  const NestedScreenRefreshBridge({
    super.key,
    required this.onRefresh,
    required this.child,
  });

  final Future<void> Function() onRefresh;
  final Widget child;

  @override
  State<NestedScreenRefreshBridge> createState() =>
      _NestedScreenRefreshBridgeState();
}

class _NestedScreenRefreshBridgeState extends State<NestedScreenRefreshBridge> {
  ScreenRefreshHost? _host;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _register());
  }

  @override
  void didUpdateWidget(covariant NestedScreenRefreshBridge oldWidget) {
    super.didUpdateWidget(oldWidget);
    _register();
  }

  void _register() {
    if (!mounted) return;
    final host = ScreenRefreshScope.maybeOf(context)?.host;
    if (host == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _register());
      return;
    }
    _host = host;
    host.registerOverlay(widget.onRefresh);
  }

  @override
  void dispose() {
    _host?.unregisterOverlay(widget.onRefresh);
    _host = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Pull-to-refresh for scrollable tab bodies (mobile and web).
class PullToRefreshBody extends StatelessWidget {
  const PullToRefreshBody({
    super.key,
    required this.onRefresh,
    required this.child,
    this.padding,
  });

  final Future<void> Function() onRefresh;
  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            physics: kRefreshScrollPhysics,
            padding: padding,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: child,
            ),
          );
        },
      ),
    );
  }
}

/// Wraps an existing [SingleChildScrollView] (or similar) with pull-to-refresh.
class PullToRefreshScrollable extends StatelessWidget {
  const PullToRefreshScrollable({
    super.key,
    required this.onRefresh,
    required this.child,
  });

  final Future<void> Function() onRefresh;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: child,
    );
  }
}

/// Spinning refresh glyph used by toolbar refresh controls.
class AnimatedRefreshIcon extends StatelessWidget {
  const AnimatedRefreshIcon({
    super.key,
    required this.spinning,
    this.icon = Icons.refresh_rounded,
    this.color,
    this.size = 24,
  });

  final bool spinning;
  final IconData icon;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (!spinning) {
      return Icon(
        icon,
        color: color,
        size: size,
      );
    }
    return _SpinningRefreshIcon(
      icon: icon,
      color: color,
      size: size,
    );
  }
}

/// Timer-driven rotation avoids [AnimationController.repeat] web view assertions.
class _SpinningRefreshIcon extends StatefulWidget {
  const _SpinningRefreshIcon({
    required this.icon,
    this.color,
    required this.size,
  });

  final IconData icon;
  final Color? color;
  final double size;

  @override
  State<_SpinningRefreshIcon> createState() => _SpinningRefreshIconState();
}

class _SpinningRefreshIconState extends State<_SpinningRefreshIcon> {
  static const _frameInterval = Duration(milliseconds: 32);
  static const _turnsPerSecond = 1.1;

  Timer? _timer;
  double _turns = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_frameInterval, (_) {
      if (!mounted) return;
      setState(() {
        _turns = (_turns + _turnsPerSecond * _frameInterval.inMilliseconds / 1000) % 1.0;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: _turns * 2 * math.pi,
      child: Icon(
        widget.icon,
        color: widget.color,
        size: widget.size,
      ),
    );
  }
}

/// Refresh control for the shell app bar / top bar.
class ShellRefreshButton extends StatelessWidget {
  const ShellRefreshButton({super.key, required this.iconColor});

  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    if (!showToolbarRefreshButtons(context)) {
      return const SizedBox.shrink();
    }
    final scope = ScreenRefreshScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([scope.host, scope.currentSection]),
      builder: (context, _) {
        final section = scope.currentSection.value;
        final host = scope.host;
        final busy = host.isOverlayRefreshing || host.isRefreshing(section);
        final enabled =
            host.hasOverlayHandler || host.hasHandler(section);
        return IconButton(
          tooltip: 'Refresh',
          onPressed: enabled
              ? () => unawaited(host.refresh(section))
              : null,
          icon: AnimatedRefreshIcon(
            spinning: busy,
            color: iconColor,
            size: 22,
          ),
        );
      },
    );
  }
}

/// App bar refresh control — stays enabled and coalesces overlapping refreshes.
class RefreshIconButton extends StatefulWidget {
  const RefreshIconButton({
    super.key,
    required this.onRefresh,
    this.iconColor,
    this.busy,
  });

  final Future<void> Function() onRefresh;
  final Color? iconColor;

  /// When set, shows the spinning icon even if this button did not start refresh.
  final bool? busy;

  @override
  State<RefreshIconButton> createState() => _RefreshIconButtonState();
}

class _RefreshIconButtonState extends State<RefreshIconButton> {
  bool _internalBusy = false;
  Future<void>? _inFlight;

  bool get _spinning => widget.busy == true || _internalBusy;

  Future<void> _handleRefresh() async {
    if (_inFlight != null) {
      await _inFlight;
      return;
    }
    setState(() => _internalBusy = true);
    _inFlight = widget.onRefresh();
    try {
      await _inFlight;
    } finally {
      _inFlight = null;
      if (mounted) setState(() => _internalBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!showToolbarRefreshButtons(context)) {
      return const SizedBox.shrink();
    }
    return IconButton(
      tooltip: 'Refresh',
      onPressed: _handleRefresh,
      icon: AnimatedRefreshIcon(
        spinning: _spinning,
        color: widget.iconColor,
        size: 22,
      ),
    );
  }
}

/// Tonal button with the same refresh animation as [RefreshIconButton].
class RefreshTonalButton extends StatefulWidget {
  const RefreshTonalButton({
    super.key,
    required this.onRefresh,
    required this.label,
    this.icon = Icons.sync_rounded,
    this.busy,
  });

  final Future<void> Function() onRefresh;
  final String label;
  final IconData icon;
  final bool? busy;

  @override
  State<RefreshTonalButton> createState() => _RefreshTonalButtonState();
}

class _RefreshTonalButtonState extends State<RefreshTonalButton> {
  bool _internalBusy = false;
  Future<void>? _inFlight;

  bool get _spinning => widget.busy == true || _internalBusy;

  Future<void> _handleRefresh() async {
    if (_inFlight != null) {
      await _inFlight;
      return;
    }
    setState(() => _internalBusy = true);
    _inFlight = widget.onRefresh();
    try {
      await _inFlight;
    } finally {
      _inFlight = null;
      if (mounted) setState(() => _internalBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!showToolbarRefreshButtons(context)) {
      return const SizedBox.shrink();
    }
    return FilledButton.tonalIcon(
      onPressed: _handleRefresh,
      icon: AnimatedRefreshIcon(
        spinning: _spinning,
        icon: widget.icon,
        size: 20,
      ),
      label: Text(widget.label),
    );
  }
}
