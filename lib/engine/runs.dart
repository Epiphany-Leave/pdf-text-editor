import 'package:pdfrx/pdfrx.dart' show PdfRect;

/// Original PDF values, before viewer zoom.
class PdfTextFormat {
  const PdfTextFormat({
    required this.fontName,
    required this.familyName,
    required this.fontSize,
    this.fontId = 0,
    this.color = 0xff000000,
    this.weight = 400,
    this.italic = false,
    this.renderMode = 0,
    this.strokeColor = 0xff000000,
    this.strokeWidth = 0,
    this.a = 1,
    this.b = 0,
    this.c = 0,
    this.d = 1,
  });
  final String fontName, familyName;
  final double fontSize;
  final int fontId, color, weight, renderMode, strokeColor;
  final bool italic;
  final double strokeWidth, a, b, c, d;
  bool get syntheticBold => renderMode == 2 && strokeWidth > 0;
  bool get bold => weight >= 600 || syntheticBold;
  bool sameAs(PdfTextFormat other) =>
      fontId == other.fontId &&
      fontName == other.fontName &&
      fontSize == other.fontSize &&
      color == other.color &&
      weight == other.weight &&
      italic == other.italic &&
      renderMode == other.renderMode &&
      strokeColor == other.strokeColor &&
      strokeWidth == other.strokeWidth &&
      a == other.a &&
      b == other.b &&
      c == other.c &&
      d == other.d;
}

class PdfTextCharacter {
  const PdfTextCharacter({
    required this.index,
    required this.text,
    required this.box,
    required this.format,
    required this.x,
    required this.y,
    this.advanceRight,
  });
  final int index; // PDFium character index, not a UTF-16 string offset.
  final String text;
  final PdfRect box;
  final PdfTextFormat format;
  final double x, y;
  final double? advanceRight;
}

class TextRun {
  const TextRun({
    required this.page,
    required this.key,
    required this.text,
    required this.box,
    required this.format,
    required this.sourceCharIndex,
    required this.sourceEndIndex,
    required this.x,
    required this.y,
  });
  final int page, sourceCharIndex, sourceEndIndex;
  final String key, text;
  final PdfRect box;
  final PdfTextFormat format;
  final double x, y; // Original baseline origin in page coordinates.
  bool containsPoint(double x, double y, {double pad = 3}) =>
      x >= box.left - pad &&
      x <= box.right + pad &&
      y >= box.bottom - pad &&
      y <= box.top + pad;
}

bool _isCjk(int r) =>
    (r >= 0x2e80 && r <= 0x9fff) ||
    (r >= 0xf900 && r <= 0xfaff) ||
    (r >= 0x20000 && r <= 0x2fa1f);

/// Format changes are editing boundaries, so neighboring fonts and colors survive.
List<TextRun> groupRuns({
  required int page,
  required List<PdfTextCharacter> characters,
}) {
  final runs = <TextRun>[];
  var start = -1;
  PdfTextCharacter? previous;
  var containsCjk = false;
  void close(int end) {
    if (start < 0) return;
    final chars = characters.sublist(start, end), first = characters[start];
    var left = first.box.left,
        right = first.box.right,
        top = first.box.top,
        bottom = first.box.bottom;
    for (final char in chars.skip(1)) {
      if (char.box.left < left) left = char.box.left;
      if (char.box.right > right) right = char.box.right;
      if (char.box.top > top) top = char.box.top;
      if (char.box.bottom < bottom) bottom = char.box.bottom;
    }
    runs.add(
      TextRun(
        page: page,
        key: '$page:${first.index}:${chars.last.index + 1}',
        text: chars.map((c) => c.text).join(),
        box: PdfRect(left, top, right, bottom),
        format: first.format,
        sourceCharIndex: first.index,
        sourceEndIndex: chars.last.index + 1,
        x: first.x,
        y: first.y,
      ),
    );
    start = -1;
    containsCjk = false;
  }

  for (var i = 0; i < characters.length; i++) {
    final char = characters[i];
    if (char.text.trim().isEmpty || char.box.isEmpty) {
      close(i);
      previous = char;
      continue;
    }
    if (start >= 0 && previous != null) {
      final h = char.box.height > previous.box.height
          ? char.box.height
          : previous.box.height;
      final sameLine =
          (char.box.top +
                  char.box.bottom -
                  previous.box.top -
                  previous.box.bottom)
              .abs() <
          h * 0.6;
      if (!sameLine ||
          char.box.left - previous.box.right > h * (containsCjk ? 0.6 : 0.9) ||
          !char.format.sameAs(previous.format)) {
        close(i);
      }
    }
    if (start < 0) start = i;
    containsCjk = containsCjk || char.text.runes.any(_isCjk);
    previous = char;
  }
  close(characters.length);
  return runs;
}
