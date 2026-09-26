import 'dart:convert';
import 'dart:io';

import 'package:audio_cpp_desk/core/app_paths.dart';
import 'package:audio_cpp_desk/core/voice_library_store.dart';
import 'package:audio_cpp_desk/models/voice_entry.dart';
import 'package:audio_cpp_desk/providers/library_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late AppPaths paths;
  late VoiceLibraryStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('voice_lib_test_');
    addTearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    paths = AppPaths(
      Directory(p.join(temp.path, 'appRoot')),
      dataRoot: Directory(p.join(temp.path, 'data')),
    );
    store = VoiceLibraryStore(paths);
  });

  test('VoiceEntry 序列化往返保留 text 与 audio_path', () {
    final entry = VoiceEntry(
      id: 'v1',
      name: '小雅',
      type: 'file',
      text: '你好，今天天气不错。',
      audioPath: r'data/voices/v1.wav',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );
    final round = VoiceEntry.fromJson({
      'id': 'v1',
      'name': '小雅',
      'type': 'file',
      'created_at_ms': 1700000000000,
    });
    expect(round.text, isNull);
    expect(round.audioPath, isNull);

    final restored =
        VoiceEntry.fromJson(Map<String, dynamic>.from(entry.toJson()));
    expect(restored.name, '小雅');
    expect(restored.type, 'file');
    expect(restored.text, '你好，今天天气不错。');
    expect(restored.audioPath, r'data/voices/v1.wav');
  });

  testWidgets('createFromFile 复制音频到 data/voices 并持久化登记', (tester) async {
    final source = File(p.join(temp.path, 'ref.wav'))..writeAsStringSync('ry');
    final controller = VoiceLibraryController(paths: paths);

    final created = await tester.runAsync(
        () => controller.createFromFile(
              name: '测试音色',
              sourcePath: source.path,
              text: '参考文本',
            ));

    expect(created!.name, '测试音色');
    expect(created.text, '参考文本');
    expect(created.type, 'file');
    expect(created.audioPath, isNotNull);
    expect(File(created.audioPath!).existsSync(), isTrue,
        reason: '音频应已复制到 data/voices');
    expect(created.audioPath, startsWith(paths.voiceDir.path));

    final reloaded = store.load();
    expect(reloaded.length, 1);
    expect(reloaded.first.name, '测试音色');
    expect(reloaded.first.audioPath, created.audioPath);
  });

  testWidgets('createFromFile 空参考文本不存储 text', (tester) async {
    final source = File(p.join(temp.path, 'ref2.wav'))..writeAsStringSync('ry');
    final controller = VoiceLibraryController(paths: paths);
    final created = await tester
        .runAsync(() => controller.createFromFile(name: '无文本', sourcePath: source.path));
    expect(created!.text, isNull);
  });

  testWidgets('audio_path 只记文件名落盘，加载时按当前数据目录拼接为绝对路径', (tester) async {
    final source = File(p.join(temp.path, 'ref_rel.wav'))..writeAsStringSync('ry');
    final controller = VoiceLibraryController(paths: paths);
    final created = await tester.runAsync(() => controller.createFromFile(
          name: '相对路径',
          sourcePath: source.path,
        ));

    final raw = jsonDecode(
            File(p.join(paths.dataDir.path, 'voice_library.json'))
                .readAsStringSync()) as Map<String, dynamic>;
    final stored = (raw['voices'] as List).first['audio_path'] as String;
    expect(stored, '${created!.id}.wav');
    expect(p.isAbsolute(stored), isFalse, reason: '落盘只记文件名');

    final reloaded = store.load();
    expect(reloaded.first.audioPath,
        p.join(paths.voiceDir.path, '${created.id}.wav'));
  });

  testWidgets('加载旧数据（绝对路径）时迁移为文件名', (tester) async {
    final id = 'vlegacy';
    final voiceDir = Directory(paths.voiceDir.path)..createSync(recursive: true);
    final audio = File(p.join(voiceDir.path, '$id.wav'))..writeAsStringSync('ry');
    File(p.join(paths.dataDir.path, 'voice_library.json')).writeAsStringSync(jsonEncode({
      'version': 1,
      'voices': [
        {
          'id': id,
          'name': '旧数据',
          'type': 'file',
          'audio_path': audio.path,
          'created_at_ms': 1700000000000,
        }
      ],
    }));

    final loaded = store.load();
    expect(loaded.first.audioPath, audio.path);

    final raw = jsonDecode(
            File(p.join(paths.dataDir.path, 'voice_library.json'))
                .readAsStringSync()) as Map<String, dynamic>;
    expect((raw['voices'] as List).first['audio_path'], '$id.wav');
  });

  testWidgets('remove 删除登记并移除复制的音频文件', (tester) async {
    final source = File(p.join(temp.path, 'ref3.wav'))..writeAsStringSync('ry');
    final controller = VoiceLibraryController(paths: paths);
    final created = await tester
        .runAsync(() => controller.createFromFile(name: '待删除', sourcePath: source.path));
    final audioPath = created!.audioPath!;
    expect(File(audioPath).existsSync(), isTrue);

    await tester.runAsync(() => controller.remove(created.id));
    expect(controller.state.voices, isEmpty);
    expect(File(audioPath).existsSync(), isFalse,
        reason: '删除音色应一并移除复制的音频文件');
  });

  testWidgets('remove 不误删无音频文件的 spec 音色', (tester) async {
    final controller = VoiceLibraryController(paths: paths);
    await tester.runAsync(() => controller.add(VoiceEntry(
          id: 'vspec',
          name: '内置音色',
          type: 'spec',
          ref: 'CosyVoice-300M',
          note: '来自服务器内置音色',
          createdAt: DateTime.now(),
        )));
    expect(controller.containsRef('spec', 'CosyVoice-300M'), isTrue);
    await tester.runAsync(() => controller.remove('vspec'));
    expect(controller.state.voices, isEmpty);
  });
}