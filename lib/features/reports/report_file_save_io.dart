import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

Future<String?> savePdfFile({
  required String filename,
  required Uint8List bytes,
}) async {
  final name = filename.endsWith('.pdf') ? filename : '$filename.pdf';
  Directory? dir;
  try {
    dir = await getDownloadsDirectory();
  } catch (_) {}
  dir ??= await getApplicationDocumentsDirectory();

  var target = File('${dir.path}${Platform.pathSeparator}$name');
  if (await target.exists()) {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    target = File(
      '${dir.path}${Platform.pathSeparator}${stem}_$stamp.pdf',
    );
  }
  await target.writeAsBytes(bytes, flush: true);
  return target.path;
}
