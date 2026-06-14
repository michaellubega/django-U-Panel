import 'dart:typed_data';

Future<String?> savePdfFile({
  required String filename,
  required Uint8List bytes,
}) {
  throw UnsupportedError('PDF save is not available on this platform.');
}
