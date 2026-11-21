// End-to-end engine test: build a fixture PDF with Chinese text via PDFium,
// apply edits through PdfEditEngine, then re-extract text and geometry to
// verify the white-out + replacement worked. Runs on the host (Linux) using
// the pdfium binary that pdfium_dart's native-assets hook materializes.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_text_editor/engine/pdf_edit_engine.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as pi;
import 'package:pdfrx/pdfrx.dart' show PdfRect;

import 'package:pdf_text_editor/engine/pdfium_extra.dart' as x;

Uint8List get font => File('assets/fonts/NotoSansSC-Regular.ttf').readAsBytesSync();

class FixtureRun {
  FixtureRun(this.text, this.box);
  final String text;
  final PdfRect box;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late pi.PDFium pdfium;
  setUpAll(() {
    pdfium = pi.getPdfium();
  });

  test('replace and delete text runs, verify by re-extraction', () async {
    final (fixture, runs) = withPdfium(pdfium, () => buildFixture(pdfium, font));
    // ignore: avoid_print
    print('T: fixture ${fixture.length} bytes, boxes: \${runs.map((r) => r.box)}');
    expect(runs.map((r) => r.text).toList(), ['原始文字', '编号:12345']);

    // ignore: avoid_print
    final out = await PdfEditEngine.applyEdits(
      source: fixture,
      fontRegular: font,
      fontBold: font,
      pages: [
        PageEdit(pageNumber: 1, edits: [
          RunEdit(
            runKey: '1:0:0:4',
            originalText: runs[0].text,
            newText: '已修改',
            box: runs[0].box,
            bold: false,
          ),
          RunEdit(
            runKey: '1:1:0:8',
            originalText: runs[1].text,
            newText: '', // 删除:盖白不写新字
            box: runs[1].box,
            bold: false,
          ),
        ]),
      ],
    );
    expect(out.length, greaterThan(1000));

    final text = withPdfium(pdfium, () => extractText(pdfium, out));
    expect(text, contains('已修改'));
    expect(text, isNot(contains('编号12345'))); // original line covered (spaces may differ)
    expect(_firstCharBoxLocked(pdfium, out, '已').left, closeTo(runs[0].box.left, 1.5));
  });
}

PdfRect _firstCharBoxLocked(pi.PDFium pdfium, Uint8List bytes, String ch) =>
    withPdfium(pdfium, () => firstCharBox(pdfium, out: bytes, ch: ch));

/// Creates a 1-page fixture with two text objects; returns bytes + their boxes.
(Uint8List, List<FixtureRun>) buildFixture(pi.PDFium pdfium, Uint8List fontBytes) {
  final doc = pdfium.FPDF_CreateNewDocument();
  final page = pdfium.FPDFPage_New(doc, 0, 595, 842);
  final runs = <FixtureRun>[
    addText(pdfium, doc, page, fontBytes, '原始文字', 24, 100, 700),
    addText(pdfium, doc, page, fontBytes, '编号:12345', 14, 100, 640),
  ];
  expect(pdfium.FPDFPage_GenerateContent(page), 1);
  final bytes = save(pdfium, doc);
  pdfium.FPDF_ClosePage(page);
  pdfium.FPDF_CloseDocument(doc);
  return (bytes, runs);
}

FixtureRun addText(pi.PDFium pdfium, pi.FPDF_DOCUMENT doc, pi.FPDF_PAGE page,
    Uint8List fontBytes, String text, double size, double tx, double ty) {
  final buf = calloc<Uint8>(fontBytes.length);
  buf.asTypedList(fontBytes.length).setAll(0, fontBytes);
  final f = x.loadTrueTypeFont(doc.cast(), buf, fontBytes.length, 2, 1);
  expect(f, isNot(nullptr));
  final obj = x.createTextObj(doc.cast(), f.cast(), size);
  expect(obj, isNot(nullptr));
  final wstr = x.toUtf16z(text, calloc);
  expect(pdfium.FPDFText_SetText(obj.cast(), wstr.cast()), 1);
  calloc.free(wstr);
  pdfium.FPDFPageObj_SetFillColor(obj.cast(), 0, 0, 0, 255);
  final m = calloc<pi.FS_MATRIX>();
  m.ref
    ..a = 1
    ..b = 0
    ..c = 0
    ..d = 1
    ..e = tx
    ..f = ty;
  expect(pdfium.FPDFPageObj_SetMatrix(obj.cast(), m), 1);
  calloc.free(m);
  final b = calloc<Float>(4);
  expect(pdfium.FPDFPageObj_GetBounds(obj.cast(), b, b + 1, b + 2, b + 3), 1);
  final box = PdfRect(b[0], b[3], b[2], b[1]);
  calloc.free(b);
  expect(pdfium.FPDFPage_InsertObject(page, obj.cast()), 1);
  return FixtureRun(text, box);
}

Uint8List save(pi.PDFium pdfium, pi.FPDF_DOCUMENT doc) {
  final sink = BytesBuilder(copy: true); // callback data is a view over pdfium-owned memory
  final callable = NativeCallable<
      Int Function(Pointer<pi.FPDF_FILEWRITE>, Pointer<Void>,
          UnsignedLong)>.isolateLocal(
      (Pointer<pi.FPDF_FILEWRITE> _, Pointer<Void> data, int size) {
    if (size > 0) sink.add(data.cast<Uint8>().asTypedList(size));
    return 1;
  }, exceptionalReturn: 0);
  final fw = calloc<pi.FPDF_FILEWRITE>();
  fw.ref.version = 1;
  fw.ref.WriteBlock = callable.nativeFunction;
  final ok = pdfium.FPDF_SaveAsCopy(doc, fw, 0);
  callable.close();
  final out = sink.takeBytes();
  calloc.free(fw);
  expect(ok, 1);
  return out;
}

String extractText(pi.PDFium pdfium, Uint8List bytes) {
  final data = calloc<Uint8>(bytes.length);
  data.asTypedList(bytes.length).setAll(0, bytes);
  final doc = pdfium.FPDF_LoadMemDocument(data.cast(), bytes.length, nullptr.cast());
  expect(doc, isNot(nullptr));
  final page = pdfium.FPDF_LoadPage(doc, 0);
  final tp = pdfium.FPDFText_LoadPage(page);
  final n = pdfium.FPDFText_CountChars(tp);
  final sb = StringBuffer();
  for (var i = 0; i < n; i++) {
    sb.writeCharCode(pdfium.FPDFText_GetUnicode(tp, i));
  }
  pdfium.FPDFText_ClosePage(tp);
  pdfium.FPDF_ClosePage(page);
  pdfium.FPDF_CloseDocument(doc);
  calloc.free(data);
  return sb.toString();
}

PdfRect firstCharBox(pi.PDFium pdfium, {required Uint8List out, required String ch}) {
  final data = calloc<Uint8>(out.length);
  data.asTypedList(out.length).setAll(0, out);
  final doc = pdfium.FPDF_LoadMemDocument(data.cast(), out.length, nullptr.cast());
  final page = pdfium.FPDF_LoadPage(doc, 0);
  final tp = pdfium.FPDFText_LoadPage(page);
  final n = pdfium.FPDFText_CountChars(tp);
  PdfRect? found;
  for (var i = 0; i < n && found == null; i++) {
    if (pdfium.FPDFText_GetUnicode(tp, i) == ch.codeUnitAt(0)) {
      final l = calloc<Double>(), b = calloc<Double>(), r = calloc<Double>(), t = calloc<Double>();
      pdfium.FPDFText_GetCharBox(tp, i, l, r, b, t);
      found = PdfRect(l.value, t.value, r.value, b.value);
      calloc.free(l);
      calloc.free(b);
      calloc.free(r);
      calloc.free(t);
    }
  }
  pdfium.FPDFText_ClosePage(tp);
  pdfium.FPDF_ClosePage(page);
  pdfium.FPDF_CloseDocument(doc);
  calloc.free(data);
  expect(found, isNotNull, reason: 'char $ch not found');
  return found!;
}
