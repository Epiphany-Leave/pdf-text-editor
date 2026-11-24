import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart';

import 'engine/pdf_edit_engine.dart';
import 'engine/runs.dart';

class EditSession extends ChangeNotifier {
  EditSession(this.document, this.sourceBytes, {this.resolveFont})
    : previewBytes = sourceBytes;
  static int _nextId = 0;
  final int id = _nextId++;
  final PdfDocument document;
  final Uint8List sourceBytes;
  final Future<Uint8List?> Function(MissingPdfFont)? resolveFont;
  Uint8List previewBytes;
  int previewRevision = 0;
  final Map<int, List<TextRun>> _runs = {};
  Map<String, RunEdit> _edits = {};
  Map<String, PdfRect> _previewBoxes = const {};
  Map<String, Uint8List> _matchingFonts = const {};
  bool _disposed = false;

  bool get hasEdits => _edits.isNotEmpty;
  int get editCount => _edits.length;
  Iterable<RunEdit> get edits => _edits.values;

  Future<List<TextRun>> runsForPage(int pageNumber) async =>
      _runs[pageNumber] ??= await PdfEditEngine.loadRuns(
        source: sourceBytes,
        pageNumber: pageNumber,
      );

  List<RunEdit> editsForPage(int pageNumber) =>
      _edits.values.where((e) => e.run.page == pageNumber).toList();
  RunEdit? editForRun(TextRun run) => _edits[run.key];
  PdfRect previewBoxForRun(TextRun run) => _previewBoxes[run.key] ?? run.box;

  Future<void> upsertEdit(
    TextRun run,
    String newText, {
    bool? bold,
    Uint8List? substituteFont,
    Future<bool> Function(Uint8List, PdfRect?)? confirmPreview,
  }) {
    final next = Map<String, RunEdit>.of(_edits);
    if (newText == run.text && (bold == null || bold == run.format.bold)) {
      next.remove(run.key);
    } else {
      next[run.key] = RunEdit(
        run: run,
        newText: newText,
        bold: bold,
        substituteFont: substituteFont,
      );
    }
    return _commit(
      next,
      confirmPreview: confirmPreview == null
          ? null
          : (preview) => confirmPreview(preview.bytes, preview.boxes[run.key]),
    );
  }

  Future<void> removeEdit(RunEdit edit) {
    final next = Map<String, RunEdit>.of(_edits)..remove(edit.runKey);
    return _commit(next);
  }

  Future<void> _commit(
    Map<String, RunEdit> next, {
    Future<bool> Function(({Uint8List bytes, Map<String, PdfRect> boxes}))?
    confirmPreview,
  }) async {
    final byPage = <int, List<RunEdit>>{};
    for (final edit in next.values) {
      byPage.putIfAbsent(edit.run.page, () => []).add(edit);
    }
    final pages = [
      for (final page in byPage.keys.toList()..sort())
        PageEdit(pageNumber: page, edits: byPage[page]!),
    ];
    final matchingFonts = next.isEmpty
        ? <String, Uint8List>{}
        : Map<String, Uint8List>.of(_matchingFonts);
    final preview = await _render(pages, matchingFonts);
    if (_disposed) return;
    if (confirmPreview != null && !await confirmPreview(preview)) return;
    if (_disposed) return;
    // Publish the edit and its rendered document together. Export uses these bytes.
    _edits = next;
    _matchingFonts = matchingFonts;
    previewBytes = preview.bytes;
    _previewBoxes = preview.boxes;
    previewRevision++;
    notifyListeners();
  }

  Future<({Uint8List bytes, Map<String, PdfRect> boxes})> _render(
    List<PageEdit> pages,
    Map<String, Uint8List> matchingFonts,
  ) async {
    if (pages.isEmpty) {
      return (bytes: sourceBytes, boxes: const <String, PdfRect>{});
    }
    final attempted = <String>{};
    while (true) {
      try {
        return await PdfEditEngine.renderEdits(
          source: sourceBytes,
          pages: pages,
          matchingFonts: matchingFonts,
        );
      } on MissingPdfFont catch (missing) {
        if (_disposed || !attempted.add(missing.key)) rethrow;
        final bytes = await resolveFont?.call(missing);
        if (bytes == null || _disposed) rethrow;
        matchingFonts[missing.key] = bytes;
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    document.dispose();
    super.dispose();
  }
}
