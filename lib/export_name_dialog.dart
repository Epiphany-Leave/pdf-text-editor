import 'package:material_ui/material_ui.dart';

final _pdfExtension = RegExp(r'\.pdf$', caseSensitive: false);

Future<String?> showExportNameDialog(BuildContext context, String fileName) =>
    showDialog<String>(
      context: context,
      builder: (_) => _ExportNameDialog(fileName),
    );

class _ExportNameDialog extends StatefulWidget {
  const _ExportNameDialog(this.fileName);

  final String fileName;

  @override
  State<_ExportNameDialog> createState() => _ExportNameDialogState();
}

class _ExportNameDialogState extends State<_ExportNameDialog> {
  final _nameField = GlobalKey<FormFieldState<String>>();
  late final _extension =
      _pdfExtension.firstMatch(widget.fileName)?.group(0) ?? '.pdf';
  late final _originalStem = widget.fileName.replaceFirst(_pdfExtension, '');
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController.fromValue(
      TextEditingValue(
        text: _originalStem,
        selection: TextSelection(
          baseOffset: 0,
          extentOffset: _originalStem.length,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _stem(String name) => name == _originalStem
      ? name
      : name.trimRight().replaceFirst(_pdfExtension, '');

  void _submit() {
    if (_nameField.currentState?.validate() != true) return;
    Navigator.pop(context, '${_stem(_controller.text)}$_extension');
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('导出文件名'),
    scrollable: true,
    content: TextFormField(
      key: _nameField,
      controller: _controller,
      autofocus: true,
      textInputAction: TextInputAction.done,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(labelText: '文件名', suffixText: _extension),
      validator: (value) {
        final name = value ?? '';
        if (_stem(name).trim().isEmpty) return '请输入文件名';
        if (name.contains('/') ||
            name.contains('\\') ||
            name.contains('\x00')) {
          return '文件名不能包含路径分隔符或空字符';
        }
        return null;
      },
      onFieldSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('选择保存位置')),
    ],
  );
}
