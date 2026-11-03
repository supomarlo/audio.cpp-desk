import 'package:flutter/material.dart';

import '../../../models/voice_entry.dart';
import '../widgets/workbench_fields.dart';
import 'generic_controller.dart';

/// 未适配 VC 的通用控制台：源音频 + 参考音色。
class GenericVcWorkbench extends StatelessWidget {
  const GenericVcWorkbench({
    super.key,
    required this.controller,
    required this.dict,
    required this.voices,
    required this.onPickAudio,
    required this.onSubmit,
  });

  final GenericWorkbenchController controller;
  final Map<String, String> dict;
  final List<VoiceEntry> voices;
  final VoidCallback onPickAudio;
  final VoidCallback onSubmit;

  void _onVoiceChanged(String id) {
    VoiceEntry? selected;
    for (final voice in voices) {
      if (voice.id == id) {
        selected = voice;
        break;
      }
    }
    controller.setVoice(selected);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          WorkbenchAudioButton(
            label: dict['workbench.pickAudio'] ?? 'Choose audio',
            path: controller.audioPath,
            onPressed: onPickAudio,
          ),
          const SizedBox(height: 12),
          WorkbenchVoiceField(
            label: dict['workbench.voice'] ?? 'Voice',
            defaultLabel: dict['workbench.defaultVoice'] ?? 'Default',
            selectedId: controller.voiceEntryId,
            voices: voices,
            onChanged: _onVoiceChanged,
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: onSubmit,
              icon: const Icon(Icons.playlist_add),
              label: Text(dict['workbench.submit'] ?? 'Add task'),
            ),
          ),
        ],
      ),
    );
  }
}
