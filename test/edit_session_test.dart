import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pdf_text_editor/edit_session.dart';
import 'package:pdf_text_editor/engine/pdf_edit_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(initPdfiumForEditing);

  test(
    'preview replaces an existing edit and undo restores the source bytes',
    () async {
      final source = File('test/fixtures/format_retention.pdf')
          .readAsBytesSync();
      final session = EditSession(await PdfDocument.openData(source), source);
      try {
        final run = (await session.runsForPage(1))
            .singleWhere((r) => r.text == '365');
        await session.upsertEdit(run, '350');
        final previous = session.previewBytes;
        final previousPixels = await _pixels(previous);
        expect(session.editCount, 1);
        expect(
          (await PdfEditEngine.loadRuns(
            source: previous,
            pageNumber: 1,
          )).any((r) => r.text == '350'),
          isTrue,
        );
        await session.upsertEdit(run, '355');
        expect(session.editCount, 1);
        expect(session.previewRevision, 2);
        expect(session.edits.single.newText, '355');
        expect(
          await _pixels(session.previewBytes),
          isNot(orderedEquals(previousPixels)),
        );
        await session.removeEdit(session.edits.single);
        expect(session.hasEdits, isFalse);
        expect(session.previewBytes, orderedEquals(source));
      } finally {
        session.dispose();
      }
    },
  );

  test(
    'an unrenderable edit leaves the displayed PDF and edit history intact',
    () async {
      final source = File('test/fixtures/format_retention.pdf')
          .readAsBytesSync();
      final session = EditSession(await PdfDocument.openData(source), source);
      try {
        final run = (await session.runsForPage(1))
            .singleWhere((r) => r.text == '365');
        await expectLater(session.upsertEdit(run, '中'), throwsStateError);
        expect(session.hasEdits, isFalse);
        expect(session.previewRevision, 0);
        expect(session.previewBytes, orderedEquals(source));
      } finally {
        session.dispose();
      }
    },
  );

  final hasFonts =
      Platform.isWindows &&
      File('C:/Windows/Fonts/simsun.ttc').existsSync() &&
      File('C:/Windows/Fonts/arialbd.ttf').existsSync();
  test(
    'a moved run remains editable by its original key and undo restores its box',
    () async {
      final source = File('test/fixtures/line_reflow.pdf').readAsBytesSync();
      final session = EditSession(await PdfDocument.openData(source), source);
      try {
        final runs = await session.runsForPage(1);
        final heading = runs.singleWhere((run) => run.text == '国寿财学平');
        final digits = runs.singleWhere((run) => run.text == '10+2+12+10');
        final original = session.previewBoxForRun(digits);
        expect(original, digits.box);

        await session.upsertEdit(heading, '中国人寿财学平');
        final shifted = session.previewBoxForRun(digits);
        expect(shifted.left, closeTo(original.left + 40, 0.5));

        await session.upsertEdit(digits, '10+12+10');
        expect(session.editCount, 2);
        final edited = session.previewBoxForRun(digits);
        expect(edited.left, closeTo(shifted.left, 0.5));
        expect(edited.right, lessThan(shifted.right));

        await session.removeEdit(session.editForRun(digits)!);
        expect(session.previewBoxForRun(digits), shifted);
        await session.removeEdit(session.edits.single);
        expect(session.previewBoxForRun(digits), original);
      } finally {
        session.dispose();
      }
    },
    skip: hasFonts
        ? false
        : 'Requires the Windows SimSun and Arial Bold faces.',
  );
}

Future<Uint8List> _pixels(Uint8List bytes) async {
  final document = await PdfDocument.openData(bytes);
  try {
    final page = document.pages.first;
    final image = await page.render(
      fullWidth: page.width * 2,
      fullHeight: page.height * 2,
    );
    expect(image, isNotNull);
    try {
      return Uint8List.fromList(image!.pixels);
    } finally {
      image!.dispose();
    }
  } finally {
    await document.dispose();
  }
}
