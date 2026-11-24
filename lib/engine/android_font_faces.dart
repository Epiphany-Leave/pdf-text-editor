import 'dart:io';
import 'dart:typed_data';

import 'system_font.dart';

const _ttf = 0x00010000;
const _ttc = 0x74746366;
const _name = 0x6e616d65;
const _head = 0x68656164;
const _os2 = 0x4f532f32;
const _post = 0x706f7374;
const _fvar = 0x66766172;
const _glyf = 0x676c7966;
const _loca = 0x6c6f6361;
const _dsig = 0x44534947;

final _subset = RegExp(r'^[A-Z]{6}\+');
final _style = RegExp(
  r'(?:[-_,\s]+(?:PS-?)?)?(?:Bold[-\s]?(?:Italic|Oblique)|Regular|Medium|Bold|Italic|Oblique)(?:MT)?$|PSMT$',
  caseSensitive: false,
);
final _separators = RegExp(r'[\s_,.-]+');
const _aliases = {
  '宋体': 'simsun',
  '新宋体': 'nsimsun',
  '黑体': 'simhei',
  '微软雅黑': 'microsoftyahei',
  '楷体': 'kaiti',
  '仿宋': 'fangsong',
  'arialmt': 'arial',
};

String _key(String name) {
  final key = name
      .trim()
      .replaceFirst(_subset, '')
      .toLowerCase()
      .replaceAll(_separators, '');
  return _aliases[key] ?? key;
}

String _withoutStyle(String name) => name.replaceFirst(_style, '');

typedef _Table = ({int tag, int offset, int length, int checksum});

class FontFileFace {
  FontFileFace._(
    this.postScriptName,
    this._names,
    this.weight,
    this.italic,
    this._read,
  );

  final String postScriptName;
  final Set<String> _names;
  final int weight;
  final bool italic;
  final Uint8List Function() _read;
  late final Uint8List bytes = _read();

  bool matches({
    required String fontName,
    required String familyName,
    required int weight,
    required bool italic,
  }) {
    if (weight != this.weight || italic != this.italic) return false;
    final requested = fontName.trim().isEmpty ? familyName : fontName;
    return _names.contains(_key(requested)) ||
        _names.contains(_key(_withoutStyle(requested)));
  }
}

List<FontFileFace> readFontFileFaces(Uint8List bytes) {
  if (bytes.length < 12) return [];
  final data = ByteData.sublistView(bytes);
  if (data.getUint32(0) != _ttc) {
    final face = _readFace(bytes, data, 0, collection: false);
    return [?face];
  }
  final count = data.getUint32(8);
  if (count == 0 || count > (data.lengthInBytes - 12) ~/ 4) return [];
  return [
    for (var i = 0; i < count; i++)
      ?_readFace(bytes, data, data.getUint32(12 + i * 4), collection: true),
  ];
}

FontFileFace? _readFace(
  Uint8List bytes,
  ByteData data,
  int start, {
  required bool collection,
}) {
  if (start + 12 > data.lengthInBytes || data.getUint32(start) != _ttf) {
    return null;
  }
  final count = data.getUint16(start + 4);
  if (start + 12 + count * 16 > data.lengthInBytes) return null;
  final tables = <int, _Table>{};
  var standaloneSize = 12 + count * 16;
  for (var i = 0; i < count; i++) {
    final record = start + 12 + i * 16;
    final tag = data.getUint32(record);
    final offset = data.getUint32(record + 8);
    final length = data.getUint32(record + 12);
    if (offset + length > data.lengthInBytes || tables.containsKey(tag)) {
      return null;
    }
    standaloneSize += (length + 3) & ~3;
    if (collection && standaloneSize > data.lengthInBytes) return null;
    tables[tag] = (
      tag: tag,
      offset: offset,
      length: length,
      checksum: data.getUint32(record + 4),
    );
  }
  final name = tables[_name];
  final head = tables[_head];
  final os2 = tables[_os2];
  if (name == null ||
      name.length < 6 ||
      head == null ||
      head.length < 54 ||
      os2 == null ||
      os2.length < 64 ||
      tables.containsKey(_fvar) ||
      !tables.containsKey(_glyf) ||
      !tables.containsKey(_loca)) {
    return null;
  }
  if ((data.getUint16(os2.offset + 8) & 0x0306) != 0) return null;
  final names = <String>{};
  String? postScript;
  final records = data.getUint16(name.offset + 2);
  final storage = data.getUint16(name.offset + 4);
  if (storage < 6 + records * 12 || storage > name.length) return null;
  for (var i = 0; i < records; i++) {
    final record = name.offset + 6 + i * 12;
    final platform = data.getUint16(record);
    final id = data.getUint16(record + 6);
    if (!{1, 4, 6, 16}.contains(id) || (platform != 0 && platform != 3)) {
      continue;
    }
    final offset = storage + data.getUint16(record + 10);
    final length = data.getUint16(record + 8);
    if (offset + length > name.length || length.isOdd) continue;
    final value = String.fromCharCodes([
      for (var j = 0; j < length; j += 2)
        data.getUint16(name.offset + offset + j),
    ]).trim();
    if (value.isEmpty) continue;
    names.add(_key(value));
    if (id == 6 && value.length <= 63) postScript ??= value;
  }
  if (postScript == null) return null;
  final post = tables[_post];
  final italic =
      (data.getUint16(os2.offset + 62) & 0x0201) != 0 ||
      (data.getUint16(head.offset + 44) & 2) != 0 ||
      (post != null && post.length >= 8 && data.getInt32(post.offset + 4) != 0);
  return FontFileFace._(
    postScript,
    names,
    data.getUint16(os2.offset + 4),
    italic,
    () => collection
        ? _standalone(
            bytes,
            tables.values.where((t) => t.tag != _dsig).toList(),
          )
        : bytes,
  );
}

Uint8List _standalone(Uint8List source, List<_Table> tables) {
  var power = 1;
  var log = 0;
  while (power * 2 <= tables.length) {
    power *= 2;
    log++;
  }
  var offset = 12 + 16 * tables.length;
  final length = tables.fold(
    offset,
    (size, table) => size + ((table.length + 3) & ~3),
  );
  final bytes = Uint8List(length);
  final data = ByteData.sublistView(bytes)
    ..setUint32(0, _ttf)
    ..setUint16(4, tables.length)
    ..setUint16(6, 16 * power)
    ..setUint16(8, log)
    ..setUint16(10, 16 * (tables.length - power));
  var adjustment = 0;
  for (var i = 0; i < tables.length; i++) {
    final table = tables[i];
    final record = 12 + 16 * i;
    data.setUint32(record, table.tag);
    data.setUint32(record + 4, table.checksum);
    data.setUint32(record + 8, offset);
    data.setUint32(record + 12, table.length);
    bytes.setRange(offset, offset + table.length, source, table.offset);
    if (table.tag == _head) {
      adjustment = offset + 8;
      data.setUint32(adjustment, 0);
    }
    offset += (table.length + 3) & ~3;
  }
  var checksum = 0;
  for (var i = 0; i < length; i += 4) {
    checksum = (checksum + data.getUint32(i)) & 0xffffffff;
  }
  data.setUint32(adjustment, (0xb1b0afba - checksum) & 0xffffffff);
  return bytes;
}

Future<FontFileFace?> findAndroidSystemFace({
  required String fontName,
  required String familyName,
  required int weight,
  required bool italic,
  required String text,
}) async {
  if (!Platform.isAndroid) return null;
  final requested = _key(
    _withoutStyle(fontName.trim().isEmpty ? familyName : fontName),
  );
  if (requested.isEmpty) return null;
  for (final path in ['/system/fonts', '/product/fonts', '/system_ext/fonts']) {
    final directory = Directory(path);
    if (!await directory.exists()) continue;
    try {
      await for (final file in directory.list()) {
        if (file is! File) continue;
        final name = file.uri.pathSegments.last.toLowerCase();
        // A collection can contain faces whose names differ from its filename.
        if (!name.endsWith('.ttc') &&
            (!name.endsWith('.ttf') ||
                !_key(name.substring(0, name.length - 4))
                    .startsWith(requested))) {
          continue;
        }
        for (final face in readFontFileFaces(await file.readAsBytes())) {
          if (face.matches(
                fontName: fontName,
                familyName: familyName,
                weight: weight,
                italic: italic,
              ) &&
              fontSupportsText(face.bytes, text) == true) {
            return face;
          }
        }
      }
    } on FileSystemException {
      // Some Android builds omit or restrict optional system font folders.
    }
  }
  return null;
}
