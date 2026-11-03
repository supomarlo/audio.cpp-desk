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

class SpecValueMeta {
  const SpecValueMeta({
    this.labels = const {},
    this.nativeLanguages = const {},
    this.descriptions = const {},
  });

  final Map<String, String> labels;
  final Map<String, String> nativeLanguages;
  final Map<String, String> descriptions;

  String label(String locale) => _localized(labels, locale);
  String nativeLanguage(String locale) => _localized(nativeLanguages, locale);
  String description(String locale) => _localized(descriptions, locale);

  static SpecValueMeta? fromJson(Map<String, dynamic> json) {
    Map<String, String> read(String key) {
      final raw = json[key];
      if (raw is! Map) return const {};
      return {
        for (final e in raw.entries)
          if (e.value is String) e.key.toString(): e.value as String,
      };
    }

    final labels = read('label');
    final nativeLanguages = read('native_language');
    final descriptions = read('description');
    if (labels.isEmpty && nativeLanguages.isEmpty && descriptions.isEmpty) {
      return null;
    }
    return SpecValueMeta(
      labels: labels,
      nativeLanguages: nativeLanguages,
      descriptions: descriptions,
    );
  }
}

String _localized(Map<String, String> values, String locale) {
  final direct = values[locale];
  if (direct != null && direct.isNotEmpty) return direct;
  final en = values['en'];
  if (en != null && en.isNotEmpty) return en;
  for (final v in values.values) {
    if (v.isNotEmpty) return v;
  }
  return '';
}

class ModelLicense {
  const ModelLicense({
    this.name = '',
    this.url = '',
    this.commercialUse = 'unclear',
    this.notes = '',
    this.checkedAt = '',
    this.sourceUrls = const [],
  });

  final String name;
  final String url;
  final String commercialUse;
  final String notes;
  final String checkedAt;
  final List<String> sourceUrls;

  static ModelLicense? fromJson(Map<String, dynamic> json) {
    final name = json['name'] as String? ?? '';
    final url = json['url'] as String? ?? '';
    final notes = json['notes'] as String? ?? '';
    final checkedAt = json['checked_at'] as String? ?? '';
    final sourceUrls = (json['source_urls'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList();
    if (name.isEmpty &&
        url.isEmpty &&
        notes.isEmpty &&
        checkedAt.isEmpty &&
        sourceUrls.isEmpty) {
      return null;
    }
    final use = json['commercial_use'] as String? ?? '';
    return ModelLicense(
      name: name,
      url: url,
      commercialUse: const {'yes', 'conditional', 'no', 'unclear'}.contains(use)
          ? use
          : 'unclear',
      notes: notes,
      checkedAt: checkedAt,
      sourceUrls: sourceUrls,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        'commercial_use': commercialUse,
        'notes': notes,
        'checked_at': checkedAt,
        'source_urls': sourceUrls,
      };
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
    this.optionValueMeta = const {},
    this.uiTexts = const {},
    this.capabilities = const {},
    this.licenses = const [],
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

  /// 枚举值元数据：`i18n.options.<name>.values.<value>`。
  final Map<String, Map<String, SpecValueMeta>> optionValueMeta;

  /// 模型专属 UI 文案：`i18n.ui.<key> = {en, zh}`。
  final Map<String, Map<String, String>> uiTexts;

  /// 能力枚举列表（标签/语言相关由 `capabilities`）。
  final Map<String, List<String>> capabilities;

  final List<ModelLicense> licenses;

  List<String> capabilitiesOf(String task) => capabilities[task] ?? const [];

  SpecValueMeta? optionValueMetaFor(String option, String value) =>
      optionValueMeta[option]?[value];

  /// 按界面语言取参数说明：i18n 叠加 → 规格英文 description → 空。
  String optionDescription(SpecOption o, String locale) {
    final m = optionDescriptions[o.name];
    final v = m?[locale];
    if (v != null && v.isNotEmpty) return v;
    return o.description;
  }

  /// 模型专属 UI 文案：目标语言 → 英文 → 调用方 fallback。
  String uiText(String key, String locale, {String fallback = ''}) {
    final m = uiTexts[key];
    final v = m?[locale];
    if (v != null && v.isNotEmpty) return v;
    final en = m?['en'];
    if (en != null && en.isNotEmpty) return en;
    return fallback;
  }

  bool get isSupported => status == 'supported';

  static ModelSpec fromJson(Map<String, dynamic> json) {
    final rawPackages = json['packages'] as List<dynamic>? ?? [];
    final defaults = json['package_defaults'] as Map<String, dynamic>?;
    final i18n = i18nDescription(json);
    return ModelSpec(
      family: json['family'] as String? ?? '',
      displayName:
          json['display_name'] as String? ?? json['family'] as String? ?? '',
      description:
          i18n.en.isNotEmpty ? i18n.en : (json['description'] as String? ?? ''),
      descriptionZh: i18n.zh.isNotEmpty
          ? i18n.zh
          : (json['description_zh'] as String? ?? ''),
      category: json['category'] as String? ?? 'other',
      status: json['status'] as String? ?? '',
      tasks: (json['tasks'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      languages: (json['languages'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      packages: rawPackages
          .whereType<Map<String, dynamic>>()
          .map(SpecPackage.fromJson)
          .toList(),
      defaultRepo: (defaults?['download'] as Map<String, dynamic>?)?['repo']
              as String? ??
          '',
      requestOptions: _requestOptions(json),
      optionDescriptions: _optionDescriptions(json),
      optionValueMeta: _optionValueMeta(json),
      uiTexts: _uiTexts(json),
      capabilities: _capabilities(json),
      licenses: _licenses(json),
    );
  }

  static List<ModelLicense> _licenses(Map<String, dynamic> json) {
    final raw = json['licenses'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => ModelLicense.fromJson(Map<String, dynamic>.from(e)))
        .whereType<ModelLicense>()
        .toList();
  }

  static Map<String, List<String>> _capabilities(Map<String, dynamic> json) {
    final caps = json['capabilities'];
    if (caps is! Map) return const {};
    return {
      for (final e in caps.entries)
        e.key.toString(): e.value is List
            ? (e.value as List).map((x) => x.toString()).toList()
            : const <String>[],
    };
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
      if (v is! Map) return;
      final descriptions = <String, String>{};
      for (final locale in const ['en', 'zh']) {
        final value = v[locale];
        if (value is String && value.isNotEmpty) {
          descriptions[locale] = value;
        }
      }
      if (descriptions.isNotEmpty) out[k.toString()] = descriptions;
    });
    return out;
  }

  static Map<String, Map<String, String>> _uiTexts(Map<String, dynamic> json) {
    final i18n = json['i18n'];
    final ui = (i18n is Map) ? i18n['ui'] : null;
    if (ui is! Map) return const {};
    final out = <String, Map<String, String>>{};
    ui.forEach((key, value) {
      if (value is! Map) return;
      final texts = <String, String>{};
      for (final locale in const ['en', 'zh']) {
        final text = value[locale];
        if (text is String && text.isNotEmpty) texts[locale] = text;
      }
      if (texts.isNotEmpty) out[key.toString()] = texts;
    });
    return out;
  }

  static Map<String, Map<String, SpecValueMeta>> _optionValueMeta(
      Map<String, dynamic> json) {
    final i18n = json['i18n'];
    final options = (i18n is Map) ? i18n['options'] : null;
    if (options is! Map) return const {};
    final out = <String, Map<String, SpecValueMeta>>{};
    options.forEach((name, option) {
      if (option is! Map) return;
      final values = option['values'];
      if (values is! Map) return;
      final parsed = <String, SpecValueMeta>{};
      values.forEach((value, meta) {
        if (meta is! Map) return;
        final item = SpecValueMeta.fromJson(Map<String, dynamic>.from(meta));
        if (item != null) parsed[value.toString()] = item;
      });
      if (parsed.isNotEmpty) out[name.toString()] = parsed;
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
    for (final e
        in (json['downloads'] as List<dynamic>? ?? []).whereType<Map>()) {
      final d = DownloadEndpoint.fromJson(Map<String, dynamic>.from(e));
      if (d != null) downloads.add(d);
    }
    return SpecPackage(
      id: json['id'] as String? ?? '',
      displayName:
          json['display_name'] as String? ?? json['id'] as String? ?? '',
      format: json['format'] as String? ?? '',
      precision: json['precision'] as String? ?? '',
      isDefault: json['default'] as bool? ?? false,
      targetDirectory: json['target_directory'] as String? ?? '',
      files: (json['files'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      stripPrefix: json['strip_prefix'] as String? ?? '',
      description:
          i18n.en.isNotEmpty ? i18n.en : (json['description'] as String? ?? ''),
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
