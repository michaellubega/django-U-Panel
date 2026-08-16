import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// In-app KIU student portal with platform WebView password autofill support.
class StudentPortalScreen extends StatefulWidget {
  const StudentPortalScreen({super.key});

  static const String portalUrl = 'https://student.kiu.ac.ug/';

  @override
  State<StudentPortalScreen> createState() => _StudentPortalScreenState();
}

class _StudentPortalScreenState extends State<StudentPortalScreen> {
  late final WebViewController _controller;
  var _loading = true;
  var _canGoBack = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (_) => unawaited(_syncHistoryState()),
          onWebResourceError: (_) {
            if (mounted) setState(() => _loading = false);
          },
        ),
      )
      ..loadRequest(Uri.parse(StudentPortalScreen.portalUrl));
  }

  Future<void> _syncHistoryState() async {
    final back = await _controller.canGoBack();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _canGoBack = back;
    });
  }

  Future<void> _handleSystemBack() async {
    if (await _controller.canGoBack()) {
      await _controller.goBack();
      await _syncHistoryState();
      return;
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_canGoBack,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _handleSystemBack();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Portal'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: 'Reload',
              onPressed: () => _controller.reload(),
            ),
          ],
        ),
        body: Stack(
          children: [
            WebViewWidget(controller: _controller),
            if (_loading)
              const Center(child: CircularProgressIndicator()),
          ],
        ),
      ),
    );
  }
}
