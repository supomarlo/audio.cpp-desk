import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:path/path.dart' as p;

import '../core/app_config.dart';
import '../core/gpu_probe.dart';
import '../core/server_client.dart';
import '../core/server_controller.dart';
import '../core/task_timeout.dart';
import '../models/audio_cpp_version.dart';
import '../models/model_catalog_entry.dart';
import '../models/model_spec.dart';
import '../models/server_snapshot.dart';
import 'app_providers.dart';
import 'catalog_providers.dart';
import 'library_providers.dart';

final serverClientProvider = Provider<ServerClient>((ref) {
  final host = ref.watch(appConfigProvider.select((c) => c.host));
  final cfgPort = ref.watch(appConfigProvider.select((c) => c.port));
  // 以"服务端实际生效端口"为准（接管 / 备用端口时会与配置端口不同）；
  // 未知（0）才回退用配置端口。
  final snapPort =
      ref.watch(serverControllerProvider.select((s) => s.port));
  final port = snapPort > 0 ? snapPort : cfgPort;
  final timeoutSec =
      ref.watch(appConfigProvider.select((c) => c.taskTimeoutSeconds));
  // 客户端接收超时 = 单次任务超时 + 余量（见 core/task_timeout.dart）。
  return ServerClient(
    'http://$host:$port',
    receiveTimeout: taskReceiveTimeout(Duration(seconds: timeoutSec)),
  );
});

final serverControllerProvider =
    StateNotifierProvider<ServerController, ServerSnapshot>((ref) {
  final paths = ref.watch(appPathsProvider);
  final config = ref.read(appConfigProvider);
  final controller = ServerController(paths: paths, config: config);
  return controller;
});

final gpuNamesProvider =
    FutureProvider.family<List<String>, String>((ref, backend) async {
  final versions = ref.watch(versionsProvider);
  final list = versions.value ?? const <AudioCppVersion>[];
  if (list.isEmpty) return const <String>[];
  final activePath =
      ref.watch(appConfigProvider.select((c) => c.activeVersionPath));
  AudioCppVersion? version;
  if (activePath.isNotEmpty) {
    for (final v in list) {
      if (v.path == activePath) {
        version = v;
        break;
      }
    }
  }
  version ??= list.first;
  return GpuProbe.listGpuNames(serverExe: version.serverExe.path, backend: backend);
});

final availableBackendsProvider = FutureProvider<List<String>>((ref) async {
  final versions = ref.watch(versionsProvider);
  final list = versions.value ?? const <AudioCppVersion>[];
  if (list.isEmpty) return const <String>[];
  final activePath =
      ref.watch(appConfigProvider.select((c) => c.activeVersionPath));
  AudioCppVersion? version;
  if (activePath.isNotEmpty) {
    for (final v in list) {
      if (v.path == activePath) {
        version = v;
        break;
      }
    }
  }
  version ??= list.first;
  return GpuProbe.listRegisteredBackends(serverExe: version.serverExe.path);
});

/// 依据已安装模型构建服务端模型条目。
List<Map<String, dynamic>> _modelsFrom(
  AppConfig cfg,
  List<ModelSpec> specs,
  String modelsDir,
  List<ModelCatalogEntry> entries,
) {
  final specByFamily = {for (final s in specs) s.family: s};
  return [
    for (final e in entries.where((e) => e.installed))
      {
        'id': e.packageId,
        'family': e.family,
        'path': p.join(modelsDir, e.targetDirectory),
        // 规格按包声明的 task 优先（如 qwen3 VoiceDesign 变体为 vdes），
        // 否则回退 family 首个 task / 分类。
        'task': e.task.isNotEmpty
            ? e.task
            : ((specByFamily[e.family]?.tasks.isNotEmpty ?? false)
                ? specByFamily[e.family]!.tasks.first
                : (e.category.isEmpty ? 'tts' : e.category)),
        'mode': 'offline',
      },
  ];
}

/// 依据当前配置与已安装模型构建服务端模型条目。
/// 供服务页手动启动与工作台自动启动共用，保证两处口径一致。
List<Map<String, dynamic>> buildServerModels(WidgetRef ref) {
  final cfg = ref.read(appConfigProvider);
  final specs = ref.read(specsProvider).value ?? const <ModelSpec>[];
  final modelsDir = cfg.modelsDir(ref.read(appPathsProvider)).path;
  return _modelsFrom(
      cfg, specs, modelsDir, ref.read(modelLibraryProvider).entries);
}

List<Map<String, dynamic>> _buildModelsRef(Ref ref) {
  final cfg = ref.read(appConfigProvider);
  final specs = ref.read(specsProvider).value ?? const <ModelSpec>[];
  final modelsDir = cfg.modelsDir(ref.read(appPathsProvider)).path;
  return _modelsFrom(
      cfg, specs, modelsDir, ref.read(modelLibraryProvider).entries);
}

/// 服务端确保/重启的共享核心（widget 与 provider 复用）。
Future<void> _ensureServerCore(
  ServerController controller,
  ServerSnapshot snap,
  List<Map<String, dynamic>> models,
  AppConfig cfg,
  List<AudioCppVersion> versions,
  String? requireModelId,
) async {
  final running = snap.isRunning && snap.healthy;
  if (running && requireModelId != null) {
    // 期望的 task（来自当前配置的模型条目）。
    final desired = models.firstWhere(
      (m) => m['id'] == requireModelId,
      orElse: () => const <String, dynamic>{},
    )['task'] as String? ?? '';
    try {
      final ms = await controller.client.models();
      final match = ms.where((m) => m.id == requireModelId).toList();
      // 运行中的服务端已注册该模型且 task 一致 → 直接复用；否则重启以套用新配置。
      if (match.isNotEmpty && (desired.isEmpty || match.first.task == desired)) {
        return;
      }
    } catch (_) {}
    await controller.stop();
  } else if (running || snap.isStarting) {
    return;
  }
  // 无版本/无已安装模型时无法启动；交给上层引导。
  if (versions.isEmpty || models.isEmpty) return;
  AudioCppVersion? version;
  for (final v in versions) {
    if (v.path == cfg.activeVersionPath) {
      version = v;
      break;
    }
  }
  version ??= versions.first;
  controller.updateConfig(cfg);
  await controller.start(version, cfg, models: models);
}

/// 确保服务端已启动；服务端以 `lazy_load` 启动，模型在首次请求时才真正加载。
/// 若 [requireModelId] 已注册于运行中的服务端则直接返回，否则重启以带上最新模型。
Future<void> ensureServerStarted(WidgetRef ref, {String? requireModelId}) async {
  final versions = await ref.read(versionsProvider.future);
  final models = buildServerModels(ref);
  final cfg = ref.read(appConfigProvider);
  await _ensureServerCore(ref.read(serverControllerProvider.notifier),
      ref.read(serverControllerProvider), models, cfg, versions, requireModelId);
}

/// 同 [ensureServerStarted]，供 provider 内部（Ref）调用。
Future<void> ensureServerStartedRef(Ref ref, {String? requireModelId}) async {
  final versions = await ref.read(versionsProvider.future);
  final models = _buildModelsRef(ref);
  final cfg = ref.read(appConfigProvider);
  await _ensureServerCore(ref.read(serverControllerProvider.notifier),
      ref.read(serverControllerProvider), models, cfg, versions, requireModelId);
}

/// 通过 API 卸载所有常驻模型，释放显存（比重启服务端轻量）。
/// 成功返回 true；失败（端点为推断接口/服务端异常）返回 false。
Future<bool> unloadAllModelsRef(Ref ref) async {
  try {
    await ref.read(serverClientProvider).unloadAllModels();
    return true;
  } catch (_) {
    return false;
  }
}