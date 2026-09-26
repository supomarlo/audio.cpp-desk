class VoiceEntry {
  VoiceEntry({
    required this.id,
    required this.name,
    required this.type,
    this.family,
    this.ref,
    this.language,
    this.gender,
    this.note = '',
    this.text,
    this.description,
    this.audioPath,
    required this.createdAt,
  });

  final String id;
  String name;
  final String type;
  String? family;
  String? ref;
  String? language;
  String? gender;
  String note;
  String? text;
  String? description;
  String? audioPath;
  final DateTime createdAt;

  VoiceEntry copyWith({
    String? name,
    String? family,
    String? ref,
    String? language,
    String? gender,
    String? note,
    String? text,
    String? description,
    String? audioPath,
  }) {
    return VoiceEntry(
      id: id,
      name: name ?? this.name,
      type: type,
      family: family ?? this.family,
      ref: ref ?? this.ref,
      language: language ?? this.language,
      gender: gender ?? this.gender,
      note: note ?? this.note,
      text: text ?? this.text,
      description: description ?? this.description,
      audioPath: audioPath ?? this.audioPath,
      createdAt: createdAt,
    );
  }

  static VoiceEntry fromJson(Map<String, dynamic> json) {
    return VoiceEntry(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      type: json['type'] as String? ?? 'spec',
      family: json['family'] as String?,
      ref: json['ref'] as String?,
      language: json['language'] as String?,
      gender: json['gender'] as String?,
      note: json['note'] as String? ?? '',
      text: json['text'] as String?,
      description: json['description'] as String?,
      audioPath: json['audio_path'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['created_at_ms'] as num?)?.toInt() ?? 0,
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'type': type,
      'family': family,
      'ref': ref,
      'language': language,
      'gender': gender,
      'note': note,
      'text': text,
      'description': description,
      'audio_path': audioPath,
      'created_at_ms': createdAt.millisecondsSinceEpoch,
    };
  }
}