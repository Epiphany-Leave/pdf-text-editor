// PDF write path: applies text edits to a PDF in memory with PDFium's editing
// API (the same engine pdfrx uses for reading, so coordinates match 1:1).
//
// Each edit = white rectangle over the original run + a new text object drawn
// at the same position, font size auto-calibrated so the new text's height
// matches the original run. The result is saved as a new file.
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as pi;
import 'package:pdfrx/pdfrx.dart' show PdfRect, Pdfrx;

import 'pdfium_extra.dart' as x;

class PageEdit {
  PageEdit({required this.pageNumber, required this.edits});

  final int pageNumber; // 1-based
  final List<RunEdit> edits;
}

class RunEdit {
  RunEdit({required this.runKey, required this.originalText, required this.newText, required this.box, required this.bold});

  final String runKey;
  final String originalText;
  final String newText;
  final PdfRect box; // y-up PDF page coordinates
  final bool bold;
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
  /// Applies [pages] edits to [source] and returns the new PDF bytes.
  /// Runs on a background isolate — pass the font bytes in, not an asset bundle.
  static Future<Uint8List> applyEdits({
    required Uint8List source,
    required Uint8List fontRegular,
    required Uint8List fontBold,
    required List<PageEdit> pages,
  }) {
    return Isolate.run(() => _applySync(source, fontRegular, fontBold, pages));
  }

  static Uint8List _applySync(Uint8List source, Uint8List fontRegular, Uint8List fontBold, List<PageEdit> pages) {
    final pdfium = pi.getPdfium();
    return withPdfium(pdfium, () => _applyLocked(pdfium, source, fontRegular, fontBold, pages));
  }

  static Uint8List _applyLocked(pi.PDFium pdfium, Uint8List source, Uint8List fontRegular, Uint8List fontBold, List<PageEdit> pages) {
    final data = calloc<Uint8>(source.length);
    data.asTypedList(source.length).setAll(0, source);
    final doc = pdfium.FPDF_LoadMemDocument(data.cast(), source.length, nullptr.cast());
    if (doc == nullptr) {
      final err = pdfium.FPDF_GetLastError();
      calloc.free(data);
      throw StateError('无法打开 PDF 文件(可能已加密或损坏),错误码 $err');
    }
    try {
      final regular = _loadFont(pdfium, doc, fontRegular);
      final bold = pages.any((p) => p.edits.any((e) => e.bold)) ? _loadFont(pdfium, doc, fontBold) : nullptr;
      for (final page in pages) {
        _applyPage(pdfium, doc, regular, bold, page);
      }
      return _save(pdfium, doc);
    } finally {
      pdfium.FPDF_CloseDocument(doc);
      calloc.free(data);
    }
  }

  /// The font data buffer must stay valid for the document's lifetime, so the
  /// allocation is intentionally retained until the isolate exits (≤2 fonts).
  static pi.FPDF_FONT _loadFont(pi.PDFium pdfium, pi.FPDF_DOCUMENT doc, Uint8List bytes) {
    final buf = calloc<Uint8>(bytes.length);
    buf.asTypedList(bytes.length).setAll(0, bytes);
    final font = x.loadTrueTypeFont(doc.cast(), buf, bytes.length, 2 /* FPDF_FONT_TRUETYPE */, 1 /* use_cid */);
    if (font == nullptr) {
      throw StateError('内置字体加载失败');
    }
    return pi.FPDF_FONT.fromAddress(font.address);
  }

  static void _applyPage(pi.PDFium pdfium, pi.FPDF_DOCUMENT doc, pi.FPDF_FONT regular, pi.FPDF_FONT? bold, PageEdit pageEdit) {
    final page = pdfium.FPDF_LoadPage(doc, pageEdit.pageNumber - 1);
    if (page == nullptr) throw StateError('无法打开第 ${pageEdit.pageNumber} 页');
    try {
      // shortcut: 旋转过的页面不做旋转变换(文字版业务文档极少旋转)
      for (final edit in pageEdit.edits) {
        _whiteOut(pdfium, page, edit.box);
        if (edit.newText.trim().isNotEmpty) {
          _drawText(pdfium, doc, regular, bold, page, edit);
        }
      }
      if (pdfium.FPDFPage_GenerateContent(page) == 0) {
        throw StateError('第 ${pageEdit.pageNumber} 页内容生成失败');
      }
    } finally {
      pdfium.FPDF_ClosePage(page);
    }
  }

  static void _whiteOut(pi.PDFium pdfium, pi.FPDF_PAGE page, PdfRect box) {
    final infX = 1.0;
    final infY = box.height * 0.12 < 1.5 ? box.height * 0.12 : 1.5;
    final l = box.left - infX, r = box.right + infX;
    final b = box.bottom - infY, t = box.top + infY;
    final path = pdfium.FPDFPageObj_CreateNewPath(l, b);
    if (path == nullptr) return;
    pdfium.FPDFPath_MoveTo(path, l, b);
    pdfium.FPDFPath_LineTo(path, r, b);
    pdfium.FPDFPath_LineTo(path, r, t);
    pdfium.FPDFPath_LineTo(path, l, t);
    pdfium.FPDFPath_Close(path);
    pdfium.FPDFPageObj_SetFillColor(path, 255, 255, 255, 255);
    pdfium.FPDFPath_SetDrawMode(path, 0 /* FPDF_FILLED */, 0);
    pdfium.FPDFPage_InsertObject(page, path);
  }

  static void _drawText(pi.PDFium pdfium, pi.FPDF_DOCUMENT doc, pi.FPDF_FONT regular, pi.FPDF_FONT? bold, pi.FPDF_PAGE page, RunEdit edit) {
    final font = (edit.bold ? bold : null) ?? regular;
    final size = _calibratedSize(pdfium, doc, font, edit);
    final obj = pi.FPDF_PAGEOBJECT.fromAddress(x.createTextObj(doc.cast(), font.cast(), size).address);
    if (obj == nullptr) throw StateError('创建文字对象失败');
    final wstr = x.toUtf16z(edit.newText, calloc);
    final ok = pdfium.FPDFText_SetText(obj, wstr.cast());
    calloc.free(wstr);
    if (ok == 0) {
      pdfium.FPDFPageObj_Destroy(obj);
      throw StateError('写入文字失败');
    }
    pdfium.FPDFPageObj_SetFillColor(obj, 0, 0, 0, 255);
    // Align the new text's bounding box with the original run: same left edge,
    // same vertical center (robust without knowing the original baseline).
    final b = calloc<Float>(4);
    pdfium.FPDFPageObj_GetBounds(obj, b, b + 1, b + 2, b + 3);
    final objL = b[0], objB = b[1], objT = b[3];
    calloc.free(b);
    final m = calloc<pi.FS_MATRIX>();
    m.ref
      ..a = 1
      ..b = 0
      ..c = 0
      ..d = 1
      ..e = edit.box.left - objL
      ..f = (edit.box.bottom + edit.box.top - objB - objT) / 2;
    pdfium.FPDFPageObj_SetMatrix(obj, m);
    calloc.free(m);
    if (pdfium.FPDFPage_InsertObject(page, obj) == 0) {
      pdfium.FPDFPageObj_Destroy(obj);
      throw StateError('插入文字对象失败');
    }
  }

  /// Creates the text once at the estimated size, measures its height and
  /// returns the size that matches the original run height.
  static double _calibratedSize(pi.PDFium pdfium, pi.FPDF_DOCUMENT doc, pi.FPDF_FONT font, RunEdit edit) {
    final estimate = _estimate(edit);
    final probe = pi.FPDF_PAGEOBJECT.fromAddress(x.createTextObj(doc.cast(), font.cast(), estimate).address);
    if (probe == nullptr) return estimate;
    final wstr = x.toUtf16z(edit.newText, calloc);
    pdfium.FPDFText_SetText(probe, wstr.cast());
    calloc.free(wstr);
    final b = calloc<Float>(4);
    pdfium.FPDFPageObj_GetBounds(probe, b, b + 1, b + 2, b + 3);
    final h = b[3] - b[1];
    calloc.free(b);
    pdfium.FPDFPageObj_Destroy(probe);
    if (h <= 0.01) return estimate;
    final scaled = estimate * edit.box.height / h;
    // Guard against pathological glyph metrics.
    if (scaled <= 0 || scaled > 400) return estimate;
    return scaled;
  }

  static double _estimate(RunEdit edit) {
    final cjk = edit.newText.runes.any((r) => r >= 0x2E80 && r <= 0x9FFF);
    return cjk ? edit.box.height * 0.98 : edit.box.height / 0.72;
  }

  static Uint8List _save(pi.PDFium pdfium, pi.FPDF_DOCUMENT doc) {
    final sink = BytesBuilder(copy: true); // callback data is a view over pdfium-owned memory
    final callable = NativeCallable<
        Int Function(Pointer<pi.FPDF_FILEWRITE>, Pointer<Void>,
            UnsignedLong)>.isolateLocal(
        (Pointer<pi.FPDF_FILEWRITE> _, Pointer<Void> data, int size) {
      if (size > 0) {
        sink.add(data.cast<Uint8>().asTypedList(size));
      }
      return 1;
    }, exceptionalReturn: 0);
    final fw = calloc<pi.FPDF_FILEWRITE>();
    fw.ref.version = 1;
    fw.ref.WriteBlock = callable.nativeFunction;
    final ok = pdfium.FPDF_SaveAsCopy(doc, fw, 0);
    callable.close();
    final out = sink.takeBytes();
    calloc.free(fw);
    if (ok == 0 || out.isEmpty) throw StateError('导出 PDF 失败');
    return out;
  }
}
