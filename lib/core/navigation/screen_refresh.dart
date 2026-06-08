import 'dart:async';

import 'package:flutter/material.dart';

import 'app_section.dart';

/// [ListView]/[SingleChildScrollView] physics so [RefreshIndicator] works on short content.
const AlwaysScrollableScrollPhysics kRefreshScrollPhysics =
    AlwaysScrollableScrollPhysics();

/// Per-tab refresh callbacks registered by main shell screens.
class ScreenRefreshHost extends ChangeNotifier {
  final Map<AppSection, Future<void> Function()> _handlers = {};
  final Set<AppSection> _refreshingSections = {};
  final Map<AppSection, Future<void>> _inFlight = {};

  bool get refreshing => _refreshingSections.isNotEmpty;

  bool isRefreshing(AppSection section) =>
      _refreshingSections.contains(section);

  bool hasHandler(AppSection section) => _handlers.containsKey(section);

  void register(AppSection section, Future<void> Function() onRefresh) {
    _handlers[section] = onRefresh;
  }

  void unregister(AppSection section) {
    _handlers.remove(section);
    _refreshingSections.remove(section);
    _inFlight.remove(section);
  }

  Future<void> refresh(AppSection section) async {
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
      // Keep the stable [_onRefresh] registered; it delegates to [widget.onRefresh].
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

/// Refresh control for the shell app bar / top bar.
class ShellRefreshButton extends StatelessWidget {
  const ShellRefreshButton({super.key, required this.iconColor});

  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    final scope = ScreenRefreshScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([scope.host, scope.currentSection]),
      builder: (context, _) {
        final section = scope.currentSection.value;
        final busy = scope.host.isRefreshing(section);
        return IconButton(
          tooltip: 'Refresh',
          onPressed: scope.host.hasHandler(section)
              ? () => unawaited(scope.host.refresh(section))
              : null,
          icon: busy
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: iconColor,
                  ),
                )
              : Icon(Icons.refresh_rounded, color: iconColor),
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
  });

  final Future<void> Function() onRefresh;
  final Color? iconColor;

  @override
  State<RefreshIconButton> createState() => _RefreshIconButtonState();
}

class _RefreshIconButtonState extends State<RefreshIconButton> {
  bool _busy = false;
  Future<void>? _inFlight;

  Future<void> _handleRefresh() async {
    if (_inFlight != null) {
      await _inFlight;
      return;
    }
    setState(() => _busy = true);
    _inFlight = widget.onRefresh();
    try {
      await _inFlight;
    } finally {
      _inFlight = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.iconColor;
    return IconButton(
      tooltip: 'Refresh',
      onPressed: _handleRefresh,
      icon: _busy
          ? SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: color,
              ),
            )
          : Icon(Icons.refresh_rounded, color: color),
    );
  }
}
