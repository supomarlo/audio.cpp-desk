import 'package:flutter/material.dart';

import '../../../models/model_spec.dart';
import '../../../models/voice_entry.dart';
import '../widgets/workbench_fields.dart';
import '../workbench_contract.dart';
import 'generic_controller.dart';

/// 未适配 TTS 的通用控制台：最小提交集。
class GenericTtsWorkbench extends StatelessWidget {
  const GenericTtsWorkbench({
    super.key,
    required this.controller,
    required this.spec,
    required this.dict,
    required this.voices,
    required this.onSubmit,
  });

  final GenericWorkbenchController controller;
  final ModelSpec spec;
  final Map<String, String> dict;

  /// 仅 file 类型的参考音色。
  final List<VoiceEntry> voices;
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
    final showVoice = workbenchHasSpeakerReference(spec);
    final showRefText =
        workbenchShowsReferenceText(spec) && controller.voiceEntryId.isNotEmpty;
    final showLanguage = spec.languages.isNotEmpty;
    final defaultLabel = dict['workbench.defaultVoice'] ?? 'Default';

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showVoice) ...[
            WorkbenchVoiceField(
              label: dict['workbench.voice'] ?? 'Voice',
              defaultLabel: defaultLabel,
              selectedId: controller.voiceEntryId,
              voices: voices,
              onChanged: _onVoiceChanged,
            ),
            const SizedBox(height: 12),
          ],
          if (showRefText) ...[
            TextField(
              controller: controller.refTextCtrl,
              maxLines: 2,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: dict['workbench.referenceText'] ?? 'Reference text',
                hintText: dict['workbench.referenceTextHint'],
              ),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: controller.textCtrl,
            maxLines: 6,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText: dict['workbench.textHint'] ?? 'Type the text…',
            ),
          ),
          const SizedBox(height: 12),
          if (showLanguage) ...[
            WorkbenchDropdown(
              label: dict['workbench.language'] ?? 'Language',
              value: workbenchLanguageValue(controller.language),
              items: [
                for (final l
                    in workbenchLanguageOptions(spec, controller.language))
                  DropdownMenuItem(value: l, child: Text(l)),
              ],
              onChanged: (v) => controller.setLanguage(
                (v == null || v == 'auto' || v.isEmpty) ? null : v,
              ),
            ),
            const SizedBox(height: 12),
          ],
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
