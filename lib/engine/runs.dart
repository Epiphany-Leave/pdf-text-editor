// Pure-Dart text run grouping: turns pdfrx text fragments (whole lines) into
// small tappable runs (a number, a word, a short CJK phrase) so the user edits
// exactly the piece they tapped.
import 'package:pdfrx/pdfrx.dart' show PdfRect;

/// A contiguous group of characters on one line, in PDF page coordinates
/// (origin bottom-left, y up).
class TextRun {
  TextRun({
    required this.page,
    required this.key,
    required this.text,
    required this.box,
    required this.fontSize,
  });

  final int page; // 1-based
  final String key; // stable identity: page:fragment:start:end
  final String text;
  final PdfRect box; // union of char boxes, y-up
  final double fontSize; // estimate for preview overlay

  bool containsPoint(double x, double y, {double pad = 3}) =>
      x >= box.left - pad &&
      x <= box.right + pad &&
      y >= box.bottom - pad &&
      y <= box.top + pad;
}

const _cjkStart = 0x2E80;

bool _isCJK(int r) =>
    (r >= _cjkStart && r <= 0x9FFF) || // CJK blocks + kana
    (r >= 0xF900 && r <= 0xFAFF) ||
    (r >= 0x20000 && r <= 0x2FA1F);

bool _isWhitespace(String ch) =>
    ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == '\u00A0';

/// Groups [charRects] (aligned with [text]) of one fragment into runs.
/// Breaks at whitespace, line changes (y jump) and horizontal gaps larger
/// than a fraction of the character height (table cells, wide word spacing).
List<TextRun> groupRuns({
  required int page,
  required int fragmentIndex,
  required String text,
  required List<PdfRect> charRects,
}) {
  final runs = <TextRun>[];
  var start = -1;
  PdfRect? prevRect;

  void close(int endExclusive) {
    if (start < 0 || endExclusive <= start) return;
    final slice = text.substring(start, endExclusive);
    final boxes = charRects.sublist(start, endExclusive).where((r) => r.isNotEmpty).toList();
    if (slice.trim().isEmpty || boxes.isEmpty) {
      start = -1;
      return;
    }
    var left = boxes.first.left, top = boxes.first.top, right = boxes.first.right, bottom = boxes.first.bottom;
    for (final b in boxes) {
      left = b.left < left ? b.left : left;
      top = b.top > top ? b.top : top;
      right = b.right > right ? b.right : right;
      bottom = b.bottom < bottom ? b.bottom : bottom;
    }
    runs.add(TextRun(
      page: page,
      key: '$page:$fragmentIndex:$start:$endExclusive',
      text: slice,
      box: PdfRect(left, top, right, bottom),
      fontSize: estimateFontSize(slice, boxes),
    ));
    start = -1;
  }

  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    final rect = i < charRects.length ? charRects[i] : null;
    if (_isWhitespace(ch) || rect == null || rect.isEmpty) {
      close(i);
      prevRect = rect ?? prevRect;
      continue;
    }
    if (prevRect != null && prevRect.isNotEmpty && start >= 0) {
      final sameLine = (rect.top + rect.bottom - prevRect.top - prevRect.bottom).abs() <
          rect.height * 0.6;
      final gap = rect.left - prevRect.right;
      final h = rect.height > prevRect.height ? rect.height : prevRect.height;
      // CJK runs split tighter (cell boundaries), latin runs tolerate word spaces.
      final gapLimit = h * (_hasCJK(text, start, i) ? 0.6 : 0.9);
      if (!sameLine || gap > gapLimit) close(i);
    }
    if (start < 0) start = i;
    prevRect = rect;
  }
  close(text.length);
  return runs;
}

bool _hasCJK(String s, int from, int to) {
  for (var i = from; i < to; i++) {
    if (_isCJK(s.codeUnitAt(i))) return true;
  }
  return false;
}

/// Preview font size estimate: CJK glyph boxes hug the em box; Latin/digit
/// boxes only cover cap/x height (~0.72 em). The export path calibrates the
/// exact size by measuring the created text object, this is display-only.
double estimateFontSize(String text, List<PdfRect> boxes) {
  final heights = boxes.map((b) => b.height).where((h) => h > 0).toList()..sort();
  if (heights.isEmpty) return 12;
  final median = heights[heights.length ~/ 2];
  final cjk = text.runes.any(_isCJK);
  return cjk ? median * 0.98 : median / 0.72;
}
