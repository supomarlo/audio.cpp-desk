import 'package:audio_cpp_desk/core/variant_key.dart';
import 'package:audio_cpp_desk/models/model_catalog_entry.dart';
import 'package:audio_cpp_desk/models/model_spec.dart';
import 'package:audio_cpp_desk/providers/server_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

ModelCatalogEntry _entry({
  required String id,
  String family = 'ming3_tts',
  bool active = false,
  List<String> files = const ['model.gguf'],
  String targetDirectory = 'Ming',
  String stripPrefix = '',
}) =>
    ModelCatalogEntry(
      packageId: id,
      family: family,
      displayName: id,
      category: 'tts',
      installed: true,
      addedAt: DateTime(2026),
      activeVersion: active,
      targetDirectory: targetDirectory,
      files: files,
      stripPrefix: stripPrefix,
      task: 'tts',
    );

void main() {
  group('本地模型路径', () {
    test('单个 GGUF 使用具体文件', () {
      final entry = _entry(id: 'bf16', files: ['model-bf16.gguf']);
      expect(
        entry.localModelPath(p.join('root', 'models')),
        p.join('root', 'models', 'Ming', 'model-bf16.gguf'),
      );
    });

    test('带 stripPrefix 的 GGUF 使用本地文件路径', () {
      final entry = _entry(
        id: 'q8',
        files: ['snapshot/model-q8.gguf'],
        stripPrefix: 'snapshot',
      );
      expect(
        entry.localModelPath(p.join('root', 'models')),
        p.join('root', 'models', 'Ming', 'model-q8.gguf'),
      );
    });

    test('多个 GGUF 保留目录', () {
      final entry = _entry(
        id: 'multi',
        files: ['a.gguf', 'b.gguf'],
      );
      expect(
        entry.localModelPath(p.join('root', 'models')),
        p.join('root', 'models', 'Ming'),
      );
    });

    test('非 GGUF 保留目录', () {
      final entry = _entry(id: 'safetensors', files: ['config.json']);
      expect(
        entry.localModelPath(p.join('root', 'models')),
        p.join('root', 'models', 'Ming'),
      );
    });
  });

  group('变体键', () {
    test('按精度归组，但保留功能变体', () {
      expect(
        VariantKey.of('ming_3_0_tts_0_5b_bf16'),
        VariantKey.of('ming_3_0_tts_0_5b_q8_0'),
      );
      expect(
        VariantKey.of('qwen3_tts_1_7b_base_q8_0'),
        isNot(VariantKey.of('qwen3_tts_1_7b_customvoice_q8_0')),
      );
    });
  });

  group('服务端模型构建', () {
    test('只注册当前版本包', () {
      final models = buildServerModelsFrom(
        specs: const <ModelSpec>[],
        modelsDir: p.join('root', 'models'),
        entries: [
          _entry(id: 'ming_bf16', active: true, files: ['bf16.gguf']),
          _entry(id: 'ming_q8', files: ['q8.gguf']),
          _entry(id: 'ming_custom_bf16', active: true, files: ['custom.gguf']),
          _entry(
            id: 'other_family',
            family: 'other',
            active: true,
            files: ['other.gguf'],
          ),
        ],
      );
      expect(
        models.map((m) => m['id']),
        ['ming_bf16', 'ming_custom_bf16', 'other_family'],
      );
      expect(
        models.first['path'],
        p.join('root', 'models', 'Ming', 'bf16.gguf'),
      );
    });
  });
}
