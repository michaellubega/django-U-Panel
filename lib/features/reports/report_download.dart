import 'package:flutter/foundation.dart';

import 'report_download_stub.dart'
    if (dart.library.html) 'report_download_web.dart' as impl;

/// On web, triggers a file download; on other platforms this is a no-op.
Future<void> maybeDownloadReportCsv(String filename, String csv) async {
  if (kIsWeb) {
    await impl.downloadReportCsvFile(filename, csv);
  }
}
