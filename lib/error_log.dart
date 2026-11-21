// In-app error capture: hooks Flutter/Dart error handlers, keeps a ring
// buffer and appends to error_log.txt in the app documents directory so
// crashes-without-trace can be diagnosed from the device.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class ErrorLog {
  static const _maxEntries = 300;
  static final List<String> _entries = [];
  static File? _file;

  static List<String> get entries => List.unmodifiable(_entries);

  static Future<void> init() async {
    FlutterError.onError = (details) {
      log('FlutterError: ${details.exception}', details.stack);
      FlutterError.presentError(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      log('未捕获异常: $error', stack);
      return true;
    };
    try {
      final dir = await getApplicationDocumentsDirectory();
      _file = File('${dir.path}/error_log.txt');
    } catch (_) {}
    log('应用启动 ${DateTime.now()}');
  }

  static void log(String message, [StackTrace? stack]) {
    final entry = StringBuffer()
      ..write('[')
      ..write(DateTime.now().toIso8601String())
      ..write('] ')
      ..write(message);
    if (stack != null) {
      final lines = stack.toString().split('\n').take(8).join('\n');
      entry.write('\n$lines');
    }
    final line = entry.toString();
    _entries.add(line);
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    _file?.writeAsString('$line\n', mode: FileMode.append);
    debugPrint('ErrorLog: $line');
  }

  static String get asText => _entries.join('\n\n');

  static Future<void> clear() async {
    _entries.clear();
    await _file?.writeAsString('');
  }
}
