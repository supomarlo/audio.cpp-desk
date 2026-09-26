import 'dart:io';

import 'package:path/path.dart' as p;

/// 应用日志（Desk 自身运行日志），落盘到 `data/logs/app-<时间戳>.log`，
/// 与服务端日志（server-*.log）分开。默认关闭；由设置里的"记录应用日志"开关控制。
///
/// 不是自动记录所有操作——只在关键流程主动调用 [info]/[error] 埋点。
class AppLogger {
  AppLogger._();

  static IOSink? _sink;
  static bool _enabled = false;

  static bool get enabled => _enabled;

  /// 配置日志：开关状态或日志目录变化时调用。
  static void configure({required Directory logDir, required bool enabled}) {
    if (enabled == _enabled && _sink != null) return;
    if (enabled && _sink == null) {
      try {
        logDir.createSync(recursive: true);
        final now = DateTime.now();
        String two(int v) => v.toString().padLeft(2, '0');
        final ts = '${now.year}${two(now.month)}${two(now.day)}'
            '-${two(now.hour)}${two(now.minute)}${two(now.second)}';
        final file = File(p.join(logDir.path, 'app-$ts.log'));
        _sink = file.openWrite();
      } catch (_) {
        _sink = null;
      }
    } else if (!enabled && _sink != null) {
      try {
        _sink!.close();
      } catch (_) {}
      _sink = null;
    }
    _enabled = enabled;
  }

  static void info(String message) => _write('INFO', message);

  static void error(String message, [Object? error]) {
    _write('ERROR',
        error == null ? message : '$message: $error');
  }

  static void _write(String level, String message) {
    final sink = _sink;
    if (!_enabled || sink == null) return;
    final t = DateTime.now().toIso8601String();
    sink.writeln('[$t][$level] $message');
  }
}
