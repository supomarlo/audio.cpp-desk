import 'dart:io';

import 'package:path/path.dart' as p;

class AppPaths {
  AppPaths(this.appRoot, {Directory? dataRoot})
      : dataRoot = dataRoot ?? Directory(p.join(appRoot.path, 'data'));

  final Directory appRoot;
  final Directory dataRoot;

  Directory get dataDir => dataRoot;
  Directory get voiceDir => Directory(p.join(dataRoot.path, 'voices'));
  Directory get historyDir => Directory(p.join(dataRoot.path, 'history'));
  Directory get logDir => Directory(p.join(dataRoot.path, 'logs'));
  Directory get tmpDir => Directory(p.join(dataRoot.path, 'tmp'));
  Directory get downloadDir => Directory(p.join(dataRoot.path, 'download'));
  Directory get downloadPartialDir =>
      Directory(p.join(downloadDir.path, 'partial'));
  Directory get downloadRecordsDir =>
      Directory(p.join(downloadDir.path, 'records'));

  String _resolve(String path) {
    return p.isAbsolute(path) ? p.normalize(path) : p.join(appRoot.path, path);
  }

  String resolve(String path) => _resolve(path);

  Future<void> ensureDirectories() async {
    final dirs = [
      voiceDir,
      historyDir,
      logDir,
      tmpDir,
      downloadDir,
      downloadPartialDir,
      downloadRecordsDir,
    ];
    for (final d in dirs) {
      await d.create(recursive: true);
    }
  }

  File configFile() => File(p.join(dataRoot.path, 'config.json'));
  File serverConfigFile() => File(p.join(dataRoot.path, 'run', 'server.json'));
}

Future<AppPaths> resolveAppRoot(List<String> args) async {
  const flag = '--app-root=';
  for (final a in args) {
    if (a.startsWith(flag)) {
      final value = a.substring(flag.length);
      return AppPaths(Directory(
        p.isAbsolute(value)
            ? p.normalize(value)
            : p.join(Directory.current.path, value),
      ));
    }
  }

  final env = Platform.environment['AUDIOCPP_DESK_ROOT'];
  if (env != null && env.isNotEmpty) {
    return AppPaths(Directory(env));
  }

  // 发行包目录（Flutter 资源在 data/flutter_assets）不能作为 app root。
  bool isBundle(String path) =>
      Directory(p.join(path, 'data', 'flutter_assets')).existsSync();

  var dir = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 16; i++) {
    if (Directory(p.join(dir.path, 'data')).existsSync() &&
        Directory(p.join(dir.path, 'audio.cpp')).existsSync() &&
        !isBundle(dir.path)) {
      return AppPaths(dir);
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }

  if (File(p.join(Directory.current.path, 'pubspec.yaml')).existsSync()) {
    final parent = Directory.current.parent;
    if (Directory(p.join(parent.path, 'app')).existsSync()) {
      return AppPaths(parent);
    }
  }

  var root = Directory.current;
  if (isBundle(root.path)) root = root.parent;
  return AppPaths(root);
}