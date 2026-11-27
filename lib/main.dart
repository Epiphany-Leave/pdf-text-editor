import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import 'app_theme.dart';
import 'edit_session.dart';
import 'engine/pdf_edit_engine.dart' show initPdfiumForEditing;
import 'error_log.dart';
import 'pdf_fonts.dart';
import 'viewer_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  ErrorLog.init();
  // 必须在任何 pdfrx 加载文档之前:认领 PDFium 初始化,避免导出时二次初始化闪退
  initPdfiumForEditing();
  runApp(const PdfTextEditorApp());
}

class PdfTextEditorApp extends StatefulWidget {
  const PdfTextEditorApp({super.key});

  @override
  State<PdfTextEditorApp> createState() => _PdfTextEditorAppState();
}

class _PdfTextEditorAppState extends State<PdfTextEditorApp> {
  final _navigation = _PdfNavigation();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PDF 文字修改',
      theme: pdfEditorTheme(),
      navigatorObservers: [_navigation],
      home: _HomePage(navigation: _navigation),
      debugShowCheckedModeBanner: false,
    );
  }
}

class _PdfNavigation extends NavigatorObserver {
  bool get canOpenPdf => _topRoute is PageRoute<dynamic>;
  Route<dynamic>? _topRoute;

  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    _topRoute = topRoute;
  }
}

class _HomePage extends StatefulWidget {
  const _HomePage({required this.navigation});

  final _PdfNavigation navigation;

  @override
  State<_HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<_HomePage> {
  static const _fileDrop = MethodChannel('pdf_text_editor/file_drop');
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) _fileDrop.setMethodCallHandler(_handleFileDrop);
  }

  @override
  void dispose() {
    if (Platform.isWindows) _fileDrop.setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> _pickPdf() async {
    if (_opening) return;
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    final file = picked.firstOrNull;
    final path = file?.path;
    if (file == null || path == null || !mounted) return;
    await _openPdf(path, file.name);
  }

  Future<void> _handleFileDrop(MethodCall call) async {
    if (!mounted || !widget.navigation.canOpenPdf || _opening) return;
    if (call.method != 'drop' || call.arguments is! List) return;
    final paths = (call.arguments as List).whereType<String>();
    final path = paths
        .where((path) => path.toLowerCase().endsWith('.pdf'))
        .firstOrNull;
    if (path == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请拖入 PDF 文件')));
      return;
    }
    await _openPdf(path, File(path).uri.pathSegments.last);
  }

  Future<void> _openPdf(String path, String name) async {
    if (_opening) return;
    _opening = true;
    try {
      final bytes = await File(path).readAsBytes();
      if (!mounted) return;
      final doc = await PdfDocument.openFile(path);
      if (!mounted || !widget.navigation.canOpenPdf) {
        await doc.dispose();
        return;
      }
      final fonts = PdfFonts();
      final session = EditSession(doc, bytes, resolveFont: fonts.findExact);
      ErrorLog.log(
        '打开文件: $path (${bytes.length ~/ 1024}KB, ${doc.pages.length}页)',
      );
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ViewerPage(
            session: session,
            filePath: path,
            fileName: name,
            fonts: fonts,
          ),
        ),
      );
    } catch (e, s) {
      ErrorLog.log('打开文件失败: $e', s);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('打开文件失败:$e')));
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('PDF 文字修改'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: TextButton.icon(
              icon: const Icon(Icons.bug_report_outlined, size: 18),
              label: const Text('日志'),
              onPressed: () => _showErrorLog(context),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 720;
            final dropZone = wide && Platform.isWindows;
            final colors = theme.colorScheme;
            final card = Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(
                horizontal: wide ? 48 : 24,
                vertical: wide ? 48 : 32,
              ),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(24),
                border: dropZone
                    ? null
                    : Border.all(color: colors.outlineVariant),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: wide
                    ? CrossAxisAlignment.center
                    : CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: colors.primaryContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(
                        Icons.picture_as_pdf_outlined,
                        color: colors.primary,
                        size: 32,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    Platform.isWindows ? '将 PDF 拖入窗口' : '编辑 PDF 文字',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '打开文件后，点按要修改的文字。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    icon: const Icon(Icons.folder_open_outlined),
                    label: const Text('打开 PDF'),
                    onPressed: _pickPdf,
                  ),
                ],
              ),
            );
            return SingleChildScrollView(
              padding: EdgeInsets.symmetric(
                horizontal: wide ? 32 : 20,
                vertical: 24,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: (constraints.maxHeight - 48).clamp(
                    0.0,
                    double.infinity,
                  ),
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: wide ? 640 : 420),
                    child: dropZone
                        ? CustomPaint(
                            foregroundPainter: _DropOutline(
                              colors.primary.withValues(alpha: 0.42),
                            ),
                            child: card,
                          )
                        : card,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _showErrorLog(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (context, ctrl) => ListView(
          controller: ctrl,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '错误日志',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy),
                  tooltip: '复制',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: ErrorLog.asText));
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('已复制到剪贴板')));
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(
              ErrorLog.asText.isEmpty ? '(暂无日志)' : ErrorLog.asText,
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _DropOutline extends CustomPainter {
  const _DropOutline(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(0.75),
          const Radius.circular(24),
        ),
      );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final metric in path.computeMetrics()) {
      for (var start = 0.0; start < metric.length; start += 12) {
        canvas.drawPath(
          metric.extractPath(start, (start + 7).clamp(0.0, metric.length)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_DropOutline oldDelegate) => oldDelegate.color != color;
}
