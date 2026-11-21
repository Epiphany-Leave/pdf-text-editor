// Supplemental FFI for the two PDFium editing functions that pdfium_dart 0.4.4
// does not bind. Loads the SAME shared library pdfrx/pdfium_dart already uses,
// so there is only one copy of PDFium in the process.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

typedef _CreateTextObjC = Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Float);
typedef _CreateTextObjDart = Pointer<Void> Function(Pointer<Void>, Pointer<Void>, double);

typedef _LoadFontC = Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>, Uint32, Int32, Int32);
typedef _LoadFontDart = Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>, int, int, int);

DynamicLibrary? _lib;
String? _overridePath;

/// Test hook: use an explicit pdfium library path (e.g. a Linux .so for host tests).
set pdfiumModulePath(String path) {
  _overridePath = path;
  _lib = null;
}

DynamicLibrary openPdfium() => _lib ??= DynamicLibrary.open(_modulePath());

String _modulePath() {
  if (_overridePath != null) return _overridePath!;
  if (Platform.isAndroid) return 'libpdfium.so';
  if (Platform.isWindows) return 'pdfium.dll';
  if (Platform.isLinux) return _linuxModulePath();
  throw UnsupportedError('pdfium extra bindings: unsupported platform');
}

/// Under `flutter test` on Linux the pdfium binary is resolved through the
/// native assets manifest materialized by pdfium_dart's build hook.
String _linuxModulePath() {
  final manifest = _findManifest(Directory('build/native_assets'));
  if (manifest == null) {
    throw StateError(
        'native_assets manifest not found; run `flutter test` from the project root '
        'or set pdfiumModulePath to a pdfium shared library');
  }
  final json = jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
  final Map<String, dynamic> assets = ((json['native-assets'] as Map<String, dynamic>?)
          ?.values
          .whereType<Map<String, dynamic>>()
          .firstWhere((m) => m.containsKey('package:pdfium_dart/libpdfium'), orElse: () => <String, dynamic>{})) ??
      <String, dynamic>{};
  final entry = assets['package:pdfium_dart/libpdfium'] as List?;
  if (entry == null || entry.first != 'absolute') {
    throw StateError('pdfium native asset missing in $manifest');
  }
  return entry.last as String;
}

File? _findManifest(Directory dir) {
  if (!dir.existsSync()) return null;
  for (final e in dir.listSync(recursive: true)) {
    if (e is File && e.path.endsWith('native_assets.json')) return e;
  }
  return null;
}

/// FPDFPageObj_CreateTextObj(document, font, font_size).
final Pointer<Void> Function(Pointer<Void>, Pointer<Void>, double) createTextObj =
    openPdfium().lookupFunction<_CreateTextObjC, _CreateTextObjDart>('FPDFPageObj_CreateTextObj');

/// FPDFText_LoadFont(doc, data, size, font_type=2 (FPDF_FONT_TRUETYPE), use_cid=1).
/// use_cid=1 is required so CJK glyph IDs resolve for the new text objects.
final Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>, int, int, int) loadTrueTypeFont =
    openPdfium().lookupFunction<_LoadFontC, _LoadFontDart>('FPDFText_LoadFont');

/// NUL-terminated UTF-16LE buffer for FPDF_WSTRING.
Pointer<Uint16> toUtf16z(String s, Allocator allocator) {
  final units = s.codeUnits;
  final p = allocator<Uint16>(units.length + 1);
  for (var i = 0; i < units.length; i++) {
    p[i] = units[i];
  }
  p[units.length] = 0;
  return p;
}
