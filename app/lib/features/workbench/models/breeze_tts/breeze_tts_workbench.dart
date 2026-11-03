import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../models/model_spec.dart';
import '../../../../models/session.dart';
import '../../../../models/voice_entry.dart';
import '../../../../providers/app_providers.dart';
import '../../../../providers/library_providers.dart';
import '../../advanced_options_dialog.dart';
import '../../widgets/workbench_fields.dart';
import '../../workbench_contract.dart';
import '../../workbench_registry.dart';

/// BreezeTTS 2：TTS / 克隆 / 语音设计，走 /v1/audio/speech。
class BreezeTtsController extends WorkbenchModelController {
  BreezeTtsController(this.packageId, this.spec);

  static const _advancedNames = {
    'text_chunk_size',
    'text_chunk_mode',
    'max_tokens',
    'guidance_scale',
    'temperature',
    'depth_temperature',
    'top_k',
    'top_p',
    'seed',
  };

  final String packageId;
  final ModelSpec spec;

  final TextEditingController textCtrl = TextEditingController();
  final TextEditingController refTextCtrl = TextEditingController();
  final TextEditingController instrCtrl = TextEditingController();

  String voiceEntryId = '';
  String? voiceRef;
  String? voiceName;
  String? language;
  Map<String, String> advanced = {};
  bool randomSeedEnabled = false;

  void setRandomSeedEnabled(bool value) {
    if (randomSeedEnabled == value) return;
    randomSeedEnabled = value;
    notifyListeners();
  }

  void setVoice(VoiceEntry? voice) {
    voiceEntryId = voice?.id ?? '';
    voiceRef = voice?.audioPath;
    voiceName = voice?.name;
    final text = voice?.text?.trim() ?? '';
    refTextCtrl.text = text;
    notifyListeners();
  }

  void setLanguage(String? value) {
    language = value;
    notifyListeners();
  }

  static const _positiveFloatNames = {
    'temperature',
    'depth_temperature',
    'top_p',
  };

  List<SpecOption> advancedOptions() => [
        for (final o in spec.requestOptions)
          if (_advancedNames.contains(o.name)) _withUiBounds(o),
      ];

  SpecOption _withUiBounds(SpecOption o) {
    if (o.name != 'top_p') return o;
    return SpecOption(
      name: o.name,
      type: o.type,
      description: o.description,
      values: o.values,
      defaultValue: o.defaultValue,
      min: 0.01,
      max: 1,
      required: o.required,
    );
  }

  @override
  Map<String, String> advancedValues() => advanced;

  @override
  void setAdvancedValues(Map<String, String> values) {
    advanced = Map<String, String>.from(values);
    notifyListeners();
  }

  @override
  String? validate() {
    if (textCtrl.text.trim().isEmpty) return 'workbench.needText';
    final hasRef = voiceRef != null && voiceRef!.isNotEmpty;
    if (hasRef && refTextCtrl.text.trim().isEmpty) {
      return 'workbench.needReferenceText';
    }
    for (final name in _positiveFloatNames) {
      final raw = advanced[name]?.trim() ?? '';
      if (raw.isEmpty) continue;
      final value = double.tryParse(raw);
      if (value == null || value <= 0) return 'workbench.invalidNumber';
    }
    return null;
  }

  @override
  WorkbenchCall? buildCall() {
    if (validate() != null) return null;
    final modelId = workbenchModelId(packageId, 'tts', spec);
    final text = textCtrl.text.trim();
    final refText = refTextCtrl.text.trim();
    final instruct = instrCtrl.text.trim();
    final seed = randomSeedEnabled
        ? Random.secure().nextInt(0x80000000).toString()
        : advanced['seed'];
    final options = <String, dynamic>{
      if (instruct.isNotEmpty) 'instruct': instruct,
      if (voiceRef != null && voiceRef!.isNotEmpty && refText.isNotEmpty)
        'reference_text': refText,
      for (final e in advanced.entries)
        if (e.value.isNotEmpty) e.key: e.value,
      if (seed != null && seed.isNotEmpty) 'seed': seed,
    };
    return WorkbenchCall(
      endpoint: '/v1/audio/speech',
      modelId: modelId,
      request: {
        'model': modelId,
        'input': text,
        if (voiceRef != null && voiceRef!.isNotEmpty) 'voice_ref': voiceRef,
        if (language != null) 'language': language,
        if (options.isNotEmpty) 'options': options,
      },
      recordInputs: {
        'text': text,
        if (voiceEntryId.isNotEmpty) 'voice_entry': voiceEntryId,
        if (voiceRef != null && voiceRef!.isNotEmpty) 'voice_ref': voiceRef!,
        if (voiceName != null) 'voice_name': voiceName!,
        if (refText.isNotEmpty) 'reference_text': refText,
        if (instruct.isNotEmpty) 'instruction': instruct,
        if (language != null) 'language': language!,
        if (advanced.isNotEmpty || (seed != null && seed.isNotEmpty))
          'params': jsonEncode({
            ...advanced,
            if (seed != null && seed.isNotEmpty) 'seed': seed,
          }),
      },
      responseFormat: 'bytes',
    );
  }

  @override
  void restore(GenerationRecord record) {
    textCtrl.text = record.inputs['text'] ?? '';
    refTextCtrl.text = record.inputs['reference_text'] ?? '';
    instrCtrl.text =
        record.inputs['instruct'] ?? record.inputs['instruction'] ?? '';
    voiceEntryId = record.inputs['voice_entry'] ?? '';
    voiceRef = record.inputs['voice_ref'];
    voiceName = record.inputs['voice_name'];
    language = record.inputs['language'];
    advanced = {};

    final rawParams = record.inputs['params'];
    if (rawParams != null && rawParams.isNotEmpty) {
      try {
        final params = jsonDecode(rawParams);
        if (params is Map) {
          refTextCtrl.text =
              params['reference_text']?.toString() ?? refTextCtrl.text;
          instrCtrl.text = params['instruct']?.toString() ??
              params['instruction']?.toString() ??
              instrCtrl.text;
          for (final name in _advancedNames) {
            final value = params[name]?.toString() ?? '';
            if (value.isNotEmpty) advanced[name] = value;
          }
        }
      } catch (_) {}
    }

    randomSeedEnabled = false;
    notifyListeners();
  }

  @override
  void dispose() {
    textCtrl.dispose();
    refTextCtrl.dispose();
    instrCtrl.dispose();
    super.dispose();
  }
}

class BreezeTtsWorkbench extends ConsumerWidget {
  const BreezeTtsWorkbench({
    super.key,
    required this.controller,
    required this.spec,
    required this.dict,
    required this.onSubmit,
  });

  final BreezeTtsController controller;
  final ModelSpec spec;
  final Map<String, String> dict;
  final VoidCallback onSubmit;

  Future<void> _openAdvanced(BuildContext context, String locale) async {
    final options = controller.advancedOptions();
    if (options.isEmpty) return;
    final result = await showDialog<Map<String, String>?>(
      context: context,
      builder: (_) => AdvancedOptionsDialog(
        title: dict['workbench.advancedTitle'] ?? 'Advanced parameters',
        options: options,
        saved: controller.advancedValues(),
        dict: dict,
        describe: (o) => spec.optionDescription(o, locale),
        stepFor: (option) => option.name == 'top_p' ? 0.01 : null,
        valueLabelFor: (option, value) {
          if (option.name != 'text_chunk_mode') return value;
          return spec.uiText('textChunkMode.$value', locale, fallback: value);
        },
      ),
    );
    if (result == null) return;
    controller.setAdvancedValues(result);
    controller.saveAdvancedValues();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(localeProvider).name;
    final voices = ref
        .watch(voiceLibraryProvider)
        .voices
        .where((v) => v.type == 'file')
        .toList();
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (spec.languages.isNotEmpty) ...[
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
          if (controller.voiceEntryId.isNotEmpty) ...[
            const SizedBox(height: 12),
            TextField(
              controller: controller.refTextCtrl,
              maxLines: 2,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText:
                    '* ${dict['workbench.referenceText'] ?? 'Reference text'}',
                hintText: dict['workbench.referenceTextHint'],
              ),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: controller.instrCtrl,
            maxLines: 2,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: dict['workbench.instruction'] ?? 'Instruction / style',
              hintText: 'Speak clearly and naturally.',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller.textCtrl,
            maxLines: 6,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              hintText: dict['workbench.textHint'] ?? 'Type the text…',
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              if (controller.advancedOptions().isNotEmpty)
                OutlinedButton.icon(
                  onPressed: () => _openAdvanced(context, locale),
                  icon: const Icon(Icons.tune),
                  label: Text(dict['workbench.advanced'] ?? 'Advanced'),
                ),
              const Spacer(),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: controller.randomSeedEnabled,
                    onChanged: (v) =>
                        controller.setRandomSeedEnabled(v ?? false),
                  ),
                  Text(dict['workbench.randomSeed'] ?? 'Randomize'),
                ],
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: onSubmit,
                icon: const Icon(Icons.playlist_add),
                label: Text(dict['workbench.submit'] ?? 'Add task'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

Widget buildBreezeTtsWorkbench(
  BuildContext context,
  WorkbenchWidgetContext ctx,
  WorkbenchModelController controller,
) {
  return BreezeTtsWorkbench(
    controller: controller as BreezeTtsController,
    spec: ctx.spec,
    dict: ctx.dict,
    onSubmit: () => ctx.submit(controller),
  );
}
