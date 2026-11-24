import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import 'edit_session.dart';
import 'engine/pdf_edit_engine.dart' show MissingPdfFont;
import 'engine/runs.dart';
import 'error_log.dart';
import 'pdf_fonts.dart';

class ViewerPage extends StatefulWidget {
  const ViewerPage({
    super.key,
    required this.session,
    required this.filePath,
    required this.fonts,
  });

  final EditSession session;
  final String filePath;
  final PdfFonts fonts;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

enum _FontAction { importFile, preview }

class _ViewerPageState extends State<ViewerPage> {
  bool _exporting = false;
  bool _updating = false;
  final _viewerController = PdfViewerController();
  Matrix4? _savedView;
  int _savedPage = 1;

  String get _fileName => widget.filePath.split(Platform.pathSeparator).last;

  @override
  void dispose() {
    widget.session.dispose();
    super.dispose();
  }

  void _onEmptyTap() {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('此页没有可编辑的文字(可能是扫描件图片页)')));
  }

  Future<void> _showEditSheet(TextRun run) async {
    final session = widget.session;
    final existing = session.editForRun(run);
    final controller = TextEditingController(
      text: existing?.newText ?? run.text,
    );
    var bold = existing?.bold ?? run.format.bold;
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
              Text(
                '第 ${run.page} 页原文:',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
              ),
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
                        Navigator.pop(context, false);
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
    if (!mounted) return;
    if (result == true) {
      await _applyChange(() => _editWithFonts(run, controller.text, bold));
    } else if (result == false && existing != null) {
      await _applyChange(() => session.removeEdit(existing));
    }
  }

  Future<void> _editWithFonts(TextRun run, String text, bool bold) async {
    final session = widget.session;
    final fonts = widget.fonts;
    ({String name, Uint8List bytes})? substitute;
    retry:
    while (mounted) {
      try {
        final candidate = substitute;
        await session.upsertEdit(
          run,
          text,
          bold: bold,
          substituteFont: candidate?.bytes,
          confirmPreview: candidate == null
              ? null
              : (bytes, box) =>
                    _confirmSubstitute(bytes, run.page, box, candidate.name),
        );
        return;
      } on MissingPdfFont catch (missing) {
        if (!mounted) return;
        final canSubstitute = missing.runKey == run.key && substitute == null;
        var action = await _chooseFont(missing, canSubstitute: canSubstitute);
        while (mounted && action == _FontAction.importFile) {
          final picked = await FilePicker.pickFiles();
          final path = picked.firstOrNull?.path;
          if (!mounted) return;
          if (path != null && await fonts.importForEdit(File(path), missing)) {
            continue retry;
          }
          if (!mounted) return;
          action = await _chooseFont(
            missing,
            canSubstitute: canSubstitute,
            importFailed: path != null,
          );
        }
        if (!mounted || action != _FontAction.preview) return;

        substitute = await fonts.substituteFor(missing);
        if (substitute == null) {
          throw StateError('可用的近似字体也缺少这些字，请导入同款完整字体。');
        }
      }
    }
  }

  Future<_FontAction?> _chooseFont(
    MissingPdfFont missing, {
    required bool canSubstitute,
    bool importFailed = false,
  }) => showDialog<_FontAction>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('需要字体'),
      content: Text(
        importFailed
            ? '所选文件无法提供这次修改需要的“${missing.fontName}”。请选择包含这些字的同款 TrueType 字体（.ttf 或 .ttc）。'
            : canSubstitute
            ? '“${missing.fontName}”无法写入新文字。你可以导入同款字体，或先预览近似字体。'
            : '需要“${missing.fontName}”才能保留该段文字的原格式。请导入同款字体。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _FontAction.importFile),
          child: const Text('导入同款字体'),
        ),
        if (canSubstitute)
          FilledButton(
            onPressed: () => Navigator.pop(context, _FontAction.preview),
            child: const Text('预览近似字体'),
          ),
      ],
    ),
  );

  Future<bool> _confirmSubstitute(
    Uint8List bytes,
    int page,
    PdfRect? box,
    String name,
  ) async {
    if (!mounted) return false;
    final sourceName = '${widget.filePath}#font-preview';
    final reference = PdfDocumentRefData(
      bytes,
      sourceName: sourceName,
      key: PdfDocumentRefKey(sourceName, [Object()]),
    );
    final controller = PdfViewerController();
    var positioning = false;
    var positioned = false;
    return await showDialog<bool>(
          context: context,
          builder: (context) => StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              title: Text('预览 $name'),
              content: SizedBox(
                width: 400,
                height: (MediaQuery.sizeOf(context).height * 0.42)
                    .clamp(120.0, 300.0)
                    .toDouble(),
                child: PdfViewer(
                  reference,
                  controller: controller,
                  initialPageNumber: page,
                  params: PdfViewerParams(
                    onViewerReady: (_, viewer) async {
                      if (positioning || !context.mounted) return;
                      positioning = true;
                      if (box != null && box.isNotEmpty) {
                        final padding = box.height * 3;
                        await viewer.goToRectInsidePage(
                          pageNumber: page,
                          rect: PdfRect(
                            box.left - padding,
                            box.top + padding,
                            box.right + padding,
                            box.bottom - padding,
                          ),
                          duration: Duration.zero,
                        );
                      }
                      if (context.mounted) {
                        setDialogState(() => positioned = true);
                      }
                    },
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                ValueListenableBuilder(
                  valueListenable: controller.visibleRenderState,
                  builder: (context, state, _) => FilledButton(
                    onPressed:
                        positioned && state == PdfVisibleRenderState.ready
                        ? () => Navigator.pop(context, true)
                        : null,
                    child: const Text('使用此字体'),
                  ),
                ),
              ],
            ),
          ),
        ) ??
        false;
  }

  Future<bool> _applyChange(Future<void> Function() change) async {
    if (_updating || _exporting) return false;
    if (_viewerController.isReady) {
      _savedView = _viewerController.value.clone();
      _savedPage = _viewerController.pageNumber ?? 1;
    }
    setState(() => _updating = true);
    try {
      await change();
      return true;
    } catch (e, s) {
      _savedView = null;
      ErrorLog.log('修改失败: $e', s);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('修改失败: $e')));
      }
      return false;
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _showChanges() async {
    final session = widget.session;
    await showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          children: [
            const ListTile(
              title: Text(
                '修改记录',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            for (final e in session.edits)
              ListTile(
                leading: CircleAvatar(child: Text(e.runKey.split(':').first)),
                title: Text(
                  '${e.originalText} → ${e.newText.trim().isEmpty ? '(删除)' : e.newText}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.undo),
                  tooltip: '撤销',
                  onPressed: () async {
                    Navigator.pop(context);
                    await _applyChange(() => session.removeEdit(e));
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('还没有修改内容。先点击文档中的文字进行修改。')));
      return;
    }
    setState(() => _exporting = true);
    ErrorLog.log('导出开始:${session.editCount} 处修改');
    try {
      final bytes = session.previewBytes;
      final base = _fileName.replaceAll(
        RegExp(r'\.pdf$', caseSensitive: false),
        '',
      );
      final suggestion = '$base-已修改.pdf';
      // file_picker 13 的 saveFile 直接收字节并负责写盘(安卓走系统保存界面)
      final uri = await FilePicker.saveFile(fileName: suggestion, bytes: bytes);
      if (uri == null) {
        ErrorLog.log('导出取消(用户关闭保存对话框)');
        return; // 用户取消
      }
      ErrorLog.log('导出成功: $uri (${bytes.length ~/ 1024}KB)');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已导出')));
      }
    } catch (e, s) {
      ErrorLog.log('导出失败: $e', s);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导出失败:$e')));
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
          body: ListenableBuilder(
            listenable: session,
            builder: (context, _) => PdfViewer(
              PdfDocumentRefData(
                session.previewBytes,
                sourceName:
                    '${widget.filePath}#${session.id}:${session.previewRevision}',
              ),
              controller: _viewerController,
              initialPageNumber: _savedPage,
              params: PdfViewerParams(
                onViewerReady: (document, controller) {
                  final saved = _savedView;
                  if (saved != null) {
                    controller.value = saved;
                    _savedView = null;
                  }
                },
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
        ),
        if (_exporting || _updating)
          const ModalBarrier(color: Colors.black54, dismissible: false),
        if (_exporting || _updating)
          Center(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 12),
                    Text(_updating ? '正在更新预览…' : '正在导出…'),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// One page's transparent overlay: registers taps and previews edits.
class _PageOverlay extends StatefulWidget {
  const _PageOverlay({
    required this.session,
    required this.page,
    required this.onTap,
    required this.onEmptyTap,
  });

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
    widget.session
        .runsForPage(widget.page.pageNumber)
        .then((r) {
          if (mounted) setState(() => _runs = r);
        })
        .catchError((Object e, StackTrace s) {
          ErrorLog.log('读取原文字格式失败: $e', s);
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text('读取文字格式失败: $e')));
          }
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
        final point = PdfPoint(
          details.localPosition.dx / scale,
          widget.page.height - details.localPosition.dy / scale,
        );
        TextRun? closest;
        var closestDistance = double.infinity;
        for (final run in runs) {
          final bounds = widget.session.previewBoxForRun(run);
          if (bounds.isEmpty || !bounds.containsPoint(point, margin: 3)) {
            continue;
          }
          final distance = bounds.distanceSquaredTo(point);
          if (distance < closestDistance) {
            closest = run;
            closestDistance = distance;
            if (distance == 0) break;
          }
        }
        if (closest != null) {
          widget.onTap(closest);
          return true;
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
                revision: widget.session.previewRevision,
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
  _EditsPainter({
    required this.session,
    required this.pageNumber,
    required this.pageHeight,
    required this.scale,
    required this.revision,
  });

  final EditSession session;
  final int pageNumber;
  final double pageHeight; // in PDF points
  final double scale;
  final int revision;

  @override
  void paint(Canvas canvas, Size size) {
    final edits = session.editsForPage(pageNumber);
    if (edits.isEmpty) return;
    final border = Paint()
      ..color = Colors.blue.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    for (final edit in edits) {
      final box = session.previewBoxForRun(edit.run);
      if (box.isEmpty) continue;
      final rect = Rect.fromLTRB(
        box.left * scale,
        (pageHeight - box.top) * scale,
        box.right * scale,
        (pageHeight - box.bottom) * scale,
      ).inflate(1.0 * scale);
      canvas.drawRect(rect, border);
    }
  }

  @override
  bool shouldRepaint(_EditsPainter old) =>
      old.session != session ||
      old.pageNumber != pageNumber ||
      old.revision != revision ||
      old.scale != scale;
}
