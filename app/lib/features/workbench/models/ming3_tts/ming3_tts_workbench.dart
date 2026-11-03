import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
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

class Ming3TtsController extends WorkbenchModelController {
  Ming3TtsController(this.packageId, this.spec);

  static const templates = <String>[
    'basic',
    'tts',
    'voice_design',
    'dialect',
    'ip',
    'emotion',
  ];

  static const _mainNames = <String>{
    'template_name',
    'language',
    'instruct',
    'voice_id',
    'emotion',
    'dialect',
    'reference_text',
    'speed',
    'pitch',
    'volume',
  };

  static const _unsupportedNames = <String>{
    'speaker_embedding_file',
    'export_speaker_embedding_file',
    'stream_frames_per_event',
    'stream_chunk_policy',
  };

  static const _advancedOrder = <String>[
    'raw_text',
    'text_chunk_size',
    'text_chunk_mode',
    'trim_silence',
    'max_tokens',
    'seed',
    'guidance_scale',
    'sigma',
    'temperature',
    'instruction_schema',
    'use_speaker_embedding',
    'zero_speaker_embedding',
  ];

  static const _structuredTemplates = <String>{
    'basic',
    'emotion',
    'dialect',
    'ip',
    'voice_design',
  };

  final String packageId;
  final ModelSpec spec;

  final TextEditingController textCtrl = TextEditingController();
  final TextEditingController refTextCtrl = TextEditingController();
  final TextEditingController instrCtrl = TextEditingController();

  String voiceEntryId = '';
  String? voiceRef;
  String? voiceName;
  String builtinVoice = '';
  String emotion = '';
  String dialect = '';
  String? language;
  String templateMode = 'basic';
  Map<String, String> advanced = {};

  bool get hasReference => voiceRef != null && voiceRef!.isNotEmpty;

  bool get _hasBasic =>
      _adv('speed').isNotEmpty ||
      _adv('pitch').isNotEmpty ||
      _adv('volume').isNotEmpty;

  bool get hasBasicControls => _hasBasic;

  bool get _zeroSpeaker => _adv('zero_speaker_embedding') == 'true';

  bool get referenceAudioIgnored => _zeroSpeaker;

  bool get zeroSpeakerEnabled => _zeroSpeaker;

  String get effectiveTemplate {
    if (templateMode == 'multilingual' ||
        templateMode == 'freeform' ||
        templateMode == 'tts' ||
        templateMode.isEmpty) {
      if (instrCtrl.text.trim().isNotEmpty) return 'freeform';
      if (language != null && language!.isNotEmpty) return 'multilingual';
      return 'tts';
    }
    return templates.contains(templateMode) ? templateMode : 'tts';
  }

  String _inferTemplateMode() {
    if (builtinVoice.isNotEmpty) return 'ip';
    if (dialect.isNotEmpty) return 'dialect';
    if (emotion.isNotEmpty) return 'emotion';
    if (_hasBasic) return 'basic';
    if (instrCtrl.text.trim().isNotEmpty && !hasReference) {
      return 'voice_design';
    }
    return 'tts';
  }

  String _adv(String name) => advanced[name]?.trim() ?? '';

  void setTemplate(String value) {
    final next = value == 'multilingual' || value == 'freeform' ? 'tts' : value;
    templateMode = templates.contains(next) ? next : 'basic';
    notifyListeners();
  }

  void _clearBasic() {
    advanced.remove('speed');
    advanced.remove('pitch');
    advanced.remove('volume');
  }

  void setBuiltinVoice(String value) {
    builtinVoice = value;
    if (value.isNotEmpty) {
      voiceEntryId = '';
      voiceRef = null;
      voiceName = null;
      refTextCtrl.clear();
      emotion = '';
      dialect = '';
      _clearBasic();
    }
    notifyListeners();
  }

  void setVoice(VoiceEntry? voice) {
    voiceEntryId = voice?.id ?? '';
    voiceRef = voice?.audioPath;
    voiceName = voice?.name;
    refTextCtrl.text = voice?.text?.trim() ?? '';
    if (voice != null) builtinVoice = '';
    notifyListeners();
  }

  void setEmotion(String value) {
    emotion = value;
    if (value.isNotEmpty) {
      dialect = '';
      builtinVoice = '';
      _clearBasic();
    }
    notifyListeners();
  }

  void setDialect(String value) {
    dialect = value;
    if (value.isNotEmpty) {
      emotion = '';
      builtinVoice = '';
      _clearBasic();
    }
    notifyListeners();
  }

  void setLanguage(String? value) {
    language = value;
    notifyListeners();
  }

  List<SpecOption> advancedOptions() {
    final byName = {
      for (final option in spec.requestOptions) option.name: option,
    };
    final out = <SpecOption>[
      for (final name in _advancedOrder)
        if (byName[name] != null) byName[name]!,
    ];
    for (final option in spec.requestOptions) {
      if (_mainNames.contains(option.name) ||
          _unsupportedNames.contains(option.name) ||
          out.any((e) => e.name == option.name)) {
        continue;
      }
      out.add(option);
    }
    return out;
  }

  @override
  Map<String, String> advancedValues() => advanced;

  @override
  void setAdvancedValues(Map<String, String> values) {
    final basic = <String, String>{
      for (final name in ['speed', 'pitch', 'volume'])
        if (_adv(name).isNotEmpty) name: _adv(name),
    };
    advanced = Map<String, String>.from(values);
    advanced.removeWhere((key, _) => _unsupportedNames.contains(key));
    advanced.addAll(basic);
    notifyListeners();
  }

  void setAdvancedValue(String name, String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      advanced.remove(name);
    } else {
      advanced[name] = trimmed;
    }
    notifyListeners();
  }

  int? _intValue(String name) => int.tryParse(_adv(name));

  double? _floatValue(String name) => double.tryParse(_adv(name));

  String? _validateAdvanced() {
    if (_adv('max_tokens').isNotEmpty &&
        (_intValue('max_tokens') == null || _intValue('max_tokens')! <= 0)) {
      return 'workbench.invalidNumber';
    }
    if (_adv('text_chunk_size').isNotEmpty &&
        (_intValue('text_chunk_size') == null ||
            _intValue('text_chunk_size')! <= 0)) {
      return 'workbench.invalidNumber';
    }
    if (_adv('seed').isNotEmpty &&
        (_intValue('seed') == null || _intValue('seed')! < 0)) {
      return 'workbench.invalidNumber';
    }
    for (final name in ['guidance_scale', 'sigma', 'temperature']) {
      if (_adv(name).isEmpty) continue;
      final value = _floatValue(name);
      if (value == null || !value.isFinite) {
        return 'workbench.invalidNumber';
      }
      if ((name == 'sigma' || name == 'temperature') && value < 0) {
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

    final template = effectiveTemplate;
    switch (template) {
      case 'basic':
        if (!_hasBasic) return 'workbench.incomplete';
      case 'emotion':
        if (emotion.isEmpty) return 'workbench.incomplete';
      case 'dialect':
        if (dialect.isEmpty) return 'workbench.incomplete';
      case 'ip':
        if (builtinVoice.isEmpty) return 'workbench.needBuiltinVoice';
      case 'voice_design':
        if (instrCtrl.text.trim().isEmpty) return 'workbench.incomplete';
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
    final template = effectiveTemplate;
    final rawText = _adv('raw_text') == 'true';
    final referenceActive = hasReference && !_zeroSpeaker;

    final options = <String, dynamic>{'template_name': template};
    switch (template) {
      case 'ip':
        options['voice_id'] = builtinVoice;
      case 'dialect':
        options['dialect'] = dialect;
      case 'emotion':
        options['emotion'] = emotion;
      case 'basic':
        for (final name in ['speed', 'pitch', 'volume']) {
          final value = _adv(name);
          if (value.isNotEmpty) options[name] = value;
        }
      case 'voice_design':
      case 'freeform':
        options['instruct'] = instruct;
      case 'tts':
      case 'multilingual':
        if (instruct.isNotEmpty) options['instruct'] = instruct;
    }

    if (referenceActive && refText.isNotEmpty) {
      options['reference_text'] = refText;
    }

    for (final name in [
      'max_tokens',
      'trim_silence',
      'seed',
      'guidance_scale',
      'sigma',
      'temperature',
      'use_speaker_embedding',
    ]) {
      final value = _adv(name);
      if (value.isNotEmpty) options[name] = value;
    }
    if (!rawText) {
      for (final name in ['text_chunk_size', 'text_chunk_mode']) {
        final value = _adv(name);
        if (value.isNotEmpty) options[name] = value;
      }
    }
    if (rawText) options['raw_text'] = 'true';
    if (_structuredTemplates.contains(template)) {
      final schema = _adv('instruction_schema');
      if (schema.isNotEmpty) options['instruction_schema'] = schema;
    }
    if (_zeroSpeaker) {
      options['zero_speaker_embedding'] = 'true';
    }

    return WorkbenchCall(
      endpoint: '/v1/audio/speech',
      modelId: modelId,
      request: {
        'model': modelId,
        'input': text,
        if (referenceActive) 'voice_ref': voiceRef,
        if (language != null) 'language': language,
        'options': options,
      },
      recordInputs: {
        'text': text,
        if (voiceEntryId.isNotEmpty) 'voice_entry': voiceEntryId,
        if (hasReference) 'voice_ref': voiceRef!,
        if (voiceName != null) 'voice_name': voiceName!,
        if (refText.isNotEmpty) 'reference_text': refText,
        if (instruct.isNotEmpty) 'instruction': instruct,
        if (language != null) 'language': language!,
        'params': jsonEncode({
          'template_mode': templateMode,
          'template_name': template,
          if (builtinVoice.isNotEmpty) 'voice_id': builtinVoice,
          if (emotion.isNotEmpty) 'emotion': emotion,
          if (dialect.isNotEmpty) 'dialect': dialect,
          if (instruct.isNotEmpty) 'instruct': instruct,
          if (refText.isNotEmpty) 'reference_text': refText,
          for (final entry in advanced.entries)
            if (entry.value.isNotEmpty) entry.key: entry.value,
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
    builtinVoice = record.inputs['voice_id'] ?? '';
    emotion = record.inputs['emotion'] ?? '';
    dialect = record.inputs['dialect'] ?? '';
    language = record.inputs['language'];
    templateMode = 'basic';
    advanced = {};
    var hasTemplateField = false;

    final rawParams = record.inputs['params'];
    if (rawParams != null && rawParams.isNotEmpty) {
      try {
        final params = jsonDecode(rawParams);
        if (params is Map) {
          final savedTemplate = params['template_mode']?.toString() ?? '';
          final savedName = params['template_name']?.toString() ?? '';
          if (params.containsKey('template_mode') ||
              params.containsKey('template_name')) {
            hasTemplateField = true;
            final raw = savedTemplate.isNotEmpty ? savedTemplate : savedName;
            templateMode = templates.contains(raw) ? raw : 'basic';
          }
          refTextCtrl.text =
              params['reference_text']?.toString() ?? refTextCtrl.text;
          instrCtrl.text = params['instruct']?.toString() ?? instrCtrl.text;
          builtinVoice = params['voice_id']?.toString() ?? builtinVoice;
          emotion = params['emotion']?.toString() ?? emotion;
          dialect = params['dialect']?.toString() ?? dialect;
          for (final option in advancedOptions()) {
            final value = params[option.name]?.toString() ?? '';
            if (value.isNotEmpty) advanced[option.name] = value;
          }
          for (final name in ['speed', 'pitch', 'volume']) {
            final value = params[name]?.toString() ?? '';
            if (value.isNotEmpty) advanced[name] = value;
          }
        }
      } catch (_) {}
    }
    if (!hasTemplateField) {
      templateMode = _inferTemplateMode();
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

class _MingTemplateTabs extends StatefulWidget {
  const _MingTemplateTabs({
    required this.controller,
    required this.spec,
    required this.locale,
  });

  final Ming3TtsController controller;
  final ModelSpec spec;
  final String locale;

  @override
  State<_MingTemplateTabs> createState() => _MingTemplateTabsState();
}

class _MingTemplateTabsState extends State<_MingTemplateTabs>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  int get _selectedIndex {
    final index = Ming3TtsController.templates.indexOf(
      widget.controller.templateMode,
    );
    return index < 0 ? 0 : index;
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: Ming3TtsController.templates.length,
      vsync: this,
      initialIndex: _selectedIndex,
    );
    _tabController.addListener(_onTabChanged);
    widget.controller.addListener(_syncTab);
  }

  @override
  void didUpdateWidget(covariant _MingTemplateTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncTab);
      widget.controller.addListener(_syncTab);
      _syncTab();
    }
  }

  void _syncTab() {
    if (!mounted) return;
    final index = _selectedIndex;
    if (_tabController.index != index) {
      _tabController.index = index;
    }
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    final value = Ming3TtsController.templates[_tabController.index];
    if (widget.controller.templateMode != value) {
      widget.controller.setTemplate(value);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncTab);
    _tabController
      ..removeListener(_onTabChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TabBar(
        controller: _tabController,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        dividerColor: Colors.transparent,
        labelPadding: const EdgeInsets.symmetric(horizontal: 12),
        onTap: (index) {
          final value = Ming3TtsController.templates[index];
          if (widget.controller.templateMode != value) {
            widget.controller.setTemplate(value);
          }
        },
        tabs: [
          for (final value in Ming3TtsController.templates)
            Tab(
              text: widget.spec.uiText(
                'template.$value',
                widget.locale,
                fallback: value,
              ),
            ),
        ],
      ),
    );
  }
}

class Ming3TtsWorkbench extends ConsumerWidget {
  const Ming3TtsWorkbench({
    super.key,
    required this.controller,
    required this.spec,
    required this.dict,
    required this.onSubmit,
  });

  final Ming3TtsController controller;
  final ModelSpec spec;
  final Map<String, String> dict;
  final VoidCallback onSubmit;

  static const _emotions = [
    ('emotion.happy', '高兴'),
    ('emotion.sad', '悲伤'),
    ('emotion.angry', '愤怒'),
    ('emotion.fearful', '恐惧'),
    ('emotion.disgusted', '厌恶'),
    ('emotion.surprised', '惊讶'),
    ('emotion.neutral', '中性'),
  ];

  static const _dialects = [
    ('dialect.chuanyu', 'chuanyu dialect'),
    ('dialect.cantonese', 'cantonese'),
  ];

  List<String> _builtinVoices() {
    for (final option in spec.requestOptions) {
      if (option.name == 'voice_id') return option.values;
    }
    return const [];
  }

  List<String> _optionValues(String name) {
    for (final option in spec.requestOptions) {
      if (option.name == name) return option.values;
    }
    return const [];
  }

  Widget _basicControl(String locale, String name) {
    return Expanded(
      child: WorkbenchDropdown(
        label: spec.uiText('basic.$name', locale, fallback: name),
        value: controller.advanced[name] ?? '',
        items: [
          DropdownMenuItem(
            value: '',
            child: Text(dict['workbench.default'] ?? 'Default'),
          ),
          for (final value in _optionValues(name))
            DropdownMenuItem(value: value, child: Text(value)),
        ],
        onChanged: (value) => controller.setAdvancedValue(name, value ?? ''),
      ),
    );
  }

  String _instructionLabel(String locale, String template) {
    final key = switch (template) {
      'voice_design' => 'instruction.voiceDesign',
      'freeform' => 'instruction.freeform',
      'multilingual' => 'instruction.multilingual',
      _ => 'instruction.tts',
    };
    final fallback = switch (template) {
      'voice_design' => 'Voice description',
      'freeform' => 'Freeform instruction',
      _ => 'Additional instruction',
    };
    final label = spec.uiText(key, locale, fallback: fallback);
    return template == 'voice_design' || template == 'freeform'
        ? '$label *'
        : label;
  }

  String _referenceBlockedHint(String locale) {
    if (controller.zeroSpeakerEnabled) {
      return spec.uiText(
        'referenceVoice.zeroSpeaker',
        locale,
        fallback:
            'Zero speaker embedding is enabled; the reference voice is not used. Disable it to restore voice selection.',
      );
    }
    return '';
  }

  Widget _disabledReference(Widget child, String locale) {
    if (!controller.referenceAudioIgnored) return child;
    final hint = _referenceBlockedHint(locale);
    if (hint.isEmpty) return child;
    return Tooltip(
      message: hint,
      child: AbsorbPointer(
        child: Opacity(opacity: 0.5, child: child),
      ),
    );
  }

  Future<void> _warnLongReference(
    BuildContext context,
    WidgetRef ref,
    String locale,
    VoiceEntry voice,
  ) async {
    if (controller.referenceAudioIgnored) return;
    if (voice.text == null || voice.text!.trim().isEmpty) return;
    const limit = 6;
    final path = voice.audioPath;
    if (path == null || path.isEmpty) return;

    final player = AudioPlayer();
    Duration? duration;
    try {
      await player.setSource(DeviceFileSource(path));
      duration = await player.getDuration();
    } catch (_) {
      duration = null;
    } finally {
      await player.dispose();
    }
    if (duration == null || !context.mounted) return;
    final seconds = duration.inMilliseconds / 1000;
    if (seconds <= limit) return;

    final text = spec.uiText(
      'referenceText.tooLong',
      locale,
      fallback:
          'Reference audio is {duration}s, above the suggested {limit}s for this template. '
          'With reference text enabled, Ming may exceed its 512-position context. '
          'Shorten the reference audio or clear the reference text.',
    );
    final message = text
        .replaceAll('{duration}', seconds.toStringAsFixed(1))
        .replaceAll('{limit}', '$limit');
    ref.read(workbenchNoticeDurationProvider.notifier).state = 5000;
    ref.read(workbenchNoticeProvider.notifier).state = message;
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
        describe: (option) => spec.optionDescription(option, locale),
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
    final builtin = _builtinVoices();
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final template = controller.effectiveTemplate;
        final showVoice = template != 'ip';
        final showBuiltin = template == 'ip';
        final showEmotion = template == 'emotion';
        final showDialect = template == 'dialect';
        final showInstruction = const {
          'tts',
          'multilingual',
          'voice_design',
          'freeform',
        }.contains(template);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _MingTemplateTabs(
              controller: controller,
              spec: spec,
              locale: locale,
            ),
            if (spec.languages.isNotEmpty) ...[
              const SizedBox(height: 12),
              WorkbenchDropdown(
                label: dict['workbench.language'] ?? 'Language',
                value: workbenchLanguageValue(controller.language),
                items: [
                  for (final language
                      in workbenchLanguageOptions(spec, controller.language))
                    DropdownMenuItem(value: language, child: Text(language)),
                ],
                onChanged: (value) => controller.setLanguage(
                  (value == null || value == 'auto' || value.isEmpty)
                      ? null
                      : value,
                ),
              ),
            ],
            if (showVoice) ...[
              const SizedBox(height: 12),
              _disabledReference(
                WorkbenchVoiceField(
                  label: dict['workbench.voice'] ?? 'Voice',
                  defaultLabel: dict['workbench.defaultVoice'] ?? 'Default',
                  selectedId: controller.voiceEntryId,
                  voices: voices,
                  onChanged: (id) {
                    VoiceEntry? found;
                    for (final voice in voices) {
                      if (voice.id == id) {
                        found = voice;
                        break;
                      }
                    }
                    controller.setVoice(found);
                    if (found != null) {
                      unawaited(
                        _warnLongReference(context, ref, locale, found),
                      );
                    }
                  },
                ),
                locale,
              ),
            ],
            if (showBuiltin) ...[
              const SizedBox(height: 12),
              WorkbenchDropdown(
                label: dict['workbench.voiceId'] ?? 'Built-in voice',
                value: builtin.contains(controller.builtinVoice)
                    ? controller.builtinVoice
                    : '',
                items: [
                  DropdownMenuItem(
                    value: '',
                    child: Text(dict['workbench.defaultVoice'] ?? 'Default'),
                  ),
                  for (final value in builtin)
                    DropdownMenuItem(value: value, child: Text(value)),
                ],
                onChanged: (value) => controller.setBuiltinVoice(value ?? ''),
              ),
            ],
            if (showVoice &&
                controller.hasReference &&
                !controller.referenceAudioIgnored) ...[
              const SizedBox(height: 12),
              TextField(
                controller: controller.refTextCtrl,
                maxLines: 2,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText:
                      dict['workbench.referenceText'] ?? 'Reference text',
                  hintText: dict['workbench.referenceTextHint'],
                ),
              ),
            ],
            if (template == 'basic') ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  _basicControl(locale, 'speed'),
                  const SizedBox(width: 12),
                  _basicControl(locale, 'pitch'),
                  const SizedBox(width: 12),
                  _basicControl(locale, 'volume'),
                ],
              ),
            ],
            if (showEmotion || showDialect) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  if (showEmotion)
                    Expanded(
                      child: WorkbenchDropdown(
                        label: spec.uiText(
                          'emotion.title',
                          locale,
                          fallback: 'emotion.title',
                        ),
                        value: controller.emotion,
                        items: [
                          DropdownMenuItem(
                            value: '',
                            child: Text(dict['workbench.default'] ?? 'Default'),
                          ),
                          for (final item in _emotions)
                            DropdownMenuItem(
                              value: item.$2,
                              child: Text(
                                spec.uiText(
                                  item.$1,
                                  locale,
                                  fallback: item.$2,
                                ),
                              ),
                            ),
                        ],
                        onChanged: (value) =>
                            controller.setEmotion(value ?? ''),
                      ),
                    ),
                  if (showEmotion && showDialect) const SizedBox(width: 12),
                  if (showDialect)
                    Expanded(
                      child: WorkbenchDropdown(
                        label: dict['workbench.dialect'] ?? 'Dialect',
                        value: controller.dialect,
                        items: [
                          DropdownMenuItem(
                            value: '',
                            child: Text(dict['workbench.default'] ?? 'Default'),
                          ),
                          for (final item in _dialects)
                            DropdownMenuItem(
                              value: item.$2,
                              child: Text(
                                spec.uiText(
                                  item.$1,
                                  locale,
                                  fallback: item.$2,
                                ),
                              ),
                            ),
                        ],
                        onChanged: (value) =>
                            controller.setDialect(value ?? ''),
                      ),
                    ),
                ],
              ),
            ],
            if (showInstruction) ...[
              const SizedBox(height: 12),
              TextField(
                controller: controller.instrCtrl,
                maxLines: 2,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: _instructionLabel(locale, template),
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: controller.textCtrl,
              maxLines: 6,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: dict['workbench.textHint'] ?? 'Type the text',
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
                  onPressed: () {
                    if (controller.effectiveTemplate == 'basic' &&
                        !controller.hasBasicControls) {
                      ref.read(workbenchNoticeDurationProvider.notifier).state =
                          4000;
                      ref.read(workbenchNoticeProvider.notifier).state =
                          spec.uiText(
                        'needBasicControl',
                        locale,
                        fallback:
                            'Choose at least one: speed, pitch, or volume',
                      );
                      return;
                    }
                    controller.saveAdvancedValues();
                    onSubmit();
                  },
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

Widget buildMing3TtsWorkbench(
  BuildContext context,
  WorkbenchWidgetContext ctx,
  WorkbenchModelController controller,
) {
  return Ming3TtsWorkbench(
    controller: controller as Ming3TtsController,
    spec: ctx.spec,
    dict: ctx.dict,
    onSubmit: () => ctx.submit(controller),
  );
}
