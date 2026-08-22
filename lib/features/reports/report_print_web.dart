// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;

/// Opens print dialog for [htmlContent]. Falls back to HTML download if blocked.
Future<void> printHtmlDocument(String title, String htmlContent) async {
  if (await _tryPrintViaBlobUrl(htmlContent)) return;
  if (await _tryPrintInIframe(htmlContent)) return;

  downloadHtmlDocument(_safeFilename(title), htmlContent);
  throw StateError(
    'Print was blocked. The report was downloaded as HTML — open it and choose Print → Save as PDF.',
  );
}

Future<void> copyPlainTextForPrint(String title, String plainText) async {
  await printHtmlDocument(title, htmlContentFromPlain(title, plainText));
}

void downloadHtmlDocument(String filename, String htmlContent) {
  final blob = html.Blob([htmlContent], 'text/html;charset=utf-8');
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..download = filename.endsWith('.html') ? filename : '$filename.html'
    ..style.display = 'none';
  html.document.body?.children.add(anchor);
  anchor.click();
  anchor.remove();
  html.Url.revokeObjectUrl(url);
}

Future<bool> _tryPrintViaBlobUrl(String htmlContent) async {
  final blob = html.Blob([htmlContent], 'text/html;charset=utf-8');
  final url = html.Url.createObjectUrlFromBlob(blob);
  final popup = html.window.open(url, '_blank') as html.Window?;
  if (popup == null) {
    html.Url.revokeObjectUrl(url);
    return false;
  }

  await Future<void>.delayed(const Duration(milliseconds: 700));
  try {
    popup.print();
    html.Url.revokeObjectUrl(url);
    return true;
  } catch (_) {
    try {
      popup.close();
    } catch (_) {}
    html.Url.revokeObjectUrl(url);
    return false;
  }
}

Future<bool> _tryPrintInIframe(String htmlContent) async {
  final completer = Completer<bool>();
  final iframe = html.IFrameElement()
    ..style.position = 'fixed'
    ..style.left = '-10000px'
    ..style.top = '0'
    ..style.width = '1px'
    ..style.height = '1px'
    ..style.border = 'none';

  var finished = false;
  void finish(bool ok) {
    if (finished) return;
    finished = true;
    iframe.remove();
    if (!completer.isCompleted) completer.complete(ok);
  }

  iframe.onLoad.listen((_) async {
    try {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      (iframe.contentWindow as html.Window?)?.print();
      finish(true);
    } catch (_) {
      finish(false);
    }
  });

  html.document.body?.append(iframe);
  iframe.srcdoc = htmlContent;

  return completer.future.timeout(
    const Duration(seconds: 8),
    onTimeout: () {
      finish(false);
      return false;
    },
  );
}

String _safeFilename(String title) {
  final cleaned = title
      .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
      .replaceAll(RegExp(r'\s+'), '_')
      .trim();
  return cleaned.isEmpty ? 'report' : cleaned;
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
