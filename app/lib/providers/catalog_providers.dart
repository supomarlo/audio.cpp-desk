import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/app_config.dart';
import '../core/model_spec_loader.dart';
import '../core/version_scanner.dart';
import '../models/audio_cpp_version.dart';
import '../models/model_spec.dart';
import '../models/workbench_rule.dart';
import 'app_providers.dart';

final versionsProvider = FutureProvider<List<AudioCppVersion>>((ref) async {
  final audioCppPath =
      ref.watch(appConfigProvider.select((c) => c.audioCppPath));
  final paths = ref.watch(appPathsProvider);
  return VersionScanner.scan(AppConfig.normalizeAgainst(paths, audioCppPath));
});

/// 当前选中版本（找不到则回退第一个；无版本则为 null）。
final activeVersionProvider = FutureProvider<AudioCppVersion?>((ref) async {
  final versionsFuture = ref.watch(versionsProvider.future);
  final activePath =
      ref.watch(appConfigProvider.select((c) => c.activeVersionPath));
  final versions = await versionsFuture;
  if (versions.isEmpty) return null;
  for (final v in versions) {
    if (v.path == activePath) return v;
  }
  return versions.first;
});

/// 选中版本目录下是否有可用的 `model_specs/*.json`。
final hasVersionSpecsProvider = FutureProvider<bool>((ref) async {
  final version = await ref.watch(activeVersionProvider.future);
  if (version == null) return false;
  final dir = Directory(p.join(version.path, 'model_specs'));
  if (!dir.existsSync()) return false;
  return dir.listSync().any(
        (e) => e is File && e.path.toLowerCase().endsWith('.json'),
      );
});

/// 当前版本的模型规格：读 `<version>/model_specs/`，叠加 `model_specs_app`。
final specsProvider = FutureProvider<List<ModelSpec>>((ref) async {
  final versionFuture = ref.watch(activeVersionProvider.future);
  final paths = ref.watch(appPathsProvider);
  final version = await versionFuture;
  if (version == null) return const [];
  final overlayDir = Directory(p.join(paths.dataRoot.path, 'model_specs_app'));
  return ModelSpecLoader.loadForVersion(
    version.path,
    overlayDir: overlayDir.existsSync() ? overlayDir : null,
  );
});

/// 各 family / 变体的工作台字段规则。
final workbenchRulesProvider = FutureProvider<Map<String, WorkbenchRule>>(
    (ref) => WorkbenchRules.load());
