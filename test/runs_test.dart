import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_text_editor/engine/runs.dart';
import 'package:pdfrx/pdfrx.dart' show PdfRect;

const _simsun = PdfTextFormat(
  fontName: 'SimSun',
  familyName: 'SimSun',
  fontSize: 20,
);

PdfRect _rect(double left, double bottom, double width, double height) =>
    PdfRect(left, bottom + height, left + width, bottom);

List<PdfTextCharacter> _characters(
  String text,
  List<PdfRect> boxes, {
  List<PdfTextFormat>? formats,
}) => [
  for (var i = 0; i < text.length; i++)
    PdfTextCharacter(
      index: i,
      text: text[i],
      box: boxes[i],
      format: formats?[i] ?? _simsun,
      x: boxes[i].left,
      y: boxes[i].bottom,
    ),
];

void main() {
  test('splits CJK label and digits at a wide gap', () {
    final runs = groupRuns(
      page: 1,
      characters: _characters('合同编号:12345', [
        for (var i = 0; i < 5; i++) _rect(100.0 + 12 * i, 700, 12, 12),
        for (var i = 0; i < 5; i++) _rect(180.0 + 8 * i, 702, 8, 8),
      ]),
    );
    expect(runs.map((run) => run.text), ['合同编号:', '12345']);
    expect(runs.first.box, const PdfRect(100, 712, 160, 700));
    expect(runs.last.box.left, 180);
  });

  test('keeps digits together with tight spacing', () {
    final runs = groupRuns(
      page: 2,
      characters: _characters('3.141', [
        for (var i = 0; i < 5; i++) _rect(50 + 8.5 * i, 300, 8, 8),
      ]),
    );
    expect(runs.single.text, '3.141');
    expect(runs.single.page, 2);
  });

  test('breaks at whitespace', () {
    final runs = groupRuns(
      page: 1,
      characters: _characters('甲 乙', [
        _rect(10, 100, 12, 12),
        _rect(22, 100, 6, 12),
        _rect(40, 100, 12, 12),
      ]),
    );
    expect(runs.map((run) => run.text), ['甲', '乙']);
    expect(runs.last.sourceCharIndex, 2);
  });

  test('breaks at a line change', () {
    final runs = groupRuns(
      page: 1,
      characters: _characters('甲乙', [
        _rect(10, 700, 12, 12),
        _rect(10, 650, 12, 12),
      ]),
    );
    expect(runs.map((run) => run.text), ['甲', '乙']);
  });

  test('inherits the font size even when glyph heights differ', () {
    final run = groupRuns(
      page: 1,
      characters: _characters('中1', [
        _rect(10, 100, 12, 14),
        _rect(22, 100, 6, 8),
      ]),
    ).single;
    expect(run.text, '中1');
    expect(run.box.height, 14);
    expect(run.format.fontSize, 20);
  });

  test('separates adjacent runs when color or font changes', () {
    const redSimSun = PdfTextFormat(
      fontName: 'SimSun',
      familyName: 'SimSun',
      fontSize: 20,
      color: 0xffc42d20,
    );
    const redArial = PdfTextFormat(
      fontName: 'Arial',
      familyName: 'Arial',
      fontSize: 20,
      color: 0xffc42d20,
    );
    final runs = groupRuns(
      page: 1,
      characters: _characters(
        '甲乙1',
        [_rect(10, 100, 12, 12), _rect(22, 100, 12, 12), _rect(34, 100, 6, 8)],
        formats: [_simsun, redSimSun, redArial],
      ),
    );
    expect(runs.map((run) => run.text), ['甲', '乙', '1']);
    expect(runs.map((run) => run.format), [_simsun, redSimSun, redArial]);
  });

  test('containsPoint hits inside padded box', () {
    final run = groupRuns(
      page: 1,
      characters: _characters('甲', [_rect(100, 700, 12, 12)]),
    ).single;
    expect(run.containsPoint(106, 706), isTrue);
    expect(run.containsPoint(103, 714), isTrue);
    expect(run.containsPoint(50, 706), isFalse);
  });
}
