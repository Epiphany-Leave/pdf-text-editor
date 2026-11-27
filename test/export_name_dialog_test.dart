import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdf_text_editor/export_name_dialog.dart';

const _originalName = '原件.PDF';

Future<void> _openDialog(
  WidgetTester tester,
  ValueChanged<String?> onClose,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              onClose(await showExportNameDialog(context, _originalName));
            },
            child: const Text('导出'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('导出'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('prefills and preserves the original file name', (tester) async {
    String? result;
    await _openDialog(tester, (name) => result = name);

    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.controller.text, '原件');
    expect(
      field.controller.selection,
      const TextSelection(baseOffset: 0, extentOffset: 2),
    );
    expect(find.text('.PDF'), findsOneWidget);
    await tester.tap(find.text('选择保存位置'));
    await tester.pumpAndSettle();

    expect(result, _originalName);
  });

  for (final (input, expected) in [
    ('改写.v2', '改写.v2.PDF'),
    ('校对.PdF', '校对.PDF'),
  ]) {
    testWidgets('submits $expected from the keyboard', (tester) async {
      String? result;
      await _openDialog(tester, (name) => result = name);

      await tester.enterText(find.byType(TextFormField), input);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(result, expected);
    });
  }

  testWidgets('shows invalid names and can cancel without a name', (
    tester,
  ) async {
    String? result = 'dialog still open';
    await _openDialog(tester, (name) => result = name);

    for (final (input, message) in [
      ('   ', '请输入文件名'),
      ('.pdf', '请输入文件名'),
      ('目录/文档.pdf', '文件名不能包含路径分隔符或空字符'),
      (r'目录\文档.pdf', '文件名不能包含路径分隔符或空字符'),
    ]) {
      await tester.enterText(find.byType(TextFormField), input);
      await tester.tap(find.text('选择保存位置'));
      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget);
      expect(result, 'dialog still open');
    }

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });
}
