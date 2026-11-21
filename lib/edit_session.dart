import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import 'engine/pdf_edit_engine.dart';
import 'engine/runs.dart';

/// All state of one editing session: the opened document, per-page text runs
/// (loaded lazily) and the user's edits.
class EditSession extends ChangeNotifier {
  EditSession(this.document, this.sourceBytes);

  final PdfDocument document;
  final Uint8List sourceBytes; // original file bytes, used at export

  final Map<int, List<TextRun>> _runs = {};
  final Map<String, RunEdit> _edits = {}; // keyed by run.key
  Uint8List? fontRegular;
  Uint8List? fontBold;

  bool get hasEdits => _edits.isNotEmpty;
  int get editCount => _edits.length;
  Iterable<RunEdit> get edits => _edits.values;

  Future<void> loadFonts() async {
    fontRegular ??= (await rootBundle.load('assets/fonts/NotoSansSC-Regular.ttf')).buffer.asUint8List();
    fontBold ??= (await rootBundle.load('assets/fonts/NotoSansSC-Bold.ttf')).buffer.asUint8List();
  }

  Future<List<TextRun>> runsForPage(PdfPage page) async {
    return _runs[page.pageNumber] ??= await _loadRuns(page);
  }

  static Future<List<TextRun>> _loadRuns(PdfPage page) async {
    final text = await page.loadStructuredText(ensureLoaded: true);
    final runs = <TextRun>[];
    for (var i = 0; i < text.fragments.length; i++) {
      final f = text.fragments[i];
      runs.addAll(groupRuns(
        page: page.pageNumber,
        fragmentIndex: i,
        text: f.text,
        charRects: f.charRects,
      ));
    }
    return runs;
  }

  List<RunEdit> editsForPage(int pageNumber) =>
      _edits.values.where((e) => e.runKey.startsWith('$pageNumber:')).toList();

  RunEdit? editForRun(TextRun run) => _edits[run.key];

  void upsertEdit(TextRun run, String newText, {bool bold = false}) {
    if (newText == run.text && !bold) {
      _edits.remove(run.key); // unchanged → no edit needed
    } else {
      _edits[run.key] = RunEdit(
        runKey: run.key,
        originalText: run.text,
        newText: newText,
        box: run.box,
        bold: bold,
      );
    }
    notifyListeners();
  }

  void removeEdit(RunEdit edit) {
    _edits.remove(edit.runKey);
    notifyListeners();
  }

  /// Edits grouped for the engine, in page order.
  List<PageEdit> toPageEdits() {
    final byPage = <int, List<RunEdit>>{};
    for (final e in _edits.values) {
      final page = int.parse(e.runKey.split(':').first);
      byPage.putIfAbsent(page, () => []).add(e);
    }
    final keys = byPage.keys.toList()..sort();
    return [for (final k in keys) PageEdit(pageNumber: k, edits: byPage[k]!)];
  }

  @override
  void dispose() {
    document.dispose();
    super.dispose();
  }
}
