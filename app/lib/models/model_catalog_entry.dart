import 'model_spec.dart';

class ModelCatalogEntry {
  ModelCatalogEntry({
    required this.packageId,
    required this.family,
    required this.displayName,
    required this.category,
    required this.installed,
    this.sizeBytes,
    this.estMemoryBytes,
    this.estVramBytes,
    this.localRevision = '',
    this.remoteRevision = '',
    required this.addedAt,
    this.status = '',
    this.description = '',
    this.descriptionZh = '',
    this.packageDescription = '',
    this.packageDescriptionZh = '',
    this.isDefault = false,
    this.sourceRepo = '',
    this.targetDirectory = '',
    this.files = const [],
    this.stripPrefix = '',
    this.downloadKind = 'huggingface_snapshot',
    this.revision = 'main',
    this.sources = const [],
    this.downloads = const [],
    this.activeVersion = false,
    this.task = '',
  });

  final String packageId;
  final String family;
  final String displayName;
  final String category;
  final bool installed;
  final int? sizeBytes;
  final int? estMemoryBytes;
  final int? estVramBytes;
  final String localRevision;
  final String remoteRevision;
  final DateTime addedAt;
  final String status;
  final String description;
  final String descriptionZh;
  final String packageDescription;
  final String packageDescriptionZh;
  final bool isDefault;
  final String sourceRepo;
  final String targetDirectory;
  final List<String> files;
  final String stripPrefix;
  final String downloadKind;
  final String revision;
  final List<String> sources;
  final List<DownloadEndpoint> downloads;
  final bool activeVersion;

  /// 注册到服务端的 task 覆盖（如 `vdes`；空则用 family 首个 task）。
  final String task;

  bool get isSupported => status == 'supported';
  bool get isExperimental => !isSupported;
  bool get hasSource => sources.isNotEmpty;

  ModelCatalogEntry copyWith({
    String? family,
    String? displayName,
    String? category,
    bool? installed,
    int? sizeBytes,
    int? estMemoryBytes,
    int? estVramBytes,
    String? localRevision,
    String? remoteRevision,
    String? status,
    String? description,
    String? descriptionZh,
    String? packageDescription,
    String? packageDescriptionZh,
    bool? isDefault,
    String? sourceRepo,
    String? targetDirectory,
    List<String>? files,
    String? stripPrefix,
    String? downloadKind,
    String? revision,
    List<String>? sources,
    List<DownloadEndpoint>? downloads,
    bool? activeVersion,
    String? task,
  }) {
    return ModelCatalogEntry(
      packageId: packageId,
      family: family ?? this.family,
      displayName: displayName ?? this.displayName,
      category: category ?? this.category,
      installed: installed ?? this.installed,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      estMemoryBytes: estMemoryBytes ?? this.estMemoryBytes,
      estVramBytes: estVramBytes ?? this.estVramBytes,
      localRevision: localRevision ?? this.localRevision,
      remoteRevision: remoteRevision ?? this.remoteRevision,
      addedAt: addedAt,
      status: status ?? this.status,
      description: description ?? this.description,
      descriptionZh: descriptionZh ?? this.descriptionZh,
      packageDescription: packageDescription ?? this.packageDescription,
      packageDescriptionZh: packageDescriptionZh ?? this.packageDescriptionZh,
      isDefault: isDefault ?? this.isDefault,
      sourceRepo: sourceRepo ?? this.sourceRepo,
      targetDirectory: targetDirectory ?? this.targetDirectory,
      files: files ?? this.files,
      stripPrefix: stripPrefix ?? this.stripPrefix,
      downloadKind: downloadKind ?? this.downloadKind,
      revision: revision ?? this.revision,
      sources: sources ?? this.sources,
      downloads: downloads ?? this.downloads,
      activeVersion: activeVersion ?? this.activeVersion,
      task: task ?? this.task,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'package_id': packageId,
      'family': family,
      'display_name': displayName,
      'category': category,
      'installed': installed,
      'size_bytes': sizeBytes,
      'est_memory_bytes': estMemoryBytes,
      'est_vram_bytes': estVramBytes,
      'local_revision': localRevision,
      'remote_revision': remoteRevision,
      'added_at_ms': addedAt.millisecondsSinceEpoch,
      'status': status,
      'description': description,
      'description_zh': descriptionZh,
      'package_description': packageDescription,
      'package_description_zh': packageDescriptionZh,
      'is_default': isDefault,
      'source_repo': sourceRepo,
      'target_directory': targetDirectory,
      'files': files,
      'strip_prefix': stripPrefix,
      'download_kind': downloadKind,
      'revision': revision,
      'sources': sources,
      'downloads': downloads.map((e) => e.toJson()).toList(),
      'active_version': activeVersion,
      'task': task,
    };
  }

  factory ModelCatalogEntry.fromJson(Map<String, dynamic> json) {
    return ModelCatalogEntry(
      packageId: json['package_id'] as String? ?? '',
      family: json['family'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      category: json['category'] as String? ?? 'other',
      installed: json['installed'] as bool? ?? false,
      sizeBytes: (json['size_bytes'] as num?)?.toInt(),
      estMemoryBytes: (json['est_memory_bytes'] as num?)?.toInt(),
      estVramBytes: (json['est_vram_bytes'] as num?)?.toInt(),
      localRevision: json['local_revision'] as String? ?? '',
      remoteRevision: json['remote_revision'] as String? ?? '',
      addedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['added_at_ms'] as num?)?.toInt() ?? 0,
      ),
      status: json['status'] as String? ?? '',
      description: json['description'] as String? ?? '',
      descriptionZh: json['description_zh'] as String? ?? '',
      packageDescription: json['package_description'] as String? ?? '',
      packageDescriptionZh: json['package_description_zh'] as String? ?? '',
      isDefault: json['is_default'] as bool? ?? false,
      sourceRepo: json['source_repo'] as String? ?? '',
      targetDirectory: json['target_directory'] as String? ?? '',
      files: (json['files'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
      stripPrefix: json['strip_prefix'] as String? ?? '',
      downloadKind: json['download_kind'] as String? ?? 'huggingface_snapshot',
      revision: json['revision'] as String? ?? 'main',
      sources: (json['sources'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      downloads: (json['downloads'] as List<dynamic>? ?? [])
          .whereType<Map>()
          .map((e) => DownloadEndpoint.fromJson(Map<String, dynamic>.from(e)))
          .whereType<DownloadEndpoint>()
          .toList(),
      activeVersion: json['active_version'] as bool? ?? false,
      task: json['task'] as String? ?? '',
    );
  }
}
