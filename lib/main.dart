import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

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

class PdfTextEditorApp extends StatelessWidget {
  const PdfTextEditorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PDF 文字修改',
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        brightness: Brightness.light,
      ),
      home: const HomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  Future<void> _openPdf(BuildContext context) async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    final path = picked.firstOrNull?.path;
    if (path == null) return;
    if (!context.mounted) return;
    try {
      final doc = await PdfDocument.openFile(path);
      final bytes = await File(path).readAsBytes();
      if (!context.mounted) return;
      final fonts = PdfFonts();
      final session = EditSession(doc, bytes, resolveFont: fonts.findExact);
      ErrorLog.log(
        '打开文件: $path (${bytes.length ~/ 1024}KB, ${doc.pages.length}页)',
      );
      if (!context.mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              ViewerPage(session: session, filePath: path, fonts: fonts),
        ),
      );
    } catch (e, s) {
      ErrorLog.log('打开文件失败: $e', s);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('打开文件失败:$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PDF 文字修改')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.picture_as_pdf, size: 96, color: Colors.blue.shade300),
            const SizedBox(height: 32),
            FilledButton.icon(
              icon: const Icon(Icons.folder_open),
              label: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Text('选择 PDF 文件', style: TextStyle(fontSize: 20)),
              ),
              onPressed: () => _openPdf(context),
            ),
            const SizedBox(height: 24),
            Text(
              '打开后点击文字即可修改,完成后导出新文件',
              style: TextStyle(color: Colors.grey.shade600),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              icon: const Icon(Icons.bug_report_outlined, size: 18),
              label: const Text('错误日志'),
              onPressed: () => _showErrorLog(context),
            ),
          ],
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
