/// 一个下载端点（HF / hf-mirror / ModelScope）。
///
/// 来源：本地库 `model_specs_app` 的叠加层（我们单独提供），或在无叠加时
/// 由版本 spec 的单个 `download.repo` 兜底合成。
class DownloadEndpoint {
  DownloadEndpoint({
    required this.source,
    required this.repo,
    this.revision = 'main',
    this.kind = 'huggingface_snapshot',
    this.gated = false,
    this.available = true,
    this.sizeBytes,
    this.license = '',
    this.licenseUrl = '',
  });

  /// `huggingface` / `hf_mirror` / `modelscope`
  final String source;
  final String repo;
  final String revision;
  final String kind;
  final bool gated;
  final bool available;
  final int? sizeBytes;

  /// 许可（SPDX id/名称；来源缺失时为空）。
  final String license;

  /// 许可/来源页面 URL。
  final String licenseUrl;

  static DownloadEndpoint? fromJson(Map<String, dynamic> json) {
    final repo = json['repo'] as String? ?? '';
    if (repo.isEmpty) return null;
    final source = json['source'] as String? ?? 'huggingface';
    return DownloadEndpoint(
      source: source,
      repo: repo,
      revision: json['revision'] as String? ??
          (source == 'modelscope' ? 'master' : 'main'),
      kind: json['kind'] as String? ?? 'huggingface_snapshot',
      gated: json['gated'] as bool? ?? false,
      available: json['available'] as bool? ?? true,
      sizeBytes: (json['size_bytes'] as num?)?.toInt(),
      license: json['license'] as String? ?? '',
      licenseUrl: json['license_url'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'source': source,
        'repo': repo,
        'revision': revision,
        'kind': kind,
        'gated': gated,
        'available': available,
        if (sizeBytes != null) 'size_bytes': sizeBytes,
        if (license.isNotEmpty) 'license': license,
        if (licenseUrl.isNotEmpty) 'license_url': licenseUrl,
      };
}

/// 包体量/内存/显存估算（来自 `model_specs_app` 的叠加层）。
class SpecSizes {
  const SpecSizes({
    this.sizeBytes,
    this.estMemoryBytes,
    this.estVramBytes,
    this.basis = '',
  });

  final int? sizeBytes;
  final int? estMemoryBytes;
  final int? estVramBytes;
  final String basis;

  static SpecSizes? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    return SpecSizes(
      sizeBytes: (json['size_bytes'] as num?)?.toInt(),
      estMemoryBytes: (json['est_memory_bytes'] as num?)?.toInt(),
      estVramBytes: (json['est_vram_bytes'] as num?)?.toInt(),
      basis: json['basis'] as String? ?? '',
    );
  }
}

/// 单个可配置的 request option（来自 `options.request`）。
///
/// 参数名保留规格原文（英文）；说明取规格 `description`（英文），
/// 中文说明由 `i18n.options` 叠加（见 [ModelSpec.optionDescriptions]）。
class SpecOption {
  SpecOption({
    required this.name,
    required this.type,
    this.description = '',
    this.values = const [],
    this.defaultValue,
    this.min,
    this.max,
    this.required = false,
  });

  final String name;

  /// string | int | float | bool | enum | ...
  final String type;
  final String description;
  final List<String> values;
  final Object? defaultValue;
  final num? min;
  final num? max;
  final bool required;

  bool get isEnum => type == 'enum' && values.isNotEmpty;
  bool get isBool => type == 'bool';
  bool get isInt => type == 'int';
  bool get isFloat => type == 'float';

  /// 文件 / 音频路径：渲染为「文本框 + 浏览」。
  bool get isPath => type == 'path' || type == 'audio_path';

  SpecOption copyWithType(String newType) => SpecOption(
        name: name,
        type: newType,
        description: description,
        values: values,
        defaultValue: defaultValue,
        min: min,
        max: max,
        required: required,
      );

  static SpecOption fromJson(Map<String, dynamic> json) => SpecOption(
        name: json['name'] as String? ?? '',
        type: json['type'] as String? ?? 'string',
        description: json['description'] as String? ?? '',
        values: (json['values'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
        defaultValue: json['default'],
        min: json['min'] as num?,
        max: json['max'] as num?,
        required: json['required'] as bool? ?? false,
      );
}

/// 读取 `i18n.description` 的 en/zh。
({String en, String zh}) i18nDescription(Map<String, dynamic>? json) {
  final i18n = json?['i18n'];
  if (i18n is Map) {
    final desc = i18n['description'];
    if (desc is Map) {
      return (
        en: desc['en'] as String? ?? '',
        zh: desc['zh'] as String? ?? '',
      );
    }
  }
  return (en: '', zh: '');
}

class ModelSpec {
  ModelSpec({
    required this.family,
    required this.displayName,
    required this.description,
    required this.descriptionZh,
    required this.category,
    required this.status,
    required this.tasks,
    required this.languages,
    required this.packages,
    this.defaultRepo = '',
    this.requestOptions = const [],
    this.optionDescriptions = const {},
  });

  final String family;
  final String displayName;
  final String description;
  final String descriptionZh;
  final String category;
  final String status;
  final List<String> tasks;
  final List<String> languages;
  final List<SpecPackage> packages;
  final String defaultRepo;

  /// 模型可配置的 request options（来自 `options.request`）。
  final List<SpecOption> requestOptions;

  /// 参数说明的多语言叠加：`i18n.options.<name> = {en, zh}`。
  final Map<String, Map<String, String>> optionDescriptions;

  /// 按界面语言取参数说明：i18n 叠加 → 规格英文 description → 空。
  String optionDescription(SpecOption o, String locale) {
    final m = optionDescriptions[o.name];
    final v = m?[locale];
    if (v != null && v.isNotEmpty) return v;
    return o.description;
  }

  bool get isSupported => status == 'supported';

  static ModelSpec fromJson(Map<String, dynamic> json) {
    final rawPackages = json['packages'] as List<dynamic>? ?? [];
    final defaults = json['package_defaults'] as Map<String, dynamic>?;
    final i18n = i18nDescription(json);
    return ModelSpec(
      family: json['family'] as String? ?? '',
      displayName: json['display_name'] as String? ?? json['family'] as String? ?? '',
      description: i18n.en.isNotEmpty
          ? i18n.en
          : (json['description'] as String? ?? ''),
      descriptionZh: i18n.zh.isNotEmpty
          ? i18n.zh
          : (json['description_zh'] as String? ?? ''),
      category: json['category'] as String? ?? 'other',
      status: json['status'] as String? ?? '',
      tasks: (json['tasks'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
      languages: (json['languages'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
      packages: rawPackages
          .whereType<Map<String, dynamic>>()
          .map(SpecPackage.fromJson)
          .toList(),
      defaultRepo:
          (defaults?['download'] as Map<String, dynamic>?)?['repo'] as String? ?? '',
      requestOptions: _requestOptions(json),
      optionDescriptions: _optionDescriptions(json),
    );
  }

  static List<SpecOption> _requestOptions(Map<String, dynamic> json) {
    final options = json['options'];
    final request = (options is Map) ? options['request'] : null;
    if (request is! List) return const [];
    return request
        .whereType<Map>()
        .map((e) => SpecOption.fromJson(Map<String, dynamic>.from(e)))
        .where((o) => o.name.isNotEmpty)
        .toList();
  }

  static Map<String, Map<String, String>> _optionDescriptions(
      Map<String, dynamic> json) {
    final i18n = json['i18n'];
    final options = (i18n is Map) ? i18n['options'] : null;
    if (options is! Map) return const {};
    final out = <String, Map<String, String>>{};
    options.forEach((k, v) {
      if (v is Map) {
        out[k.toString()] =
            v.map((k2, v2) => MapEntry(k2.toString(), v2.toString()));
      }
    });
    return out;
  }
}

class SpecPackage {
  SpecPackage({
    required this.id,
    required this.displayName,
    required this.format,
    required this.precision,
    required this.isDefault,
    required this.targetDirectory,
    required this.files,
    this.stripPrefix = '',
    this.description = '',
    this.descriptionZh = '',
    this.downloadRepo = '',
    this.downloadKind = 'huggingface_snapshot',
    this.revision = 'main',
    this.sizes,
    this.downloads = const [],
    this.task = '',
  });

  final String id;
  final String displayName;
  final String format;
  final String precision;
  final bool isDefault;
  final String targetDirectory;
  final List<String> files;
  final String stripPrefix;
  final String description;
  final String descriptionZh;

  /// 版本 spec 的单个下载源（兜底用；实际下载优先看 [downloads]）。
  final String downloadRepo;
  final String downloadKind;
  final String revision;

  /// 体量/内存/显存（来自叠加层，可能为空）。
  final SpecSizes? sizes;

  /// 多端点下载地址（叠加层提供；无叠加时由版本 `download` 兜底合成）。
  final List<DownloadEndpoint> downloads;

  /// 该包注册到服务端时的 **task**（如 `tts`/`clon`/`vdes`；
  /// 为空则用 family 的首个 task）。
  final String task;

  List<DownloadEndpoint> get availableDownloads =>
      downloads.where((e) => e.available).toList();

  bool get hasDownload => availableDownloads.isNotEmpty;

  static SpecPackage fromJson(Map<String, dynamic> json) {
    final download = json['download'] as Map<String, dynamic>?;
    final kind = download?['kind'] as String? ?? 'huggingface_snapshot';
    final i18n = i18nDescription(json);
    final downloads = <DownloadEndpoint>[];
    for (final e in (json['downloads'] as List<dynamic>? ?? []).whereType<Map>()) {
      final d = DownloadEndpoint.fromJson(Map<String, dynamic>.from(e));
      if (d != null) downloads.add(d);
    }
    return SpecPackage(
      id: json['id'] as String? ?? '',
      displayName: json['display_name'] as String? ?? json['id'] as String? ?? '',
      format: json['format'] as String? ?? '',
      precision: json['precision'] as String? ?? '',
      isDefault: json['default'] as bool? ?? false,
      targetDirectory: json['target_directory'] as String? ?? '',
      files: (json['files'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
      stripPrefix: json['strip_prefix'] as String? ?? '',
      description: i18n.en.isNotEmpty
          ? i18n.en
          : (json['description'] as String? ?? ''),
      descriptionZh: i18n.zh.isNotEmpty
          ? i18n.zh
          : (json['description_zh'] as String? ?? ''),
      downloadRepo: download?['repo'] as String? ?? '',
      downloadKind: kind,
      revision: download?['revision'] as String? ??
          (kind == 'modelscope_snapshot' ? 'master' : 'main'),
      sizes: SpecSizes.fromJson(json['sizes'] as Map<String, dynamic>?),
      downloads: downloads,
      task: json['task'] as String? ?? '',
    );
  }
}
