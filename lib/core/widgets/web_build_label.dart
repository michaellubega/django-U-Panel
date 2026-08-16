import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../version/app_build_info.dart';

/// Small footer on web so users can confirm they loaded the latest bundle.
class WebBuildLabel extends StatelessWidget {
  const WebBuildLabel({super.key});

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Text(
        'Web ${appVersionDisplay}',
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppTheme.textTertiary,
              fontSize: 11,
            ),
      ),
    );
  }
}
