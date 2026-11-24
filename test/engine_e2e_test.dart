import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_text_editor/engine/pdf_edit_engine.dart';
import 'package:pdf_text_editor/engine/pdfium_extra.dart' as x;
import 'package:pdf_text_editor/engine/runs.dart';
import 'package:pdf_text_editor/engine/system_font.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as pi;
import 'package:pdfrx/pdfrx.dart' show PdfRect;

const _black = 0xff000000;
const _red = 0xffc42d20;
const _digits = '10+2+12+10';
const _cases = [
  (
    page: 1,
    original: '365',
    replacement: '350',
    family: 'arial',
    size: 12.0,
    color: _black,
  ),
  (
    page: 2,
    original: '国寿财学平',
    replacement: '中国人寿财学平',
    family: 'simsun',
    size: 20.0,
    color: _black,
  ),
  (
    page: 3,
    original: '本说明为您的权益保障概要，',
    replacement: '本文本为您的权益保障概要，',
    family: 'simsun',
    size: 14.0,
    color: _red,
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late pi.PDFium pdfium;
  late Uint8List source;

  setUpAll(() {
    pdfium = pi.getPdfium();
    initPdfiumForEditing();
    source = File('test/fixtures/format_retention.pdf').readAsBytesSync();
  });

  test('replaces and visually deletes runs', () async {
    final fixture = withPdfium(pdfium, () => _buildFixture(pdfium));
    final runs = await PdfEditEngine.loadRuns(source: fixture, pageNumber: 1);
    expect(runs.map((run) => run.text), ['原始文字', '编号:12345']);
    final deletedBox = runs.last.box;
    expect(_renderRegion(pdfium, fixture, 1, deletedBox).any(_isDark), isTrue);

    final out = await PdfEditEngine.applyEdits(
      source: fixture,
      pages: [
        PageEdit(
          pageNumber: 1,
          edits: [
            RunEdit(run: runs.first, newText: '已修改'),
            RunEdit(run: runs.last, newText: ''),
          ],
        ),
      ],
    );
    expect(
      _renderRegion(pdfium, out, 1, deletedBox).every((rgb) => rgb == 0xffffff),
      isTrue,
      reason: 'The deleted text area should render white.',
    );
    final edited = await _loadRun(out, 1, '已修改');
    expect(edited.box.left, closeTo(runs.first.box.left, 1.5));
  });

  test(
    'reads original font, size, color, baseline and weight from PDF',
    () async {
      for (final example in _cases) {
        final run = await _loadRun(source, example.page, example.original);
        _expectFormat(run, example.family, example.size, example.color);
        expect(run.y, closeTo(72, 0.01));
      }

      final mixed = await PdfEditEngine.loadRuns(source: source, pageNumber: 2);
      expect(mixed.map((run) => run.text), [_digits, _cases[1].original]);
      _expectFormat(mixed.first, 'arial', 20, _black);
      expect(mixed.first.format.bold, isTrue);
      expect(mixed.last.format.bold, isFalse);

      final notice = await _loadRun(source, 3, _cases.last.original);
      expect(notice.format.bold, isTrue);
      expect(notice.format.renderMode, 2);
      expect(notice.format.strokeColor, _red);
      expect(notice.format.strokeWidth, closeTo(0.25, 0.01));
      expect(notice.format.a, closeTo(1.08, 0.001));
    },
  );

  final hasWindowsFonts =
      Platform.isWindows &&
      File('C:/Windows/Fonts/arial.ttf').existsSync() &&
      File('C:/Windows/Fonts/simsun.ttc').existsSync();
  test(
    'exports three edited pages with the originals’ formatting and new glyphs',
    () async {
      final originals = [
        for (final example in _cases)
          await _loadRun(source, example.page, example.original),
      ];
      final digitsBefore = await _loadRun(source, 2, _digits);
      final out = await PdfEditEngine.applyEdits(
        source: source,
        pages: [
          for (var i = 0; i < _cases.length; i++)
            PageEdit(
              pageNumber: _cases[i].page,
              edits: [
                RunEdit(run: originals[i], newText: _cases[i].replacement),
              ],
            ),
        ],
      );

      for (var i = 0; i < _cases.length; i++) {
        final example = _cases[i];
        final before = originals[i];
        final after = await _loadRun(out, example.page, example.replacement);
        _expectFormat(after, example.family, example.size, example.color);
        expect(after.format.bold, before.format.bold);
        expect(after.format.italic, before.format.italic);
        expect(after.format.renderMode, before.format.renderMode);
        expect(after.format.strokeColor, before.format.strokeColor);
        expect(
          after.format.strokeWidth,
          closeTo(before.format.strokeWidth, 0.01),
        );
        expect(after.format.a, closeTo(before.format.a, 0.001));
        expect(after.format.b, closeTo(before.format.b, 0.001));
        expect(after.format.c, closeTo(before.format.c, 0.001));
        expect(after.format.d, closeTo(before.format.d, 0.001));
        expect(after.x, closeTo(before.x, 0.02));
        expect(after.y, closeTo(before.y, 0.02));

        final newGlyph = switch (example.page) {
          1 => '0',
          2 => '中',
          _ => '文',
        };
        final glyphBox = _firstCharBox(pdfium, out, example.page, newGlyph);
        final pixels = _renderRegion(pdfium, out, example.page, glyphBox);
        expect(
          pixels.where(example.color == _red ? _isRed : _isDark).length,
          greaterThan(10),
          reason:
              'The new character $newGlyph must render in its original color.',
        );
      }

      final digitsAfter = await _loadRun(out, 2, _digits);
      _expectFormat(digitsAfter, 'arial', 20, _black);
      expect(digitsAfter.format.bold, isTrue);
      expect(
        listEquals(
          _renderRegion(pdfium, source, 2, digitsBefore.box),
          _renderRegion(pdfium, out, 2, digitsBefore.box),
        ),
        isTrue,
        reason:
            'Editing the Chinese heading must preserve the adjacent digits.',
      );
    },
    skip: hasWindowsFonts
        ? false
        : 'Requires the Windows Arial and SimSun faces.',
  );

  test(
    'rejects replacement glyphs unsupported by the original family',
    () async {
      final run = await _loadRun(source, 1, '365');
      await expectLater(
        PdfEditEngine.applyEdits(
          source: source,
          pages: [
            PageEdit(
              pageNumber: 1,
              edits: [RunEdit(run: run, newText: '365中')],
            ),
          ],
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('无法保持原字体'),
          ),
        ),
      );
    },
  );

  test('removes synthetic bold using the original embedded face', () async {
    final run = await _loadRun(source, 3, _cases.last.original);
    expect(run.format.syntheticBold, isTrue);
    expect(run.format.weight, 400);
    expect(run.format.fontName, matches(r'^[A-Z]{6}\+SimSun'));

    final out = await PdfEditEngine.applyEdits(
      source: source,
      pages: [
        PageEdit(
          pageNumber: 3,
          edits: [RunEdit(run: run, newText: run.text, bold: false)],
        ),
      ],
    );

    // Text extraction merges repeated, overlapping text on this page.
    _readPage(pdfium, out, 3, (page) {
      final obj = _lastTextObject(pdfium, page);
      final font = pdfium.FPDFTextObj_GetFont(obj);
      expect(pdfium.FPDFFont_GetIsEmbedded(font), 1);
      expect(pdfium.FPDFTextObj_GetTextRenderMode(obj).value, 0);
      using((arena) {
        final nameLength = pdfium.FPDFFont_GetBaseFontName(font, nullptr, 0);
        expect(nameLength, greaterThan(1));
        final name = arena<Char>(nameLength);
        pdfium.FPDFFont_GetBaseFontName(font, name, nameLength);
        expect(name.cast<Utf8>().toDartString(), run.format.fontName);

        final size = arena<Float>();
        expect(pdfium.FPDFTextObj_GetFontSize(obj, size), 1);
        expect(size.value, closeTo(14, 0.01));
        final rgba = arena<UnsignedInt>(4);
        expect(
          pdfium.FPDFPageObj_GetFillColor(
            obj,
            rgba,
            rgba + 1,
            rgba + 2,
            rgba + 3,
          ),
          1,
        );
        expect([rgba[0], rgba[1], rgba[2], rgba[3]], [196, 45, 32, 255]);
      });
    });
  });

  final hasHelveticaBold =
      loadSystemFont(
        fontName: 'Helvetica',
        familyName: '',
        weight: 700,
        italic: false,
      ) !=
      null;
  test(
    'changing non-embedded Helvetica to bold rejects a substitute family',
    () async {
      final fixture = File('test/fixtures/unembedded_helvetica.pdf')
          .readAsBytesSync();
      final run = await _loadRun(fixture, 1, 'Hello');
      expect(run.format.fontName, 'Helvetica');
      expect(run.format.bold, isFalse);
      _readPage(pdfium, fixture, 1, (page) {
        final obj = _lastTextObject(pdfium, page);
        expect(
          pdfium.FPDFFont_GetIsEmbedded(pdfium.FPDFTextObj_GetFont(obj)),
          0,
        );
      });

      await expectLater(
        PdfEditEngine.applyEdits(
          source: fixture,
          pages: [
            PageEdit(
              pageNumber: 1,
              edits: [RunEdit(run: run, newText: run.text, bold: true)],
            ),
          ],
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('无法保持原字体'),
          ),
        ),
      );
    },
    skip: hasHelveticaBold ? 'Genuine Helvetica Bold is installed.' : false,
  );
}

Future<TextRun> _loadRun(Uint8List bytes, int page, String text) async {
  final runs = await PdfEditEngine.loadRuns(source: bytes, pageNumber: page);
  final matches = runs.where((run) => run.text == text);
  expect(
    matches,
    hasLength(1),
    reason: 'Page $page runs: ${runs.map((r) => r.text)}',
  );
  return matches.single;
}

void _expectFormat(TextRun run, String family, double size, int color) {
  expect(run.format.familyName.toLowerCase(), startsWith(family));
  expect(run.format.fontSize, closeTo(size, 0.01));
  expect(run.format.color, color);
}

bool _isDark(int rgb) =>
    rgb >> 16 < 100 && (rgb >> 8 & 0xff) < 100 && (rgb & 0xff) < 100;

bool _isRed(int rgb) =>
    rgb >> 16 > 150 && (rgb >> 8 & 0xff) < 120 && (rgb & 0xff) < 120;

T _readPage<T>(
  pi.PDFium pdfium,
  Uint8List bytes,
  int pageNumber,
  T Function(pi.FPDF_PAGE) read,
) => withPdfium(pdfium, () {
  final data = calloc<Uint8>(bytes.length);
  data.asTypedList(bytes.length).setAll(0, bytes);
  final doc = pdfium.FPDF_LoadMemDocument(
    data.cast(),
    bytes.length,
    nullptr.cast(),
  );
  try {
    expect(doc, isNot(nullptr));
    final page = pdfium.FPDF_LoadPage(doc, pageNumber - 1);
    try {
      expect(page, isNot(nullptr));
      return read(page);
    } finally {
      pdfium.FPDF_ClosePage(page);
    }
  } finally {
    pdfium.FPDF_CloseDocument(doc);
    calloc.free(data);
  }
});

pi.FPDF_PAGEOBJECT _lastTextObject(pi.PDFium pdfium, pi.FPDF_PAGE page) {
  for (var i = pdfium.FPDFPage_CountObjects(page) - 1; i >= 0; i--) {
    final object = pdfium.FPDFPage_GetObject(page, i);
    if (pdfium.FPDFPageObj_GetType(object) == pi.FPDF_PAGEOBJ_TEXT) {
      return object;
    }
  }
  fail('No text object was found on the PDF page.');
}

List<int> _renderRegion(
  pi.PDFium pdfium,
  Uint8List bytes,
  int pageNumber,
  PdfRect box,
) => _readPage(pdfium, bytes, pageNumber, (page) {
  const scale = 2;
  final width = (pdfium.FPDF_GetPageWidthF(page) * scale).round();
  final height = (pdfium.FPDF_GetPageHeightF(page) * scale).round();
  final bitmap = pdfium.FPDFBitmap_Create(width, height, 0);
  try {
    expect(bitmap, isNot(nullptr));
    expect(
      pdfium.FPDFBitmap_FillRect(bitmap, 0, 0, width, height, 0xffffffff),
      1,
    );
    pdfium.FPDF_RenderPageBitmap(bitmap, page, 0, 0, width, height, 0, 0);
    final stride = pdfium.FPDFBitmap_GetStride(bitmap);
    final pixels = pdfium.FPDFBitmap_GetBuffer(bitmap)
        .cast<Uint8>()
        .asTypedList(stride * height);

    // PDF uses y-up coordinates, the BGRx bitmap uses y-down coordinates.
    final top = (height - box.top * scale).floor().clamp(0, height).toInt();
    final bottom = (height - box.bottom * scale)
        .ceil()
        .clamp(0, height)
        .toInt();
    final left = (box.left * scale).floor().clamp(0, width).toInt();
    final right = (box.right * scale).ceil().clamp(0, width).toInt();
    return [
      for (var y = top; y < bottom; y++)
        for (var x = left; x < right; x++)
          (pixels[y * stride + x * 4 + 2] << 16) |
              (pixels[y * stride + x * 4 + 1] << 8) |
              pixels[y * stride + x * 4],
    ];
  } finally {
    pdfium.FPDFBitmap_Destroy(bitmap);
  }
});

PdfRect _firstCharBox(
  pi.PDFium pdfium,
  Uint8List bytes,
  int pageNumber,
  String char,
) => _readPage(pdfium, bytes, pageNumber, (page) {
  final text = pdfium.FPDFText_LoadPage(page);
  final box = calloc<Double>(4);
  try {
    final count = pdfium.FPDFText_CountChars(text);
    for (var i = 0; i < count; i++) {
      if (pdfium.FPDFText_GetUnicode(text, i) == char.runes.single) {
        expect(
          pdfium.FPDFText_GetCharBox(text, i, box, box + 2, box + 1, box + 3),
          1,
        );
        return PdfRect(box[0], box[3], box[2], box[1]);
      }
    }
    fail('Character $char was not found on page $pageNumber.');
  } finally {
    calloc.free(box);
    pdfium.FPDFText_ClosePage(text);
  }
});

Uint8List _buildFixture(pi.PDFium pdfium) {
  final bytes = File('assets/fonts/NotoSansSC-Regular.ttf').readAsBytesSync();
  final buf = calloc<Uint8>(bytes.length);
  buf.asTypedList(bytes.length).setAll(0, bytes);
  final doc = pdfium.FPDF_CreateNewDocument();
  final page = pdfium.FPDFPage_New(doc, 0, 595, 842);
  try {
    final font = x.loadTrueTypeFont(doc.cast(), buf, bytes.length, 2, 1);
    expect(font, isNot(nullptr));
    _addText(pdfium, doc, page, font, '原始文字', 24, 100, 700);
    _addText(pdfium, doc, page, font, '编号:12345', 14, 100, 640);
    expect(pdfium.FPDFPage_GenerateContent(page), 1);
    return _save(pdfium, doc);
  } finally {
    pdfium.FPDF_ClosePage(page);
    pdfium.FPDF_CloseDocument(doc);
    calloc.free(buf);
  }
}

void _addText(
  pi.PDFium pdfium,
  pi.FPDF_DOCUMENT doc,
  pi.FPDF_PAGE page,
  Pointer<Void> font,
  String text,
  double size,
  double tx,
  double ty,
) {
  final obj = x.createTextObj(doc.cast(), font, size);
  expect(obj, isNot(nullptr));
  final wstr = x.toUtf16z(text, calloc);
  expect(pdfium.FPDFText_SetText(obj.cast(), wstr.cast()), 1);
  calloc.free(wstr);
  pdfium.FPDFPageObj_SetFillColor(obj.cast(), 0, 0, 0, 255);
  final matrix = calloc<pi.FS_MATRIX>();
  matrix.ref
    ..a = 1
    ..b = 0
    ..c = 0
    ..d = 1
    ..e = tx
    ..f = ty;
  expect(pdfium.FPDFPageObj_SetMatrix(obj.cast(), matrix), 1);
  calloc.free(matrix);
  expect(pdfium.FPDFPage_InsertObject(page, obj.cast()), 1);
}

Uint8List _save(pi.PDFium pdfium, pi.FPDF_DOCUMENT doc) {
  final sink = BytesBuilder(copy: true);
  final callable =
      NativeCallable<
        Int Function(Pointer<pi.FPDF_FILEWRITE>, Pointer<Void>, UnsignedLong)
      >.isolateLocal((
        Pointer<pi.FPDF_FILEWRITE> _,
        Pointer<Void> data,
        int size,
      ) {
        if (size > 0) sink.add(data.cast<Uint8>().asTypedList(size));
        return 1;
      }, exceptionalReturn: 0);
  final writer = calloc<pi.FPDF_FILEWRITE>();
  writer.ref.version = 1;
  writer.ref.WriteBlock = callable.nativeFunction;
  try {
    expect(pdfium.FPDF_SaveAsCopy(doc, writer, 0), 1);
    return sink.takeBytes();
  } finally {
    calloc.free(writer);
    callable.close();
  }
}
