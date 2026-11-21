import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_text_editor/engine/runs.dart';
import 'package:pdfrx/pdfrx.dart';

PdfRect r(double l, double b, double w, double h) => PdfRect(l, b + h, l + w, b);

void main() {
  test('splits CJK label and digits at a wide gap', () {
    // "合同编号:" each char 12 wide, then a 20pt gap, then "12345"
    final rects = <PdfRect>[];
    var x = 100.0;
    for (var i = 0; i < 5; i++) {
      rects.add(r(x, 700, 12, 12));
      x += 12;
    }
    x += 20; // wide gap
    for (var i = 0; i < 5; i++) {
      rects.add(r(x, 702, 8, 8));
      x += 8;
    }
    final runs = groupRuns(page: 1, fragmentIndex: 0, text: '合同编号:12345', charRects: rects);
    expect(runs.map((e) => e.text).toList(), ['合同编号:', '12345']);
    expect(runs[0].box.left, 100);
    expect(runs[0].box.bottom, 700);
    expect(runs[0].box.top, 712);
    expect(runs[1].box.left, 180);
  });

  test('keeps digits together with tight spacing', () {
    final rects = <PdfRect>[];
    var x = 50.0;
    for (var i = 0; i < 5; i++) {
      rects.add(r(x, 300, 8, 8));
      x += 8.5;
    }
    final runs = groupRuns(page: 2, fragmentIndex: 0, text: '3.141', charRects: rects);
    expect(runs, hasLength(1));
    expect(runs[0].text, '3.141');
  });

  test('breaks at whitespace', () {
    final rects = [r(10, 100, 12, 12), r(22, 100, 6, 12), r(40, 100, 12, 12)];
    final runs = groupRuns(page: 1, fragmentIndex: 0, text: '甲 乙', charRects: rects);
    expect(runs.map((e) => e.text).toList(), ['甲', '乙']);
  });

  test('breaks at newline (y jump)', () {
    final rects = [r(10, 700, 12, 12), r(10, 700, 0, 0), r(10, 650, 12, 12)];
    final runs = groupRuns(page: 1, fragmentIndex: 0, text: '甲\n乙', charRects: rects);
    expect(runs.map((e) => e.text).toList(), ['甲', '乙']);
  });

  test('font size estimate: CJK vs digits', () {
    final cjk = estimateFontSize('合同', [r(0, 0, 12, 12)]);
    final digits = estimateFontSize('123', [r(0, 0, 8, 7.2)]);
    expect(cjk, closeTo(11.76, 0.01));
    expect(digits, closeTo(10.0, 0.01));
  });

  test('containsPoint hits inside padded box', () {
    final rects = [r(100, 700, 12, 12)];
    final run = groupRuns(page: 1, fragmentIndex: 0, text: '甲', charRects: rects).single;
    expect(run.containsPoint(106, 706), true);
    expect(run.containsPoint(103, 714), true); // within 3pt pad
    expect(run.containsPoint(50, 706), false);
  });
}
