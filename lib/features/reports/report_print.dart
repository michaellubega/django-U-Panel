import 'package:flutter/foundation.dart';

import 'report_print_stub.dart'
    if (dart.library.html) 'report_print_web.dart' as impl;

/// Opens a browser print dialog on web; copies plain text elsewhere.
Future<void> printAttendanceRollText({
  required String title,
  required String plainText,
}) async {
  if (kIsWeb) {
    await impl.printHtmlDocument(title, _htmlFromPlain(title, plainText));
    return;
  }
  await impl.copyPlainTextForPrint(title, plainText);
}

String _htmlFromPlain(String title, String plainText) {
  final escaped = plainText
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>${title.replaceAll('&', '&amp;').replaceAll('<', '&lt;')}</title>
  <style>
    body { font-family: system-ui, sans-serif; font-size: 12px; margin: 24px; color: #111; }
    h1 { font-size: 16px; margin: 0 0 12px; }
    pre { white-space: pre-wrap; font-family: ui-monospace, monospace; line-height: 1.45; }
    @media print { body { margin: 12mm; } }
  </style>
</head>
<body>
  <h1>${title.replaceAll('&', '&amp;').replaceAll('<', '&lt;')}</h1>
  <pre>$escaped</pre>
</body>
</html>
''';
}
