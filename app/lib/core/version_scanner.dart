import 'dart:io';

import '../models/audio_cpp_version.dart';

class VersionScanner {
  static List<AudioCppVersion> scan(String rootPath) {
    final root = Directory(rootPath);
    if (!root.existsSync()) return [];

    final versions = <AudioCppVersion>[];
    final visited = <String>{};

    void collect(Directory dir) {
      final serverExe = File('${dir.path}\\audiocpp_server.exe');
      if (!serverExe.existsSync()) return;
      final normalized = dir.path.replaceAll('\\', '/').toLowerCase();
      if (visited.contains(normalized)) return;
      visited.add(normalized);
      versions.add(
        AudioCppVersion(
          path: dir.path,
          name: dir.path,
          serverExe: serverExe,
        ),
      );
    }

    collect(root);

    for (final entry in root.listSync(followLinks: false)) {
      if (entry is! Directory) continue;
      collect(entry);
      for (final sub in entry.listSync(followLinks: false)) {
        if (sub is Directory) collect(sub);
      }
    }

    return versions;
  }
}

String shortPath(String path) {
  var p = path.replaceAll('\\', '/');
  final last = p.split('/').last;
  return last.isEmpty ? p : last;
}