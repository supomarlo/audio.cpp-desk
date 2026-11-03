import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../models/model_spec.dart';
import '../../../../models/session.dart';
import '../../../../models/voice_entry.dart';
import '../../../../providers/app_providers.dart';
import '../../../../providers/library_providers.dart';
import '../../../../providers/server_providers.dart';
import '../../advanced_options_dialog.dart';
import '../../widgets/workbench_fields.dart';
import '../../workbench_contract.dart';
import '../../workbench_registry.dart';
import 'omnivoice_instruction_groups.dart';
import 'omnivoice_language_names_zh.dart';
import 'omnivoice_languages.dart';

bool omniVoiceSupportsNortheasternDialect(String version) {
  final match = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(version.trim());
  if (match == null) return false;
  final major = int.parse(match.group(1)!);
  final minor = int.parse(match.group(2)!);
  final patch = int.parse(match.group(3)!);
  if (major != 0) return major > 0;
  if (minor != 9) return minor > 9;
  return patch > 3;
}

/// OmniVoice：TTS / 克隆 / 语音设计，走 /v1/audio/speech。
class OmniVoiceController extends WorkbenchModelController {
  OmniVoiceController(this.packageId, this.spec);

  static const _mainNames = {'language', 'reference_text', 'instruct'};

  static const _advancedOrder = [
    'seed',
    'duration_sec',
    'speed',
    'num_inference_steps',
    'guidance_scale',
    'shift',
    'class_temperature',
    'position_temperature',
    'layer_penalty_factor',
    'denoise',
    'preprocess_prompt',
    'postprocess_output',
    'text_chunk_size',
    'text_chunk_mode',
    'audio_chunk_duration_sec',
    'audio_chunk_threshold_sec',
  ];

  final String packageId;
  final ModelSpec spec;

  final TextEditingController textCtrl = TextEditingController();
  final TextEditingController refTextCtrl = TextEditingController();
  final TextEditingController instrCtrl = TextEditingController();
  final TextEditingController languageCtrl = TextEditingController();

  String voiceEntryId = '';
  String? voiceRef;
  String? voiceName;
  Map<String, String> advanced = {};
  final Map<String, String> _instrAttrs = {};
  String accentTab = 'accent';
  bool _accentTabInitialized = false;

  void ensureAccentTab(String locale) {
    if (_accentTabInitialized) return;
    _accentTabInitialized = true;
    accentTab = locale == 'zh' ? 'dialect' : 'accent';
  }

  void setVoice(VoiceEntry? voice) {
    voiceEntryId = voice?.id ?? '';
    voiceRef = voice?.audioPath;
    voiceName = voice?.name;
    refTextCtrl.text = voice?.text?.trim() ?? '';
    if (voice != null) {
      _instrAttrs.clear();
      instrCtrl.clear();
    }
    notifyListeners();
  }

  void setInstructAttr(String group, String value) {
    if (value.isEmpty) {
      _instrAttrs.remove(group);
    } else {
      if (group == 'accent') {
        _instrAttrs.remove('dialect');
        accentTab = 'accent';
        _accentTabInitialized = true;
      }
      if (group == 'dialect') {
        _instrAttrs.remove('accent');
        accentTab = 'dialect';
        _accentTabInitialized = true;
      }
      _instrAttrs[group] = value;
    }
    instrCtrl.text = [
      for (final g in kOmniVoiceInstructGroups)
        if ((_instrAttrs[g.id] ?? '').isNotEmpty) _instrAttrs[g.id]!,
    ].join(', ');
    notifyListeners();
  }

  void setAccentTab(String value) {
    accentTab = value;
    _accentTabInitialized = true;
    _instrAttrs.remove(value == 'accent' ? 'dialect' : 'accent');
    instrCtrl.text = [
      for (final g in kOmniVoiceInstructGroups)
        if ((_instrAttrs[g.id] ?? '').isNotEmpty) _instrAttrs[g.id]!,
    ].join(', ');
    notifyListeners();
  }

  void _restoreInstruct(String value) {
    _instrAttrs.clear();
    final parts = value
        .split(RegExp(r'[,，]'))
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.isNotEmpty)
        .toSet();
    for (final group in kOmniVoiceInstructGroups) {
      for (final item in group.values) {
        if (parts.contains(item.value.toLowerCase())) {
          _instrAttrs[group.id] = item.value;
          break;
        }
      }
    }
    if (_instrAttrs.containsKey('accent') &&
        _instrAttrs.containsKey('dialect')) {
      _instrAttrs.remove('accent');
    }
    if (_instrAttrs.containsKey('dialect')) {
      accentTab = 'dialect';
      _accentTabInitialized = true;
    } else if (_instrAttrs.containsKey('accent')) {
      accentTab = 'accent';
      _accentTabInitialized = true;
    }
    instrCtrl.text = [
      for (final g in kOmniVoiceInstructGroups)
        if ((_instrAttrs[g.id] ?? '').isNotEmpty) _instrAttrs[g.id]!,
    ].join(', ');
  }

  void setLanguage(String value) {
    languageCtrl.text = value;
    notifyListeners();
  }

  Set<String> get _allAdvancedNames => {
        for (final o in spec.requestOptions)
          if (!_mainNames.contains(o.name)) o.name,
      };

  List<SpecOption> advancedOptions() {
    final byName = {for (final o in spec.requestOptions) o.name: o};
    final ordered = [
      for (final name in _advancedOrder)
        if (byName.containsKey(name)) name,
      for (final o in spec.requestOptions)
        if (!_mainNames.contains(o.name) && !_advancedOrder.contains(o.name))
          o.name,
    ];
    final out = <SpecOption>[];
    for (final name in ordered) {
      final o = byName[name];
      if (o == null) continue;
      if (name == 'text_chunk_mode') {
        out.add(SpecOption(
          name: o.name,
          type: 'enum',
          description: o.description,
          values: const ['default', 'tag_aware', 'japanese', 'endline'],
          defaultValue: o.defaultValue,
          required: o.required,
        ));
      } else if (name == 'seed') {
        out.add(SpecOption(
          name: o.name,
          type: o.type,
          description: o.description,
          values: o.values,
          defaultValue: o.defaultValue,
          min: o.min,
          required: o.required,
        ));
      } else {
        out.add(o);
      }
    }
    return out;
  }

  @override
  Map<String, String> advancedValues() => advanced;

  @override
  void setAdvancedValues(Map<String, String> values) {
    final allowed = _allAdvancedNames;
    advanced = {
      for (final e in values.entries)
        if (allowed.contains(e.key)) e.key: e.value,
    };
    notifyListeners();
  }

  @override
  String? validate() {
    if (textCtrl.text.trim().isEmpty) return 'workbench.needText';
    if (voiceRef != null &&
        voiceRef!.isNotEmpty &&
        refTextCtrl.text.trim().isEmpty) {
      return 'workbench.needReferenceText';
    }
    return _advancedError();
  }

  String? _advancedError() {
    bool badInt(String name, {int min = 0, int? max}) {
      final raw = advanced[name];
      if (raw == null || raw.isEmpty) return false;
      final value = int.tryParse(raw);
      return value == null || value < min || (max != null && value > max);
    }

    bool badNumber(String name, {double? min, double? max}) {
      final raw = advanced[name];
      if (raw == null || raw.isEmpty) return false;
      final value = double.tryParse(raw);
      return value == null ||
          !value.isFinite ||
          (min != null && value < min) ||
          (max != null && value > max);
    }

    if (badInt('seed', max: 4294967295) ||
        badInt('num_inference_steps', min: 1) ||
        badInt('text_chunk_size', min: 1) ||
        badNumber('duration_sec', min: 0) ||
        badNumber('class_temperature', min: 0) ||
        badNumber('audio_chunk_duration_sec', min: 0) ||
        badNumber('audio_chunk_threshold_sec', min: 0) ||
        badNumber('speed') ||
        badNumber('guidance_scale') ||
        badNumber('shift') ||
        badNumber('layer_penalty_factor') ||
        badNumber('position_temperature')) {
      return 'workbench.invalidValue';
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
    final language = languageCtrl.text.trim();
    final hasVoice = voiceRef != null && voiceRef!.isNotEmpty;
    final chunked = (advanced['text_chunk_size'] ?? '').isNotEmpty;
    final hasDuration = (advanced['duration_sec'] ?? '').isNotEmpty;
    bool ignored(String name) {
      if (_mainNames.contains(name)) return true;
      if (!hasVoice && const {'denoise', 'preprocess_prompt'}.contains(name)) {
        return true;
      }
      if (chunked &&
          const {'audio_chunk_duration_sec', 'audio_chunk_threshold_sec'}
              .contains(name)) {
        return true;
      }
      if (!chunked && name == 'text_chunk_mode') return true;
      if (hasDuration && name == 'speed') return true;
      return false;
    }

    final options = <String, dynamic>{
      if (!hasVoice && instruct.isNotEmpty) 'instruct': instruct,
      if (hasVoice && refText.isNotEmpty) 'reference_text': refText,
      for (final e in advanced.entries)
        if (e.value.isNotEmpty && !ignored(e.key)) e.key: e.value,
    };
    return WorkbenchCall(
      endpoint: '/v1/audio/speech',
      modelId: modelId,
      request: {
        'model': modelId,
        'input': text,
        if (voiceRef != null && voiceRef!.isNotEmpty) 'voice_ref': voiceRef,
        if (language.isNotEmpty) 'language': language,
        if (options.isNotEmpty) 'options': options,
      },
      recordInputs: {
        'text': text,
        if (voiceEntryId.isNotEmpty) 'voice_entry': voiceEntryId,
        if (hasVoice) 'voice_ref': voiceRef!,
        if (voiceName != null) 'voice_name': voiceName!,
        if (hasVoice && refText.isNotEmpty) 'reference_text': refText,
        if (!hasVoice && instruct.isNotEmpty) 'instruction': instruct,
        if (language.isNotEmpty) 'language': language,
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
    languageCtrl.text = record.inputs['language'] ?? '';
    voiceEntryId = record.inputs['voice_entry'] ?? '';
    voiceRef = record.inputs['voice_ref'];
    voiceName = record.inputs['voice_name'];
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
          for (final name in _allAdvancedNames) {
            final value = params[name]?.toString() ?? '';
            if (value.isNotEmpty) advanced[name] = value;
          }
        }
      } catch (_) {}
    }
    if (voiceRef == null || voiceRef!.isEmpty) {
      _restoreInstruct(instrCtrl.text);
    } else {
      _instrAttrs.clear();
      instrCtrl.clear();
    }

    notifyListeners();
  }

  @override
  void dispose() {
    textCtrl.dispose();
    refTextCtrl.dispose();
    instrCtrl.dispose();
    languageCtrl.dispose();
    super.dispose();
  }
}

class OmniVoiceWorkbench extends ConsumerWidget {
  const OmniVoiceWorkbench({
    super.key,
    required this.controller,
    required this.spec,
    required this.dict,
    required this.onSubmit,
  });

  final OmniVoiceController controller;
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
        valueLabelFor: (option, value) {
          if (option.name != 'text_chunk_mode') return value;
          return spec.uiText('textChunkMode.$value', locale, fallback: value);
        },
        enabledFor: (name, values) {
          if (name == 'speed') {
            return (values['duration_sec'] ?? '').isEmpty;
          }
          if (name == 'text_chunk_mode') {
            return (values['text_chunk_size'] ?? '').isNotEmpty;
          }
          if (const {'audio_chunk_duration_sec', 'audio_chunk_threshold_sec'}
              .contains(name)) {
            return (values['text_chunk_size'] ?? '').isEmpty;
          }
          return true;
        },
        disabledHintFor: (name, values) {
          if (name == 'speed' && (values['duration_sec'] ?? '').isNotEmpty) {
            return spec.uiText(
              'speed.ignoredByDuration',
              locale,
              fallback: '',
            );
          }
          if (name == 'text_chunk_mode' &&
              (values['text_chunk_size'] ?? '').isEmpty) {
            return spec.uiText(
              'textChunkMode.requiresChunkSize',
              locale,
              fallback: '',
            );
          }
          if (const {'audio_chunk_duration_sec', 'audio_chunk_threshold_sec'}
                  .contains(name) &&
              (values['text_chunk_size'] ?? '').isNotEmpty) {
            return spec.uiText(
              'audioChunk.ignoredByTextChunk',
              locale,
              fallback: '',
            );
          }
          return '';
        },
      ),
    );
    if (result == null) return;
    controller.setAdvancedValues(result);
    controller.saveAdvancedValues();
  }

  String _languageName(({String id, String name}) entry, String locale) =>
      locale == 'zh'
          ? (kOmniVoiceLanguageNamesZh[entry.id] ?? entry.name)
          : entry.name;

  String _languageLabel(String locale) {
    final id = controller.languageCtrl.text.trim();
    if (id.isEmpty) {
      return spec.uiText('language.auto', locale, fallback: 'Auto');
    }
    for (final entry in kOmniVoiceLanguages) {
      if (entry.id == id || entry.name == id) {
        return _languageName(entry, locale);
      }
    }
    return id;
  }

  Future<void> _pickLanguage(BuildContext context, String locale) async {
    final selected = await showDialog<String>(
      context: context,
      builder: (_) => _OmniVoiceLanguageDialog(
        initial: controller.languageCtrl.text.trim(),
        locale: locale,
        title: dict['workbench.language'] ?? 'Language',
        autoLabel: spec.uiText('language.auto', locale, fallback: 'Auto'),
        cancelLabel: dict['common.cancel'] ?? 'Cancel',
      ),
    );
    if (selected == null) return;
    controller.setLanguage(selected);
  }

  Widget _attributeChip(
    String locale,
    OmniVoiceInstructGroup group,
    OmniVoiceInstructValue item, {
    required bool disabled,
    String? disabledHint,
  }) {
    final chip = ChoiceChip(
      label: Text(
        locale == 'zh' ? item.zh : (item.en.isEmpty ? item.zh : item.en),
      ),
      selected: controller._instrAttrs[group.id] == item.value,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onSelected: disabled
          ? null
          : (_) {
              final selected = controller._instrAttrs[group.id] == item.value;
              controller.setInstructAttr(group.id, selected ? '' : item.value);
            },
    );
    if (!disabled || disabledHint == null) return chip;
    return Tooltip(message: disabledHint, child: chip);
  }

  Widget _attributeGroup(
    BuildContext context,
    String locale,
    OmniVoiceInstructGroup group, {
    bool showLabel = true,
    bool fill = false,
    Set<String> disabledValues = const {},
    String? disabledHint,
  }) {
    final small = Theme.of(context).textTheme.bodySmall;
    final chips = Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final item in group.values)
          _attributeChip(
            locale,
            group,
            item,
            disabled: disabledValues.contains(item.value),
            disabledHint: disabledHint,
          ),
      ],
    );
    if (!showLabel) {
      return fill ? Row(children: [Expanded(child: chips)]) : chips;
    }
    final label = Padding(
      padding: const EdgeInsets.only(top: 6),
      child: SizedBox(
        width: 56,
        child: Text(
          locale == 'zh' ? group.zh : group.en,
          style: small,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
    if (fill) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          label,
          const SizedBox(width: 8),
          Expanded(child: chips),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        label,
        const SizedBox(width: 8),
        chips,
      ],
    );
  }

  Widget _instructionAttributes(
    BuildContext context,
    String locale, {
    required bool supportsNortheastern,
  }) {
    final byId = {
      for (final group in kOmniVoiceInstructGroups) group.id: group,
    };
    final gender = byId['gender']!;
    final age = byId['age']!;
    final pitch = byId['pitch']!;
    final style = byId['style']!;
    final accent = byId['accent']!;
    final dialect = byId['dialect']!;
    final activeAccent = controller.accentTab == 'dialect' ? dialect : accent;
    final unavailableHint =
        spec.uiText('northeasternRequiresNewerServer', locale);
    return InputDecorator(
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        labelText: dict['workbench.instruction'] ?? 'Instruction / style',
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _attributeGroup(context, locale, gender, fill: true),
          const SizedBox(height: 6),
          _attributeGroup(context, locale, age, fill: true),
          const SizedBox(height: 6),
          _attributeGroup(context, locale, pitch, fill: true),
          const SizedBox(height: 6),
          _attributeGroup(context, locale, style, fill: true),
          const SizedBox(height: 10),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(
                value: 'accent',
                label: Text(locale == 'zh' ? accent.zh : accent.en),
              ),
              ButtonSegment(
                value: 'dialect',
                label: Text(locale == 'zh' ? dialect.zh : dialect.en),
              ),
            ],
            selected: {controller.accentTab},
            showSelectedIcon: false,
            onSelectionChanged: (values) =>
                controller.setAccentTab(values.first),
          ),
          const SizedBox(height: 6),
          _attributeGroup(
            context,
            locale,
            activeAccent,
            showLabel: false,
            fill: true,
            disabledValues:
                activeAccent.id == 'dialect' && !supportsNortheastern
                    ? const {'东北话'}
                    : const {},
            disabledHint: unavailableHint.isEmpty ? null : unavailableHint,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(localeProvider).name;
    final serverVersion =
        ref.watch(serverControllerProvider.select((s) => s.version));
    final supportsNortheastern =
        omniVoiceSupportsNortheasternDialect(serverVersion);
    controller.ensureAccentTab(locale);
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
          InputDecorator(
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: dict['workbench.language'] ?? 'Language',
            ),
            child: InkWell(
              onTap: () => _pickLanguage(context, locale),
              child: Row(
                children: [
                  Expanded(child: Text(_languageLabel(locale))),
                  const Icon(Icons.search, size: 20),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
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
                    '${dict['workbench.referenceText'] ?? 'Reference text'} *',
                hintText: dict['workbench.referenceTextHint'],
              ),
            ),
          ],
          if (controller.voiceRef == null || controller.voiceRef!.isEmpty) ...[
            const SizedBox(height: 12),
            _instructionAttributes(
              context,
              locale,
              supportsNortheastern: supportsNortheastern,
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
      ),
    );
  }
}

class _OmniVoiceLanguageDialog extends StatefulWidget {
  const _OmniVoiceLanguageDialog({
    required this.initial,
    required this.locale,
    required this.title,
    required this.autoLabel,
    required this.cancelLabel,
  });

  final String initial;
  final String locale;
  final String title;
  final String autoLabel;
  final String cancelLabel;

  @override
  State<_OmniVoiceLanguageDialog> createState() =>
      _OmniVoiceLanguageDialogState();
}

class _OmniVoiceLanguageDialogState extends State<_OmniVoiceLanguageDialog> {
  final TextEditingController _queryCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  String _languageName(({String id, String name}) entry) =>
      widget.locale == 'zh'
          ? (kOmniVoiceLanguageNamesZh[entry.id] ?? entry.name)
          : entry.name;

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final entries = [
      for (final entry in kOmniVoiceLanguages)
        if (q.isEmpty ||
            entry.id.toLowerCase().contains(q) ||
            entry.name.toLowerCase().contains(q) ||
            _languageName(entry).toLowerCase().contains(q))
          entry,
    ];
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 480,
          maxHeight: size.height * 0.72,
          minWidth: 360,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _queryCtrl,
                autofocus: true,
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  isDense: true,
                  hintText: widget.title,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () {
                            _queryCtrl.clear();
                            setState(() => _query = '');
                          },
                        ),
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: entries.length + 1,
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return ListTile(
                        dense: true,
                        title: Text(widget.autoLabel),
                        trailing: widget.initial.isEmpty
                            ? const Icon(Icons.check, size: 18)
                            : null,
                        onTap: () => Navigator.of(context).pop(''),
                      );
                    }
                    final entry = entries[index - 1];
                    final localized = _languageName(entry);
                    final subtitle = localized == entry.name
                        ? entry.id
                        : '${entry.name} · ${entry.id}';
                    return ListTile(
                      dense: true,
                      title: Text(localized),
                      subtitle: Text(subtitle),
                      trailing: widget.initial == entry.id ||
                              widget.initial == entry.name
                          ? const Icon(Icons.check, size: 18)
                          : null,
                      onTap: () => Navigator.of(context).pop(entry.id),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(widget.cancelLabel),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget buildOmniVoiceWorkbench(
  BuildContext context,
  WorkbenchWidgetContext ctx,
  WorkbenchModelController controller,
) {
  return OmniVoiceWorkbench(
    controller: controller as OmniVoiceController,
    spec: ctx.spec,
    dict: ctx.dict,
    onSubmit: () => ctx.submit(controller),
  );
}
