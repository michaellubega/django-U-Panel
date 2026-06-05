// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

Future<void> printHtmlDocument(String title, String htmlContent) async {
  final iframe = html.IFrameElement()
    ..style.border = 'none'
    ..style.width = '0'
    ..style.height = '0'
    ..srcdoc = htmlContent;
  html.document.body?.append(iframe);
  await Future<void>.delayed(const Duration(milliseconds: 400));
  (iframe.contentWindow as html.Window?)?.print();
  await Future<void>.delayed(const Duration(milliseconds: 500));
  iframe.remove();
}

Future<void> copyPlainTextForPrint(String title, String plainText) async {
  await printHtmlDocument(title, htmlContentFromPlain(title, plainText));
}

String htmlContentFromPlain(String title, String plainText) {
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
