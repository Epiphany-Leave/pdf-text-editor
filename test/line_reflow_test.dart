import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_text_editor/engine/pdf_edit_engine.dart';
import 'package:pdf_text_editor/engine/runs.dart';
import 'package:pdfrx/pdfrx.dart' show PdfRect;
import 'package:pdfium_dart/pdfium_dart.dart' as pi;

const _heading = '国寿财学平';
const _longHeading = '中国人寿财学平';
const _shortHeading = '财学平';
const _digits = '10+2+12+10';
const _shortDigits = '10+12+10';
const _unit = '年';
const _column = '单独栏';
const _blue = 0xff194678;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initPdfiumForEditing);
  final hasFonts =
      Platform.isWindows &&
      File('C:/Windows/Fonts/simsun.ttc').existsSync() &&
      File('C:/Windows/Fonts/arialbd.ttf').existsSync();

  group(
    'reflows mixed-format PDF text on one line',
    () {
      late Uint8List source;
      late List<TextRun> originals;

      setUpAll(() async {
        source = File('test/fixtures/line_reflow.pdf').readAsBytesSync();
        originals = await PdfEditEngine.loadRuns(source: source, pageNumber: 1);
        expect(originals.map((run) => run.text), [
          _heading,
          _digits,
          _unit,
          _column,
        ]);
        final digits = _find(originals, _digits);
        expect(digits.format.familyName.toLowerCase(), startsWith('arial'));
        expect(digits.format.bold, isTrue);
        expect(digits.format.fontSize, closeTo(20, 0.01));
        expect(digits.format.color, _blue);
      });

      for (final (description, replacement, shift) in [
        ('moves the digits right when the heading grows', _longHeading, 40.0),
        (
          'moves the digits left when the heading shrinks',
          _shortHeading,
          -40.0,
        ),
      ]) {
        test(description, () async {
          final heading = _find(originals, _heading);
          final out = await PdfEditEngine.applyEdits(
            source: source,
            pages: [
              PageEdit(
                pageNumber: 1,
                edits: [RunEdit(run: heading, newText: replacement)],
              ),
            ],
          );
          final runs = await PdfEditEngine.loadRuns(source: out, pageNumber: 1);

          final digits = _find(runs, _digits);
          _expectMoved(_find(originals, _digits), digits, shift);
          final updated = _find(runs, replacement);
          expect(updated.x, closeTo(heading.x, 0.05));
          expect(updated.y, closeTo(heading.y, 0.05));
          expect(digits.box.left, greaterThanOrEqualTo(updated.box.right));
          _expectMoved(_find(originals, _unit), _find(runs, _unit), shift);
          _expectMoved(_find(originals, _column), _find(runs, _column), 0);

          final beforeInk = _blueInk(source);
          expect(beforeInk, isNotEmpty);
          final afterInk = _blueInk(out);
          expect(afterInk.length, beforeInk.length);
          expect(
            beforeInk.every(
              (pixel) => afterInk.contains(pixel + (2 * shift).round()),
            ),
            isTrue,
            reason:
                'All of the visible digits should move with their text boxes.',
          );
        });
      }

      test(
        'applies both width changes once to the runs after two edits',
        () async {
          final digits = _find(originals, _digits);
          final out = await PdfEditEngine.applyEdits(
            source: source,
            pages: [
              PageEdit(
                pageNumber: 1,
                edits: [
                  RunEdit(run: digits, newText: _shortDigits),
                  RunEdit(
                    run: _find(originals, _heading),
                    newText: _longHeading,
                  ),
                ],
              ),
            ],
          );
          final runs = await PdfEditEngine.loadRuns(source: out, pageNumber: 1);
          final updatedDigits = _find(runs, _shortDigits);
          expect(updatedDigits.x, closeTo(digits.x + 40, 0.5));
          _expectStyle(digits, updatedDigits);
          expect(
            updatedDigits.format.familyName.toLowerCase(),
            startsWith('arial'),
          );
          expect(
            updatedDigits.box.left,
            greaterThanOrEqualTo(_find(runs, _longHeading).box.right),
          );
          // Two SimSun glyphs add 40 pt. Removing "+2" in Arial Bold saves 22.8 pt.
          final unit = _find(runs, _unit);
          _expectMoved(_find(originals, _unit), unit, 17.2);
          expect(unit.box.left, greaterThanOrEqualTo(updatedDigits.box.right));
          _expectMoved(_find(originals, _column), _find(runs, _column), 0);
        },
      );

      test('rejects an edit that would cover the independent column', () async {
        await expectLater(
          PdfEditEngine.applyEdits(
            source: source,
            pages: [
              PageEdit(
                pageNumber: 1,
                edits: [
                  RunEdit(
                    run: _find(originals, _heading),
                    // The line ends around x=479, within the 505 pt page.
                    newText: _heading * 3,
                  ),
                ],
              ),
            ],
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('会压住其他内容'),
            ),
          ),
        );
      });

      test(
        'expands into space freed by deleting the independent column',
        () async {
          final out = await PdfEditEngine.applyEdits(
            source: source,
            pages: [
              PageEdit(
                pageNumber: 1,
                edits: [
                  RunEdit(
                    run: _find(originals, _heading),
                    newText: _heading * 3,
                  ),
                  RunEdit(run: _find(originals, _column), newText: ''),
                ],
              ),
            ],
          );
          final runs = await PdfEditEngine.loadRuns(source: out, pageNumber: 1);
          expect(runs.map((run) => run.text), isNot(contains(_column)));
          _expectMoved(_find(originals, _digits), _find(runs, _digits), 200);
        },
      );
    },
    skip: hasFonts
        ? false
        : 'Requires the Windows SimSun and Arial Bold faces.',
  );

  test('preserves the following word in a shared PDF text object', () async {
    final source = File('test/fixtures/line_shared_object.pdf')
        .readAsBytesSync();
    final originals = await PdfEditEngine.loadRuns(
      source: source,
      pageNumber: 1,
    );
    expect(originals.map((run) => run.text), ['100', '123456']);
    final follower = originals.last;
    expect(follower.format.fontName, 'Helvetica');

    final out = await PdfEditEngine.applyEdits(
      source: source,
      pages: [
        PageEdit(
          pageNumber: 1,
          edits: [RunEdit(run: originals.first, newText: '1')],
        ),
      ],
    );
    final runs = await PdfEditEngine.loadRuns(source: out, pageNumber: 1);
    final shifted = runs.where(
      (run) => run.text == follower.text && run.x < follower.x - 10,
    );
    expect(
      shifted,
      hasLength(1),
      reason: 'Text runs: ${runs.map((r) => '${r.text} @ ${r.x}')}',
    );
    final moved = shifted.single;
    expect(moved.x, closeTo(follower.x - 20, 1.5));
    expect(moved.format.fontName, follower.format.fontName);
    _expectStyle(follower, moved);

    final beforeInk = _blueInk(source, within: follower.box);
    expect(beforeInk, isNotEmpty);
    final afterInk = _blueInk(out, within: moved.box);
    expect(afterInk.length, closeTo(beforeInk.length, beforeInk.length * 0.08));
    expect(
      _blueInk(
        out,
        within: PdfRect(
          moved.box.right + 1,
          follower.box.top,
          follower.box.right + 1,
          follower.box.bottom,
        ),
      ),
      isEmpty,
      reason: 'The old position should contain no trailing glyphs.',
    );
  });
}

TextRun _find(List<TextRun> runs, String text) {
  final matches = runs.where((run) => run.text == text);
  expect(
    matches,
    hasLength(1),
    reason: 'Text runs: ${runs.map((run) => run.text)}',
  );
  return matches.single;
}

void _expectMoved(TextRun before, TextRun after, double shift) {
  expect(after.x, closeTo(before.x + shift, 0.5), reason: before.text);
  expect(after.box.left, closeTo(before.box.left + shift, 0.5));
  expect(after.box.right, closeTo(before.box.right + shift, 0.5));
  expect(after.format.fontName, before.format.fontName);
  _expectStyle(before, after);
}

void _expectStyle(TextRun before, TextRun after) {
  expect(after.y, closeTo(before.y, 0.05));
  expect(after.format.fontSize, closeTo(before.format.fontSize, 0.01));
  expect(after.format.color, before.format.color);
  expect(after.format.weight, before.format.weight);
  expect(after.format.bold, before.format.bold);
}

Set<int> _blueInk(Uint8List bytes, {PdfRect? within}) {
  final pdfium = pi.getPdfium();
  return withPdfium(
    pdfium,
    () => using((arena) {
      final data = arena<Uint8>(bytes.length)
        ..asTypedList(bytes.length).setAll(0, bytes);
      final doc = pdfium.FPDF_LoadMemDocument(
        data.cast(),
        bytes.length,
        nullptr,
      );
      expect(doc, isNot(nullptr));
      try {
        final page = pdfium.FPDF_LoadPage(doc, 0);
        expect(page, isNot(nullptr));
        try {
          final width = (pdfium.FPDF_GetPageWidthF(page) * 2).round();
          final height = (pdfium.FPDF_GetPageHeightF(page) * 2).round();
          final bitmap = pdfium.FPDFBitmap_Create(width, height, 0);
          expect(bitmap, isNot(nullptr));
          try {
            pdfium.FPDFBitmap_FillRect(bitmap, 0, 0, width, height, 0xffffffff);
            pdfium.FPDF_RenderPageBitmap(
              bitmap,
              page,
              0,
              0,
              width,
              height,
              0,
              0,
            );
            final stride = pdfium.FPDFBitmap_GetStride(bitmap);
            final pixels = pdfium.FPDFBitmap_GetBuffer(bitmap)
                .cast<Uint8>()
                .asTypedList(stride * height);
            final left = within == null
                ? 0
                : (within.left * 2).floor().clamp(0, width);
            final right = within == null
                ? width
                : (within.right * 2).ceil().clamp(0, width);
            final top = within == null
                ? 0
                : (height - within.top * 2).floor().clamp(0, height);
            final bottom = within == null
                ? height
                : (height - within.bottom * 2).ceil().clamp(0, height);
            final ink = <int>{};
            for (var y = top; y < bottom; y++) {
              for (var x = left; x < right; x++) {
                final index = y * stride + x * 4;
                if (pixels[index] - pixels[index + 2] > 35) {
                  ink.add(y * width + x);
                }
              }
            }
            return ink;
          } finally {
            pdfium.FPDFBitmap_Destroy(bitmap);
          }
        } finally {
          pdfium.FPDF_ClosePage(page);
        }
      } finally {
        pdfium.FPDF_CloseDocument(doc);
      }
    }),
  );
}
