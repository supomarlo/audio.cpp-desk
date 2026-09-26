import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_paths.dart';
import '../models/voice_entry.dart';

class VoiceLibraryStore {
  VoiceLibraryStore(this.paths);

  final AppPaths paths;

  File get _file => File(p.join(paths.dataDir.path, 'voice_library.json'));

  /// 音色库目录固定在**数据目录**下（`paths.voiceDir` = `<dataDir>/voices`），
  /// 复制进来的音频也总是直接放在其中。因此落盘只记**文件名**；读取时用
  /// **当前**数据目录下的音色库目录拼接即可——数据目录无论是内置相对路径，
  /// 还是被用户改成外部路径，都随当前设置同步。
  String? _absolute(String? stored) {
    if (stored == null || stored.isEmpty) return null;
    return p.join(paths.voiceDir.path, p.basename(stored));
  }

  String? _stored(String? absolute) {
    if (absolute == null || absolute.isEmpty) return null;
    return p.basename(absolute);
  }

  List<VoiceEntry> load() {
    if (!_file.existsSync()) return [];
    try {
      final raw = jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
      final list = raw['voices'] as List<dynamic>? ?? [];
      final voices = list
          .map((e) => VoiceEntry.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      var migrate = false;
      for (final v in voices) {
        final stored = v.audioPath;
        // 旧数据存的是路径（绝对/相对）而非文件名 → 迁移为文件名
        if (stored != null && stored.isNotEmpty && stored != p.basename(stored)) {
          migrate = true;
        }
        v.audioPath = _absolute(stored);
      }
      if (migrate) save(voices);
      return voices;
    } catch (_) {
      return [];
    }
  }

  void save(List<VoiceEntry> voices) {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(
      jsonEncode({
        'version': 1,
        'voices': [
          for (final v in voices)
            {...v.toJson(), 'audio_path': _stored(v.audioPath)},
        ],
      }),
    );
  }
}
