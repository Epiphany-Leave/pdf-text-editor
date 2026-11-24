import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'font_download_catalog.dart';

/// Stores downloads in the app's private font directory for offline reuse.
class FontDownloadCache {
  FontDownloadCache(this._directory);

  static const _maxBytes = 24 * 1024 * 1024;
  static final _inFlight = <String, Future<Uint8List?>>{};

  final Directory _directory;

  /// Callers still verify the face identity, embedding rights and glyphs.
  Future<Uint8List?> readOrDownload(FontDownloadFace face) {
    final name = Uri.encodeComponent(face.url.toString());
    final path = '${_directory.absolute.path}${Platform.pathSeparator}$name';
    return _inFlight.putIfAbsent(
      path,
      () => _readOrDownload(File(path), face.url).whenComplete(() {
        _inFlight.remove(path);
      }),
    );
  }

  Future<Uint8List?> _readOrDownload(File file, Uri url) async {
    try {
      if (await file.exists() && await file.length() <= _maxBytes) {
        final cached = await file.readAsBytes();
        if (_looksLikeTrueType(cached)) return cached;
      }
    } on FileSystemException {
      // A cache read failure can still be recovered by downloading the font.
    }

    if (url.scheme != 'https') return null;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    Uint8List? bytes;
    try {
      bytes = await _download(client, url).timeout(const Duration(seconds: 75));
    } on IOException {
      return null;
    } on TimeoutException {
      return null;
    } finally {
      client.close(force: true);
    }
    if (bytes == null || !_looksLikeTrueType(bytes)) return null;

    final part = File('${file.path}.part');
    try {
      await _directory.create(recursive: true);
      await part.writeAsBytes(bytes, flush: true);
      await part.rename(file.path);
    } on FileSystemException {
      // The downloaded bytes are usable even if the app cannot persist them.
      try {
        if (await part.exists()) await part.delete();
      } on FileSystemException {
        // A partial download is never read as a cached font.
      }
    }
    return bytes;
  }

  Future<Uint8List?> _download(HttpClient client, Uri url) async {
    final request = await client
        .getUrl(url)
        .timeout(const Duration(seconds: 10));
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != HttpStatus.ok ||
        response.contentLength > _maxBytes) {
      return null;
    }
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (buffer.length + chunk.length > _maxBytes) return null;
      buffer.add(chunk);
    }
    return buffer.takeBytes();
  }

  bool _looksLikeTrueType(Uint8List bytes) =>
      bytes.length >= 12 &&
      bytes.length <= _maxBytes &&
      ByteData.sublistView(bytes).getUint32(0) == 0x00010000;
}
