import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'engine/android_font_faces.dart';
import 'engine/font_download_cache.dart';
import 'engine/font_download_catalog.dart';
import 'engine/pdf_edit_engine.dart';
import 'engine/system_font.dart';

class PdfFonts {
  static const _maxImportBytes = 64 * 1024 * 1024;
  static final _serifName = RegExp(
    r'宋|明朝|明體|serif|simsun|song|times|ming|mincho|georgia|garamond',
    caseSensitive: false,
  );
  static final _sansName = RegExp('sans', caseSensitive: false);
  late final _folder = getApplicationSupportDirectory();
  late final _downloads = _folder.then(
    (dir) => FontDownloadCache(Directory('${dir.path}/downloaded-fonts')),
  );
  final _bundled = <bool, Future<List<FontFileFace>>>{};

  Future<Uint8List?> findExact(MissingPdfFont request) async {
    final imported = await _findImported(request);
    if (imported != null) return imported;

    final bundled = _match(await _bundledFaces(request.weight), request);
    if (bundled != null) return bundled.bytes;

    final installed = await findAndroidSystemFace(
      fontName: request.fontName,
      familyName: request.familyName,
      weight: request.weight,
      italic: request.italic,
      text: request.text,
    );
    if (installed != null) return installed.bytes;

    final download = exactFontDownload(
      fontName: request.fontName,
      familyName: request.familyName,
      weight: request.weight,
      italic: request.italic,
    );
    if (download == null) return null;
    final bytes = await (await _downloads).readOrDownload(download);
    return bytes == null
        ? null
        : _match(readFontFileFaces(bytes), request)?.bytes;
  }

  Future<bool> importForEdit(File file, MissingPdfFont request) async {
    if (await file.length() > _maxImportBytes) return false;
    final face = _match(readFontFileFaces(await file.readAsBytes()), request);
    if (face == null) return false;

    final imported = await _importFolder();
    await imported.create(recursive: true);
    final fileName = base64Url.encode(utf8.encode(face.postScriptName));
    final target = File('${imported.path}/$fileName.ttf');
    final draft = await File('${target.path}.part').writeAsBytes(face.bytes);
    await draft.rename(target.path);
    return true;
  }

  Future<({String name, Uint8List bytes})?> substituteFor(
    MissingPdfFont request,
  ) async {
    final names = '${request.fontName} ${request.familyName}';
    if (!_sansName.hasMatch(names) && _serifName.hasMatch(names)) {
      final serif = similarSerifDownload(
        weight: request.weight,
        italic: request.italic,
      );
      if (serif != null) {
        final bytes = await (await _downloads).readOrDownload(serif);
        if (bytes != null) {
          for (final face in readFontFileFaces(bytes)) {
            if (face.matches(
                  fontName: serif.postscriptName ?? serif.familyName,
                  familyName: serif.familyName,
                  weight: serif.weight,
                  italic: serif.italic,
                ) &&
                fontSupportsText(face.bytes, request.text) == true) {
              return (name: serif.familyName, bytes: face.bytes);
            }
          }
        }
      }
    }
    if (request.italic) return null;
    for (final face in await _bundledFaces(request.weight)) {
      if (fontSupportsText(face.bytes, request.text) == true) {
        return (name: 'Noto Sans SC', bytes: face.bytes);
      }
    }
    return null;
  }

  Future<Directory> _importFolder() async =>
      Directory('${(await _folder).path}/imported-fonts');

  Future<Uint8List?> _findImported(MissingPdfFont request) async {
    final dir = await _importFolder();
    if (!await dir.exists()) return null;
    await for (final file in dir.list()) {
      if (file is! File || !file.path.endsWith('.ttf')) continue;
      final face = _match(readFontFileFaces(await file.readAsBytes()), request);
      if (face != null) return face.bytes;
    }
    return null;
  }

  Future<List<FontFileFace>> _bundledFaces(int weight) => _bundled.putIfAbsent(
    weight >= 600,
    () async {
      final style = weight >= 600 ? 'Bold' : 'Regular';
      final data = await rootBundle.load('assets/fonts/NotoSansSC-$style.ttf');
      return readFontFileFaces(Uint8List.sublistView(data));
    },
  );

  FontFileFace? _match(List<FontFileFace> faces, MissingPdfFont request) {
    for (final face in faces) {
      if (face.matches(
            fontName: request.fontName,
            familyName: request.familyName,
            weight: request.weight,
            italic: request.italic,
          ) &&
          fontSupportsText(face.bytes, request.text) == true) {
        return face;
      }
    }
    return null;
  }
}
