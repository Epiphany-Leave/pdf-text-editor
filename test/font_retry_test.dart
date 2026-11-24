import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_text_editor/edit_session.dart';
import 'package:pdf_text_editor/engine/pdf_edit_engine.dart';
import 'package:pdf_text_editor/engine/runs.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Uint8List source;
  late Uint8List noto;
  setUpAll(() {
    initPdfiumForEditing();
    source = File('test/fixtures/font_retry.pdf').readAsBytesSync();
    noto = File('assets/fonts/NotoSansSC-Regular.ttf').readAsBytesSync();
  });

  test(
    'retries an embedded CJK subset with the complete matching face',
    () async {
      final requests = <MissingPdfFont>[];
      final session = EditSession(
        await PdfDocument.openData(source),
        source,
        resolveFont: (missing) async {
          requests.add(missing);
          return noto;
        },
      );
      addTearDown(session.dispose);
      final original = (await session.runsForPage(1)).first;
      expect(original.text, '原始文字');
      expect(
        original.format.fontName,
        matches(r'^[A-Z]{6}\+Noto Sans SC Regular$'),
      );

      await session.upsertEdit(original, '已修改');

      expect(requests, hasLength(1));
      final missing = requests.single;
      expect(missing.runKey, original.key);
      expect(missing.text, '已修改');
      expect(missing.familyName, original.format.familyName);
      expect(missing.weight, 400);
      expect(missing.italic, isFalse);
      final runs = await _pageRuns(session.previewBytes);
      expect(runs.map((run) => run.text), unorderedEquals(['Before', '已修改']));
      final edited = runs.singleWhere((run) => run.text == '已修改');
      expect(edited.format.familyName, original.format.familyName);
      expect(edited.format.fontSize, original.format.fontSize);
      expect(edited.x, closeTo(original.x, 0.01));
      expect(edited.y, closeTo(original.y, 0.01));
    },
  );

  test(
    'an approximate edit changes the PDF only after preview approval',
    () async {
      final session = EditSession(await PdfDocument.openData(source), source);
      addTearDown(session.dispose);
      final [untouched, target] = await session.runsForPage(1);
      expect(target.text, 'Before');
      const replacement = '示例文本';
      await expectLater(
        session.upsertEdit(target, replacement),
        throwsA(isA<MissingPdfFont>()),
      );
      expect(session.previewBytes, same(source));

      var approved = false;
      Uint8List? shownPreview;
      Future<bool> confirm(Uint8List bytes, PdfRect? box) async {
        final runs = await _pageRuns(bytes);
        expect(runs, hasLength(2));
        final other = runs.singleWhere((run) => run.text == untouched.text);
        final edited = runs.singleWhere((run) => run.text == replacement);
        expect(edited.format.familyName, untouched.format.familyName);
        expect(edited.format.fontSize, target.format.fontSize);
        expect(edited.format.color, target.format.color);
        expect(other.format.fontName, untouched.format.fontName);
        expect(other.box, untouched.box);
        expect(box, isNotNull);
        expect(session.previewBytes, same(source));
        expect(session.hasEdits, isFalse);
        shownPreview = bytes;
        return approved;
      }

      await session.upsertEdit(
        target,
        replacement,
        substituteFont: noto,
        confirmPreview: confirm,
      );
      expect(shownPreview, isNotNull);
      expect(session.previewBytes, same(source));
      expect(session.editCount, 0);
      expect(session.previewRevision, 0);

      approved = true;
      await session.upsertEdit(
        target,
        replacement,
        substituteFont: noto,
        confirmPreview: confirm,
      );
      expect(session.previewBytes, same(shownPreview));
      expect(session.edits.single.runKey, target.key);
      expect(session.previewRevision, 1);
    },
  );
}

Future<List<TextRun>> _pageRuns(Uint8List bytes) =>
    PdfEditEngine.loadRuns(source: bytes, pageNumber: 1);
