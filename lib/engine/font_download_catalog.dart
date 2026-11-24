/// A single static TrueType face from a pinned, licensed upstream source.
class FontDownloadFace {
  FontDownloadFace._({
    required this.familyName,
    required this.postscriptName,
    required this.weight,
    required this.italic,
    required String path,
  }) : url = Uri.https('raw.githubusercontent.com', path);

  final String familyName;
  final String? postscriptName;
  final int weight;
  final bool italic;
  final Uri url;
}

// Noto and Roboto static faces are published under the SIL OFL 1.1.
const _noto =
    '/notofonts/noto-fonts/ffebf8c1ee449e544955a7e813c54f9b73848eac/hinted/ttf';
const _roboto =
    '/google/fonts/113bac0943d5b85dcc6c2c01b48fae88d4b5c52a/ofl/roboto/static';

const _families = [
  (name: 'Roboto', stem: 'Roboto', path: _roboto),
  (name: 'Noto Sans', stem: 'NotoSans', path: '$_noto/NotoSans'),
  (name: 'Noto Serif', stem: 'NotoSerif', path: '$_noto/NotoSerif'),
];

const _styles = [
  (weight: 400, italic: false, suffix: 'Regular'),
  (weight: 400, italic: true, suffix: 'Italic'),
  (weight: 700, italic: false, suffix: 'Bold'),
  (weight: 700, italic: true, suffix: 'BoldItalic'),
];

// The author publishes a mainland Chinese serif derived from Source Han Serif
// under SIL OFL 1.1. Plane 0 is the static face with the usual CJK characters.
final _superHan = FontDownloadFace._(
  familyName: 'SuperHan0ivd',
  postscriptName: 'SuperHan0ivd',
  weight: 400,
  italic: false,
  path: '/takushun-wu/SuperHan/d0bd0eec71e21bd657bb5a48b14eb9aec3d548bb/ttf/SuperHan0ivd.ttf',
);

final _faces = [
  for (final family in _families)
    for (final style in _styles)
      FontDownloadFace._(
        familyName: family.name,
        postscriptName: '${family.stem}-${style.suffix}',
        weight: style.weight,
        italic: style.italic,
        path: '${family.path}/${family.stem}-${style.suffix}.ttf',
      ),
  _superHan,
];

final _subsetPrefix = RegExp(r'^[A-Z]{6}\+');
final _separators = RegExp(r'[\s-]+');

String _fontKey(String name) => name
    .trim()
    .replaceFirst(_subsetPrefix, '')
    .toLowerCase()
    .replaceAll(_separators, '');

FontDownloadFace? exactFontDownload({
  required String fontName,
  required String familyName,
  required int weight,
  required bool italic,
}) {
  // Prefer the PDF base name so a renderer's substitute family name cannot
  // make an unrelated download count as an original face.
  final requested = _fontKey(fontName.trim().isEmpty ? familyName : fontName);
  final original = _faces.where((face) {
    return requested == _fontKey(face.familyName) ||
        requested == _fontKey(face.postscriptName ?? face.familyName);
  }).firstOrNull;
  if (original == null) return null;
  return _faces
      .where(
        (face) =>
            face.familyName == original.familyName &&
            face.weight == weight &&
            face.italic == italic,
      )
      .firstOrNull;
}

FontDownloadFace? similarSerifDownload({
  required int weight,
  required bool italic,
}) =>
    weight == _superHan.weight && italic == _superHan.italic ? _superHan : null;
