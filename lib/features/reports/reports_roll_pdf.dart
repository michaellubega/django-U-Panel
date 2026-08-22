import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/widgets/app_brand_logo.dart';
import 'report_file_save.dart';
import 'reports_pdf_text.dart';

const _brandGreen = PdfColor.fromInt(0xFF177245);

class _RollPdfFonts {
  const _RollPdfFonts({
    required this.regular,
    required this.bold,
  });

  final pw.Font regular;
  final pw.Font bold;

  pw.TextStyle textStyle({
    required double fontSize,
    bool header = false,
    PdfColor? color,
  }) {
    return pw.TextStyle(
      font: header ? bold : regular,
      fontSize: fontSize,
      color: color,
    );
  }
}

Future<_RollPdfFonts> _loadRollPdfFonts() async {
  try {
    final regular = await PdfGoogleFonts.notoSansRegular();
    final bold = await PdfGoogleFonts.notoSansBold();
    return _RollPdfFonts(regular: regular, bold: bold);
  } catch (_) {
    // Offline or font fetch failed — Noto is still preferred via openSans fallback.
    final regular = await PdfGoogleFonts.openSansRegular();
    final bold = await PdfGoogleFonts.openSansBold();
    return _RollPdfFonts(regular: regular, bold: bold);
  }
}

Future<Uint8List?> _loadAppLogoBytes() async {
  try {
    final data = await rootBundle.load(AppBrandLogo.assetForPlatform());
    return data.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}

pw.Widget _rollPdfHeader({
  required _RollPdfFonts fonts,
  required String title,
  required String subtitleLine,
  Uint8List? logoBytes,
}) {
  final titleBlock = pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(
        title,
        style: fonts.textStyle(
          fontSize: 14,
          header: true,
          color: _brandGreen,
        ),
      ),
      pw.SizedBox(height: 4),
      pw.Text(
        subtitleLine,
        style: fonts.textStyle(
          fontSize: 9,
          color: PdfColors.grey700,
        ),
      ),
    ],
  );

  if (logoBytes == null) return titleBlock;

  return pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.ClipRRect(
        horizontalRadius: 6,
        verticalRadius: 6,
        child: pw.Image(
          pw.MemoryImage(logoBytes),
          width: 44,
          height: 44,
          fit: pw.BoxFit.cover,
        ),
      ),
      pw.SizedBox(width: 10),
      pw.Expanded(child: titleBlock),
    ],
  );
}

/// Builds a landscape roll table PDF and saves it to the device.
Future<String?> saveRollTablePdf({
  required String filename,
  required String title,
  required String subtitle,
  required List<String> headerCells,
  required List<List<String>> bodyRows,
}) async {
  final bytes = await buildRollTablePdfBytes(
    title: title,
    subtitle: subtitle,
    headerCells: headerCells,
    bodyRows: bodyRows,
  );
  return savePdfFile(
    filename: safePdfFilename(filename),
    bytes: bytes,
  );
}

Future<Uint8List> buildRollTablePdfBytes({
  required String title,
  required String subtitle,
  required List<String> headerCells,
  required List<List<String>> bodyRows,
}) async {
  final fonts = await _loadRollPdfFonts();
  final logoBytes = await _loadAppLogoBytes();
  final safeTitle = preparePdfText(title);
  final safeSubtitle = preparePdfText(subtitle);
  final safeHeaders = preparePdfTextRow(headerCells);
  final safeRows = preparePdfTextRows(bodyRows);

  final colCount = safeHeaders.length.clamp(1, 999);
  final fontSize = colCount > 24
      ? 5.0
      : colCount > 16
          ? 5.5
          : colCount > 10
              ? 6.5
              : 7.5;
  final generated = DateTime.now()
      .toIso8601String()
      .substring(0, 16)
      .replaceFirst('T', ' ');

  pw.Widget cell(
    String text, {
    required bool header,
    required double size,
  }) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 4),
      child: pw.Align(
        alignment: pw.Alignment.topLeft,
        child: pw.Text(
          text,
          style: fonts.textStyle(
            fontSize: size,
            header: header,
            color: header ? PdfColors.white : PdfColors.black,
          ),
        ),
      ),
    );
  }

  pw.TableRow tableRow(
    List<String> cells, {
    required bool header,
    required double size,
  }) {
    return pw.TableRow(
      decoration: header
          ? const pw.BoxDecoration(color: _brandGreen)
          : null,
      children: [
        for (final value in cells) cell(value, header: header, size: size),
      ],
    );
  }

  final tableRows = <pw.TableRow>[
    tableRow(safeHeaders, header: true, size: fontSize),
    for (final row in safeRows) tableRow(row, header: false, size: fontSize),
  ];

  final doc = pw.Document(
    theme: pw.ThemeData.withFont(
      base: fonts.regular,
      bold: fonts.bold,
    ),
  );
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(20),
      build: (context) => [
        _rollPdfHeader(
          fonts: fonts,
          title: safeTitle,
          subtitleLine: '$safeSubtitle | Generated $generated',
          logoBytes: logoBytes,
        ),
        pw.SizedBox(height: 10),
        pw.Table(
          border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.4),
          columnWidths: {
            for (var i = 0; i < colCount; i++)
              i: i == 0
                  ? const pw.FlexColumnWidth(1.4)
                  : i == 1
                      ? const pw.FlexColumnWidth(1.1)
                      : const pw.FlexColumnWidth(0.9),
          },
          children: tableRows,
        ),
      ],
    ),
  );

  return Uint8List.fromList(await doc.save());
}

String safePdfFilename(String title) {
  final cleaned = preparePdfText(title)
      .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
      .replaceAll(RegExp(r'\s+'), '_')
      .trim();
  final base = cleaned.isEmpty ? 'report' : cleaned;
  return base.endsWith('.pdf') ? base : '$base.pdf';
}
