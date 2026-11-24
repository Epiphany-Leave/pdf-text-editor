// PDF write path: applies text edits to a PDF in memory with PDFium's editing
// API (the same engine pdfrx uses for reading, so coordinates match 1:1).
//
// Replacement text keeps its original style. Adjacent runs on the same
// baseline shift by the measured change in width.
import 'dart:ffi';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as pi;
import 'package:pdfrx/pdfrx.dart' show PdfRect, Pdfrx;

import 'pdfium_extra.dart' as x;
import 'runs.dart';
import 'system_font.dart';

class PageEdit {
  PageEdit({required this.pageNumber, required this.edits});

  final int pageNumber; // 1-based
  final List<RunEdit> edits;
}

class RunEdit {
  RunEdit({
    required this.run,
    required this.newText,
    this.bold,
    this.substituteFont,
  });
  final TextRun run;
  final String newText;
  final bool? bold;
  final Uint8List? substituteFont;
  String get runKey => run.key;
  String get originalText => run.text;
  PdfRect get box => run.box;
}

class MissingPdfFont extends StateError {
  MissingPdfFont({
    required this.fontName,
    required this.familyName,
    required this.weight,
    required this.italic,
    required this.runKey,
    required this.text,
  }) : super('无法保持原字体“$fontName”：原字体缺少新文字，请安装同款完整字体后重试。');

  final String fontName, familyName, runKey, text;
  final int weight;
  final bool italic;

  // Fonts with the same name can have different coverage across versions.
  String get key => jsonEncode([fontName, familyName, weight, italic, text]);
}

/// MUST run at app startup, before any pdfrx viewer loads a document:
/// claims the process-wide PDFium gate and performs the single
/// FPDF_InitLibrary for the whole process. The viewer then sees the gate
/// claimed and skips its own init; without this, initializing PDFium twice
/// from two threads segfaults (the Android export crash).
void initPdfiumForEditing() {
  Pdfrx.useProcessWidePdfiumGate = true;
  try {
    final pdfium = pi.getPdfium();
    pi.PdfiumProcessGate.enable();
    pi.PdfiumProcessGate.acquire();
    try {
      if (pi.PdfiumProcessGate.claimInit()) {
        pdfium.FPDF_InitLibrary();
      }
    } finally {
      pi.PdfiumProcessGate.release();
    }
  } catch (_) {
    // Gate unavailable: pdfrx keeps ownership of FPDF_InitLibrary; the
    // engine below never initializes, so no double-init can happen.
  }
}

/// Holds the process-wide gate while [work] runs, serializing PDFium calls
/// against the viewer's background worker. Never calls FPDF_InitLibrary.
/// Best effort: if the gate cannot be resolved in this isolate, [work]
/// still runs (the caller must ensure no concurrent rendering — see
/// PdfViewerParams.isVisible in viewer_page.dart).
T withPdfium<T>(pi.PDFium pdfium, T Function() work) {
  bool gated = false;
  try {
    pi.PdfiumProcessGate.acquire();
    gated = true;
  } catch (_) {
    gated = false;
  }
  try {
    return work();
  } finally {
    if (gated) {
      try {
        pi.PdfiumProcessGate.release();
      } catch (_) {}
    }
  }
}

class PdfEditEngine {
  static final _numberLabel = RegExp(r'(?:号码|编号|证件号|身份证号)[:：]$');
  static final _numberValue = RegExp(r'^[0-9]{2,}[Xx]?$');

  static Future<List<TextRun>> loadRuns({
    required Uint8List source,
    required int pageNumber,
  }) => Isolate.run(
    () => _withDocument(source, (pdfium, doc, arena) {
      final page = pdfium.FPDF_LoadPage(doc, pageNumber - 1);
      if (page == nullptr) throw StateError('无法打开第 $pageNumber 页');
      try {
        return groupRuns(
          page: pageNumber,
          characters: _characters(pdfium, page, arena),
        );
      } finally {
        pdfium.FPDF_ClosePage(page);
      }
    }),
  );

  static Future<Uint8List> applyEdits({
    required Uint8List source,
    required List<PageEdit> pages,
  }) async => (await renderEdits(source: source, pages: pages)).bytes;

  static Future<({Uint8List bytes, Map<String, PdfRect> boxes})> renderEdits({
    required Uint8List source,
    required List<PageEdit> pages,
    Map<String, Uint8List> matchingFonts = const {},
  }) => Isolate.run(
    () => _withDocument(source, (pdfium, doc, arena) {
      final fonts = _EditFonts(pdfium, doc, arena, matchingFonts);
      final boxes = <String, PdfRect>{};
      try {
        for (final edits in pages) {
          final page = pdfium.FPDF_LoadPage(doc, edits.pageNumber - 1);
          if (page == nullptr) throw StateError('无法打开第 ${edits.pageNumber} 页');
          try {
            boxes.addAll(_applyPage(pdfium, doc, page, edits, fonts, arena));
            if (pdfium.FPDFPage_GenerateContent(page) == 0) {
              throw StateError('页面内容生成失败');
            }
          } finally {
            pdfium.FPDF_ClosePage(page);
          }
        }
        return (bytes: _save(pdfium, doc), boxes: boxes);
      } finally {
        fonts.close();
      }
    }),
  );

  static T _withDocument<T>(
    Uint8List source,
    T Function(pi.PDFium, pi.FPDF_DOCUMENT, Arena) work,
  ) {
    final pdfium = pi.getPdfium();
    return withPdfium(
      pdfium,
      () => using((arena) {
        final data = arena<Uint8>(source.length)
          ..asTypedList(source.length).setAll(0, source);
        final doc = pdfium.FPDF_LoadMemDocument(
          data.cast(),
          source.length,
          nullptr.cast(),
        );
        if (doc == nullptr) {
          throw StateError('无法打开 PDF 文件，错误码 ${pdfium.FPDF_GetLastError()}');
        }
        try {
          return work(pdfium, doc, arena);
        } finally {
          pdfium.FPDF_CloseDocument(doc);
        }
      }),
    );
  }

  static List<PdfTextCharacter> _characters(
    pi.PDFium p,
    pi.FPDF_PAGE page,
    Arena arena, {
    void Function(int index, int rune, pi.FPDF_PAGEOBJECT object)? onCharacter,
  }) {
    final tp = p.FPDFText_LoadPage(page);
    if (tp == nullptr) throw StateError('无法读取 PDF 文字');
    final chars = <PdfTextCharacter>[];
    final bounds = arena<Double>(4), origin = arena<Double>(2);
    final loose = arena<pi.FS_RECTF>();
    final size = arena<Float>(), width = arena<Float>();
    final matrix = arena<pi.FS_MATRIX>(), rgba = arena<UnsignedInt>(4);
    final names = <int, (String, String)>{};
    try {
      for (var i = 0; i < p.FPDFText_CountChars(tp); i++) {
        final rune = p.FPDFText_GetUnicode(tp, i);
        final obj = p.FPDFText_GetTextObject(tp, i);
        onCharacter?.call(i, rune, obj);
        if (rune == 0) continue;
        if (obj == nullptr) {
          // Generated spaces and line breaks must still separate editable runs.
          chars.add(
            PdfTextCharacter(
              index: i,
              text: String.fromCharCode(rune),
              box: const PdfRect(0, 0, 0, 0),
              format: const PdfTextFormat(
                fontName: '',
                familyName: '',
                fontSize: 0,
              ),
              x: 0,
              y: 0,
            ),
          );
          continue;
        }
        if (p.FPDFText_GetCharBox(
                  tp,
                  i,
                  bounds,
                  bounds + 2,
                  bounds + 1,
                  bounds + 3,
                ) ==
                0 ||
            p.FPDFText_GetCharOrigin(tp, i, origin, origin + 1) == 0 ||
            p.FPDFText_GetMatrix(tp, i, matrix) == 0 ||
            p.FPDFTextObj_GetFontSize(obj, size) == 0) {
          throw StateError('无法读取原文字的位置或字号');
        }
        final font = p.FPDFTextObj_GetFont(obj);
        final name = names.putIfAbsent(
          font.address,
          () => (
            _fontName(
              (buffer, length) =>
                  p.FPDFFont_GetBaseFontName(font, buffer, length),
            ),
            _fontName(
              (buffer, length) =>
                  p.FPDFFont_GetFamilyName(font, buffer, length),
            ),
          ),
        );
        if (p.FPDFText_GetFillColor(
              tp,
              i,
              rgba,
              rgba + 1,
              rgba + 2,
              rgba + 3,
            ) ==
            0) {
          throw StateError('无法读取原文字颜色');
        }
        final color = _argb(rgba);
        final stroke =
            p.FPDFText_GetStrokeColor(
                  tp,
                  i,
                  rgba,
                  rgba + 1,
                  rgba + 2,
                  rgba + 3,
                ) !=
                0
            ? _argb(rgba)
            : color;
        p.FPDFPageObj_GetStrokeWidth(obj, width);
        final flags = p.FPDFFont_GetFlags(font);
        final rawWeight = p.FPDFText_GetFontWeight(tp, i);
        final namedBold = RegExp(
          'bold|heavy|black',
          caseSensitive: false,
        ).hasMatch(name.$1);
        final weight = namedBold && rawWeight < 600
            ? 700
            : (rawWeight > 0 ? rawWeight : 400);
        chars.add(
          PdfTextCharacter(
            index: i,
            text: String.fromCharCode(rune),
            box: PdfRect(bounds[0], bounds[3], bounds[2], bounds[1]),
            x: origin[0],
            y: origin[1],
            advanceRight: p.FPDFText_GetLooseCharBox(tp, i, loose) != 0
                ? loose.ref.right
                : null,
            format: PdfTextFormat(
              fontName: name.$1,
              familyName: name.$2,
              fontSize: size.value,
              fontId: font.address,
              color: color,
              weight: weight,
              italic: flags >= 0 && flags & 64 != 0,
              renderMode: p.FPDFTextObj_GetTextRenderMode(obj).value,
              strokeColor: stroke,
              strokeWidth: width.value,
              a: matrix.ref.a,
              b: matrix.ref.b,
              c: matrix.ref.c,
              d: matrix.ref.d,
            ),
          ),
        );
      }
      return chars;
    } finally {
      p.FPDFText_ClosePage(tp);
    }
  }

  static Map<String, PdfRect> _applyPage(
    pi.PDFium p,
    pi.FPDF_DOCUMENT doc,
    pi.FPDF_PAGE page,
    PageEdit edits,
    _EditFonts fonts,
    Arena arena,
  ) {
    final indexToObject = <int, pi.FPDF_PAGEOBJECT>{};
    final objectIndices = <pi.FPDF_PAGEOBJECT, List<int>>{};
    final known = <pi.FPDF_FONT, Set<int>>{};
    final characters = _characters(
      p,
      page,
      arena,
      onCharacter: (index, rune, object) {
        if (object == nullptr) return;
        indexToObject[index] = object;
        objectIndices.putIfAbsent(object, () => []).add(index);
        final font = p.FPDFTextObj_GetFont(object);
        known.putIfAbsent(font, () => {}).add(rune);
      },
    );
    final charAt = {for (final char in characters) char.index: char};
    final runs = groupRuns(page: edits.pageNumber, characters: characters);
    final changeByKey = {for (final edit in edits.edits) edit.runKey: edit};
    final pending = <pi.FPDF_PAGEOBJECT>{};
    final replaced = <pi.FPDF_PAGEOBJECT>{};
    final masks = <PdfRect>[];
    final boxes = <String, PdfRect>{};
    final separations = <(TextRun, TextRun)>[];
    final originalMoves = <TextRun, (Set<pi.FPDF_PAGEOBJECT>, double)>{};
    final topLevel = {
      for (var i = 0; i < p.FPDFPage_CountObjects(page); i++)
        p.FPDFPage_GetObject(page, i),
    };

    pi.FPDF_FONT chooseFont(RunEdit edit) {
      final object = indexToObject[edit.run.sourceCharIndex];
      if (object == null) throw StateError('找不到原文字');
      final font = p.FPDFTextObj_GetFont(object);
      return fonts.resolve(font, edit, known[font] ?? {});
    }

    Set<pi.FPDF_PAGEOBJECT>? wholeObjects(TextRun run) {
      final objects = {
        for (var j = run.sourceCharIndex; j < run.sourceEndIndex; j++)
          ?indexToObject[j],
      };
      if (objects.isEmpty ||
          objects.any(
            (object) =>
                !topLevel.contains(object) ||
                objectIndices[object]!.any(
                  (j) => j < run.sourceCharIndex || j >= run.sourceEndIndex,
                ),
          )) {
        return null;
      }
      return objects;
    }

    void redrawAtOffset(TextRun run, double dx) {
      final unchanged = RunEdit(run: run, newText: run.text);
      final font = chooseFont(unchanged);
      for (var j = run.sourceCharIndex; j < run.sourceEndIndex; j++) {
        final char = charAt[j];
        if (char == null || char.text.trim().isEmpty) continue;
        pending.add(
          _createText(
            p,
            doc,
            font,
            unchanged,
            arena,
            text: char.text,
            xPosition: char.x + dx,
            yPosition: char.y,
          ),
        );
      }
    }

    try {
      final bounds = arena<Float>(4);
      final glyphWidth = arena<Float>();
      for (final row in _rows(runs)) {
        var dx = 0.0;
        var fixedAfter = -1;
        for (var i = 0; i < row.length; i++) {
          final run = row[i];
          final edit = changeByKey[run.key];
          var widthChange = 0.0;
          if (edit != null) {
            final oldAdvanceRight =
                charAt[run.sourceEndIndex - 1]?.advanceRight ?? run.box.right;
            final objects = wholeObjects(run);
            if (objects == null) {
              masks.add(run.box);
            } else {
              replaced.addAll(objects);
            }
            if (edit.newText.trim().isEmpty) {
              boxes[run.key] = const PdfRect(0, 0, 0, 0);
              widthChange = run.x - oldAdvanceRight;
            } else {
              final font = chooseFont(edit);
              final obj = _createText(
                p,
                doc,
                font,
                edit,
                arena,
                xPosition: run.x + dx,
                yPosition: run.y,
              );
              pending.add(obj);
              final box = _objectBounds(p, obj, bounds);
              boxes[run.key] = box;
              var advance = 0.0;
              for (final rune in edit.newText.runes) {
                if (p.FPDFFont_GetGlyphWidth(
                      font,
                      rune,
                      run.format.fontSize,
                      glyphWidth,
                    ) ==
                    0) {
                  advance = box.right - dx - run.x;
                  break;
                }
                advance += glyphWidth.value * run.format.a;
              }
              // Advance includes side bearings, so a final narrow glyph
              // such as '1' does not eat into the following space.
              widthChange = run.x + advance - oldAdvanceRight;
            }
          } else if (dx.abs() > 0.01) {
            boxes[run.key] = _shift(run.box, dx);
            final objects = wholeObjects(run);
            if (objects != null) {
              originalMoves[run] = (objects, dx);
            } else {
              // A PDF object can straddle several runs (for example "12 kg").
              // Repaint just these characters at their original spacing.
              masks.add(run.box);
              redrawAtOffset(run, dx);
            }
          }

          if (i + 1 < row.length) {
            final next = row[i + 1];
            final gap = next.box.left - run.box.right;
            final em = run.format.fontSize * run.format.a;
            final after = boxes[run.key];
            if (i != fixedAfter && gap >= -em * 0.25 && gap <= em * 0.6) {
              dx += widthChange;
            } else if (i != fixedAfter &&
                gap > em * 0.6 &&
                gap <= em * 2 &&
                after != null &&
                after.isNotEmpty &&
                _numberLabel.hasMatch(run.text) &&
                _numberValue.hasMatch(next.text)) {
              // Form labels can be separated from their values by deliberate
              // whitespace. Use that space before moving the number.
              final needed = after.right + em * 0.25 - next.box.left;
              dx = needed > 0 ? needed : 0;
              if (dx > 0) fixedAfter = i + 1;
            } else {
              if (after != null && (gap > em * 0.6 || i == fixedAfter)) {
                separations.add((run, next));
              }
              dx = 0;
            }
            if (dx.abs() <= 0.01) dx = 0;
          }
        }
      }
      for (final (left, right) in separations) {
        final after = boxes[left.key]!;
        final boundary = boxes[right.key] ?? right.box;
        if (after.isNotEmpty &&
            boundary.isNotEmpty &&
            after.right > boundary.left + 0.5) {
          throw StateError('修改后的文字会压住其他内容，请缩短内容');
        }
      }
      _checkSpace(p, page, runs, boxes, arena);

      final stationary = runs.where((run) => !boxes.containsKey(run.key));
      final maskRects = masks.map((box) {
        final padded = PdfRect(
          box.left - 0.25,
          box.top + 0.25,
          box.right + 0.25,
          box.bottom - 0.25,
        );
        // Only add antialiasing clearance where it won't erase another run.
        return stationary.any((run) => _boxesOverlap(padded, run.box, 0))
            ? box
            : padded;
      }).toList();
      for (final entry in originalMoves.entries) {
        final (objects, dx) = entry.value;
        final destination = boxes[entry.key.key]!;
        if (maskRects.any((mask) => _boxesOverlap(mask, destination, 0))) {
          // A mask can be in a later PDF content stream than the moving text.
          // Draw the moved glyphs after the mask in this case.
          replaced.addAll(objects);
          redrawAtOffset(entry.key, dx);
        } else {
          for (final object in objects) {
            p.FPDFPageObj_Transform(object, 1, 0, 0, 1, dx, 0);
          }
        }
      }
      for (final object in replaced) {
        if (p.FPDFPage_RemoveObject(page, object) == 0) {
          throw StateError('无法移除旧文字');
        }
        p.FPDFPageObj_Destroy(object);
      }
      for (final mask in maskRects) {
        _whiteOut(p, page, mask);
      }
      for (final object in pending.toList()) {
        if (p.FPDFPage_InsertObject(page, object) == 0) {
          throw StateError('插入文字对象失败');
        }
        pending.remove(object);
      }
      return boxes;
    } finally {
      for (final object in pending) {
        p.FPDFPageObj_Destroy(object);
      }
    }
  }

  static List<List<TextRun>> _rows(List<TextRun> runs) {
    final sorted = [...runs]..sort((a, b) => b.y.compareTo(a.y));
    final rows = <List<TextRun>>[];
    for (final run in sorted) {
      final horizontal =
          run.format.a > 0 && run.format.d > 0 && run.format.b.abs() < 0.001;
      if (horizontal && rows.isNotEmpty) {
        final row = rows.last;
        final anchor = row.first;
        final tolerance =
            (run.box.height < anchor.box.height
                ? run.box.height
                : anchor.box.height) *
            0.18;
        if (anchor.format.a > 0 &&
            anchor.format.d > 0 &&
            anchor.format.b.abs() < 0.001 &&
            (run.y - anchor.y).abs() <= tolerance) {
          row.add(run);
          continue;
        }
      }
      rows.add([run]);
    }
    for (final row in rows) {
      row.sort((a, b) => a.x.compareTo(b.x));
    }
    return rows;
  }

  static PdfRect _shift(PdfRect box, double dx) =>
      PdfRect(box.left + dx, box.top, box.right + dx, box.bottom);

  static PdfRect _objectBounds(
    pi.PDFium p,
    pi.FPDF_PAGEOBJECT obj,
    Pointer<Float> b,
  ) {
    if (p.FPDFPageObj_GetBounds(obj, b, b + 1, b + 2, b + 3) == 0) {
      throw StateError('无法测量修改后的文字宽度');
    }
    return PdfRect(b[0], b[3], b[2], b[1]);
  }

  static void _checkSpace(
    pi.PDFium p,
    pi.FPDF_PAGE page,
    List<TextRun> runs,
    Map<String, PdfRect> boxes,
    Arena arena,
  ) {
    final pageBox = arena<pi.FS_RECTF>();
    final hasBounds = p.FPDF_GetPageBoundingBox(page, pageBox) != 0;
    const tolerance = 0.5;
    for (final run in runs) {
      final box = boxes[run.key];
      if (box == null || box.isEmpty) continue;
      if (hasBounds &&
          (box.left < pageBox.ref.left - tolerance &&
                  box.left < run.box.left - tolerance ||
              box.right > pageBox.ref.right + tolerance &&
                  box.right > run.box.right + tolerance)) {
        throw StateError('这行没有足够空间放下修改后的文字，请缩短内容');
      }
      for (final other in runs) {
        if (identical(other, run)) continue;
        final target = boxes[other.key] ?? other.box;
        if (target.isEmpty || !_boxesOverlap(box, target, tolerance)) {
          continue;
        }
        final alreadyOverlapped =
            _overlap(
              run.box.bottom,
              run.box.top,
              other.box.bottom,
              other.box.top,
            ) >
            tolerance;
        final oldOverlap = alreadyOverlapped
            ? _overlap(
                run.box.left,
                run.box.right,
                other.box.left,
                other.box.right,
              )
            : 0.0;
        if (_overlap(box.left, box.right, target.left, target.right) >
            oldOverlap + tolerance) {
          throw StateError('修改后的文字会压住其他内容，请缩短内容');
        }
      }
    }
  }

  static double _overlap(double a0, double a1, double b0, double b1) =>
      (a1 < b1 ? a1 : b1) - (a0 > b0 ? a0 : b0);

  static bool _boxesOverlap(PdfRect a, PdfRect b, double tolerance) =>
      _overlap(a.left, a.right, b.left, b.right) > tolerance &&
      _overlap(a.bottom, a.top, b.bottom, b.top) > tolerance;

  static int _argb(Pointer<UnsignedInt> c) =>
      (c[3] << 24) | (c[0] << 16) | (c[1] << 8) | c[2];
  static String _fontName(int Function(Pointer<Char>, int) get) {
    final length = get(nullptr, 0);
    if (length == 0) return '';
    final data = calloc<Char>(length);
    try {
      get(data, length);
      return utf8.decode(data.cast<Uint8>().asTypedList(length - 1));
    } finally {
      calloc.free(data);
    }
  }

  static void _whiteOut(pi.PDFium p, pi.FPDF_PAGE page, PdfRect box) {
    final path = p.FPDFPageObj_CreateNewRect(
      box.left,
      box.bottom,
      box.width,
      box.height,
    );
    if (path == nullptr) throw StateError('无法覆盖原文字');
    p.FPDFPageObj_SetFillColor(path, 255, 255, 255, 255);
    p.FPDFPath_SetDrawMode(path, pi.FPDF_FILLMODE_WINDING, 0);
    if (p.FPDFPage_InsertObject(page, path) == 0) {
      p.FPDFPageObj_Destroy(path);
      throw StateError('无法覆盖原文字');
    }
  }

  static void _setColor(
    pi.PDFium p,
    pi.FPDF_PAGEOBJECT obj,
    int color, {
    bool stroke = false,
  }) {
    final r = color >> 16 & 255,
        g = color >> 8 & 255,
        b = color & 255,
        a = color >> 24 & 255;
    if (stroke) {
      p.FPDFPageObj_SetStrokeColor(obj, r, g, b, a);
    } else {
      p.FPDFPageObj_SetFillColor(obj, r, g, b, a);
    }
  }

  static pi.FPDF_PAGEOBJECT _createText(
    pi.PDFium p,
    pi.FPDF_DOCUMENT doc,
    pi.FPDF_FONT font,
    RunEdit edit,
    Arena arena, {
    required double xPosition,
    required double yPosition,
    String? text,
  }) {
    final f = edit.run.format;
    final obj = p.FPDFPageObj_CreateTextObj(doc, font, f.fontSize);
    if (obj == nullptr) throw StateError('创建文字对象失败');
    final words = x.toUtf16z(text ?? edit.newText, arena);
    if (p.FPDFText_SetText(obj, words.cast()) == 0) {
      p.FPDFPageObj_Destroy(obj);
      throw StateError('写入文字失败');
    }
    _setColor(p, obj, f.color);
    _setColor(p, obj, f.strokeColor, stroke: true);
    p.FPDFPageObj_SetStrokeWidth(obj, f.strokeWidth);
    final mode = edit.bold == false && f.syntheticBold ? 0 : f.renderMode;
    p.FPDFTextObj_SetTextRenderMode(
      obj,
      pi.FPDF_TEXT_RENDERMODE.fromValue(mode),
    );
    final m = arena<pi.FS_MATRIX>();
    m.ref
      ..a = f.a
      ..b = f.b
      ..c = f.c
      ..d = f.d
      ..e = xPosition
      ..f = yPosition;
    if (p.FPDFPageObj_SetMatrix(obj, m) == 0) {
      p.FPDFPageObj_Destroy(obj);
      throw StateError('无法定位修改后的文字');
    }
    return obj;
  }

  static Uint8List _save(pi.PDFium p, pi.FPDF_DOCUMENT doc) {
    final sink = BytesBuilder(copy: true);
    final callback =
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
    writer.ref
      ..version = 1
      ..WriteBlock = callback.nativeFunction;
    try {
      if (p.FPDF_SaveAsCopy(doc, writer, 0) == 0) throw StateError('导出 PDF 失败');
      return sink.takeBytes();
    } finally {
      callback.close();
      calloc.free(writer);
    }
  }
}

class _EditFonts {
  _EditFonts(this.pdfium, this.doc, this.arena, this.matchingFonts);
  final pi.PDFium pdfium;
  final pi.FPDF_DOCUMENT doc;
  final Arena arena;
  final Map<String, Uint8List> matchingFonts;
  final _data = <int, Uint8List>{};
  final _system = <String, pi.FPDF_FONT>{};
  final _loaded = <Uint8List, pi.FPDF_FONT>{};

  pi.FPDF_FONT resolve(pi.FPDF_FONT original, RunEdit edit, Set<int> known) {
    if (original == nullptr) throw StateError('无法读取原字体');
    final format = edit.run.format;
    final keepWeight = edit.bold == null || edit.bold == format.bold;
    final removeSyntheticOnly =
        edit.bold == false && format.syntheticBold && format.weight < 600;
    if ((keepWeight || removeSyntheticOnly) &&
        _supports(original, edit.newText, known)) {
      return original;
    }
    final weight = keepWeight
        ? (format.weight / 100).round() * 100
        : (edit.bold! ? 700 : 400);
    final familyName = pdfium.FPDFFont_GetIsEmbedded(original) == 1
        ? format.familyName
        : '';
    final missing = MissingPdfFont(
      fontName: format.fontName,
      familyName: familyName,
      weight: weight,
      italic: format.italic,
      runKey: edit.runKey,
      text: edit.newText,
    );
    final matching = _loadFile(matchingFonts[missing.key], edit.newText);
    if (matching != null) return matching;

    final key = '${format.fontName}:$familyName:$weight:${format.italic}';
    final cached = _system[key];
    if (cached != null && _supports(cached, edit.newText, {})) return cached;
    final system = loadSystemFont(
      fontName: format.fontName,
      familyName: familyName,
      weight: weight,
      italic: format.italic,
    );
    final installed = _loadFile(system?.bytes, edit.newText);
    if (installed != null) {
      _system[key] = installed;
      return installed;
    }
    final substitute = _loadFile(edit.substituteFont, edit.newText);
    if (substitute != null) return substitute;
    throw missing;
  }

  pi.FPDF_FONT? _loadFile(Uint8List? bytes, String text) {
    if (bytes == null || fontSupportsText(bytes, text) != true) return null;
    final loaded = _loaded.putIfAbsent(bytes, () {
      final buffer = arena<Uint8>(bytes.length)
        ..asTypedList(bytes.length).setAll(0, bytes);
      return pdfium.FPDFText_LoadFont(
        doc,
        buffer,
        bytes.length,
        pi.FPDF_FONT_TRUETYPE,
        1,
      );
    });
    if (loaded == nullptr) return null;
    _data[loaded.address] = bytes;
    if (!_supports(loaded, text, {})) return null;
    return loaded;
  }

  bool _supports(pi.FPDF_FONT font, String text, Set<int> known) {
    final bytes = _data.putIfAbsent(font.address, () {
      final length = arena<Size>();
      if (pdfium.FPDFFont_GetFontData(font, nullptr, 0, length) == 0 ||
          length.value == 0) {
        return Uint8List(0);
      }
      final data = arena<Uint8>(length.value);
      if (pdfium.FPDFFont_GetFontData(font, data, length.value, length) == 0) {
        return Uint8List(0);
      }
      return Uint8List.fromList(data.asTypedList(length.value));
    });
    final coverage = fontSupportsText(bytes, text);
    if (coverage == false ||
        coverage == null &&
            text.runes.any(
              (r) =>
                  String.fromCharCode(r).trim().isNotEmpty &&
                  !known.contains(r),
            )) {
      return false;
    }
    for (final rune in text.runes.toSet()) {
      if (String.fromCharCode(rune).trim().isEmpty) continue;
      final path = pdfium.FPDFFont_GetGlyphPath(font, rune, 12);
      if (path == nullptr ||
          pdfium.FPDFGlyphPath_CountGlyphSegments(path) <= 0) {
        return false;
      }
    }
    // A subset may map Unicode to missing or different character codes.
    final index = pdfium.FPDF_GetPageCount(doc);
    final page = pdfium.FPDFPage_New(doc, index, 1000, 1000);
    pi.FPDF_TEXTPAGE? textPage;
    try {
      final obj = pdfium.FPDFPageObj_CreateTextObj(doc, font, 12);
      if (obj == nullptr) return false;
      if (pdfium.FPDFText_SetText(obj, x.toUtf16z(text, arena).cast()) == 0) {
        pdfium.FPDFPageObj_Destroy(obj);
        return false;
      }
      if (pdfium.FPDFPage_InsertObject(page, obj) == 0) {
        pdfium.FPDFPageObj_Destroy(obj);
        return false;
      }
      textPage = pdfium.FPDFText_LoadPage(page);
      final length = pdfium.FPDFTextObj_GetText(obj, textPage, nullptr, 0);
      if (length < 2) return false;
      final buffer = arena<Uint16>(length ~/ 2);
      pdfium.FPDFTextObj_GetText(obj, textPage, buffer.cast(), length);
      return String.fromCharCodes(buffer.asTypedList(length ~/ 2 - 1)) == text;
    } finally {
      if (textPage != null) pdfium.FPDFText_ClosePage(textPage);
      pdfium.FPDF_ClosePage(page);
      pdfium.FPDFPage_Delete(doc, index);
    }
  }

  void close() {
    for (final font in _loaded.values) {
      if (font != nullptr) pdfium.FPDFFont_Close(font);
    }
  }
}
