import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../models/model_spec.dart';
import '../../../../models/session.dart';
import '../../../../providers/app_providers.dart';
import '../../../../providers/player_providers.dart';
import '../../advanced_options_dialog.dart';
import '../../widgets/workbench_fields.dart';
import '../../workbench_contract.dart';
import '../../widgets/asr_srt.dart';
import '../../workbench_registry.dart';

const _asrMediaExtensions = [
  ...kWorkbenchAudioExtensions,
  'mp4',
  'mov',
  'm4v',
  'avi',
  'wmv',
];
const _videoExtensions = {'mp4', 'mov', 'm4v', 'avi', 'wmv'};

/// Qwen3-ASR：ASR 任务，走 /v1/tasks/run 以支持 request options。
class Qwen3AsrController extends WorkbenchModelController {
  Qwen3AsrController(this.packageId, this.spec);

  static const _advancedNames = {
    'max_tokens',
    'audio_chunk_mode',
    'audio_chunk_duration_sec',
    'return_timestamps',
    'clamp_timestamps_to_audio',
    'preserve_punctuation',
  };

  /// 当前语言的文本是否以空格分词。
  /// 目前中文、粤语、日语、泰语不使用词间空格；其他语言默认保留空格。
  static bool languageUsesSpaces(String? language) =>
      asrLanguageUsesSpaces(language);

  final String packageId;
  final ModelSpec spec;

  String? audioPath;
  String? language;
  Map<String, String> advanced = {};

  void setAudio(String? path) {
    audioPath = path;
    notifyListeners();
  }

  void setLanguage(String? value) {
    language = value;
    notifyListeners();
  }

  List<SpecOption> advancedOptions() => [
        for (final o in spec.requestOptions)
          if (_advancedNames.contains(o.name)) o,
      ];

  @override
  Map<String, String> advancedValues() => advanced;

  @override
  void setAdvancedValues(Map<String, String> values) {
    advanced = Map<String, String>.from(values);
    notifyListeners();
  }

  int? _maxTokens() {
    final text = advanced['max_tokens']?.trim() ?? '';
    if (text.isEmpty) return null;
    final value = int.tryParse(text);
    if (value == null || value <= 0) return null;
    return value;
  }

  double? _chunkDuration() {
    final text = advanced['audio_chunk_duration_sec']?.trim() ?? '';
    if (text.isEmpty) return null;
    final value = double.tryParse(text);
    if (value == null || value <= 0) return null;
    return value;
  }

  @override
  String? validate() {
    if (audioPath == null || audioPath!.isEmpty) return 'workbench.needAudio';
    final maxTokens = advanced['max_tokens']?.trim() ?? '';
    if (maxTokens.isNotEmpty && _maxTokens() == null) {
      return 'workbench.invalidNumber';
    }
    final duration = advanced['audio_chunk_duration_sec']?.trim() ?? '';
    if (duration.isNotEmpty && _chunkDuration() == null) {
      return 'workbench.invalidNumber';
    }
    return null;
  }

  @override
  WorkbenchCall? buildCall() {
    if (validate() != null) return null;
    final modelId = workbenchModelId(packageId, 'asr', spec);
    final maxTokens = _maxTokens();
    final chunkMode = advanced['audio_chunk_mode']?.trim();
    final chunkDuration = _chunkDuration();
    final timestampOptions = <String, String>{
      for (final name in const [
        'return_timestamps',
        'clamp_timestamps_to_audio',
        'preserve_punctuation',
      ])
        if ((advanced[name] ?? '').isNotEmpty) name: advanced[name]!,
    };
    final options = <String, dynamic>{
      if (maxTokens != null) 'max_tokens': maxTokens.toString(),
      if (chunkMode != null && chunkMode.isNotEmpty && chunkMode != 'auto')
        'audio_chunk_mode': chunkMode,
      if (chunkDuration != null)
        'audio_chunk_duration_sec': chunkDuration.toString(),
      ...timestampOptions,
    };
    return WorkbenchCall(
      endpoint: '/v1/tasks/run',
      modelId: modelId,
      request: {
        'model': modelId,
        'request': {
          'audio': audioPath,
          if (language != null) 'language': language,
          if (options.isNotEmpty) 'options': options,
        },
      },
      recordInputs: {
        'audio': audioPath!,
        if (language != null) 'language': language!,
        if (advanced.isNotEmpty) 'params': jsonEncode(advanced),
      },
      responseFormat: 'json_text',
      audioPath: audioPath,
    );
  }

  @override
  void restore(GenerationRecord record) {
    audioPath = record.inputs['audio'];
    language = record.inputs['language'];
    advanced = {};
    final rawParams = record.inputs['params'];
    if (rawParams != null && rawParams.isNotEmpty) {
      try {
        final params = jsonDecode(rawParams);
        if (params is Map) {
          for (final name in _advancedNames) {
            final value = params[name]?.toString() ?? '';
            if (value.isNotEmpty) advanced[name] = value;
          }
        }
      } catch (_) {}
    }

    notifyListeners();
  }
}

class Qwen3AsrWorkbench extends ConsumerStatefulWidget {
  const Qwen3AsrWorkbench({
    super.key,
    required this.controller,
    required this.spec,
    required this.dict,
    required this.onSubmit,
    this.selectedRecord,
    this.availableHeight,
  });

  final Qwen3AsrController controller;
  final ModelSpec spec;
  final Map<String, String> dict;
  final VoidCallback onSubmit;
  final GenerationRecord? selectedRecord;
  final double? availableHeight;

  @override
  ConsumerState<Qwen3AsrWorkbench> createState() => _Qwen3AsrWorkbenchState();
}

class _Qwen3AsrWorkbenchState extends ConsumerState<Qwen3AsrWorkbench> {
  double _formHeight = 320;

  Future<void> _pickAudio() async {
    final f = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'Media', extensions: _asrMediaExtensions),
    ]);
    if (f == null) return;
    widget.controller.setAudio(f.path);
    final ext = p.extension(f.path).toLowerCase().replaceFirst('.', '');
    if (!_videoExtensions.contains(ext)) {
      ref.read(audioPlayerProvider).load(f.path, title: f.name);
    }
  }

  Future<void> _openAdvanced(BuildContext context, String locale) async {
    final options = widget.controller.advancedOptions();
    if (options.isEmpty) return;
    final result = await showDialog<Map<String, String>?>(
      context: context,
      builder: (_) => AdvancedOptionsDialog(
        title: widget.dict['workbench.advancedTitle'] ?? 'Advanced parameters',
        options: options,
        saved: widget.controller.advancedValues(),
        dict: widget.dict,
        describe: (o) => widget.spec.optionDescription(o, locale),
        placeholderFor: (name, values) {
          if (name == 'max_tokens') return '512';
          if (name == 'audio_chunk_duration_sec') {
            return values['return_timestamps'] == 'true' ? '15' : '30';
          }
          return '';
        },
        valueLabelFor: (option, value) {
          if (option.name != 'audio_chunk_mode') return value;
          return widget.spec.uiText(
            'audioChunkMode.$value',
            locale,
            fallback: value,
          );
        },
        enabledFor: (name, values) {
          final timestamps = values['return_timestamps'] == 'true';
          final mode = values['audio_chunk_mode'] ?? 'auto';
          return switch (name) {
            'clamp_timestamps_to_audio' => timestamps,
            'preserve_punctuation' => timestamps && mode != 'none',
            _ => true,
          };
        },
      ),
    );
    if (result == null) return;
    widget.controller.setAdvancedValues(result);
    widget.controller.saveAdvancedValues();
  }

  void _onFormHeight(double height) {
    if (!mounted || (height - _formHeight).abs() < 1) return;
    setState(() => _formHeight = height);
  }

  double _resultMaxHeight(BuildContext context) {
    final available =
        widget.availableHeight ?? MediaQuery.sizeOf(context).height - 220;
    final maxHeight = available - _formHeight - 16 - 96;
    return maxHeight < 180 ? 180 : maxHeight;
  }

  @override
  Widget build(BuildContext context) {
    final locale = ref.watch(localeProvider).name;
    final controller = widget.controller;
    final spec = widget.spec;
    final dict = widget.dict;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _MeasureSize(
            onSize: _onFormHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (spec.languages.isNotEmpty) ...[
                  WorkbenchDropdown(
                    label: dict['workbench.language'] ?? 'Language',
                    value: workbenchLanguageValue(controller.language),
                    items: [
                      for (final l in workbenchLanguageOptions(
                          spec, controller.language))
                        DropdownMenuItem(value: l, child: Text(l)),
                    ],
                    onChanged: (v) => controller.setLanguage(
                      (v == null || v == 'auto' || v.isEmpty) ? null : v,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                OutlinedButton.icon(
                  onPressed: _pickAudio,
                  icon: const Icon(Icons.perm_media_outlined),
                  label: Text(
                    controller.audioPath == null
                        ? spec.uiText('pickMedia', locale,
                            fallback: 'Choose media')
                        : p.basename(controller.audioPath!),
                    overflow: TextOverflow.ellipsis,
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
                      onPressed: widget.onSubmit,
                      icon: const Icon(Icons.playlist_add),
                      label: Text(dict['workbench.submit'] ?? 'Add task'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (widget.selectedRecord != null) ...[
            const SizedBox(height: 16),
            _Qwen3AsrResult(
              record: widget.selectedRecord!,
              dict: dict,
              maxHeight: _resultMaxHeight(context),
            ),
          ],
        ],
      ),
    );
  }
}

class _MeasureSize extends StatefulWidget {
  const _MeasureSize({required this.child, required this.onSize});

  final Widget child;
  final ValueChanged<double> onSize;

  @override
  State<_MeasureSize> createState() => _MeasureSizeState();
}

class _MeasureSizeState extends State<_MeasureSize> {
  final GlobalKey _key = GlobalKey();

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(covariant _MeasureSize oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedule();
  }

  void _schedule() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _key.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) widget.onSize(box.size.height);
    });
  }

  @override
  Widget build(BuildContext context) =>
      Container(key: _key, child: widget.child);
}

Widget buildQwen3AsrWorkbench(
  BuildContext context,
  WorkbenchWidgetContext ctx,
  WorkbenchModelController controller,
) {
  final record = ctx.selectedRecord;
  return Qwen3AsrWorkbench(
    controller: controller as Qwen3AsrController,
    spec: ctx.spec,
    dict: ctx.dict,
    selectedRecord: record?.family == ctx.spec.family ? record : null,
    availableHeight: ctx.availableHeight,
    onSubmit: () => ctx.submit(controller),
  );
}

class _Qwen3AsrResult extends StatefulWidget {
  const _Qwen3AsrResult({
    required this.record,
    required this.dict,
    this.maxHeight,
  });

  final GenerationRecord record;
  final Map<String, String> dict;
  final double? maxHeight;

  @override
  State<_Qwen3AsrResult> createState() => _Qwen3AsrResultState();
}

class _Qwen3AsrResultState extends State<_Qwen3AsrResult> {
  bool _showWords = false;
  AsrSrt? _srt;
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  List<dynamic> get _words {
    final words = widget.record.ret?['words'];
    return words is List ? words : const [];
  }

  AsrSrt get _srtData => _srt ??= AsrSrt(widget.record);

  @override
  void didUpdateWidget(covariant _Qwen3AsrResult oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.record.id != widget.record.id) {
      _showWords = false;
      _srt = null;
      _resetScroll();
    }
  }

  Future<void> _copy(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      _copyNotice(widget.dict['common.copied'] ?? 'Copied');
    } catch (_) {
      _copyNotice(widget.dict['common.copyFailed'] ?? 'Copy failed');
    }
  }

  void _copyNotice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        width: 160,
        duration: const Duration(milliseconds: 1500),
      ),
    );
  }

  Future<void> _saveRaw() async {
    final ret = Map<String, dynamic>.from(
      widget.record.ret ?? const <String, dynamic>{},
    )..remove('timing');
    if (ret.isEmpty) ret['text'] = widget.record.displayText;
    final save = await getSaveLocation(
      suggestedName: 'transcript_${widget.record.id}_raw.json',
    );
    if (save == null) return;
    try {
      await File(save.path).writeAsString(
        const JsonEncoder.withIndent('  ').convert(ret),
      );
      _notice(widget.dict['session.saved'] ?? 'Saved');
    } catch (e) {
      _notice('$e');
    }
  }

  Future<void> _saveText() async {
    final save = await getSaveLocation(
      suggestedName: 'transcript_${widget.record.id}.txt',
    );
    if (save == null) return;
    try {
      await File(save.path).writeAsString(widget.record.displayText);
      _notice(widget.dict['session.saved'] ?? 'Saved');
    } catch (e) {
      _notice('$e');
    }
  }

  Future<void> _saveSrt() async {
    final save = await getSaveLocation(
      suggestedName: 'transcript_${widget.record.id}.srt',
    );
    if (save == null) return;
    try {
      await File(save.path).writeAsString(_srtData.srt);
      _notice(widget.dict['session.saved'] ?? 'Saved');
    } catch (e) {
      _notice('$e');
    }
  }

  void _resetScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtrl.hasClients) return;
      _scrollCtrl.jumpTo(0);
    });
  }

  void _notice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final words = _words;
    final text = widget.record.displayText;
    if (text.isEmpty && words.isEmpty) return const SizedBox.shrink();
    final showWords = _showWords && words.isNotEmpty;
    final view = showWords ? _srtData.preview : text;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.dict['workbench.result'] ?? 'Result',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (words.isNotEmpty) ...[
                  Text(
                    widget.dict['workbench.words'] ?? 'Words',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  SizedBox(
                    width: 36,
                    height: 24,
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: Switch(
                        value: _showWords,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onChanged: (value) {
                          setState(() => _showWords = value);
                          _resetScroll();
                        },
                      ),
                    ),
                  ),
                ],
                if (showWords) ...[
                  IconButton(
                    icon: const Icon(Icons.data_object, size: 18),
                    tooltip: widget.dict['workbench.exportRaw'] ??
                        'Export source data (JSON)',
                    onPressed: _saveRaw,
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    icon: const Icon(Icons.subtitles_outlined, size: 18),
                    tooltip: widget.dict['workbench.exportSrt'] ?? 'Export SRT',
                    onPressed: _saveSrt,
                    visualDensity: VisualDensity.compact,
                  ),
                ] else ...[
                  IconButton(
                    icon: const Icon(Icons.save_alt, size: 18),
                    tooltip:
                        widget.dict['workbench.exportText'] ?? 'Export text',
                    onPressed: _saveText,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
                IconButton(
                  icon: const Icon(Icons.content_copy, size: 18),
                  tooltip: widget.dict['common.copy'] ?? 'Copy',
                  onPressed: () => _copy(view),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: 180,
                maxHeight: (widget.maxHeight ??
                        MediaQuery.sizeOf(context).height - 220)
                    .clamp(180.0, double.infinity),
              ),
              child: SizedBox(
                width: double.infinity,
                child: Scrollbar(
                  controller: _scrollCtrl,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _scrollCtrl,
                    child: SizedBox(
                      width: double.infinity,
                      child: SelectableText(
                        view,
                        style: showWords
                            ? const TextStyle(fontFamily: 'monospace')
                            : null,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
