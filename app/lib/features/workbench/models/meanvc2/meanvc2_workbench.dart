import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../models/model_spec.dart';
import '../../../../models/session.dart';
import '../../../../models/voice_entry.dart';
import '../../../../providers/app_providers.dart';
import '../../../../providers/library_providers.dart';
import '../../../../providers/player_providers.dart';
import '../../widgets/workbench_fields.dart';
import '../../workbench_contract.dart';
import '../../workbench_registry.dart';

/// MeanVC2：VC 任务，源音频 + 参考音色，可选 seed。
class MeanVc2Controller extends WorkbenchModelController {
  MeanVc2Controller(this.packageId, this.spec);

  final String packageId;
  final ModelSpec spec;

  String? audioPath;
  String voiceEntryId = '';
  String? voiceRefPath;
  String? voiceName;
  final TextEditingController seedCtrl = TextEditingController();

  void setAudio(String? path) {
    audioPath = path;
    notifyListeners();
  }

  void setVoice(VoiceEntry? voice) {
    voiceEntryId = voice?.id ?? '';
    voiceRefPath = voice?.audioPath;
    voiceName = voice?.name;
    notifyListeners();
  }

  int? _seed() {
    final text = seedCtrl.text.trim();
    if (text.isEmpty) return null;
    final value = int.tryParse(text);
    if (value == null || value < 0) return null;
    return value;
  }

  @override
  String? validate() {
    if (audioPath == null || audioPath!.isEmpty) return 'workbench.needAudio';
    if (voiceRefPath == null || voiceRefPath!.isEmpty) {
      return 'workbench.needReference';
    }
    final seedText = seedCtrl.text.trim();
    if (seedText.isNotEmpty && _seed() == null) {
      return 'workbench.invalidNumber';
    }
    return null;
  }

  @override
  WorkbenchCall? buildCall() {
    if (validate() != null) return null;
    final modelId = workbenchModelId(packageId, 'vc', spec);
    final seed = _seed();
    return WorkbenchCall(
      endpoint: '/v1/tasks/run',
      modelId: modelId,
      request: {
        'model': modelId,
        'request': {
          'audio': audioPath,
          if (voiceRefPath != null) 'voice_ref': voiceRefPath,
          if (seed != null && seed != 42) 'seed': seed.toString(),
        },
      },
      recordInputs: {
        'audio': audioPath!,
        'voice_entry': voiceEntryId,
        'voice_ref': voiceRefPath ?? '',
        if (voiceName != null) 'voice_name': voiceName!,
        if (seed != null) 'params': jsonEncode({'seed': seed.toString()}),
      },
      responseFormat: 'json_base64',
      audioPath: audioPath,
    );
  }

  @override
  void restore(GenerationRecord record) {
    audioPath = record.inputs['audio'];
    voiceEntryId = record.inputs['voice_entry'] ?? '';
    voiceRefPath = record.inputs['voice_ref'];
    voiceName = record.inputs['voice_name'];
    var seed = '';
    final raw = record.inputs['params'];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map && decoded['seed'] != null) {
          seed = decoded['seed'].toString();
        }
      } catch (_) {}
    }
    seedCtrl.text = seed;
    notifyListeners();
  }

  @override
  void dispose() {
    seedCtrl.dispose();
    super.dispose();
  }
}

class MeanVc2Workbench extends ConsumerWidget {
  const MeanVc2Workbench({
    super.key,
    required this.controller,
    required this.spec,
    required this.dict,
    required this.onSubmit,
  });

  final MeanVc2Controller controller;
  final ModelSpec spec;
  final Map<String, String> dict;
  final VoidCallback onSubmit;

  Future<void> _pickAudio(WidgetRef ref) async {
    final f = await openFile(acceptedTypeGroups: const [
      XTypeGroup(
        label: 'Audio',
        extensions: kWorkbenchAudioExtensions,
      ),
    ]);
    if (f == null) return;
    controller.setAudio(f.path);
    ref.read(audioPlayerProvider).load(f.path, title: f.name);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final voices = ref
        .watch(voiceLibraryProvider)
        .voices
        .where((v) => v.type == 'file')
        .toList();
    final locale = ref.watch(localeProvider).name;
    SpecOption? seedOption;
    for (final o in spec.requestOptions) {
      if (o.name == 'seed') {
        seedOption = o;
        break;
      }
    }
    final seedHelp =
        seedOption == null ? null : spec.optionDescription(seedOption, locale);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          WorkbenchVoiceField(
            label: dict['workbench.voice'] ?? 'Voice',
            defaultLabel: dict['workbench.defaultVoice'] ?? 'Default',
            selectedId: controller.voiceEntryId,
            voices: voices,
            onChanged: (id) {
              VoiceEntry? found;
              for (final v in voices) {
                if (v.id == id) {
                  found = v;
                  break;
                }
              }
              controller.setVoice(found);
            },
          ),
          const SizedBox(height: 12),
          WorkbenchAudioButton(
            label: dict['workbench.pickAudio'] ?? 'Choose audio',
            path: controller.audioPath,
            onPressed: () => _pickAudio(ref),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller.seedCtrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: seedOption?.name ?? 'seed',
              hintText: '${seedOption?.defaultValue ?? 42}',
              suffixIcon: seedHelp == null || seedHelp.isEmpty
                  ? null
                  : Tooltip(
                      message: seedHelp,
                      child: const Icon(Icons.info_outline, size: 18),
                    ),
            ),
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

Widget buildMeanVc2Workbench(
  BuildContext context,
  WorkbenchWidgetContext ctx,
  WorkbenchModelController controller,
) {
  return MeanVc2Workbench(
    controller: controller as MeanVc2Controller,
    spec: ctx.spec,
    dict: ctx.dict,
    onSubmit: () => ctx.submit(controller),
  );
}
