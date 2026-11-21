import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'edit_session.dart';
import 'viewer_page.dart';
void main() {
  runApp(const PdfTextEditorApp());
}

class PdfTextEditorApp extends StatelessWidget {
  const PdfTextEditorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PDF 文字修改',
      theme: ThemeData(colorSchemeSeed: Colors.blue, brightness: Brightness.light),
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
      final session = EditSession(doc, bytes);
      await session.loadFonts();
      if (!context.mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ViewerPage(session: session, filePath: path)),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('打开文件失败:$e')),
      );
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
            Text('打开后点击文字即可修改,完成后导出新文件',
                style: TextStyle(color: Colors.grey.shade600)),
          ],
        ),
      ),
    );
  }
}
