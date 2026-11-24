import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as win;

class SystemFontData {
  const SystemFontData(this.bytes, this.familyName);

  final Uint8List bytes;
  final String familyName;
}

const _trueType = 0x00010000;
const _appleTrueType = 0x74727565; // true
const _openTypeCff = 0x4f54544f; // OTTO
const _gdiError = 0xffffffff;
const _head = 0x68656164;
const _name = 0x6e616d65;
const _os2 = 0x4f532f32;
const _cmap = 0x636d6170;
const _dsig = 0x44534947;

// win32 does not currently expose GetFontData.
final _getFontData = DynamicLibrary.open('gdi32.dll')
    .lookupFunction<
      Uint32 Function(Pointer, Uint32, Uint32, Pointer<Void>, Uint32),
      int Function(Pointer, int, int, Pointer<Void>, int)
    >('GetFontData');

const _aliases = {
  '宋体': 'SimSun',
  'simsun': 'SimSun',
  '新宋体': 'NSimSun',
  'nsimsun': 'NSimSun',
  '黑体': 'SimHei',
  'simhei': 'SimHei',
  '微软雅黑': 'Microsoft YaHei',
  'microsoftyahei': 'Microsoft YaHei',
  '楷体': 'KaiTi',
  'kaiti': 'KaiTi',
  '仿宋': 'FangSong',
  'fangsong': 'FangSong',
  'arialmt': 'Arial',
  'timesnewroman': 'Times New Roman',
  'timesnewromanpsmt': 'Times New Roman',
};

final _subsetPrefix = RegExp(r'^[A-Z]{6}\+');
final _nameSeparators = RegExp(r'[\s_,.-]+');
final _styleSuffix = RegExp(
  r'[-_,\s]*(?:PS-?)?(?:bold[-\s]?(?:italic|oblique)|'
  r'bold|italic|oblique|regular)(?:MT)?$|PSMT$',
  caseSensitive: false,
);

String _withoutSubset(String name) =>
    name.trim().replaceFirst(_subsetPrefix, '');

String _nameKey(String name) {
  final key = _withoutSubset(name)
      .toLowerCase()
      .replaceAll(_nameSeparators, '');
  return _aliases[key]?.toLowerCase().replaceAll(_nameSeparators, '') ?? key;
}

Iterable<String> _candidates(String name) sync* {
  final face = _withoutSubset(name);
  for (final candidate in {face, face.replaceFirst(_styleSuffix, '')}) {
    if (candidate.isEmpty) continue;
    final key = candidate.toLowerCase().replaceAll(_nameSeparators, '');
    yield _aliases[key] ?? candidate;
  }
}

/// Returns the selected installed TrueType face only after checking its names.
SystemFontData? loadSystemFont({
  required String fontName,
  required String familyName,
  required int weight,
  required bool italic,
}) {
  if (!Platform.isWindows) return null;
  final dc = win.CreateCompatibleDC(null);
  if (!dc.isValid) return null;
  try {
    for (final face in {..._candidates(familyName), ..._candidates(fontName)}) {
      // LOGFONT has space for 31 UTF-16 code units and its terminator.
      if (face.length > 31 || face.contains('\u0000')) continue;
      final name = face.toNativeUtf16();
      final font = win.CreateFont(
        -16,
        0,
        0,
        0,
        weight > 0 ? weight : 400,
        italic ? 1 : 0,
        0,
        0,
        win.DEFAULT_CHARSET,
        win.OUT_TT_ONLY_PRECIS,
        win.CLIP_DEFAULT_PRECIS,
        win.DEFAULT_QUALITY,
        0,
        win.PCWSTR(name),
      );
      malloc.free(name);
      if (!font.isValid) continue;
      final previous = win.SelectObject(dc, win.HGDIOBJ(font));
      try {
        if (!previous.isValid) continue;
        final names = _readTable(dc, _name);
        if (names == null) continue;
        final family = _matchingFamily(names, face);
        if (family == null || !_hasStyle(dc, weight, italic)) continue;
        final bytes = _standaloneFont(dc);
        if (bytes != null) return SystemFontData(bytes, family);
      } finally {
        if (previous.isValid) win.SelectObject(dc, previous);
        font.close();
      }
    }
    return null;
  } finally {
    win.DeleteDC(dc);
  }
}

int _gdiTag(int tag) =>
    ((tag & 0xff) << 24) |
    ((tag & 0xff00) << 8) |
    ((tag >> 8) & 0xff00) |
    (tag >> 24);

ByteData? _readTable(win.HDC dc, int tag, [int? size]) {
  final table = _gdiTag(tag);
  final length = size ?? _getFontData(dc, table, 0, nullptr, 0);
  if (length == 0 || length == _gdiError) return null;
  final buffer = malloc<Uint8>(length);
  try {
    if (_getFontData(dc, table, 0, buffer.cast(), length) != length) {
      return null;
    }
    return ByteData.sublistView(Uint8List.fromList(buffer.asTypedList(length)));
  } finally {
    malloc.free(buffer);
  }
}

String? _matchingFamily(ByteData table, String requested) {
  if (table.lengthInBytes < 6) return null;
  final recordsEnd = 6 + 12 * table.getUint16(2);
  final strings = table.getUint16(4);
  if (strings < recordsEnd || strings > table.lengthInBytes) return null;
  final names = <({int id, String label, int priority})>[];
  for (var pos = 6; pos < recordsEnd; pos += 12) {
    final id = table.getUint16(pos + 6);
    if (id != 1 && id != 4 && id != 6 && id != 16 && id != 17) continue;
    final platform = table.getUint16(pos);
    final encoding = table.getUint16(pos + 2);
    final start = strings + table.getUint16(pos + 10);
    final length = table.getUint16(pos + 8);
    final end = start + length;
    if (length == 0 || end > table.lengthInBytes) continue;
    final unicode =
        platform == 0 ||
        (platform == 3 && (encoding < 3 || encoding == 6 || encoding == 10));
    if (unicode && length.isOdd) continue;
    final units = <int>[
      for (var i = start; i < end; i += unicode ? 2 : 1)
        unicode ? table.getUint16(i) : table.getUint8(i),
    ];
    if (!unicode && units.any((unit) => unit > 0x7f)) continue;
    final label = String.fromCharCodes(units).trim();
    if (label.isEmpty) continue;
    final priority = platform == 3 && table.getUint16(pos + 4) == 0x0409
        ? 0
        : unicode
        ? 1
        : 2;
    names.add((id: id, label: label, priority: priority));
  }
  final key = _nameKey(requested);
  final families = names.where((name) => name.id == 1 || name.id == 16).toList()
    ..sort(
      (a, b) => (a.priority * 32 + a.id).compareTo(b.priority * 32 + b.id),
    );
  for (final family in families) {
    if (_nameKey(family.label) == key) return family.label;
  }
  final fullNameMatches = names.any(
    (name) =>
        (name.id == 4 || name.id == 6) &&
        (_nameKey(name.label) == key ||
            _nameKey(name.label.replaceFirst(_styleSuffix, '')) == key),
  );
  if (fullNameMatches) return families.firstOrNull?.label;
  for (final family in families) {
    if (names.any(
      (name) =>
          name.id == 17 && _nameKey('${family.label} ${name.label}') == key,
    )) {
      return family.label;
    }
  }
  return null;
}

bool _hasStyle(win.HDC dc, int weight, bool italic) {
  // GDI can synthesize styles that do not exist in the bytes being embedded.
  final os2 = _readTable(dc, _os2);
  if (weight > 0 && os2 != null && os2.lengthInBytes >= 6) {
    if (os2.getUint16(4) != weight) return false;
  }
  final head = _readTable(dc, _head);
  if (head == null || head.lengthInBytes < 46) return false;
  final flags = os2 != null && os2.lengthInBytes >= 64 ? os2.getUint16(62) : 0;
  final actualItalic = (head.getUint16(44) & 2) != 0 || (flags & 0x201) != 0;
  return actualItalic == italic;
}

Uint8List? _standaloneFont(win.HDC dc) {
  final header = _readTable(dc, 0, 12);
  if (header == null) return null;
  final version = header.getUint32(0);
  if (version != _trueType && version != _appleTrueType) return null;
  final count = header.getUint16(4);
  if (count == 0) return null;
  // A TTC's face directory points at shared tables relative to the collection.
  final directory = _readTable(dc, 0, 12 + count * 16);
  if (directory == null) return null;
  final tables = <({int tag, int length})>[
    for (var pos = 12; pos < directory.lengthInBytes; pos += 16)
      if (directory.getUint32(pos) !=
          _dsig) // Rebuilding invalidates a signature.
        (tag: directory.getUint32(pos), length: directory.getUint32(pos + 12)),
  ];
  final directorySize = 12 + tables.length * 16;
  final size = tables.fold(
    directorySize,
    (sum, table) => sum + _aligned(table.length),
  );
  final buffer = calloc<Uint8>(size);
  try {
    final bytes = buffer.asTypedList(size);
    final sfnt = ByteData.sublistView(bytes);
    final entrySelector = tables.length.bitLength - 1;
    final searchRange = 16 << entrySelector;
    sfnt
      ..setUint32(0, version)
      ..setUint16(4, tables.length)
      ..setUint16(6, searchRange)
      ..setUint16(8, entrySelector)
      ..setUint16(10, tables.length * 16 - searchRange);
    var offset = directorySize;
    var pos = 12;
    int? adjustment;
    var tableSum = 0;
    for (final table in tables) {
      if (table.length != 0 &&
          _getFontData(
                dc,
                _gdiTag(table.tag),
                0,
                (buffer + offset).cast(),
                table.length,
              ) !=
              table.length) {
        return null;
      }
      if (table.tag == _head && table.length >= 12) {
        adjustment = offset + 8;
        sfnt.setUint32(adjustment, 0);
      }
      final end = offset + _aligned(table.length);
      final sum = _checksum(sfnt, offset, end);
      sfnt
        ..setUint32(pos, table.tag)
        ..setUint32(pos + 4, sum)
        ..setUint32(pos + 8, offset)
        ..setUint32(pos + 12, table.length);
      tableSum = (tableSum + sum) & 0xffffffff;
      offset = end;
      pos += 16;
    }
    if (adjustment == null) return null;
    final sum = _checksum(sfnt, 0, directorySize) + tableSum;
    sfnt.setUint32(adjustment, (0xb1b0afba - sum) & 0xffffffff);
    return Uint8List.fromList(bytes);
  } finally {
    calloc.free(buffer);
  }
}

int _aligned(int length) => (length + 3) & ~3;

int _checksum(ByteData data, int start, int end) {
  var sum = 0;
  for (var i = start; i < end; i += 4) {
    sum = (sum + data.getUint32(i)) & 0xffffffff;
  }
  return sum;
}

/// Whether every non-whitespace rune is mapped by a supported Unicode cmap.
/// Returns null when the bytes do not expose a usable format 4 or 12 cmap.
bool? fontSupportsText(Uint8List bytes, String text) {
  final font = ByteData.sublistView(bytes);
  final cmap = _findCmap(font);
  if (cmap == null || cmap.getUint16(0) != 0) return null;
  final recordsEnd = 4 + 8 * cmap.getUint16(2);
  if (recordsEnd > cmap.lengthInBytes) return null;
  ByteData? best;
  var bestPriority = 0;
  for (var pos = 4; pos < recordsEnd; pos += 8) {
    final platform = cmap.getUint16(pos);
    final encoding = cmap.getUint16(pos + 2);
    if (platform != 0 && (platform != 3 || (encoding != 1 && encoding != 10))) {
      continue;
    }
    final start = cmap.getUint32(pos + 4);
    if (start < recordsEnd || start + 16 > cmap.lengthInBytes) continue;
    final format = cmap.getUint16(start);
    if (format != 4 && format != 12) continue;
    final length = format == 12
        ? cmap.getUint32(start + 4)
        : cmap.getUint16(start + 2);
    if (length < 16 || start + length > cmap.lengthInBytes) continue;
    final count = format == 12
        ? cmap.getUint32(start + 12)
        : cmap.getUint16(start + 6);
    final outOfBounds = format == 12
        ? 16 + 12 * count > length
        : count == 0 || count.isOdd || 16 + 4 * count > length;
    if (outOfBounds) continue;
    final priority = (format == 12 ? 3 : 1) + (platform == 3 ? 1 : 0);
    if (priority <= bestPriority) continue;
    best = ByteData.view(cmap.buffer, cmap.offsetInBytes + start, length);
    bestPriority = priority;
  }
  if (best == null) return null;
  final format = best.getUint16(0);
  for (final rune in text.runes) {
    if (String.fromCharCode(rune).trim().isEmpty) continue;
    final glyph = format == 12 ? _glyph12(best, rune) : _glyph4(best, rune);
    if (glyph == null) return null;
    if (glyph == 0) return false;
  }
  return true;
}

ByteData? _findCmap(ByteData font) {
  if (font.lengthInBytes < 12) return null;
  final version = font.getUint32(0);
  if (version != _trueType &&
      version != _appleTrueType &&
      version != _openTypeCff) {
    return null;
  }
  final end = 12 + 16 * font.getUint16(4);
  if (end > font.lengthInBytes) return null;
  for (var pos = 12; pos < end; pos += 16) {
    if (font.getUint32(pos) != _cmap) continue;
    final offset = font.getUint32(pos + 8);
    final length = font.getUint32(pos + 12);
    if (offset < end || length < 4 || offset + length > font.lengthInBytes) {
      return null;
    }
    return ByteData.view(font.buffer, font.offsetInBytes + offset, length);
  }
  return null;
}

int _glyph12(ByteData cmap, int rune) {
  var low = 0;
  var high = cmap.getUint32(12);
  while (low < high) {
    final mid = (low + high) ~/ 2;
    final pos = 16 + mid * 12;
    final start = cmap.getUint32(pos);
    final end = cmap.getUint32(pos + 4);
    if (rune < start) {
      high = mid;
    } else if (rune > end) {
      low = mid + 1;
    } else {
      return cmap.getUint32(pos + 8) + rune - start;
    }
  }
  return 0;
}

int? _glyph4(ByteData cmap, int rune) {
  if (rune > 0xffff) return 0;
  final segments = cmap.getUint16(6) ~/ 2;
  var low = 0;
  var high = segments;
  while (low < high) {
    final mid = (low + high) ~/ 2;
    if (cmap.getUint16(14 + mid * 2) < rune) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  if (low == segments) return 0;
  final index = 16 + low * 2;
  final start = cmap.getUint16(index + segments * 2);
  if (rune < start) return 0;
  final delta = cmap.getInt16(index + segments * 4);
  final rangePos = index + segments * 6;
  final range = cmap.getUint16(rangePos);
  if (range == 0) return (rune + delta) & 0xffff;
  final glyphPos = rangePos + range + (rune - start) * 2;
  if (glyphPos < 16 + segments * 8 || glyphPos + 2 > cmap.lengthInBytes) {
    return null;
  }
  final glyph = cmap.getUint16(glyphPos);
  return glyph == 0 ? 0 : (glyph + delta) & 0xffff;
}
