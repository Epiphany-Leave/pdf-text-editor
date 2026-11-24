import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_text_editor/engine/pdf_edit_engine.dart';
import 'package:pdf_text_editor/engine/runs.dart';

const _label = '被保险人证件号码：';
const _shortGrowth = '被保险人的证件号码：';
const _longLabel = '被保险人的有效证件号码：';
const _number = '00000000000000000X';
const _leftLabel = '单号：';
const _leftValue = 'DEMO1234';
const _rightColumn = '已受理';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final hasFonts =
      Platform.isWindows &&
      File('C:/Windows/Fonts/simsun.ttc').existsSync() &&
      File('C:/Windows/Fonts/arial.ttf').existsSync();

  group('reflows a PDF label and its number across a wider gap', () {
    late Uint8List source;
    late List<TextRun> original;

    setUpAll(() async {
      initPdfiumForEditing();
      source = File('test/fixtures/field_reflow.pdf').readAsBytesSync();
      original = await PdfEditEngine.loadRuns(source: source, pageNumber: 1);
      final label = _find(original, _label);
      final number = _find(original, _number);
      expect(number.y, closeTo(label.y, 0.05));
      expect(
        number.box.left - label.box.right,
        greaterThan(label.format.fontSize * 0.6),
      );
      expect(number.format.familyName.toLowerCase(), startsWith('arial'));
      expect(number.format.fontSize, closeTo(13, 0.01));
      expect(number.format.color, 0xff194678);
    });

    test('uses the existing gap before moving the number', () async {
      final out = await _editLabel(
        source,
        _find(original, _label),
        _shortGrowth,
      );
      final runs = await PdfEditEngine.loadRuns(source: out, pageNumber: 1);
      final number = _find(runs, _number);
      expect(number.x, closeTo(_find(original, _number).x, 0.05));
      expect(number.box.left, greaterThan(_find(runs, _shortGrowth).box.right));
    });

    test('moves the number when the longer label needs more space', () async {
      final originalLabel = _find(original, _label);
      final originalNumber = _find(original, _number);
      final out = await _editLabel(source, originalLabel, _longLabel);
      final runs = await PdfEditEngine.loadRuns(source: out, pageNumber: 1);
      final label = _find(runs, _longLabel);
      final number = _find(runs, _number);

      expect(label.x, closeTo(originalLabel.x, 0.05));
      expect(label.y, closeTo(originalLabel.y, 0.05));
      expect(label.box.right, greaterThan(originalNumber.box.left));
      expect(number.x, greaterThan(originalNumber.x));
      expect(number.y, closeTo(originalNumber.y, 0.05));
      expect(number.box.left, greaterThanOrEqualTo(label.box.right));
      expect(number.format.fontName, originalNumber.format.fontName);
      expect(
        number.format.fontSize,
        closeTo(originalNumber.format.fontSize, 0.01),
      );
      expect(number.format.color, originalNumber.format.color);
      for (final text in [_leftLabel, _leftValue]) {
        final before = _find(original, text);
        final after = _find(runs, text);
        expect(after.x, closeTo(before.x, 0.05));
        expect(after.y, closeTo(before.y, 0.05));
      }
    });

    test(
      'rejects a displaced number that would cover another column',
      () async {
        final runs = await PdfEditEngine.loadRuns(
          source: source,
          pageNumber: 2,
        );
        expect(
          _find(runs, _rightColumn).box.left,
          greaterThan(_find(runs, _number).box.right),
        );
        await expectLater(
          _editLabel(source, _find(runs, _label), _longLabel),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('会压住其他内容'),
            ),
          ),
        );
      },
    );
  }, skip: hasFonts ? false : 'Requires the Windows SimSun and Arial faces.');
}

Future<Uint8List> _editLabel(Uint8List source, TextRun label, String newText) =>
    PdfEditEngine.applyEdits(
      source: source,
      pages: [
        PageEdit(
          pageNumber: label.page,
          edits: [RunEdit(run: label, newText: newText)],
        ),
      ],
    );

TextRun _find(List<TextRun> runs, String text) {
  final matches = runs.where((run) => run.text == text);
  expect(
    matches,
    hasLength(1),
    reason: 'Text runs: ${runs.map((run) => run.text)}',
  );
  return matches.single;
}
