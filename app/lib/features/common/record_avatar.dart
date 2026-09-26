import 'package:flutter/material.dart';

import '../../core/glyph.dart';
import '../../models/session.dart';

IconData recordTypeIcon(String type) => switch (type) {
      RecordType.tts => Icons.record_voice_over_outlined,
      RecordType.asr => Icons.transcribe_outlined,
      _ => Icons.volume_up_outlined,
    };

/// 记录头像字符：ASR 取转写文本，其它取生成时记录的音色/角色名。
String? recordGlyph(GenerationRecord r) => firstGlyph(
      r.type == RecordType.asr ? r.text : (r.inputs['voice_name'] ?? ''),
    );

/// 任务 / 记录 / 历史的前导：截取到首字则显示圆形头像（仿头像），
/// 否则回退为记录类型图标。
class RecordAvatar extends StatelessWidget {
  const RecordAvatar({super.key, required this.record});

  final GenerationRecord record;

  @override
  Widget build(BuildContext context) {
    final glyph = recordGlyph(record);
    if (glyph == null) {
      // 与仿头像保持同尺寸并居中，避免回退的类型图标相对仿头像偏左。
      return SizedBox(
        width: 32,
        height: 32,
        child: Center(child: Icon(recordTypeIcon(record.type))),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: 16,
      backgroundColor: scheme.primaryContainer,
      child: Text(
        glyph,
        style: TextStyle(
          color: scheme.onPrimaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
