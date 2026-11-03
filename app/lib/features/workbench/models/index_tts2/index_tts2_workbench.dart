import 'dart:convert';

import 'package:file_selector/file_selector.dart';
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

/// IndexTTS2 / 2.5：参考音色 + 情感控制，走 /v1/tasks/run。
class IndexTts2Controller extends WorkbenchModelController {
  IndexTts2Controller(this.packageId, this.spec);

  static const _advancedNames = {
    'do_sample',
    'top_p',
    'top_k',
    'temperature',
    'length_penalty',
    'num_beams',
    'repetition_penalty',
    'max_tokens',
    'duration_scale',
    'seed',
    'interval_silence_ms',
    'text_chunk_size',
    'text_chunk_mode',
  };

  static const _advancedOrder = [
    'max_tokens',
    'duration_scale',
    'seed',
    'interval_silence_ms',
    'text_chunk_size',
    'text_chunk_mode',
    'repetition_penalty',
    'do_sample',
    'temperature',
    'top_k',
    'top_p',
    'num_beams',
    'length_penalty',
  ];

  final String packageId;
  final ModelSpec spec;
  String locale = 'en';

  final TextEditingController textCtrl = TextEditingController();
  final TextEditingController emotionTextCtrl = TextEditingController();

  String voiceEntryId = '';
  String? voiceRef;
  String? voiceName;
  String? language;
  String emotionMode = 'none';
  String? emotionAudioPath;
  double emotionAlpha = 1.0;
  List<double> emotionVector = List<double>.filled(8, 0);
  Map<String, String> advanced = {};

  bool get isV25 => packageId.contains('index_tts2_5');

  void setVoice(VoiceEntry? voice) {
    voiceEntryId = voice?.id ?? '';
    voiceRef = voice?.audioPath;
    voiceName = voice?.name;
    notifyListeners();
  }

  void setLanguage(String? value) {
    language = value;
    notifyListeners();
  }

  void setEmotionMode(String value) {
    emotionMode = value;
    notifyListeners();
  }

  void setEmotionAudio(String? path) {
    emotionAudioPath = path;
    notifyListeners();
  }

  void setEmotionAlpha(double value) {
    emotionAlpha = value;
    notifyListeners();
  }

  void setEmotionVector(int index, double value) {
    if (index < 0 || index >= emotionVector.length) return;
    emotionVector[index] = value.clamp(0, 1).toDouble();
    notifyListeners();
  }

  List<SpecOption> advancedOptions() {
    final byName = {
      for (final o in spec.requestOptions)
        if (_advancedNames.contains(o.name)) o.name: o,
    };
    final out = <SpecOption>[];
    final seen = <String>{};
    for (final name in _advancedOrder) {
      final option = byName[name];
      if (option == null) continue;
      out.add(_workbenchOption(option));
      seen.add(name);
    }
    for (final o in spec.requestOptions) {
      if (_advancedNames.contains(o.name) && !seen.contains(o.name)) {
        out.add(_workbenchOption(o));
        seen.add(o.name);
      }
    }
    return out;
  }

  SpecOption _workbenchOption(SpecOption o) {
    switch (o.name) {
      case 'top_p':
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
      case 'seed':
        return SpecOption(
          name: o.name,
          type: o.type,
          description: o.description,
          values: o.values,
          defaultValue: o.defaultValue,
          min: 0,
          required: o.required,
        );
      case 'text_chunk_size':
        return SpecOption(
          name: o.name,
          type: o.type,
          description: o.description,
          values: o.values,
          defaultValue: o.defaultValue,
          min: 1,
          required: o.required,
        );
      case 'temperature':
      case 'duration_scale':
        return SpecOption(
          name: o.name,
          type: o.type,
          description: o.description,
          values: o.values,
          defaultValue: o.defaultValue,
          min: double.minPositive,
          required: o.required,
        );
      default:
        return o;
    }
  }

  @override
  Map<String, String> advancedValues() => advanced;

  @override
  void setAdvancedValues(Map<String, String> values) {
    advanced = Map<String, String>.from(values);
    notifyListeners();
  }

  String _emotionText(String key) => spec.uiText(key, locale, fallback: key);

  @override
  String? validate() {
    if (textCtrl.text.trim().isEmpty) return 'workbench.needText';
    if (voiceRef == null || voiceRef!.isEmpty) {
      return 'workbench.needReference';
    }
    if (emotionMode == 'reference' &&
        (emotionAudioPath == null || emotionAudioPath!.isEmpty)) {
      return _emotionText('emotion.needAudio');
    }
    if (emotionMode == 'text' && emotionTextCtrl.text.trim().isEmpty) {
      return _emotionText('emotion.needText');
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

    bool badNumber(String name, {double min = 0, double? max}) {
      final raw = advanced[name];
      if (raw == null || raw.isEmpty) return false;
      final value = double.tryParse(raw);
      return value == null ||
          !value.isFinite ||
          value < min ||
          (max != null && value > max);
    }

    if (badInt('max_tokens', min: 1) ||
        badInt('num_beams', min: 1) ||
        badInt('text_chunk_size', min: 1) ||
        badInt('interval_silence_ms') ||
        badInt('seed', max: 4294967295)) {
      return 'workbench.invalidValue';
    }
    if (advanced['do_sample'] != 'false') {
      if (badInt('top_k', min: 1) ||
          badNumber('temperature', min: double.minPositive) ||
          badNumber('top_p', min: 0.01, max: 1)) {
        return 'workbench.invalidValue';
      }
    }
    if (badNumber('duration_scale', min: double.minPositive)) {
      return 'workbench.invalidValue';
    }
    return null;
  }

  @override
  WorkbenchCall? buildCall() {
    if (validate() != null) return null;
    final modelId = workbenchModelId(packageId, 'tts', spec);
    final options = <String, dynamic>{
      for (final e in advanced.entries)
        if (e.value.isNotEmpty) e.key: e.value,
    };
    if (isV25 && language != null && language!.isNotEmpty) {
      options['language'] = language;
    }
    if (advanced['do_sample'] == 'false') {
      options.remove('temperature');
      options.remove('top_k');
      options.remove('top_p');
    }
    final vector = emotionMode == 'vector'
        ? '[${emotionVector.map((v) => v.toStringAsFixed(3)).join(',')}]'
        : null;
    String? emotionAudio;
    switch (emotionMode) {
      case 'reference':
        emotionAudio = emotionAudioPath;
        break;
      case 'text':
        options['use_emotion_text'] = 'true';
        options['emotion_text'] = emotionTextCtrl.text.trim();
        break;
      case 'vector':
        options['emotion_vector'] = vector!;
        break;
      case 'random':
        options['use_random_emotion'] = 'true';
        break;
      default:
        break;
    }
    if (emotionMode != 'none' && (emotionAlpha - 1.0).abs() > 1e-9) {
      options['emotion_alpha'] = emotionAlpha.toString();
    }
    return WorkbenchCall(
      endpoint: '/v1/tasks/run',
      modelId: modelId,
      request: {
        'model': modelId,
        'request': {
          'text': textCtrl.text.trim(),
          'voice_ref': voiceRef,
          if (emotionAudio != null) 'audio': emotionAudio,
          if (options.isNotEmpty) 'options': options,
        },
      },
      recordInputs: {
        'text': textCtrl.text.trim(),
        if (voiceEntryId.isNotEmpty) 'voice_entry': voiceEntryId,
        'voice_ref': voiceRef!,
        if (voiceName != null) 'voice_name': voiceName!,
        if (language != null) 'language': language!,
        if (emotionAudio != null) 'emotion_audio': emotionAudio,
        'params': jsonEncode({
          'emotion_mode': emotionMode,
          if (emotionMode == 'text')
            'emotion_text': emotionTextCtrl.text.trim(),
          if (emotionMode != 'none') 'emotion_alpha': emotionAlpha.toString(),
          if (vector != null) 'emotion_vector': vector,
          for (final e in advanced.entries)
            if (e.value.isNotEmpty) e.key: e.value,
        }),
      },
      responseFormat: 'json_base64',
      audioPath: emotionAudio,
    );
  }

  @override
  void restore(GenerationRecord record) {
    textCtrl.text = record.inputs['text'] ?? '';
    emotionTextCtrl.text = record.inputs['emotion_text'] ?? '';
    voiceEntryId = record.inputs['voice_entry'] ?? '';
    voiceRef = record.inputs['voice_ref'];
    voiceName = record.inputs['voice_name'];
    language = record.inputs['language'];
    emotionMode = record.inputs['emotion_mode'] ?? 'none';
    emotionAudioPath = record.inputs['emotion_audio'];
    emotionAlpha = double.tryParse(record.inputs['emotion_alpha'] ?? '') ?? 1.0;
    advanced = {};

    final rawParams = record.inputs['params'];
    if (rawParams != null && rawParams.isNotEmpty) {
      try {
        final params = jsonDecode(rawParams);
        if (params is Map) {
          emotionMode = params['emotion_mode']?.toString() ?? emotionMode;
          emotionTextCtrl.text =
              params['emotion_text']?.toString() ?? emotionTextCtrl.text;
          emotionAlpha =
              double.tryParse(params['emotion_alpha']?.toString() ?? '') ??
                  emotionAlpha;
          for (final name in _advancedNames) {
            final value = params[name]?.toString() ?? '';
            if (value.isNotEmpty) advanced[name] = value;
          }
          _restoreEmotionExtra(params);
        }
      } catch (_) {}
    }

    notifyListeners();
  }

  void _restoreEmotionExtra(Map options) {
    final alpha = double.tryParse(options['emotion_alpha']?.toString() ?? '');
    if (alpha != null) emotionAlpha = alpha;
    final vector = options['emotion_vector']?.toString() ?? '';
    if (vector.isNotEmpty) {
      final parts = vector
          .replaceAll('[', '')
          .replaceAll(']', '')
          .split(',')
          .map((s) => double.tryParse(s.trim()) ?? 0)
          .toList();
      for (var i = 0; i < emotionVector.length && i < parts.length; i++) {
        emotionVector[i] = parts[i].clamp(0, 1).toDouble();
      }
    }
  }

  @override
  void dispose() {
    textCtrl.dispose();
    emotionTextCtrl.dispose();
    super.dispose();
  }
}

class IndexTts2Workbench extends ConsumerWidget {
  const IndexTts2Workbench({
    super.key,
    required this.controller,
    required this.spec,
    required this.dict,
    required this.onSubmit,
  });

  final IndexTts2Controller controller;
  final ModelSpec spec;
  final Map<String, String> dict;
  final VoidCallback onSubmit;

  static const _vectorDims = [
    'happy',
    'angry',
    'sad',
    'afraid',
    'disgusted',
    'melancholic',
    'surprised',
    'calm',
  ];

  Future<void> _pickEmotionAudio() async {
    final f = await openFile(acceptedTypeGroups: const [
      XTypeGroup(
        label: 'Audio',
        extensions: kWorkbenchAudioExtensions,
      ),
    ]);
    if (f == null) return;
    controller.setEmotionAudio(f.path);
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
        enabledFor: (name, values) {
          if (values['do_sample'] == 'false' &&
              const {'temperature', 'top_k', 'top_p'}.contains(name)) {
            return false;
          }
          return true;
        },
        stepFor: (o) => o.name == 'top_p' ? 0.01 : null,
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

  Widget _alphaSlider(String locale) {
    return Row(
      children: [
        SizedBox(
          width: 88,
          child: Text(
            spec.uiText(
              'emotion.strength',
              locale,
              fallback: 'emotion.strength',
            ),
          ),
        ),
        Expanded(
          child: Slider(
            value: controller.emotionAlpha,
            min: 0,
            max: 1,
            onChanged: controller.setEmotionAlpha,
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            controller.emotionAlpha.toStringAsFixed(2),
            textAlign: TextAlign.end,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(localeProvider).name;
    controller.locale = locale;
    String ui(String key) => spec.uiText(key, locale, fallback: key);
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
          if (controller.isV25 && spec.languages.isNotEmpty) ...[
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
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 4),
            child: Text(
              ui('emotion.title'),
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          _EmotionTabs(
            value: controller.emotionMode,
            options: [
              (
                value: 'none',
                label: ui('emotion.none'),
              ),
              (
                value: 'reference',
                label: ui('emotion.reference'),
              ),
              (
                value: 'text',
                label: ui('emotion.text'),
              ),
              (
                value: 'vector',
                label: ui('emotion.vector'),
              ),
              (
                value: 'random',
                label: ui('emotion.random'),
              ),
            ],
            onChanged: controller.setEmotionMode,
          ),
          if (controller.emotionMode == 'reference') ...[
            const SizedBox(height: 12),
            WorkbenchAudioButton(
              label: ui('emotion.pickAudio'),
              path: controller.emotionAudioPath,
              onPressed: _pickEmotionAudio,
            ),
          ],
          if (controller.emotionMode == 'text') ...[
            const SizedBox(height: 12),
            TextField(
              controller: controller.emotionTextCtrl,
              maxLines: 2,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: ui('emotion.textLabel'),
              ),
            ),
          ],
          if (controller.emotionMode == 'vector') ...[
            const SizedBox(height: 8),
            for (var i = 0; i < _vectorDims.length; i++)
              Row(
                children: [
                  SizedBox(
                    width: 88,
                    child: Text(
                      spec.uiText(
                        'emotion.vector.${_vectorDims[i]}',
                        locale,
                        fallback: _vectorDims[i],
                      ),
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: controller.emotionVector[i],
                      min: 0,
                      max: 1,
                      onChanged: (v) => controller.setEmotionVector(i, v),
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      controller.emotionVector[i].toStringAsFixed(2),
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              ),
          ],
          if (controller.emotionMode != 'none') ...[
            const SizedBox(height: 12),
            _alphaSlider(locale),
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

class _EmotionTabs extends StatefulWidget {
  const _EmotionTabs({
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String value;
  final List<({String value, String label})> options;
  final ValueChanged<String> onChanged;

  @override
  State<_EmotionTabs> createState() => _EmotionTabsState();
}

class _EmotionTabsState extends State<_EmotionTabs>
    with SingleTickerProviderStateMixin {
  late TabController _controller;

  int get _index {
    final index = widget.options.indexWhere((o) => o.value == widget.value);
    return index < 0 ? 0 : index;
  }

  @override
  void initState() {
    super.initState();
    _controller = TabController(
      length: widget.options.length,
      vsync: this,
      initialIndex: _index,
    );
  }

  @override
  void didUpdateWidget(covariant _EmotionTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_controller.length != widget.options.length) {
      _controller.dispose();
      _controller = TabController(
        length: widget.options.length,
        vsync: this,
        initialIndex: _index,
      );
    } else if (_controller.index != _index) {
      _controller.index = _index;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TabBar(
      controller: _controller,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      labelPadding: const EdgeInsets.symmetric(horizontal: 12),
      onTap: (index) => widget.onChanged(widget.options[index].value),
      tabs: [
        for (final option in widget.options) Tab(text: option.label),
      ],
    );
  }
}

Widget buildIndexTts2Workbench(
  BuildContext context,
  WorkbenchWidgetContext ctx,
  WorkbenchModelController controller,
) {
  return IndexTts2Workbench(
    controller: controller as IndexTts2Controller,
    spec: ctx.spec,
    dict: ctx.dict,
    onSubmit: () => ctx.submit(controller),
  );
}
