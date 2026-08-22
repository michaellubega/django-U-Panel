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

/// Styled roll table — on web opens print / Save as PDF.
Future<void> printRollHtmlDocument({
  required String title,
  required String html,
}) async {
  if (kIsWeb) {
    await impl.printHtmlDocument(title, html);
    return;
  }
  await impl.copyPlainTextForPrint(title, _plainFromRollHtml(html));
}

String _escapeHtml(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('\n', '<br>');

String buildRollTableHtml({
  required String title,
  required String subtitle,
  required List<String> headerCells,
  required List<List<String>> bodyRows,
}) {
  final head = headerCells.map((c) => '<th>${_escapeHtml(c)}</th>').join();
  final rows = bodyRows.map((cells) {
    final tds = cells.map((c) => '<td>${_escapeHtml(c)}</td>').join();
    return '<tr>$tds</tr>';
  }).join('\n');

  return '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <title>${_escapeHtml(title)}</title>
  <style>
    body { font-family: system-ui, sans-serif; font-size: 10px; margin: 16px; color: #111; }
    h1 { font-size: 16px; margin: 0 0 4px; color: #177245; }
    .sub { font-size: 12px; color: #64748b; margin: 0 0 14px; }
    table { border-collapse: collapse; width: 100%; table-layout: auto; }
    th, td { border: 1px solid #cbd5e1; padding: 6px 8px; vertical-align: top; text-align: left; }
    th { background: #177245; color: #fff; font-weight: 700; white-space: nowrap; }
    tr:nth-child(even) td { background: #f8fafc; }
    td:first-child { font-weight: 600; min-width: 120px; }
    @media print {
      body { margin: 10mm; }
      @page { size: landscape; margin: 10mm; }
    }
  </style>
</head>
<body>
  <h1>${_escapeHtml(title)}</h1>
  <p class="sub">${_escapeHtml(subtitle)} · Generated ${DateTime.now().toIso8601String().substring(0, 16).replaceFirst('T', ' ')}</p>
  <table>
    <thead><tr>$head</tr></thead>
    <tbody>
$rows
    </tbody>
  </table>
</body>
</html>
''';
}

String _plainFromRollHtml(String html) {
  return html
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
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
