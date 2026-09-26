// 会话与生成记录的数据模型。

/// 会话摘要（列表用，来自会话 meta 文件，不含记录）。
class SessionSummary {
  const SessionSummary({
    required this.id,
    required this.name,
    required this.createdAtMs,
    required this.updatedAtMs,
    required this.recordCount,
  });

  final String id;
  final String name;
  final int createdAtMs;
  final int updatedAtMs;
  final int recordCount;
}

class Session {
  Session({
    required this.id,
    this.name = '',
    this.collectionId,
    required this.createdAtMs,
    required this.updatedAtMs,
    List<GenerationRecord>? records,
  }) : records = records ?? [];

  final String id;

  /// 仅作识别；可为空（界面显示本地化默认名）。
  String name;

  /// 所属集合 id（单归属；null=未归类）。
  String? collectionId;
  int createdAtMs;
  int updatedAtMs;
  final List<GenerationRecord> records;

  Map<String, dynamic> metaJson() => {
        'schema_version': 1,
        'id': id,
        'name': name,
        if (collectionId != null) 'collection_id': collectionId,
        'created_at_ms': createdAtMs,
        'updated_at_ms': updatedAtMs,
        'record_count': records.length,
      };
}

/// 集合：把多个会话按顺序分节组织（如一个脚本的多个小节）。
class Collection {
  Collection({
    required this.id,
    this.name = '',
    this.note = '',
    required this.createdAtMs,
    required this.updatedAtMs,
    List<String>? sessionIds,
  }) : sessionIds = sessionIds ?? [];

  final String id;
  String name;
  String note;
  int createdAtMs;
  int updatedAtMs;

  /// 有序的会话 id 列表（权威顺序）。
  final List<String> sessionIds;

  Map<String, dynamic> toJson() => {
        'schema_version': 1,
        'id': id,
        'name': name,
        'note': note,
        'created_at_ms': createdAtMs,
        'updated_at_ms': updatedAtMs,
        'session_ids': sessionIds,
      };

  static Collection fromJson(Map<String, dynamic> j) => Collection(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        note: j['note'] as String? ?? '',
        createdAtMs: (j['created_at_ms'] as num?)?.toInt() ?? 0,
        updatedAtMs: (j['updated_at_ms'] as num?)?.toInt() ?? 0,
        sessionIds:
            (j['session_ids'] as List<dynamic>? ?? []).map((e) => e.toString()).toList(),
      );
}

/// 生成记录类型：驱动后续操作逻辑（试听方式、可下载物等）。
class RecordType {
  static const tts = 'tts';
  static const asr = 'asr';
  static const vc = 'vc';
  static const other = 'other';
}

class GenerationRecord {
  GenerationRecord({
    required this.id,
    required this.type,
    this.family = '',
    this.packageId = '',
    this.status = 'generating',
    required this.createdAtMs,
    Map<String, String>? inputs,
    List<RecordOutput>? outputs,
    this.text = '',
    this.error = '',
  })  : inputs = inputs ?? {},
        outputs = outputs ?? [];

  final String id;
  final String type;
  final String family;
  final String packageId;

  /// generating | done | failed
  String status;
  final int createdAtMs;
  final Map<String, String> inputs;
  final List<RecordOutput> outputs;

  /// ASR 转写结果（供核对）。
  String text;
  String error;

  Map<String, dynamic> toJson() => {
        'schema_version': 1,
        'id': id,
        'type': type,
        'family': family,
        'package_id': packageId,
        'status': status,
        'created_at_ms': createdAtMs,
        'inputs': inputs,
        'outputs': outputs.map((e) => e.toJson()).toList(),
        if (text.isNotEmpty) 'text': text,
        if (error.isNotEmpty) 'error': error,
      };

  static GenerationRecord fromJson(Map<String, dynamic> json) => GenerationRecord(
        id: json['id'] as String? ?? '',
        type: json['type'] as String? ?? RecordType.other,
        family: json['family'] as String? ?? '',
        packageId: json['package_id'] as String? ?? '',
        status: json['status'] as String? ?? 'done',
        createdAtMs: (json['created_at_ms'] as num?)?.toInt() ?? 0,
        inputs: (json['inputs'] as Map?)?.map(
                (k, v) => MapEntry(k.toString(), v?.toString() ?? '')) ??
            {},
        outputs: (json['outputs'] as List<dynamic>? ?? [])
            .whereType<Map>()
            .map((e) => RecordOutput.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        text: json['text'] as String? ?? '',
        error: json['error'] as String? ?? '',
      );
}

class RecordOutput {
  const RecordOutput({required this.kind, required this.path, this.durationMs});

  /// audio | text | ...
  final String kind;

  /// 相对 history 根的路径（如 `audio/<sid>/<rid>.wav`）。
  final String path;
  final int? durationMs;

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'path': path,
        if (durationMs != null) 'duration_ms': durationMs,
      };

  static RecordOutput fromJson(Map<String, dynamic> json) => RecordOutput(
        kind: json['kind'] as String? ?? 'audio',
        path: json['path'] as String? ?? '',
        durationMs: (json['duration_ms'] as num?)?.toInt(),
      );
}
