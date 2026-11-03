import 'dart:convert';

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

/// Qwen3-TTS：Base / CustomVoice / VoiceDesign 三变体，走 /v1/audio/speech。
class Qwen3TtsController extends WorkbenchModelController {
  Qwen3TtsController(this.packageId, this.spec);

  static const _commonAdvanced = {
    'do_sample',
    'temperature',
    'top_k',
    'top_p',
    'repetition_penalty',
    'subtalker_do_sample',
    'subtalker_temperature',
    'subtalker_top_k',
    'subtalker_top_p',
    'seed',
    'max_tokens',
    'text_chunk_size',
  };

  static const _advancedOrder = [
    'max_tokens',
    'text_chunk_size',
    'seed',
    'do_sample',
    'temperature',
    'top_k',
    'top_p',
    'repetition_penalty',
    'subtalker_do_sample',
    'subtalker_temperature',
    'subtalker_top_k',
    'subtalker_top_p',
  ];

  final String packageId;
  final ModelSpec spec;

  final TextEditingController textCtrl = TextEditingController();
  final TextEditingController refTextCtrl = TextEditingController();
  final TextEditingController instrCtrl = TextEditingController();

  String voiceEntryId = '';
  String? voiceRef;
  String? voiceName;
  String voiceId = '';
  String? language;
  Map<String, String> advanced = {};

  String get variant {
    final id = packageId.toLowerCase();
    if (id.contains('customvoice')) return 'customvoice';
    if (id.contains('voicedesign')) return 'voicedesign';
    return 'base';
  }

  void setVoice(VoiceEntry? voice) {
    voiceEntryId = voice?.id ?? '';
    voiceRef = voice?.audioPath;
    voiceName = voice?.name;
    refTextCtrl.text = voice?.text?.trim() ?? '';
    notifyListeners();
  }

  List<String> _voiceValues() {
    for (final o in spec.requestOptions) {
      if (o.name == 'voice_id') return o.values;
    }
    return const [];
  }

  String _canonicalVoiceId(String raw) {
    final lower = raw.toLowerCase();
    for (final value in _voiceValues()) {
      if (value.toLowerCase() == lower) return value;
    }
    return raw;
  }

  void setBuiltinVoice(String value) {
    voiceId = _canonicalVoiceId(value);
    notifyListeners();
  }

  void setLanguage(String? value) {
    language = value;
    notifyListeners();
  }

  List<SpecOption> advancedOptions() {
    final byName = {for (final o in spec.requestOptions) o.name: o};
    return [
      for (final name in _advancedOrder)
        if (byName[name] != null) _withUiBounds(byName[name]!),
    ];
  }

  SpecOption _withUiBounds(SpecOption o) {
    if (o.name != 'seed') return o;
    return SpecOption(
      name: o.name,
      type: o.type,
      description: o.description,
      values: o.values,
      defaultValue: o.defaultValue,
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

  int? _intValue(String name) {
    final raw = advanced[name]?.trim() ?? '';
    if (raw.isEmpty) return null;
    return int.tryParse(raw);
  }

  double? _floatValue(String name) {
    final raw = advanced[name]?.trim() ?? '';
    if (raw.isEmpty) return null;
    return double.tryParse(raw);
  }

  String? _validateAdvanced() {
    final seed = _intValue('seed');
    if ((advanced['seed']?.trim() ?? '').isNotEmpty &&
        (seed == null || seed < 0 || seed > 4294967295)) {
      return 'workbench.invalidNumber';
    }

    final maxTokens = _intValue('max_tokens');
    if ((advanced['max_tokens']?.trim() ?? '').isNotEmpty &&
        (maxTokens == null || maxTokens <= 0)) {
      return 'workbench.invalidNumber';
    }

    final chunkSize = _intValue('text_chunk_size');
    if ((advanced['text_chunk_size']?.trim() ?? '').isNotEmpty &&
        (chunkSize == null || chunkSize <= 0)) {
      return 'workbench.invalidNumber';
    }

    final repetition = _floatValue('repetition_penalty');
    if ((advanced['repetition_penalty']?.trim() ?? '').isNotEmpty &&
        (repetition == null || repetition <= 0)) {
      return 'workbench.invalidNumber';
    }

    if (advanced['do_sample'] != 'false') {
      final topK = _intValue('top_k');
      if ((advanced['top_k']?.trim() ?? '').isNotEmpty &&
          (topK == null || topK < 0)) {
        return 'workbench.invalidNumber';
      }

      final topP = _floatValue('top_p');
      if ((advanced['top_p']?.trim() ?? '').isNotEmpty &&
          (topP == null || topP < 0 || topP > 1)) {
        return 'workbench.invalidNumber';
      }

      final temperature = _floatValue('temperature');
      if ((advanced['temperature']?.trim() ?? '').isNotEmpty &&
          (temperature == null || temperature <= 0)) {
        return 'workbench.invalidNumber';
      }
    }

    if (advanced['subtalker_do_sample'] != 'false') {
      final subTopK = _intValue('subtalker_top_k');
      if ((advanced['subtalker_top_k']?.trim() ?? '').isNotEmpty &&
          (subTopK == null || subTopK < 0)) {
        return 'workbench.invalidNumber';
      }

      final subTopP = _floatValue('subtalker_top_p');
      if ((advanced['subtalker_top_p']?.trim() ?? '').isNotEmpty &&
          (subTopP == null || subTopP < 0 || subTopP > 1)) {
        return 'workbench.invalidNumber';
      }

      final subTemperature = _floatValue('subtalker_temperature');
      if ((advanced['subtalker_temperature']?.trim() ?? '').isNotEmpty &&
          (subTemperature == null || subTemperature <= 0)) {
        return 'workbench.invalidNumber';
      }
    }
    return null;
  }

  @override
  String? validate() {
    if (textCtrl.text.trim().isEmpty) return 'workbench.needText';
    final advancedError = _validateAdvanced();
    if (advancedError != null) return advancedError;
    switch (variant) {
      case 'base':
        if (voiceRef == null || voiceRef!.isEmpty) {
          return 'workbench.needReference';
        }
        break;
      case 'customvoice':
        if (voiceId.isEmpty) return 'workbench.needBuiltinVoice';
        break;
      default:
        break;
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
    final options = <String, dynamic>{
      for (final e in advanced.entries)
        if (e.value.isNotEmpty) e.key: e.value,
    };
    if (advanced['do_sample'] == 'false') {
      options.remove('temperature');
      options.remove('top_k');
      options.remove('top_p');
    }
    if (advanced['subtalker_do_sample'] == 'false') {
      options.remove('subtalker_temperature');
      options.remove('subtalker_top_k');
      options.remove('subtalker_top_p');
    }
    if (variant == 'base') {
      options['x_vector_only_mode'] = refText.isEmpty.toString();
      if (refText.isNotEmpty) options['reference_text'] = refText;
    }
    if (variant == 'customvoice') {
      options['voice_id'] = voiceId;
      if (instruct.isNotEmpty) options['instruct'] = instruct;
    }
    if (variant == 'voicedesign' && instruct.isNotEmpty) {
      options['instruct'] = instruct;
    }
    return WorkbenchCall(
      endpoint: '/v1/audio/speech',
      modelId: modelId,
      request: {
        'model': modelId,
        'input': text,
        if (variant == 'base' && voiceRef != null && voiceRef!.isNotEmpty)
          'voice_ref': voiceRef,
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
        if (voiceId.isNotEmpty) 'voice_id': voiceId,
        if (language != null) 'language': language!,
        if (advanced.isNotEmpty) 'params': jsonEncode(advanced),
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
    voiceId = _canonicalVoiceId(record.inputs['voice_id'] ?? '');
    language = record.inputs['language'];
    advanced = {};

    final rawParams = record.inputs['params'];
    if (rawParams != null && rawParams.isNotEmpty) {
      try {
        final params = jsonDecode(rawParams);
        if (params is Map) {
          refTextCtrl.text =
              params['reference_text']?.toString() ?? refTextCtrl.text;
          instrCtrl.text = params['instruct']?.toString() ?? instrCtrl.text;
          voiceId = _canonicalVoiceId(
            params['voice_id']?.toString() ?? voiceId,
          );
          for (final name in _commonAdvanced) {
            final value = params[name]?.toString() ?? '';
            if (value.isNotEmpty) advanced[name] = value;
          }
        }
      } catch (_) {}
    }

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

class Qwen3TtsWorkbench extends ConsumerWidget {
  const Qwen3TtsWorkbench({
    super.key,
    required this.controller,
    required this.spec,
    required this.dict,
    required this.onSubmit,
  });

  final Qwen3TtsController controller;
  final ModelSpec spec;
  final Map<String, String> dict;
  final VoidCallback onSubmit;

  List<String> _builtinVoices() {
    for (final o in spec.requestOptions) {
      if (o.name == 'voice_id') return o.values;
    }
    return const [];
  }

  List<DropdownMenuItem<String>> _voiceItems(String locale) {
    final voices = _builtinVoices();
    return [
      for (final value in voices)
        DropdownMenuItem(
          value: value,
          child: Text(
            _voiceLabel(value, locale),
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ];
  }

  String _voiceLabel(String value, String locale) {
    final meta = spec.optionValueMetaFor('voice_id', value);
    if (meta == null) return value;
    final label = meta.label(locale);
    final language = meta.nativeLanguage(locale);
    final description = meta.description(locale);
    return [
      label.isEmpty ? value : label,
      if (language.isNotEmpty) language,
      if (description.isNotEmpty) description,
    ].join(' · ');
  }

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
        stepFor: (option) =>
            option.name == 'top_p' || option.name == 'subtalker_top_p'
                ? 0.01
                : null,
        enabledFor: (name, values) {
          final mainSampling = values['do_sample'] != 'false';
          final subSampling = values['subtalker_do_sample'] != 'false';
          if (const {'temperature', 'top_k', 'top_p'}.contains(name)) {
            return mainSampling;
          }
          if (const {
            'subtalker_temperature',
            'subtalker_top_k',
            'subtalker_top_p',
          }.contains(name)) {
            return subSampling;
          }
          return true;
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
    final builtin = _builtinVoices();
    final variant = controller.variant;

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final showReferenceText =
            variant == 'base' && controller.voiceEntryId.isNotEmpty;
        return Column(
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
            if (variant == 'base') ...[
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
              if (showReferenceText) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: controller.refTextCtrl,
                  maxLines: 2,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText:
                        dict['workbench.referenceText'] ?? 'Reference text',
                    hintText: spec.uiText(
                      'referenceText.hint',
                      locale,
                      fallback: 'referenceText.hint',
                    ),
                  ),
                ),
              ],
            ],
            if (variant == 'customvoice') ...[
              WorkbenchDropdown(
                label: dict['workbench.voiceId'] ?? 'Built-in voice',
                value: builtin.contains(controller.voiceId)
                    ? controller.voiceId
                    : '',
                items: [
                  DropdownMenuItem(
                    value: '',
                    child: Text(dict['workbench.defaultVoice'] ?? 'Default'),
                  ),
                  ..._voiceItems(locale),
                ],
                onChanged: (v) => controller.setBuiltinVoice(v ?? ''),
              ),
            ],
            if (variant != 'base') ...[
              const SizedBox(height: 12),
              TextField(
                controller: controller.instrCtrl,
                maxLines: 2,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText:
                      dict['workbench.instruction'] ?? 'Instruction / style',
                ),
              ),
            ],
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
                FilledButton.icon(
                  onPressed: onSubmit,
                  icon: const Icon(Icons.playlist_add),
                  label: Text(dict['workbench.submit'] ?? 'Add task'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

Widget buildQwen3TtsWorkbench(
  BuildContext context,
  WorkbenchWidgetContext ctx,
  WorkbenchModelController controller,
) {
  return Qwen3TtsWorkbench(
    controller: controller as Qwen3TtsController,
    spec: ctx.spec,
    dict: ctx.dict,
    onSubmit: () => ctx.submit(controller),
  );
}
