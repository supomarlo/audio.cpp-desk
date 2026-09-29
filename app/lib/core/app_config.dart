import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_paths.dart';

class AppConfig {
  AppConfig({
    this.audioCppPath = r'audio.cpp',
    this.modelsPath = r'models',
    this.dataPath = r'data',
    this.host = '127.0.0.1',
    this.port = 18081,
    this.backend = 'vulkan',
    this.device = 0,
    this.threads = 4,
    this.taskTimeoutSeconds = 300,
    this.showExperimental = false,
    this.serverLogToFile = false,
    this.appLogToFile = false,
    this.activeVersionPath = '',
    this.locale,
    this.lastUsedPackageId = '',
    this.sessionPanelWidth = 360,
    Map<String, Map<String, String>>? modelParams,
  }) : modelParams = modelParams ?? {};

  String audioCppPath;
  String modelsPath;
  String dataPath;
  String host;
  int port;
  String backend;
  int device;
  int threads;
  int taskTimeoutSeconds;
  bool showExperimental;
  bool serverLogToFile;
  bool appLogToFile;
  String activeVersionPath;
  String? locale;
  String lastUsedPackageId;
  int sessionPanelWidth;

  /// 各 family 的「高级参数」最后配置值：family → {optionName: value}。
  Map<String, Map<String, String>> modelParams;

  static const backendOptions = ['cuda', 'vulkan', 'metal', 'hip', 'cpu'];

  static String normalizeBackend(String value) =>
      backendOptions.contains(value) ? value : 'vulkan';

  static const gpuBackends = {'cuda', 'hip', 'rocm', 'vulkan', 'metal'};

  Map<String, dynamic> toJson() {
    return {
      'audio_cpp_path': audioCppPath,
      'models_path': modelsPath,
      'data_path': dataPath,
      'host': host,
      'port': port,
      'backend': normalizeBackend(backend),
      'device': device,
      'threads': threads,
      'task_timeout_seconds': taskTimeoutSeconds,
      'show_experimental': showExperimental,
      'server_log_to_file': serverLogToFile,
      'app_log_to_file': appLogToFile,
      'active_version_path': activeVersionPath,
      'locale': locale,
      'last_used_package_id': lastUsedPackageId,
      'session_panel_width': sessionPanelWidth,
      'model_params': modelParams,
    };
  }

  static AppConfig fromJson(Map<String, dynamic> json) {
    return AppConfig(
      audioCppPath: json['audio_cpp_path'] as String? ?? r'audio.cpp',
      modelsPath: json['models_path'] as String? ?? r'models',
      dataPath: json['data_path'] as String? ?? r'data',
      host: json['host'] as String? ?? '127.0.0.1',
      port: (json['port'] as num?)?.toInt() ?? 18081,
      backend: normalizeBackend(json['backend'] as String? ?? 'vulkan'),
      device: (json['device'] as num?)?.toInt() ?? 0,
      threads: (json['threads'] as num?)?.toInt() ?? 4,
      taskTimeoutSeconds:
          (json['task_timeout_seconds'] as num?)?.toInt() ?? 300,
      showExperimental: json['show_experimental'] as bool? ?? false,
      serverLogToFile: json['server_log_to_file'] as bool? ?? false,
      appLogToFile: json['app_log_to_file'] as bool? ?? false,
      activeVersionPath: json['active_version_path'] as String? ?? '',
      locale: json['locale'] as String?,
      lastUsedPackageId: json['last_used_package_id'] as String? ?? '',
      sessionPanelWidth: (json['session_panel_width'] as num?)?.toInt() ?? 360,
      modelParams: _parseModelParams(json['model_params']),
    );
  }

  static Map<String, Map<String, String>> _parseModelParams(dynamic raw) {
    if (raw is! Map) return {};
    final out = <String, Map<String, String>>{};
    raw.forEach((k, v) {
      if (v is Map) {
        out[k.toString()] =
            v.map((k2, v2) => MapEntry(k2.toString(), v2?.toString() ?? ''));
      }
    });
    return out;
  }

  static Future<AppConfig> load(AppPaths paths) async {
    final file = paths.configFile();
    if (!file.existsSync()) return AppConfig();
    try {
      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return AppConfig.fromJson(raw);
    } catch (_) {
      return AppConfig();
    }
  }

  Future<void> save(AppPaths paths) async {
    final file = paths.configFile();
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(toJson()));
  }

  String resolveWith(AppPaths paths, String path) =>
      AppConfig.normalizeAgainst(paths, path);

  static String normalizeAgainst(AppPaths paths, String path) {
    return p.normalize(
      p.isAbsolute(path) ? path : p.join(paths.appRoot.path, path),
    );
  }

  AppConfig normalizedFor(AppPaths paths) {
    return AppConfig(
      audioCppPath: AppConfig.normalizeStored(paths, audioCppPath),
      modelsPath: AppConfig.normalizeStored(paths, modelsPath),
      dataPath: AppConfig.normalizeStored(paths, dataPath),
      host: host,
      port: port,
      backend: backend,
      device: device,
      threads: threads,
      showExperimental: showExperimental,
      serverLogToFile: serverLogToFile,
      appLogToFile: appLogToFile,
      activeVersionPath: activeVersionPath,
      locale: locale,
      lastUsedPackageId: lastUsedPackageId,
      sessionPanelWidth: sessionPanelWidth,
      modelParams: modelParams,
    );
  }

  static String normalizeStored(AppPaths paths, String value) {
    var v = value.trim();
    if (v.isEmpty) return v;
    final abs = p.normalize(
      p.isAbsolute(v) ? v : p.join(paths.appRoot.path, v),
    );
    final root = p.normalize(paths.appRoot.path);
    if (p.isWithin(root, abs)) {
      final rel = p.relative(abs, from: root);
      return '.${p.separator}$rel';
    }
    return abs;
  }

  String get audioCppDir => audioCppPath;

  Directory modelsDir(AppPaths paths) => Directory(resolveWith(paths, modelsPath));

  Future<void> ensureDirectories(AppPaths paths) async {
    await Directory(resolveWith(paths, audioCppPath)).create(recursive: true);
    await modelsDir(paths).create(recursive: true);
    await Directory(resolveWith(paths, dataPath)).create(recursive: true);
  }
}