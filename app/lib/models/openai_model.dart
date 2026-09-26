class OpenAIModel {
  OpenAIModel(
      {required this.id,
      required this.object,
      this.created,
      this.ownedBy = '',
      this.family = '',
      this.task = ''});

  final String id;
  final String object;
  final int? created;
  final String ownedBy;
  final String family;

  /// 服务端注册的 task（如 `tts`/`clon`/`vdes`/`asr`）。
  final String task;

  static OpenAIModel fromJson(Map<String, dynamic> json) {
    return OpenAIModel(
      id: json['id'] as String? ?? '',
      object: json['object'] as String? ?? 'model',
      created: (json['created'] as num?)?.toInt(),
      ownedBy: json['owned_by'] as String? ?? '',
      family: json['family'] as String? ?? '',
      task: json['task'] as String? ?? '',
    );
  }
}