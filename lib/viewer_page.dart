import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'edit_session.dart';
import 'engine/font_charset.dart';
import 'engine/pdf_edit_engine.dart';
import 'engine/runs.dart';
import 'error_log.dart';

class ViewerPage extends StatefulWidget {
  const ViewerPage({super.key, required this.session, required this.filePath});

  final EditSession session;
  final String filePath;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  bool _exporting = false;

  String get _fileName => widget.filePath.split(Platform.pathSeparator).last;

  @override
  void dispose() {
    widget.session.dispose();
    super.dispose();
  }

  void _onEmptyTap() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('此页没有可编辑的文字(可能是扫描件图片页)')),
    );
  }

  Future<void> _showEditSheet(TextRun run) async {
    final session = widget.session;
    final existing = session.editForRun(run);
    final controller = TextEditingController(text: existing?.newText ?? run.text);
    var bold = existing?.bold ?? false;
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('第 ${run.page} 页原文:', style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
              const SizedBox(height: 4),
              Text(run.text, style: const TextStyle(fontSize: 16)),
              const Divider(height: 24),
              TextField(
                controller: controller,
                autofocus: true,
                maxLines: null,
                style: const TextStyle(fontSize: 18),
                decoration: const InputDecoration(
                  labelText: '改为',
                  border: OutlineInputBorder(),
                ),
              ),
              ValueListenableBuilder(
                valueListenable: controller,
                builder: (context, value, _) {
                  final uncovered = value.text.runes
                      .where((r) => !fontCovers(String.fromCharCode(r)))
                      .map(String.fromCharCode)
                      .toSet()
                      .take(8)
                      .join();
                  if (uncovered.isEmpty) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '提示:内置字体不包含 $uncovered 等字,导出后这些字可能显示为空白',
                      style: const TextStyle(color: Colors.orange, fontSize: 13),
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('粗体'),
                value: bold,
                onChanged: (v) => setState(() => bold = v),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('确定'),
                    ),
                  ),
                  if (existing != null) ...[
                    const SizedBox(width: 12),
                    OutlinedButton(
                      onPressed: () {
                        session.removeEdit(existing);
                        Navigator.pop(context);
                      },
                      child: const Text('清除修改'),
                    ),
                  ],
                  const SizedBox(width: 12),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (result == true) {
      session.upsertEdit(run, controller.text, bold: bold);
    }
  }

  Future<void> _showChanges() async {
    final session = widget.session;
    await showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          children: [
            const ListTile(title: Text('修改记录', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
            for (final e in session.edits)
              ListTile(
                leading: CircleAvatar(child: Text(e.runKey.split(':').first)),
                title: Text('${e.originalText} → ${e.newText.trim().isEmpty ? '(删除)' : e.newText}',
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  icon: const Icon(Icons.undo),
                  tooltip: '撤销',
                  onPressed: () {
                    session.removeEdit(e);
                    Navigator.pop(context);
                    _showChanges();
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _export() async {
    final session = widget.session;
    if (!session.hasEdits) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没有修改内容。先点击文档中的文字进行修改。')),
      );
      return;
    }
    setState(() => _exporting = true);
    ErrorLog.log('导出开始:${session.editCount} 处修改');
    try {
      // 暂停查看器渲染(isVisible=false 会取消未完成渲染并释放页面图像),
      // 等待在迹任务排空,确保导出期间 PDFium 只有一个使用者。
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final bytes = await PdfEditEngine.applyEdits(
        source: session.sourceBytes,
        fontRegular: session.fontRegular!,
        fontBold: session.fontBold!,
        pages: session.toPageEdits(),
      );
      final base = _fileName.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');
      final suggestion = '$base-已修改.pdf';
      // file_picker 13 的 saveFile 直接收字节并负责写盘(安卓走系统保存界面)
      final uri = await FilePicker.saveFile(fileName: suggestion, bytes: bytes);
      if (uri == null) {
        ErrorLog.log('导出取消(用户关闭保存对话框)');
        return; // 用户取消
      }
      ErrorLog.log('导出成功: $uri (${bytes.length ~/ 1024}KB)');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已导出')),
        );
      }
    } catch (e, s) {
      ErrorLog.log('导出失败: $e', s);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出失败:$e')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            title: Text(_fileName, overflow: TextOverflow.ellipsis),
            actions: [
              IconButton(
                icon: Badge(
                  isLabelVisible: session.editCount > 0,
                  label: Text('${session.editCount}'),
                  child: const Icon(Icons.list_alt),
                ),
                tooltip: '修改记录',
                onPressed: _showChanges,
              ),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: FilledButton.icon(
                  onPressed: _export,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('导出'),
                ),
              ),
            ],
          ),
          body: _exporting
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('正在导出,大约需要几秒…'),
                    ],
                  ),
                )
              : PdfViewer(
                  PdfDocumentRefFile(widget.filePath),
                  params: PdfViewerParams(
              pageOverlaysBuilder: (context, pageRect, page) {
                return [
                  Positioned.fill(
                    child: _PageOverlay(
                      session: session,
                      page: page,
                      onTap: _showEditSheet,
                      onEmptyTap: _onEmptyTap,
                    ),
                  ),
                ];
              },
            ),
          ),
        ),
        if (_exporting)
          const ModalBarrier(color: Colors.black54, dismissible: false),
        if (_exporting)
          const Center(child: Card(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))),
      ],
    );
  }
}

/// One page's transparent overlay: registers taps and previews edits.
class _PageOverlay extends StatefulWidget {
  const _PageOverlay({required this.session, required this.page, required this.onTap, required this.onEmptyTap});

  final EditSession session;
  final PdfPage page;
  final void Function(TextRun run) onTap;
  final VoidCallback onEmptyTap;

  @override
  State<_PageOverlay> createState() => _PageOverlayState();
}

class _PageOverlayState extends State<_PageOverlay> {
  List<TextRun>? _runs;

  @override
  void initState() {
    super.initState();
    widget.session.runsForPage(widget.page).then((r) {
      if (mounted) setState(() => _runs = r);
    });
  }

  @override
  Widget build(BuildContext context) {
    return PdfOverlayInteractionRegion(
      onTap: (details) {
        final runs = _runs;
        final box = context.findRenderObject() as RenderBox?;
        if (runs == null || box == null || !box.size.isFinite) return false;
        final scale = box.size.width / widget.page.width;
        final pdfX = details.localPosition.dx / scale;
        final pdfY = widget.page.height - details.localPosition.dy / scale;
        for (final run in runs) {
          if (run.containsPoint(pdfX, pdfY)) {
            widget.onTap(run);
            return true;
          }
        }
        if (runs.isEmpty) widget.onEmptyTap();
        return false;
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (!constraints.biggest.isFinite) return const SizedBox.shrink();
          return ListenableBuilder(
            listenable: widget.session,
            builder: (context, _) => CustomPaint(
              size: constraints.biggest,
              painter: _EditsPainter(
                session: widget.session,
                pageNumber: widget.page.pageNumber,
                pageHeight: widget.page.height,
                scale: constraints.biggest.width / widget.page.width,
              ),
              child: const SizedBox.expand(),
            ),
          );
        },
      ),
    );
  }
}

class _EditsPainter extends CustomPainter {
  _EditsPainter({required this.session, required this.pageNumber, required this.pageHeight, required this.scale});

  final EditSession session;
  final int pageNumber;
  final double pageHeight; // in PDF points
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final edits = session.editsForPage(pageNumber);
    if (edits.isEmpty) return;
    final white = Paint()..color = Colors.white;
    final border = Paint()
      ..color = Colors.blue.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    for (final edit in edits) {
      final rect = Rect.fromLTRB(
        edit.box.left * scale,
        (pageHeight - edit.box.top) * scale,
        edit.box.right * scale,
        (pageHeight - edit.box.bottom) * scale,
      ).inflate(1.0 * scale);
      canvas.drawRect(rect, white);
      canvas.drawRect(rect, border);
      if (edit.newText.trim().isEmpty) continue;
      // Match the run height: estimate from the original text height.
      final fontSize = _estimateFontSize(edit) * scale;
      final tp = TextPainter(
        text: TextSpan(
          text: edit.newText,
          style: TextStyle(
            fontFamily: 'NotoSansSC',
            fontWeight: edit.bold ? FontWeight.w700 : FontWeight.w400,
            fontSize: fontSize,
            color: Colors.black,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      tp.layout();
      canvas.translate(rect.left, rect.top + (rect.height - tp.height) / 2);
      tp.paint(canvas, Offset.zero);
      canvas.translate(-rect.left, -(rect.top + (rect.height - tp.height) / 2));
    }
  }

  double _estimateFontSize(RunEdit edit) {
    final cjk = edit.newText.runes.any((r) => r >= 0x2E80 && r <= 0x9FFF);
    final src = edit.originalText.runes.any((r) => r >= 0x2E80 && r <= 0x9FFF);
    final h = edit.box.height;
    return (cjk || src) ? h * 0.98 : h / 0.72;
  }

  @override
  bool shouldRepaint(_EditsPainter old) =>
      old.session != session ||
      old.pageNumber != pageNumber ||
      old.session.editCount != session.editCount ||
      old.scale != scale;
}
