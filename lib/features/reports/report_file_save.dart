import 'dart:typed_data';

import 'report_file_save_stub.dart'
    if (dart.library.html) 'report_file_save_web.dart'
    if (dart.library.io) 'report_file_save_io.dart' as impl;

/// Saves [bytes] as a PDF file. Returns a local path on desktop/mobile, null on web (browser download).
Future<String?> savePdfFile({
  required String filename,
  required Uint8List bytes,
}) {
  return impl.savePdfFile(filename: filename, bytes: bytes);
}
