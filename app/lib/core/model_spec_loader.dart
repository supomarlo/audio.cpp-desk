import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import '../models/model_spec.dart';

/// 模型规格加载：
/// - **基线**：选中 audio.cpp 版本目录下的 `model_specs/<family>.json`（只读，不改动）；
/// - **叠加**：`model_specs_app/<family>.json`（我们单独提供），命中时取
///   `i18n`（显示描述）、`options`（运行时契约字段，上游 JSON 为 legacy/不完整时补齐）、
///   `sizes`、`downloads`（下载地址）；其余契约字段仍来自基线。
class ModelSpecLoader {
  static const _overlayAssetDir = 'assets/model_specs_app';

  /// 读取某个版本目录的 `model_specs/` 并叠加 [overlayDir]（若为 null 则尝试内置资源）。
  static Future<List<ModelSpec>> loadForVersion(
    String versionPath, {
    Directory? overlayDir,
  }) async {
    final dir = Directory(p.join(versionPath, 'model_specs'));
    if (!dir.existsSync()) return const [];

    final specs = <ModelSpec>[];
    for (final entry in dir.listSync(followLinks: false)) {
      if (entry is! File || !entry.path.toLowerCase().endsWith('.json')) {
        continue;
      }
      final name = p.basename(entry.path);
      try {
        final base =
            jsonDecode(_stripBom(entry.readAsStringSync())) as Map<String, dynamic>;
        final overlay = await _loadOverlay(name, overlayDir);
        specs.add(ModelSpec.fromJson(_merge(base, overlay)));
      } catch (_) {
        // 单个 family 解析失败不影响其它
      }
    }
    return specs;
  }

  static Future<Map<String, dynamic>?> _loadOverlay(
    String name,
    Directory? overlayDir,
  ) async {
    if (overlayDir != null) {
      final f = File(p.join(overlayDir.path, name));
      if (f.existsSync()) {
        try {
          return jsonDecode(_stripBom(f.readAsStringSync()))
              as Map<String, dynamic>;
        } catch (_) {}
      }
    }
    try {
      final raw = await rootBundle.loadString('$_overlayAssetDir/$name');
      return jsonDecode(_stripBom(raw)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// 版本 spec 为基；叠加只覆盖 `i18n`/`sizes`/`downloads`。
  static Map<String, dynamic> _merge(
    Map<String, dynamic> base,
    Map<String, dynamic>? overlay,
  ) {
    final out = jsonDecode(jsonEncode(base)) as Map<String, dynamic>;
    final defaults = out['package_defaults'] as Map<String, dynamic>?;
    final defaultRepo =
        (defaults?['download'] as Map<String, dynamic>?)?['repo'] as String? ??
            '';

    final overlayPackages = <String, Map>{};
    if (overlay != null) {
      final familyI18n = overlay['i18n'];
      if (familyI18n is Map) out['i18n'] = familyI18n;
      // 运行时契约字段：上游 JSON 为 legacy/不完整时，以本地库的 options 为准
      // （参数必须由 audio.cpp 实际处理，故以本地库契约补充/覆盖）。
      if (overlay['options'] is Map) out['options'] = overlay['options'];
      for (final pkg in (overlay['packages'] as List<dynamic>? ?? [])
          .whereType<Map>()) {
        final id = pkg['id'] as String? ?? '';
        if (id.isNotEmpty) overlayPackages[id] = pkg;
      }
    }

    for (final pkg in (out['packages'] as List<dynamic>? ?? []).whereType<Map>()) {
      final id = pkg['id'] as String? ?? '';
      final ov = overlayPackages[id];
      if (ov != null) {
        if (ov['i18n'] is Map) pkg['i18n'] = ov['i18n'];
        if (ov['sizes'] is Map) pkg['sizes'] = ov['sizes'];
        if (ov['downloads'] is List) pkg['downloads'] = ov['downloads'];
        // 包级 task（模型事实增强）：如 qwen3 VoiceDesign 变体为 vdes。
        if (ov['task'] is String) pkg['task'] = ov['task'];
      }
      final hasDownloads =
          pkg['downloads'] is List && (pkg['downloads'] as List).isNotEmpty;
      if (!hasDownloads) {
        final synth = _synthDownloads(pkg, defaultRepo);
        if (synth.isNotEmpty) pkg['downloads'] = synth;
      }
    }
    return out;
  }

  /// 无叠加时，用版本 spec 的 `download`（或家族默认 repo）兜底合成端点。
  static List<Map<String, dynamic>> _synthDownloads(
    Map<dynamic, dynamic> pkg,
    String defaultRepo,
  ) {
    final dl = pkg['download'];
    final repo = ((dl is Map ? dl['repo'] : null) as String?) ?? defaultRepo;
    if (repo.isEmpty) return const [];
    final kind = (dl is Map ? dl['kind'] : null) as String? ?? 'huggingface_snapshot';
    final revision = (dl is Map ? dl['revision'] : null) as String? ??
        (kind == 'modelscope_snapshot' ? 'master' : 'main');
    final gated = (dl is Map ? dl['gated'] : null) as bool? ?? false;

    if (kind == 'modelscope_snapshot') {
      return [
        {
          'source': 'modelscope',
          'repo': repo,
          'revision': revision,
          'kind': kind,
          'gated': gated,
          'available': true,
        },
      ];
    }
    return [
      {
        'source': 'huggingface',
        'repo': repo,
        'revision': revision,
        'kind': kind,
        'gated': gated,
        'available': true,
      },
      {
        'source': 'hf_mirror',
        'repo': repo,
        'revision': revision,
        'available': true,
      },
    ];
  }

  static String _stripBom(String s) =>
      s.startsWith('\uFEFF') ? s.substring(1) : s;
}
