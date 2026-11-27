import 'package:material_ui/material_ui.dart';

const _background = Color(0xfff6f7f9);
const _paper = Color(0xffffffff);
const _ink = Color(0xff181c22);
const _mutedInk = Color(0xff5c6573);
const _line = Color(0xffdce1e8);
const _blue = Color(0xff1d5bff);

ThemeData pdfEditorTheme() {
  final colors = ColorScheme.fromSeed(
    seedColor: _blue,
    primary: _blue,
    onPrimary: _paper,
    primaryContainer: const Color(0xffebf1ff),
    onPrimaryContainer: _blue,
    tertiary: const Color(0xffd97706),
    tertiaryContainer: const Color(0xfffff3c4),
    onTertiaryContainer: const Color(0xff753803),
    surface: _paper,
    onSurface: _ink,
    onSurfaceVariant: _mutedInk,
    surfaceContainer: const Color(0xffe9ecef),
    surfaceContainerHighest: _background,
    outline: _mutedInk,
    outlineVariant: _line,
  );
  return ThemeData(
    colorScheme: colors,
    fontFamily: 'NotoSansSC',
    scaffoldBackgroundColor: _background,
    appBarTheme: const AppBarThemeData(
      backgroundColor: _paper,
      foregroundColor: _ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: 'NotoSansSC',
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: _ink,
      ),
      shape: Border(bottom: BorderSide(color: _line)),
    ),
    dividerColor: _line,
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: _background,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _line),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: _paper,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: _paper,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
  );
}
