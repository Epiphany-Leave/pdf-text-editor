import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdf_text_editor/engine/pdf_edit_engine.dart';
import 'package:pdf_text_editor/main.dart';
import 'package:pdfrx/pdfrx.dart' show Pdfrx;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    initPdfiumForEditing();
    Pdfrx.cacheDirectoryPath = Directory.systemTemp.path;
  });

  testWidgets('file drops open PDFs and keep the previous editor available', (
    tester,
  ) async {
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final first = File('test/fixtures/unembedded_helvetica.PDF').absolute.path;
    final second = File('test/fixtures/line_reflow.pdf').absolute.path;

    Future<void> drop(List<String> paths) async {
      await tester.runAsync(() async {
        await messenger.handlePlatformMessage(
          'pdf_text_editor/file_drop',
          codec.encodeMethodCall(MethodCall('drop', paths)),
          (reply) {
            if (reply != null) codec.decodeEnvelope(reply);
          },
        );
      });
      await tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
    }

    await tester.pumpWidget(const PdfTextEditorApp());
    await drop([File('notes.txt').absolute.path, first]);
    expect(find.text('unembedded_helvetica.PDF'), findsOneWidget);

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pump();
    expect(find.byTooltip('导出 PDF'), findsOneWidget);
    expect(find.byTooltip('修改记录'), findsOneWidget);

    await drop([second]);
    expect(find.text('line_reflow.pdf'), findsOneWidget);

    Navigator.of(tester.element(find.text('line_reflow.pdf'))).pop();
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 5),
    );
    expect(find.text('unembedded_helvetica.PDF'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !Platform.isWindows);
}
