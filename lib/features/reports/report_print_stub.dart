import 'package:flutter/services.dart';

Future<void> printHtmlDocument(String title, String html) async {
  throw UnsupportedError('HTML print is only available on web.');
}

Future<void> copyPlainTextForPrint(String title, String plainText) async {
  await Clipboard.setData(ClipboardData(text: plainText));
}
