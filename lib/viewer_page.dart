import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import 'edit_session.dart';
import 'engine/pdf_edit_engine.dart' show MissingPdfFont;
import 'engine/runs.dart';
import 'error_log.dart';
import 'export_name_dialog.dart';
import 'pdf_fonts.dart';

class ViewerPage extends StatefulWidget {
  const ViewerPage({
    super.key,
    required this.session,
    required this.filePath,
    required this.fileName,
    required this.fonts,
  });

  final EditSession session;
  final String filePath;
  final String fileName;
  final PdfFonts fonts;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

enum _FontAction { importFile, preview }

class _ViewerPageState extends State<ViewerPage> {
  bool _exporting = false;
  bool _updating = false;
  final _viewerController = PdfViewerController();
  final _currentPage = ValueNotifier<int>(1);
  Matrix4? _savedView;
  int _savedPage = 1;

  @override
  void dispose() {
    _currentPage.dispose();
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
    var newText = existing?.newText ?? run.text;
    var bold = existing?.bold ?? run.format.bold;
    final wide = MediaQuery.sizeOf(context).width >= 720;
    Widget editPanel(BuildContext context) => StatefulBuilder(
      builder: (context, setState) {
        final theme = Theme.of(context);
        return SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              24,
              wide ? 24 : 0,
              24,
              MediaQuery.viewInsetsOf(context).bottom + 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('编辑文字', style: theme.textTheme.titleLarge),
                const SizedBox(height: 16),
                Text('第 ${run.page} 页原文', style: theme.textTheme.labelLarge),
                const SizedBox(height: 6),
                Text(run.text, style: theme.textTheme.bodyLarge),
                const SizedBox(height: 16),
                TextFormField(
                  initialValue: newText,
                  autofocus: true,
                  minLines: 1,
                  maxLines: 5,
                  onChanged: (value) => newText = value,
                  decoration: const InputDecoration(labelText: '改为'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('粗体'),
                  value: bold,
                  onChanged: (v) => setState(() => bold = v),
                ),
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                    if (existing != null)
                      OutlinedButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('清除修改'),
                      ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('应用修改'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    final result = wide
        ? await showGeneralDialog<bool>(
            context: context,
            barrierDismissible: true,
            barrierLabel: '关闭文字编辑',
            barrierColor: Colors.black26,
            pageBuilder: (context, _, _) => SafeArea(
              child: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: 380,
                  height: double.infinity,
                  child: Material(
                    color: Theme.of(context).colorScheme.surface,
                    elevation: 12,
                    borderRadius: const BorderRadius.horizontal(
                      left: Radius.circular(20),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: editPanel(context),
                  ),
                ),
              ),
            ),
          )
        : await showModalBottomSheet<bool>(
            context: context,
            useSafeArea: true,
            isScrollControlled: true,
            showDragHandle: true,
            builder: editPanel,
          );
    if (!mounted) return;
    if (result == true) {
      await _applyChange(() => _editWithFonts(run, newText, bold));
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
    if (_exporting || _updating || ModalRoute.isCurrentOf(context) != true) {
      return;
    }
    final session = widget.session;
    if (!session.hasEdits) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('还没有修改内容。先点击文档中的文字进行修改。')));
      return;
    }
    String? fileName = widget.fileName;
    if (Platform.isAndroid) {
      fileName = await showExportNameDialog(context, fileName);
      if (!mounted || fileName == null) return;
    }
    setState(() => _exporting = true);
    ErrorLog.log('导出开始:${session.editCount} 处修改');
    try {
      final bytes = session.previewBytes;
      // file_picker 13 的 saveFile 直接收字节并负责写盘(安卓走系统保存界面)
      final uri = await FilePicker.saveFile(fileName: fileName, bytes: bytes);
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
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final busy = _exporting || _updating;
    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            toolbarHeight: MediaQuery.textScalerOf(context)
                .scale(56)
                .clamp(56.0, 96.0),
            titleSpacing: 4,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.fileName, overflow: TextOverflow.ellipsis),
                ValueListenableBuilder<int>(
                  valueListenable: _currentPage,
                  builder: (context, page, _) => Text(
                    '$page / ${session.document.pages.length} 页',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              ListenableBuilder(
                listenable: session,
                builder: (context, _) {
                  final icon = Badge(
                    isLabelVisible: session.hasEdits,
                    label: Text('${session.editCount}'),
                    backgroundColor: colors.tertiaryContainer,
                    textColor: colors.onTertiaryContainer,
                    child: const Icon(Icons.list_alt_outlined),
                  );
                  return wide
                      ? TextButton.icon(
                          icon: icon,
                          label: const Text('修改记录'),
                          onPressed: busy ? null : _showChanges,
                        )
                      : IconButton(
                          icon: icon,
                          tooltip: '修改记录',
                          onPressed: busy ? null : _showChanges,
                        );
                },
              ),
              Padding(
                padding: EdgeInsets.only(
                  left: wide ? 8 : 0,
                  right: wide ? 20 : 12,
                ),
                child: wide
                    ? FilledButton.icon(
                        onPressed: busy ? null : _export,
                        icon: const Icon(Icons.download_outlined),
                        label: const Text('导出 PDF'),
                      )
                    : IconButton.filled(
                        onPressed: busy ? null : _export,
                        icon: const Icon(Icons.download_outlined),
                        tooltip: '导出 PDF',
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
                backgroundColor: colors.surfaceContainer,
                pageDropShadow: const BoxShadow(
                  color: Color(0x300e1927),
                  blurRadius: 12,
                  offset: Offset(0, 3),
                ),
                onPageChanged: (page) {
                  if (page == null) return;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _currentPage.value = page;
                  });
                },
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
        if (busy) const ModalBarrier(color: Colors.black26, dismissible: false),
        if (busy)
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
                color: Theme.of(context).colorScheme.tertiary,
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
    required this.color,
  });

  final EditSession session;
  final int pageNumber;
  final double pageHeight; // in PDF points
  final double scale;
  final int revision;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final edits = session.editsForPage(pageNumber);
    if (edits.isEmpty) return;
    final border = Paint()
      ..color = color.withValues(alpha: 0.8)
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
      old.color != color ||
      old.scale != scale;
}
