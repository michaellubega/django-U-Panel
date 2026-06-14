/// Normalizes Unicode punctuation for PDF when a glyph may be missing.
String preparePdfText(String text) {
  return text
      .replaceAll('\u2014', '-') // em dash —
      .replaceAll('\u2013', '-') // en dash –
      .replaceAll('\u2012', '-')
      .replaceAll('\u2212', '-')
      .replaceAll('\u00B7', ' | ') // middle dot ·
      .replaceAll('\u2022', '*') // bullet •
      .replaceAll('\u2192', '->') // right arrow →
      .replaceAll('\u2190', '<-') // left arrow ←
      .replaceAll('\u2026', '...') // ellipsis …
      .replaceAll('\u00A0', ' ') // non-breaking space
      .replaceAll('\u2018', "'") // left single quote '
      .replaceAll('\u2019', "'") // right single quote '
      .replaceAll('\u201C', '"') // left double quote "
      .replaceAll('\u201D', '"'); // right double quote "
}

List<String> preparePdfTextRow(List<String> cells) =>
    cells.map(preparePdfText).toList();

List<List<String>> preparePdfTextRows(List<List<String>> rows) =>
    rows.map(preparePdfTextRow).toList();
