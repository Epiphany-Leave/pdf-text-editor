import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_text_editor/engine/system_font.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as pi;

void main() {
  test('unknown embedded font format has unknown Unicode coverage', () {
    expect(fontSupportsText(Uint8List.fromList([1, 0, 4, 4]), '汉'), isNull);
  });

  group('Windows system fonts', () {
    test(
      'finds the Arial PostScript alias and verifies the physical style',
      () {
        final arial = _font(
          'ABCDEF+Arial-BoldItalicMT',
          weight: 700,
          italic: true,
        );
        expect(arial.familyName, 'Arial');
        expect(fontSupportsText(arial.bytes, ' ABC 123\t\n'), isTrue);
        expect(fontSupportsText(arial.bytes, '汉'), isFalse);
        expect(fontSupportsText(arial.bytes, '𠀀'), isFalse);
        final tables = _readStandaloneDirectory(arial.bytes);
        final os2 = tables['OS/2']!;
        expect(os2.getUint16(4), 700);
        expect(os2.getUint16(62) & 1, 1);
      },
    );

    test('rebuilds both SimSun collection faces with their own names', () {
      for (final (name, family) in [('宋体', 'SimSun'), ('新宋体', 'NSimSun')]) {
        final font = _font(name);
        expect(font.familyName, family);
        expect(fontSupportsText(font.bytes, '宋体新档案 123'), isTrue);
        _readStandaloneDirectory(font.bytes);
      }
    });

    test('checks supplementary-plane characters in format 12', () {
      final font = _font('SimSun-ExtB');
      expect(font.familyName, 'SimSun-ExtB');
      expect(fontSupportsText(font.bytes, '𠀀'), isTrue);
      expect(fontSupportsText(font.bytes, '🦊'), isFalse);
    });

    test('rejects font family substitutes and synthesized styles', () {
      expect(
        loadSystemFont(
          fontName: 'ABCDEF+No Such GDI Family',
          familyName: 'No Such GDI Family',
          weight: 400,
          italic: false,
        ),
        isNull,
      );
      expect(
        loadSystemFont(
          fontName: 'SimSun',
          familyName: '宋体',
          weight: 700,
          italic: false,
        ),
        isNull,
      );
    });

    test('PDFium can create Chinese text using the rebuilt NSimSun', () {
      final fontData = _font('新宋体').bytes;
      final pdfium = pi.getPdfium();
      pdfium.FPDF_InitLibrary();
      try {
        using((arena) {
          final bytes = arena<Uint8>(fontData.length);
          bytes.asTypedList(fontData.length).setAll(0, fontData);
          final doc = pdfium.FPDF_CreateNewDocument();
          expect(doc, isNot(nullptr));
          try {
            final font = pdfium.FPDFText_LoadFont(
              doc,
              bytes,
              fontData.length,
              pi.FPDF_FONT_TRUETYPE,
              1,
            );
            expect(font, isNot(nullptr));
            final page = pdfium.FPDFPage_New(doc, 0, 200, 200);
            expect(page, isNot(nullptr));
            try {
              final obj = pdfium.FPDFPageObj_CreateTextObj(doc, font, 24);
              expect(obj, isNot(nullptr));
              expect(
                pdfium.FPDFText_SetText(
                  obj,
                  '宋体 123'.toNativeUtf16(allocator: arena).cast(),
                ),
                1,
              );
              pdfium.FPDFPage_InsertObject(page, obj);
              expect(pdfium.FPDFPage_GenerateContent(page), 1);
              final text = pdfium.FPDFText_LoadPage(page);
              try {
                expect(pdfium.FPDFText_CountChars(text), 6);
                expect(pdfium.FPDFText_GetUnicode(text, 0), '宋'.codeUnitAt(0));
              } finally {
                pdfium.FPDFText_ClosePage(text);
              }
            } finally {
              pdfium.FPDF_ClosePage(page);
              pdfium.FPDFFont_Close(font);
            }
          } finally {
            pdfium.FPDF_CloseDocument(doc);
          }
        });
      } finally {
        pdfium.FPDF_DestroyLibrary();
      }
    });
  }, skip: !Platform.isWindows);
}

SystemFontData _font(String name, {int weight = 400, bool italic = false}) {
  final result = loadSystemFont(
    fontName: name,
    familyName: '',
    weight: weight,
    italic: italic,
  );
  expect(result, isNotNull, reason: name);
  return result!;
}

Map<String, ByteData> _readStandaloneDirectory(Uint8List bytes) {
  final font = ByteData.sublistView(bytes);
  expect(font.getUint32(0), 0x10000);
  expect(bytes.length % 4, 0);
  final directoryEnd = 12 + 16 * font.getUint16(4);
  expect(directoryEnd, lessThan(bytes.length));
  final tables = <String, ByteData>{};
  for (var pos = 12; pos < directoryEnd; pos += 16) {
    final tag = String.fromCharCodes(bytes.sublist(pos, pos + 4));
    final offset = font.getUint32(pos + 8);
    final length = font.getUint32(pos + 12);
    expect(offset, greaterThanOrEqualTo(directoryEnd), reason: tag);
    expect(offset % 4, 0, reason: tag);
    expect(offset + length, lessThanOrEqualTo(bytes.length), reason: tag);
    tables[tag] = ByteData.sublistView(bytes, offset, offset + length);
  }
  expect(tables.keys, containsAll(['head', 'name', 'cmap', 'glyf']));
  var sum = 0;
  for (var i = 0; i < bytes.length; i += 4) {
    sum = (sum + font.getUint32(i)) & 0xffffffff;
  }
  expect(sum, 0xb1b0afba);
  return tables;
}
