import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_paths.dart';

/// 首次运行引导标记：缺此文件表示尚未引导过。
class Onboarding {
  Onboarding._();

  static File _file(AppPaths paths) =>
      File(p.join(paths.dataDir.path, 'onboarding.json'));

  static bool isDone(AppPaths paths) {
    try {
      return _file(paths).existsSync();
    } catch (_) {
      return true;
    }
  }

  static void markDone(AppPaths paths) {
    try {
      final f = _file(paths);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(
        jsonEncode({
          'schema_version': 1,
          'onboarded_at_ms': DateTime.now().millisecondsSinceEpoch,
        }),
        encoding: utf8,
      );
    } catch (_) {}
  }
}
