// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html;

/// Trigger a browser download of [csv] as UTF-8 text/csv.
Future<void> downloadReportCsvFile(String filename, String csv) async {
  final safeName =
      filename.replaceAll(RegExp(r'[^\w.\-]'), '_').replaceAll('__', '_');
  final blob = html.Blob(<Object>[csv], 'text/csv;charset=utf-8');
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..setAttribute('download', safeName.endsWith('.csv') ? safeName : '$safeName.csv')
    ..style.display = 'none';
  html.document.body!.append(anchor);
  anchor.click();
  anchor.remove();
  html.Url.revokeObjectUrl(url);
}
