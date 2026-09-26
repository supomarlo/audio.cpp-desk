import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/variant_key.dart';
import '../../localization/strings.dart';
import '../../models/model_catalog_entry.dart';
import '../../models/model_spec.dart';
import '../../models/session.dart';
import '../../models/voice_entry.dart';
import '../../models/workbench_rule.dart';
import '../../providers/app_providers.dart';
import '../../providers/catalog_providers.dart';
import '../../providers/generation_providers.dart';
import '../../providers/library_providers.dart';
import '../../providers/player_providers.dart';
import '../../providers/session_providers.dart';
import '../common/audition_button.dart';
import '../common/busy_guard.dart';
import '../common/record_avatar.dart';
import '../player/player_bar.dart';
import '../server/server_status_bar.dart';

class WorkbenchPage extends ConsumerStatefulWidget {
  const WorkbenchPage({super.key});

  @override
  ConsumerState<WorkbenchPage> createState() => _WorkbenchPageState();
}

class _WorkbenchPageState extends ConsumerState<WorkbenchPage> {
  String? _selectedPackageId;
  String? _selectedRecordId;
  String _voiceId = '';
  String _builtinVoice = '';
  String? _ttsLanguage;
  String? _asrLanguage;
  final TextEditingController _textCtrl = TextEditingController();
  final TextEditingController _refTextCtrl = TextEditingController();
  final TextEditingController _instrCtrl = TextEditingController();
  String _instrChoice = '';
  /// `instructionType='attributes'`：类别 id → 选中值。
  final Map<String, String> _instrAttr = {};
  final TextEditingController _builtinVoiceCtrl = TextEditingController();
  String _emotionRuleKey = '';
  String _emotionMode = 'none';
  List<double> _emotionVector = [];
  final TextEditingController _emotionTextCtrl = TextEditingController();
  double _emotionStrength = 1.0;
  String? _emotionAudioPath;
  final Map<String, String> _inputPaths = {};
  String? _audioPath;
  double _panelWidth = 360;
  /// 会话面板可拖动的最大宽度（由可用宽度 - 控制区最小宽度 动态决定）。
  double _maxPanelWidth = 900;
  /// 分隔条宽度。
  static const double _resizerWidth = 6;
  /// 控制区最小宽度（保证操作区不被挤压）。
  static const double _minControlWidth = 520;
  bool _queueBusy = false;
  String? _lastQueueText;
  String? _result;
  String? _notice;
  bool _noticeAutoHide = false;
  Timer? _noticeTimer;
  String? _copyFeedback;
  Timer? _copyTimer;
  final TextEditingController _nameCtrl = TextEditingController();
  late final FocusNode _nameFocus;
  String _currentSessionId = '';
  Timer? _genTicker;
  DateTime? _genStart;
  Duration _genElapsed = Duration.zero;

  void _startGenTimer() {
    _genTicker?.cancel();
    _genStart = DateTime.now();
    _genElapsed = Duration.zero;
    _genTicker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final s = _genStart;
      if (s != null && mounted) {
        setState(() => _genElapsed = DateTime.now().difference(s));
      }
    });
  }

  void _stopGenTimer() {
    _genTicker?.cancel();
    _genTicker = null;
    final s = _genStart;
    if (s != null) _genElapsed = DateTime.now().difference(s);
    if (mounted) setState(() {});
  }

  /// 清除"生成用时"（切换模型/会话时调用，避免旧耗时残留）。
  void _clearGenStatus() {
    _genTicker?.cancel();
    _genTicker = null;
    _genStart = null;
    _genElapsed = Duration.zero;
  }

  String _fmtDur(Duration d) {
    final totalSec = d.inMilliseconds / 1000.0;
    if (totalSec < 60) return '${totalSec.toStringAsFixed(1)}s';
    final m = d.inMinutes;
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${m}m${s}s';
  }

  @override
  void initState() {
    super.initState();
    final session = ref.read(currentSessionProvider).session;
    _currentSessionId = session.id;
    _nameCtrl.text = session.name;
    final pw = ref.read(appConfigProvider).sessionPanelWidth;
    _panelWidth = (pw >= 260 && pw <= 900) ? pw.toDouble() : 360;
    _nameFocus = FocusNode();
    _nameFocus.addListener(() {
      if (!_nameFocus.hasFocus) {
        ref.read(currentSessionProvider).rename(_nameCtrl.text.trim());
      }
    });
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _refTextCtrl.dispose();
    _instrCtrl.dispose();
    _builtinVoiceCtrl.dispose();
    _emotionTextCtrl.dispose();
    _nameCtrl.dispose();
    _nameFocus.dispose();
    _genTicker?.cancel();
    _noticeTimer?.cancel();
    _copyTimer?.cancel();
    super.dispose();
  }

  WorkbenchRule _ruleFor(String packageId, String family) {
    final rules = ref.read(workbenchRulesProvider).value ?? const {};
    return rules[VariantKey.of(packageId)] ?? rules[family] ?? WorkbenchRule.none;
  }

  ModelSpec? _specFor(String family) {
    for (final s in ref.read(specsProvider).value ?? const <ModelSpec>[]) {
      if (s.family == family) return s;
    }
    return null;
  }

  /// 高级参数：规格声明的 request options，排除已被专用控件占用的
  /// （指令 / 参考文本 / 语言）。
  List<SpecOption> _advancedOptions(ModelSpec? spec, WorkbenchRule rule) {
    if (spec == null) return const [];
    final occupied = <String>{
      if (rule.showsInstruction) rule.instructionKey,
      if (rule.showsReferenceText) 'reference_text',
      if (rule.showsLanguage) 'language',
    };
    final e = rule.emotion;
    if (e != null) occupied.addAll(e.occupiedOptions);
    occupied.addAll(rule.inputs.map((i) => i.option));
    occupied.addAll(rule.hiddenOptions);
    final vi = rule.voiceId;
    if (vi != null && vi.option.isNotEmpty) occupied.add(vi.option);
    return spec.requestOptions
        .where((o) => !occupied.contains(o.name))
        .toList();
  }

  /// 情感控制提交字段（无/向量/文本+强度；参考音频暂不提交）。
  Map<String, String> _emotionParams(WorkbenchRule rule) {
    final e = rule.emotion;
    if (e == null) return const {};
    final m = e.modeById(_emotionMode);
    if (m == null) return const {};
    // 参考音频经 inputs['emotion_audio'] 提交；此处只带强度（非默认时）。
    if (m.audio) return _strengthParam(e);
    if (m.option.isEmpty) return const {};
    if (m.dimensions.isNotEmpty) {
      if (_emotionVector.isEmpty) return const {};
      return {
        m.option:
            '[${_emotionVector.map((v) => v.toStringAsFixed(3)).join(',')}]',
      };
    }
    final t = _emotionTextCtrl.text.trim();
    if (t.isEmpty) return const {};
    return {
      m.option: t,
      if (m.enabledOption.isNotEmpty) m.enabledOption: 'true',
      ..._strengthParam(e),
    };
  }

  /// 情感强度（emotion_alpha）：等于默认值时不提交。
  Map<String, String> _strengthParam(EmotionRule e) {
    if (e.strengthOption.isEmpty) return const {};
    if ((_emotionStrength - e.strengthDefault).abs() < 1e-9) return const {};
    return {e.strengthOption: _emotionStrength.toString()};
  }

  Widget _strengthRow(Map<String, String> dict, EmotionRule e) {
    return Row(
      children: [
        SizedBox(
          width: 88,
          child: Text(dict['workbench.emotion.strength'] ?? 'Strength'),
        ),
        Expanded(
          child: Slider(
            value: _emotionStrength.clamp(e.strengthMin, e.strengthMax),
            min: e.strengthMin,
            max: e.strengthMax,
            onChanged: (v) => setState(() => _emotionStrength = v),
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(_emotionStrength.toStringAsFixed(2),
              textAlign: TextAlign.end),
        ),
      ],
    );
  }

  Future<void> _pickEmotionAudio() async {
    final f = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'Audio', extensions: [
        'wav', 'mp3', 'flac', 'ogg', 'm4a', 'aac', 'webm', 'opus',
      ]),
    ]);
    if (f == null) return;
    setState(() => _emotionAudioPath = f.path);
  }

  Widget _inputsSection(Map<String, String> dict, WorkbenchRule rule) {
    final uiLang = ref.read(localeProvider).code;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final i in rule.inputs) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _pickInput(i),
            icon: Icon(i.isAudio ? Icons.audio_file_outlined : Icons.folder_open),
            label: Text(
              _inputPaths[i.option] == null || _inputPaths[i.option]!.isEmpty
                  ? i.label(uiLang)
                  : '${i.label(uiLang)}: ${File(_inputPaths[i.option]!).uri.pathSegments.last}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _pickInput(InputSpec i) async {
    // audio_path 直接提交路径（不转码），后端通常只支持 WAV → 缺省仅 WAV。
    const audioExt = ['wav'];
    final ext = i.extensions.isNotEmpty
        ? i.extensions
        : (i.isAudio ? audioExt : const <String>[]);
    final f = await openFile(acceptedTypeGroups: [
      if (ext.isNotEmpty)
        XTypeGroup(label: i.isAudio ? 'Audio' : 'File', extensions: ext),
    ]);
    if (f == null) return;
    setState(() => _inputPaths[i.option] = f.path);
  }

  /// 指令 / 风格输入：规则 `instructionType` 决定形态
  /// （`text` 文本框 / `enum` 单选下拉 / `attributes` 分组属性）。
  Widget _instructionField(Map<String, String> dict, WorkbenchRule rule) {
    final label = dict['workbench.instruction'] ?? 'Instruction / style';
    if (rule.instructionType == 'attributes' &&
        rule.instructionGroups.isNotEmpty) {
      return _instructionAttributes(dict, rule);
    }
    if (rule.instructionType == 'enum' && rule.instructionValues.isNotEmpty) {
      final opts = <String>{'', ...rule.instructionValues};
      final v = opts.contains(_instrChoice) ? _instrChoice : '';
      return InputDecorator(
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          isDense: true,
          labelText: label,
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: v,
            isExpanded: true,
            isDense: true,
            items: [
              DropdownMenuItem(
                value: '',
                child: Text(dict['workbench.default'] ?? 'Default'),
              ),
              for (final x in rule.instructionValues)
                DropdownMenuItem(value: x, child: Text(x)),
            ],
            onChanged: (val) => setState(() => _instrChoice = val ?? ''),
          ),
        ),
      );
    }
    return TextField(
      controller: _instrCtrl,
      maxLines: 2,
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        labelText: label,
      ),
    );
  }

  /// 指令提交值：`enum` 取单选、`attributes` 拼接各组选中值（`, ` 连接）、
  /// 否则取文本框内容。
  String _instructionValue(WorkbenchRule rule) {
    switch (rule.instructionType) {
      case 'enum':
        return _instrChoice;
      case 'attributes':
        return rule.instructionGroups
            .map((g) => _instrAttr[g.id] ?? '')
            .where((v) => v.isNotEmpty)
            .join(', ');
      default:
        return _instrCtrl.text.trim();
    }
  }

  /// 从记录里的指令串恢复分组属性选择（按组 values 匹配，忽略大小写）。
  void _restoreInstrAttrs(WorkbenchRule rule, String instruction) {
    _instrAttr.clear();
    if (rule.instructionType != 'attributes' || instruction.isEmpty) return;
    final parts = instruction
        .split(RegExp(r'[,，]'))
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.isNotEmpty)
        .toSet();
    for (final g in rule.instructionGroups) {
      for (final o in g.values) {
        if (parts.contains(o.value.toLowerCase())) {
          _instrAttr[g.id] = o.value;
          break;
        }
      }
    }
  }

  /// 分组属性指令：每类一行「类别名 + 下拉（默认/各值）」，组内单选、跨组组合；
  /// 底部为"已选"预览或提示。
  Widget _instructionAttributes(Map<String, String> dict, WorkbenchRule rule) {
    return InputDecorator(
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        labelText: dict['workbench.instruction'] ?? 'Instruction / style',
      ),
      // 自适应列数：按每项最小宽度决定列数（窄→1 列，宽→多列）。
      child: _grid(
          [for (final g in rule.instructionGroups)
            _instructionGroupField(dict, g, rule)],
          300,
          12),
    );
  }

  /// 单个分组属性的「标签 + 下拉」控件（也可作为 `instructionGroup` 节点单用）。
  /// `labelWidth` 为标签宽度（规则 `instructionLabelWidth`）；标签超宽时省略，
  /// 悬停显示完整标题。
  Widget _instructionGroupField(
      Map<String, String> dict, InstructionGroup g, WorkbenchRule rule) {
    final locale = ref.read(localeProvider).code;
    final small = Theme.of(context).textTheme.bodySmall;
    final label = g.label(locale);
    final labelWidth = rule.instructionLabelWidth;
    // tooltip 文案：none 不输出；title 用完整标题；custom 用规则自定义文案。
    final mode = rule.instructionLabelTooltipMode;
    var tip = '';
    if (mode != 'none') {
      tip = mode == 'custom' ? rule.instructionLabelTooltip(locale) : label;
      if (tip.isEmpty) tip = label;
    }
    // 仅当标题超过标签宽度、会被省略时才加 tooltip。
    final tp = TextPainter(
      text: TextSpan(text: label, style: small),
      maxLines: 1,
      textDirection: Directionality.of(context),
    )..layout();
    final showTip = tp.width > labelWidth && tip.isNotEmpty;
    final labelText =
        Text(label, style: small, overflow: TextOverflow.ellipsis);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: labelWidth,
            child: showTip ? Tooltip(message: tip, child: labelText) : labelText,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: InputDecorator(
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _instrAttr[g.id] ?? '',
                  isExpanded: true,
                  isDense: true,
                  items: [
                    DropdownMenuItem(
                      value: '',
                      child: Text(dict['workbench.default'] ?? 'Default'),
                    ),
                    for (final o in g.values)
                      DropdownMenuItem(
                          value: o.value, child: Text(o.label(locale))),
                  ],
                  onChanged: (v) => setState(() {
                    if (v == null || v.isEmpty) {
                      _instrAttr.remove(g.id);
                    } else {
                      _instrAttr[g.id] = v;
                    }
                  }),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emotionSection(Map<String, String> dict, EmotionRule e) {
    final uiLang = ref.read(localeProvider).code;
    final labels = <String, String>{
      'reference': dict['workbench.emotion.reference'] ?? 'Reference audio',
      'vector': dict['workbench.emotion.vector'] ?? 'Vector',
      'text': dict['workbench.emotion.text'] ?? 'Emotion text',
    };
    final ids = {'none', ...e.modes.map((m) => m.id)};
    final mode = ids.contains(_emotionMode) ? _emotionMode : 'none';
    final m = mode == 'none' ? null : e.modeById(mode);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InputDecorator(
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            isDense: true,
            labelText: dict['workbench.emotion'] ?? 'Emotion',
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: mode,
              isExpanded: true,
              isDense: true,
              items: [
                DropdownMenuItem(
                  value: 'none',
                  child: Text(e.noneLabel(uiLang) ??
                      (dict['workbench.emotion.none'] ?? 'Default')),
                ),
                for (final mm in e.modes)
                  DropdownMenuItem(
                    value: mm.id,
                    child: Text(labels[mm.id] ?? mm.id),
                  ),
              ],
              onChanged: (v) => setState(() => _emotionMode = v ?? 'none'),
            ),
          ),
        ),
        if (m != null && m.audio) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _pickEmotionAudio,
            icon: const Icon(Icons.audio_file_outlined),
            label: Text(
              _emotionAudioPath == null
                  ? (dict['workbench.emotion.pickAudio'] ??
                      'Choose emotion reference audio')
                  : File(_emotionAudioPath!).uri.pathSegments.last,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
        if (m != null && m.dimensions.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (var i = 0; i < m.dimensions.length; i++)
            Row(
              children: [
                SizedBox(
                  width: 64,
                  child: Text(
                    m.dimensions[i].label(uiLang),
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: i < _emotionVector.length ? _emotionVector[i] : 0,
                    min: 0,
                    max: 1,
                    onChanged: (v) => setState(() {
                      if (i < _emotionVector.length) _emotionVector[i] = v;
                    }),
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text(
                    (i < _emotionVector.length ? _emotionVector[i] : 0)
                        .toStringAsFixed(2),
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ],
            ),
        ],
        if (m != null && m.option.isNotEmpty && m.dimensions.isEmpty) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _emotionTextCtrl,
            maxLines: 2,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              isDense: true,
              labelText: labels[m.id] ?? m.id,
            ),
          ),
        ],
        if (m != null && m.strength && e.strengthOption.isNotEmpty) ...[
          const SizedBox(height: 8),
          _strengthRow(dict, e),
        ],
      ],
    );
  }

  /// 打开「高级参数」弹窗；保存时按 family 持久化，重置则清除。
  Future<void> _openAdvanced(
    ModelCatalogEntry entry,
    List<SpecOption> options,
    Map<String, String> dict,
  ) async {
    final spec = _specFor(entry.family);
    if (spec == null || options.isEmpty) return;
    final rule = _ruleFor(entry.packageId, entry.family);
    // 规则可覆盖某参数的控件类型（如把 string 的路径参数显示为「上传」）。
    final opts = <SpecOption>[
      for (final o in options)
        rule.optionTypes.containsKey(o.name)
            ? o.copyWithType(rule.optionTypes[o.name]!)
            : o,
    ];
    final locale = ref.read(localeProvider).code;
    final saved = Map<String, String>.from(
        ref.read(appConfigProvider).modelParams[entry.family] ?? const {});
    final result = await showDialog<Map<String, String>?>(
      context: context,
      builder: (_) => _AdvancedDialog(
        title: dict['workbench.advancedTitle'] ?? 'Advanced parameters',
        options: opts,
        saved: saved,
        dict: dict,
        extensions: rule.optionExtensions,
        describe: (o) => spec.optionDescription(o, locale),
      ),
    );
    if (result == null) return;
    await ref.read(appConfigProvider.notifier).update((c) {
      if (result.isEmpty) {
        c.modelParams.remove(entry.family);
      } else {
        c.modelParams[entry.family] = result;
      }
    });
  }

  void _resetTtsInputs() {
    _voiceId = '';
    _builtinVoice = '';
    _builtinVoiceCtrl.text = '';
    _refTextCtrl.text = '';
    _instrCtrl.text = '';
    _instrChoice = '';
    _instrAttr.clear();
    _inputPaths.clear();
    _ttsLanguage = null;
  }

  /// 记录最后使用的模型（写入 config），下次打开工作台默认选中它。
  void _rememberModel(String? packageId) {
    if (packageId == null || packageId.isEmpty) return;
    if (ref.read(appConfigProvider).lastUsedPackageId == packageId) return;
    ref
        .read(appConfigProvider.notifier)
        .update((c) => c.lastUsedPackageId = packageId);
  }

  /// 内置音色的有效值：用户选择优先，否则用文档默认值，再否则用第一个。
  String _effectiveBuiltinVoice(WorkbenchRule rule) {
    if (_builtinVoice.isNotEmpty) return _builtinVoice;
    final v = rule.voiceId;
    if (v == null) return '';
    if (v.defaultValue.isNotEmpty) return v.defaultValue;
    if (v.values != null && v.values!.isNotEmpty) return v.values!.first;
    return '';
  }

  /// TTS 生成角色（音色）显示名，供记录头像取首字。参考音色优先，其次内置音色。
  String _ttsRoleName(WorkbenchRule rule) {
    if (_voiceId.isNotEmpty) {
      for (final v in ref.read(voiceLibraryProvider).voices) {
        if (v.id == _voiceId) return v.name;
      }
    }
    if (rule.showsVoiceId) return _effectiveBuiltinVoice(rule);
    return '';
  }

  /// 是否已选定音色：本地音色库的参考音色，或显式选择的内置音色。
  /// 用于 `instructionWhen=no-voice` 时隐藏 / 不提交指令。
  bool _hasVoiceSelected(WorkbenchRule rule) =>
      _voiceId.isNotEmpty || (rule.showsVoiceId && _builtinVoice.isNotEmpty);

  List<ModelCatalogEntry> _workModels(
    List<ModelCatalogEntry> entries,
    Map<String, ModelSpec> specByFamily,
  ) {
    return entries.where((e) {
      if (!e.installed) return false;
      final tasks = specByFamily[e.family]?.tasks ?? const <String>[];
      return tasks.contains('tts') || tasks.contains('asr');
    }).toList();
  }

  List<ModelCatalogEntry> _workModelsSorted(
    List<ModelCatalogEntry> entries,
    Map<String, ModelSpec> specByFamily,
  ) {
    final list = _workModels(entries, specByFamily);
    list.sort((a, b) => a.displayName.compareTo(b.displayName));
    return list;
  }

  String _taskOf(ModelCatalogEntry e, Map<String, ModelSpec> specByFamily) {
    final tasks = specByFamily[e.family]?.tasks ?? const <String>[];
    if (tasks.contains('tts')) return 'tts';
    if (tasks.contains('asr')) return 'asr';
    return '';
  }

  Future<void> _pickAudio() async {
    final f = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'Audio', extensions: [
        'wav', 'mp3', 'flac', 'ogg', 'm4a', 'aac', 'webm', 'opus',
      ]),
    ]);
    if (f == null) return;
    setState(() => _audioPath = f.path);
    // 载入播放器但不播放。
    ref.read(audioPlayerProvider).load(f.path, title: f.name);
  }

  /// 提交为一条任务（入队排队）；一次点击 = 一条任务，TTS/ASR 一致。
  void _enqueue() {
    final packageId = _selectedPackageId;
    if (packageId == null) return;
    _noticeTimer?.cancel();
    if (_notice != null) setState(() => _notice = null);
    final specs = ref.read(specsProvider).value ?? const <ModelSpec>[];
    final specByFamily = {for (final s in specs) s.family: s};
    ModelCatalogEntry? entry;
    for (final e in ref.read(modelLibraryProvider).entries) {
      if (e.packageId == packageId) {
        entry = e;
        break;
      }
    }
    if (entry == null) return;
    _rememberModel(packageId);
    final task = _taskOf(entry, specByFamily);
    final ctrl = ref.read(currentSessionProvider);
    if (task == 'tts') {
      final text = _textCtrl.text.trim();
      if (text.isEmpty) {
        _toast(tr(ref, 'workbench.needText'));
        return;
      }
      final rule = _ruleFor(entry.packageId, entry.family);
      if (rule.referenceRequired && _voiceId.isEmpty) {
        _toast(tr(ref, 'workbench.needReference'));
        return;
      }
      if (rule.referenceTextRequired &&
          _voiceId.isNotEmpty &&
          _refTextCtrl.text.trim().isEmpty) {
        _toast(tr(ref, 'workbench.needReferenceText'));
        return;
      }
      final instrEmpty = _instructionValue(rule).isEmpty;
      if (rule.instructionRequired &&
          rule.instructionShownWithVoice(_hasVoiceSelected(rule)) &&
          instrEmpty) {
        _toast(tr(ref, 'workbench.needInstruction'));
        return;
      }
      if ((rule.emotion?.modeById(_emotionMode)?.audio ?? false) &&
          _emotionAudioPath == null) {
        _toast(tr(ref, 'workbench.emotion.needAudio'));
        return;
      }
      final (voicePreset, voiceRef) = _resolveVoice();
      final roleName = _ttsRoleName(rule);
      final lang = _ttsLanguage ??
          (rule.languageDefault.isNotEmpty ? rule.languageDefault : null);
      // 高级参数（仅未占用、非空的项）随记录快照一起提交。
      final advancedNames = _advancedOptions(_specFor(entry.family), rule)
          .map((o) => o.name)
          .toSet();
      final familyParams = <String, String>{
        for (final e in (ref.read(appConfigProvider).modelParams[entry.family] ??
                const <String, String>{})
            .entries)
          if (advancedNames.contains(e.key) && e.value.isNotEmpty)
            e.key: e.value,
      };
      // 情感控制与高级参数一起进入记录快照（作为 request options）。
      final ttsParams = <String, String>{
        ...familyParams,
        ..._emotionParams(rule),
        for (final i in rule.inputs)
          if ((_inputPaths[i.option] ?? '').isNotEmpty)
            i.option: _inputPaths[i.option]!,
      };
      // 内置音色：规则声明 option 时提交到 options.<option>（否则顶层 voice）。
      final vi = rule.voiceId;
      if (rule.showsVoiceId && vi != null && vi.option.isNotEmpty) {
        ttsParams[vi.option] = _effectiveBuiltinVoice(rule);
      }
      final record = ctrl.addRecord(
        type: RecordType.tts,
        family: entry.family,
        packageId: entry.packageId,
        status: 'queued',
        inputs: {
          'text': text,
          if (voiceRef != null) 'voice_ref': voiceRef,
          if (voicePreset != null) 'voice': voicePreset,
          if (_voiceId.isNotEmpty) 'voice_entry': _voiceId,
          if (roleName.isNotEmpty) 'voice_name': roleName,
          if (rule.showsVoiceId && (rule.voiceId?.option.isEmpty ?? true))
            'voice_id': _effectiveBuiltinVoice(rule),
          'reference_text': (rule.showsReferenceText && _voiceId.isNotEmpty)
              ? _refTextCtrl.text.trim()
              : '',
          'instruction': rule.instructionShownWithVoice(_hasVoiceSelected(rule))
              ? _instructionValue(rule)
              : '',
          'instruction_key': rule.instructionKey,
          'language': rule.showsLanguage ? (lang ?? '') : '',
          if ((rule.emotion?.modeById(_emotionMode)?.audio ?? false) &&
              _emotionAudioPath != null)
            'emotion_audio': _emotionAudioPath!,
          if (ttsParams.isNotEmpty) 'params': jsonEncode(ttsParams),
        },
      );
      ref.read(generationQueueProvider).enqueue(ctrl.session.id, record.id);
    } else if (task == 'asr') {
      final path = _audioPath;
      if (path == null) {
        _toast(tr(ref, 'workbench.needAudio'));
        return;
      }
      final record = ctrl.addRecord(
        type: RecordType.asr,
        family: entry.family,
        packageId: entry.packageId,
        status: 'queued',
        inputs: {
          'audio': path,
          'language':
              (_asrLanguage?.isEmpty ?? true) ? '' : (_asrLanguage ?? ''),
        },
      );
      ref.read(generationQueueProvider).enqueue(ctrl.session.id, record.id);
    }
  }

  /// 页内提示。`autoHide=true` 仅用于"已载入工作台"这类短暂提示（1.5s 自动消失、
  /// 无按钮）；否则保留（可复制/关闭/点空白关闭），便于用户看清错误文本。
  void _toast(String msg, {bool autoHide = false}) {
    if (!mounted) return;
    _noticeTimer?.cancel();
    setState(() {
      _notice = msg;
      _noticeAutoHide = autoHide;
    });
    if (autoHide) {
      _noticeTimer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => _notice = null);
      });
    }
  }

  void _dismissNotice() {
    _noticeTimer?.cancel();
    _copyTimer?.cancel();
    if (_notice != null || _copyFeedback != null) {
      setState(() {
        _notice = null;
        _copyFeedback = null;
      });
    }
  }

  Future<void> _copyNotice() {
    final text = _notice;
    if (text == null) return Future.value();
    return _copyText(text);
  }

  /// 复制文本并在页内显示独立反馈；不替换/关闭原提示，避免丢失报错信息。
  Future<void> _copyText(String text) async {
    final dict = ref.read(stringsProvider);
    var ok = false;
    try {
      await Clipboard.setData(ClipboardData(text: text));
      ok = true;
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    _copyTimer?.cancel();
    setState(() {
      _copyFeedback =
          dict[ok ? 'common.copied' : 'common.copyFailed'] ??
              (ok ? 'Copied to clipboard' : 'Copy failed');
    });
    _copyTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copyFeedback = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String?>(workbenchNoticeProvider, (_, next) {
      if (next != null) {
        _toast(next, autoHide: true);
        ref.read(workbenchNoticeProvider.notifier).state = null;
      }
    });
    // 持久提示（不自动关闭）：如服务端多次启动失败导致队列停止。
    ref.listen<String?>(workbenchErrorNoticeProvider, (_, next) {
      if (next != null) {
        _toast(next, autoHide: false);
        ref.read(workbenchErrorNoticeProvider.notifier).state = null;
      }
    });
    // 生成队列：运行开始/结束驱动计时器；ASR 结果更新到结果栏。
    // 注意：ChangeNotifierProvider 的 listen 回调 prev/next 是同一实例，
    // 需用本地变量记录上一次状态来判断变化。
    ref.listen<GenerationQueue>(generationQueueProvider, (_, next) {
      final busy = next.busy;
      if (busy && !_queueBusy) {
        _startGenTimer();
      } else if (!busy && _queueBusy) {
        _stopGenTimer();
      }
      _queueBusy = busy;
      final lt = next.lastText;
      if (lt != null && lt != _lastQueueText) {
        _lastQueueText = lt;
        // 结果栏已可见（用户在查看）时不抢占，避免打断。
        if (_result == null) setState(() => _result = lt);
      }
    });
    final dict = ref.watch(stringsProvider);
    final lib = ref.watch(modelLibraryProvider);
    final specs = ref.watch(specsProvider).value ?? const <ModelSpec>[];
    final specByFamily = {for (final s in specs) s.family: s};
    final workModels = _workModelsSorted(lib.entries, specByFamily);
    final textTheme = Theme.of(context).textTheme;

    ModelCatalogEntry? current;
    if (_selectedPackageId != null) {
      for (final e in workModels) {
        if (e.packageId == _selectedPackageId) {
          current = e;
          break;
        }
      }
    }
    // 回退：上次使用的模型；若它已被删除/未安装（未命中）则忽略，继续回退到首个。
    if (current == null) {
      final last = ref.read(appConfigProvider).lastUsedPackageId;
      if (last.isNotEmpty) {
        for (final e in workModels) {
          if (e.packageId == last) {
            current = e;
            break;
          }
        }
      }
    }
    if (current == null && workModels.isNotEmpty) {
      current = workModels.first;
    }
    _selectedPackageId = current?.packageId;
    final task = current == null ? '' : _taskOf(current, specByFamily);
    final languages = current == null
        ? const <String>[]
        : (specByFamily[current.family]?.languages ?? const <String>[]);

    final session = ref.watch(currentSessionProvider).session;
    if (session.id != _currentSessionId) {
      _currentSessionId = session.id;
      _nameCtrl.text = session.name;
      // 切换会话：清除生成用时与结果，避免残留上一个会话的信息。
      // 有任务在跑时保留计时器。
      if (!ref.read(generationQueueProvider).busy) _clearGenStatus();
      _result = null;
      _selectedRecordId = null;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // 控制区保留最小宽度；会话面板宽度受可用宽度约束，避免挤压/越界。
        final avail = constraints.maxWidth.isFinite
            ? constraints.maxWidth - _resizerWidth - _minControlWidth
            : 900.0;
        _maxPanelWidth = avail.clamp(260.0, 900.0);
        final panelW = _panelWidth.clamp(260.0, _maxPanelWidth);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _sessionHeader(dict),
                        const SizedBox(height: 12),
                        Expanded(
                          child: workModels.isEmpty
                              ? Center(
                                  child: Text(
                                      dict['workbench.noModels'] ??
                                          'No TTS / ASR models installed. Install and load one from the model library first.',
                                      style: textTheme.bodyLarge),
                                )
                              : _buildBody(dict, current!, task, languages),
                        ),
                        const PlayerBar(),
                      ],
                    ),
                  ),
                  if (_notice != null && !_noticeAutoHide)
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: _dismissNotice,
                        child: const SizedBox.expand(),
                      ),
                    ),
                  if (_notice != null || _copyFeedback != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 16,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_copyFeedback != null) ...[
                            _copyFeedbackBar(context),
                            const SizedBox(height: 8),
                          ],
                          if (_notice != null) _noticeBar(context),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            _panelResizer(),
            SizedBox(width: panelW, child: _sessionPanel(dict)),
          ],
        );
      },
    );
  }

  /// 工作台页内提示（底部居中，作用域限于本页，不依附全局）。
  Widget _noticeBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640),
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(4),
        color: scheme.inverseSurface,
        child: Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: _noticeAutoHide ? 16 : 8,
            top: _noticeAutoHide ? 12 : 8,
            bottom: _noticeAutoHide ? 12 : 8,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  _notice!,
                  style:
                      TextStyle(color: scheme.onInverseSurface, fontSize: 14),
                ),
              ),
              if (!_noticeAutoHide) ...[
                const SizedBox(width: 8),
                IconButton(
                  icon: Icon(Icons.content_copy,
                      size: 16, color: scheme.onInverseSurface),
                  onPressed: _copyNotice,
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  icon: Icon(Icons.close,
                      size: 18, color: scheme.onInverseSurface),
                  onPressed: _dismissNotice,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 复制反馈（独立于提示本身，短暂显示，不替换/关闭原提示）。
  Widget _copyFeedbackBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640),
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(4),
        color: scheme.inverseSurface,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            _copyFeedback!,
            style: TextStyle(color: scheme.onInverseSurface, fontSize: 13),
          ),
        ),
      ),
    );
  }

  Widget _sessionHeader(Map<String, String> dict) {
    final ctrl = ref.watch(currentSessionProvider);
    final cc = ref.watch(collectionsProvider);
    final sid = ctrl.session.id;
    final currentCid = ctrl.session.collectionId ?? '';
    final items = <DropdownMenuItem<String>>[
      DropdownMenuItem(
          value: '', child: Text(dict['collection.none'] ?? 'Unfiled')),
      for (final c in cc.collections)
        DropdownMenuItem(
          value: c.id,
          child: Text(
            c.name.isNotEmpty
                ? c.name
                : (dict['collection.unnamed'] ?? 'Collection'),
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ];
    final value = items.any((e) => e.value == currentCid) ? currentCid : '';
    return Row(
      children: [
        IconButton(
          tooltip: dict['collection.new'] ?? 'New collection',
          icon: const Icon(Icons.create_new_folder_outlined),
          onPressed: () => _newCollection(dict, sid),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 180,
          child: InputDecorator(
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              isDense: true,
              labelText: dict['collection.label'] ?? 'Collection',
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: value,
                isExpanded: true,
                isDense: true,
                items: items,
                onChanged: (v) {
                  if (v == null) return;
                  if (v.isEmpty) {
                    cc.removeSession(sid);
                    ctrl.setCollectionId(null);
                  } else {
                    cc.addSession(sid, v);
                    ctrl.setCollectionId(v);
                  }
                },
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _nameCtrl,
            focusNode: _nameFocus,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              isDense: true,
              labelText: dict['session.name'] ?? 'Session name',
              hintText: dict['session.unnamed'] ?? 'New session',
            ),
          ),
        ),
        const SizedBox(width: 12),
        OutlinedButton.icon(
          onPressed: () async {
            if (await confirmWhileBusy(ref, context, goWorkbench: false)) {
              ref.read(currentSessionProvider).newSession();
            }
          },
          icon: const Icon(Icons.add, size: 18),
          label: Text(dict['session.new'] ?? 'New session'),
        ),
      ],
    );
  }

  Future<void> _newCollection(Map<String, String> dict, String sid) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(dict['collection.new'] ?? 'New collection'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: dict['collection.label'] ?? 'Collection',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(dict['common.cancel'] ?? 'Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: Text(dict['common.save'] ?? 'Save')),
        ],
      ),
    );
    if (name == null) return;
    final c = ref
        .read(collectionsProvider)
        .create(name, addSessionId: sid);
    ref.read(currentSessionProvider).setCollectionId(c.id);
  }

  Widget _sessionPanel(Map<String, String> dict) {
    final session = ref.watch(currentSessionProvider).session;
    final queue = ref.watch(generationQueueProvider);
    final tasks = session.records
        .where((r) => r.status == 'queued' || r.status == 'generating')
        .toList();
    final done = session.records
        .where((r) => r.status != 'queued' && r.status != 'generating')
        .toList()
        .reversed
        .toList();
    final showTasks = tasks.isNotEmpty || queue.busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showTasks) ...[
          _panelHeader(
            dict['session.tasks'] ?? 'Tasks',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (tasks.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.clear_all),
                    tooltip: dict['task.clear'] ?? 'Clear',
                    onPressed: () => _clearTasks(tasks),
                  ),
                _queueButton(dict, queue),
              ],
            ),
          ),
          for (final r in tasks) _taskTile(dict, r),
        ],
        _panelHeader(dict['session.records'] ?? 'Session records'),
        Expanded(
          child: done.isEmpty
              ? Center(
                  child: Text(
                    dict['session.empty'] ?? 'No records yet',
                    style: const TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  itemCount: done.length,
                  itemBuilder: (c, i) => _recordTile(dict, done[i]),
                ),
        ),
        const ServerStatusBar(),
      ],
    );
  }

  /// 任务区右上角的主按钮：暂停 / 开始（暂停中显示繁忙并禁用）。
  Widget _queueButton(Map<String, String> dict, GenerationQueue queue) {
    if (queue.pausing) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (queue.busy && !queue.paused) {
      return IconButton(
        icon: const Icon(Icons.pause),
        tooltip: dict['task.pause'] ?? 'Pause',
        onPressed: () => ref.read(generationQueueProvider).pause(),
      );
    }
    return IconButton(
      icon: const Icon(Icons.play_arrow),
      tooltip: dict['task.resume'] ?? 'Start',
      onPressed: () => ref.read(generationQueueProvider).start(),
    );
  }

  /// 清空任务区里非运行中的任务（无法停止正在生成的，需先暂停）。
  void _clearTasks(List<GenerationRecord> tasks) {
    final queue = ref.read(generationQueueProvider);
    final runningId = queue.runningId;
    final ctrl = ref.read(currentSessionProvider);
    for (final r in tasks) {
      if (r.id == runningId) continue;
      queue.cancelQueued(r.id);
      ctrl.deleteRecord(r.id);
    }
  }

  /// 会话面板可拖动分隔条（调整宽度并在结束时持久化）。
  Widget _panelResizer() => MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: (d) {
            setState(() {
              _panelWidth =
                  (_panelWidth - d.delta.dx).clamp(260.0, _maxPanelWidth);
            });
          },
          onHorizontalDragEnd: (_) {
            ref.read(appConfigProvider.notifier).update(
                (c) => c.sessionPanelWidth = _panelWidth.round());
          },
          child: const SizedBox(
            width: _resizerWidth,
            child: VerticalDivider(width: 1, thickness: 1),
          ),
        ),
      );

  Widget _panelHeader(String title, {Widget? trailing}) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Row(
          children: [
            Expanded(
              child:
                  Text(title, style: Theme.of(context).textTheme.titleSmall),
            ),
            if (trailing != null) trailing,
          ],
        ),
      );

  Widget _taskTile(Map<String, String> dict, GenerationRecord r) {
    final running = ref.watch(generationQueueProvider).runningId == r.id;
    final subtitle = running
        ? dictTpl(dict, 'workbench.generating', {'time': _fmtDur(_genElapsed)})
        : (dict['task.queued'] ?? 'Queued');
    final Widget trailing = running
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : IconButton(
            icon: const Icon(Icons.close),
            tooltip: dict['common.cancel'] ?? 'Cancel',
            onPressed: () => _removeTask(r),
          );
    return ListTile(
      dense: true,
      leading: RecordAvatar(record: r),
      title:
          Text(_recordTitle(r), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
      trailing: trailing,
    );
  }

  void _removeTask(GenerationRecord r) {
    ref.read(generationQueueProvider).cancelQueued(r.id);
    ref.read(currentSessionProvider).deleteRecord(r.id);
  }

  /// 把一条记录的生成参数回填到工作台。
  /// 模型选择回退：优先记录里的具体模型；不在则按大类(tts/asr)取默认排序首个。
  void _applyRecord(Map<String, String> dict, GenerationRecord r) {
    final specs = ref.read(specsProvider).value ?? const <ModelSpec>[];
    final specByFamily = {for (final s in specs) s.family: s};
    final workModels =
        _workModelsSorted(ref.read(modelLibraryProvider).entries, specByFamily);
    ModelCatalogEntry? target;
    for (final e in workModels) {
      if (e.packageId == r.packageId) {
        target = e;
        break;
      }
    }
    if (target == null) {
      for (final e in workModels) {
        if (_taskOf(e, specByFamily) == r.type) {
          target = e;
          break;
        }
      }
    }
    final store = ref.read(sessionStoreProvider);
    String? audioAbs;
    for (final o in r.outputs) {
      if (o.kind == 'audio') {
        audioAbs = p.join(store.baseDir.path, o.path);
        break;
      }
    }
    final rule = _ruleFor(r.packageId, r.family);
    final busy = ref.read(generationQueueProvider).busy;
    setState(() {
      // 有任务在跑时不动计时器（否则会清零且不再累加）。
      if (!busy) _clearGenStatus();
      _noticeTimer?.cancel();
      _notice = null;
      _selectedRecordId = r.id;
      if (target != null) _selectedPackageId = target.packageId;
      _resetTtsInputs();
      if (r.type == RecordType.tts) {
        _audioPath = null;
        _textCtrl.text = r.inputs['text'] ?? '';
        _refTextCtrl.text = r.inputs['reference_text'] ?? '';
        _instrCtrl.text = r.inputs['instruction'] ?? '';
        _instrChoice = r.inputs['instruction'] ?? '';
        _restoreInstrAttrs(rule, r.inputs['instruction'] ?? '');
        _builtinVoice = r.inputs['voice_id'] ?? '';
        _builtinVoiceCtrl.text = _builtinVoice;
        _voiceId = r.inputs['voice_entry'] ?? '';
        _ttsLanguage = _nn(r.inputs['language']);
        _result = null;
        _restoreEmotion(rule, r);
        final pin = _paramsOf(r);
        for (final i in rule.inputs) {
          final v = pin[i.option];
          if (v != null && v.isNotEmpty) _inputPaths[i.option] = v;
        }
      } else {
        _textCtrl.text = '';
        _audioPath = _nn(r.inputs['audio']);
        _asrLanguage = _nn(r.inputs['language']);
        _result = r.text.isNotEmpty ? r.text : null;
      }
    });
    if (target == null) {
      _toast(dict['workbench.modelMissing'] ?? 'Model not available');
    }
    // 高级参数：按记录 params 回填到配置（供高级弹窗显示），排除情感字段。
    if (r.type == RecordType.tts && r.inputs.containsKey('params')) {
      final p = _paramsOf(r);
      final emoNames = rule.emotion?.occupiedOptions ?? const <String>{};
      final adv = <String, String>{
        for (final e in p.entries)
          if (!emoNames.contains(e.key)) e.key: e.value,
      };
      ref.read(appConfigProvider.notifier).update((c) {
        if (adv.isEmpty) {
          c.modelParams.remove(r.family);
        } else {
          c.modelParams[r.family] = adv;
        }
      });
    }
    // 有音频结果/输入（TTS 结果、ASR 输入音频）都载入播放器，但不播放。
    // 若播放器已是同一条内容，则取消载入，避免打断正在进行的试听。
    if (audioAbs != null) {
      final player = ref.read(audioPlayerProvider);
      final current = player.currentPath;
      if (current == null || !p.equals(current, audioAbs)) {
        player.load(audioAbs, title: _recordTitle(r));
      }
    }
  }

  static String? _nn(String? s) => (s == null || s.isEmpty) ? null : s;

  /// 记录快照里的 params（高级 + 情感字段的 JSON）。
  Map<String, String> _paramsOf(GenerationRecord r) {
    final raw = r.inputs['params'];
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
      }
    } catch (_) {}
    return const {};
  }

  List<double> _parseVector(String s, int len) {
    var t = s.trim();
    if (t.startsWith('[')) t = t.substring(1);
    if (t.endsWith(']')) t = t.substring(0, t.length - 1);
    final parts = t.split(',');
    final out = List<double>.filled(len, 0);
    for (var i = 0; i < len && i < parts.length; i++) {
      out[i] = (double.tryParse(parts[i].trim()) ?? 0).clamp(0, 1).toDouble();
    }
    return out;
  }

  /// 用记录快照回填情感控件（模式/向量/文本/强度/参考音频）。
  void _restoreEmotion(WorkbenchRule rule, GenerationRecord r) {
    final emo = rule.emotion;
    if (emo == null) return;
    _emotionRuleKey = r.family;
    final p = _paramsOf(r);
    _emotionMode = 'none';
    _emotionVector = List<double>.filled(emo.maxDimensions, 0);
    _emotionTextCtrl.text = '';
    _emotionStrength = emo.strengthDefault;
    _emotionAudioPath = _nn(r.inputs['emotion_audio']);
    if (_emotionAudioPath != null) {
      for (final m in emo.modes) {
        if (m.audio) {
          _emotionMode = m.id;
          break;
        }
      }
      if (_emotionMode == 'none' && emo.modes.isNotEmpty) {
        _emotionMode = emo.modes.first.id;
      }
    } else {
      for (final m in emo.modes) {
        if (m.option.isNotEmpty && p[m.option] != null) {
          _emotionMode = m.id;
          if (m.dimensions.isNotEmpty) {
            _emotionVector = _parseVector(p[m.option]!, m.dimensions.length);
          } else {
            _emotionTextCtrl.text = p[m.option]!;
          }
          break;
        }
      }
    }
    if (emo.strengthOption.isNotEmpty && p[emo.strengthOption] != null) {
      _emotionStrength =
          double.tryParse(p[emo.strengthOption]!) ?? emo.strengthDefault;
    }
  }

  Widget _recordTile(Map<String, String> dict, GenerationRecord r) {
    final hasAudio = r.outputs.any((o) => o.kind == 'audio');
    final selected = r.id == _selectedRecordId;
    return ListTile(
      dense: true,
      // 选中态常驻：便于知道当前试听/阅读的是哪条（弹跳高亮点击后即消失）。
      tileColor: selected
          ? Theme.of(context).colorScheme.primaryContainer
          : null,
      // 点击记录：把该次的类型/模型/参数填回工作台（便于直接重新生成）；
      // 有结果的优先展示——TTS 载入播放器（不自动播放），ASR 展示文本。
      onTap: () => _applyRecord(dict, r),
      leading: RecordAvatar(record: r),
      title: Text(_recordTitle(r), maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${_statusText(dict, r.status)} · ${_timeText(r.createdAtMs)}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: dict['session.record.delete'] ?? 'Delete record',
            onPressed: () =>
                ref.read(currentSessionProvider).deleteRecord(r.id),
          ),
          if (r.type == RecordType.asr) ...[
            // ASR：删除、播放（输入音频）、下载（文本）
            if (hasAudio)
              AuditionButton(
                path: _recordAudioAbs(r),
                title: _recordTitle(r),
              ),
            if (r.text.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.save_alt),
                tooltip: dict['session.export'] ?? 'Export',
                onPressed: () => _saveRecordText(r),
              ),
          ] else ...[
            // TTS：删除、下载（音频）、播放
            if (hasAudio)
              IconButton(
                icon: const Icon(Icons.save_alt),
                tooltip: dict['session.export'] ?? 'Export',
                onPressed: () => _saveRecord(r),
              ),
            if (hasAudio)
              AuditionButton(
                path: _recordAudioAbs(r),
                title: _recordTitle(r),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _saveRecord(GenerationRecord r) async {
    final store = ref.read(sessionStoreProvider);
    String? abs;
    for (final o in r.outputs) {
      if (o.kind == 'audio') {
        abs = p.join(store.baseDir.path, o.path);
        break;
      }
    }
    if (abs == null) return;
    final dict = ref.read(stringsProvider);
    final save = await getSaveLocation(suggestedName: 'audio_${r.id}.wav');
    if (save == null) return;
    try {
      await File(abs).copy(save.path);
      _toast(dict['session.saved'] ?? 'Saved');
    } catch (e) {
      _toast('$e');
    }
  }

  Future<void> _saveRecordText(GenerationRecord r) async {
    final text = r.text;
    if (text.isEmpty) return;
    final dict = ref.read(stringsProvider);
    final save = await getSaveLocation(suggestedName: 'transcript_${r.id}.txt');
    if (save == null) return;
    try {
      await File(save.path).writeAsString(text);
      _toast(dict['session.saved'] ?? 'Saved');
    } catch (e) {
      _toast('$e');
    }
  }

  String _statusText(Map<String, String> dict, String s) => switch (s) {
        'generating' => dict['record.status.generating'] ?? 'Generating',
        'failed' => dict['record.status.failed'] ?? 'Failed',
        _ => dict['record.status.done'] ?? 'Done',
      };

  String _timeText(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }

  String _recordTitle(GenerationRecord r) {
    final t = r.inputs['text'] ?? '';
    if (t.isNotEmpty) return t;
    if (r.text.isNotEmpty) return r.text;
    return r.family.isEmpty ? r.type : r.family;
  }

  String? _recordAudioAbs(GenerationRecord r) {
    final store = ref.read(sessionStoreProvider);
    for (final o in r.outputs) {
      if (o.kind == 'audio') return p.join(store.baseDir.path, o.path);
    }
    return null;
  }

  Widget _buildBody(
    Map<String, String> dict,
    ModelCatalogEntry entry,
    String task,
    List<String> languages,
  ) {
    final rules = ref.watch(workbenchRulesProvider).value ?? const {};
    final rule = rules[VariantKey.of(entry.packageId)] ??
        rules[entry.family] ??
        WorkbenchRule.none;
    var advanced = _advancedOptions(_specFor(entry.family), rule);
    // ASR 的 language 由专用语言控件承载，避免与高级重复。
    if (task == 'asr') {
      advanced = advanced.where((o) => o.name != 'language').toList();
    }
    // 情感控制的按 family 初始化/重置（切换模型时）。
    final emotion = rule.emotion;
    if (_emotionRuleKey != entry.family) {
      _emotionRuleKey = entry.family;
      _emotionMode = 'none';
      _emotionVector = List<double>.filled(emotion?.maxDimensions ?? 0, 0);
      _emotionTextCtrl.text = '';
      _emotionStrength = emotion?.strengthDefault ?? 1.0;
      _emotionAudioPath = null;
      _inputPaths.clear();
    } else if (emotion != null && _emotionVector.length != emotion.maxDimensions) {
      _emotionVector = List<double>.filled(emotion.maxDimensions, 0);
    }
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(dict['workbench.model'] ?? 'Model',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: entry.packageId,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      for (final m in _workModelsSorted(
                          ref.read(modelLibraryProvider).entries,
                          {for (final s in ref
                                  .read(specsProvider)
                                  .value ??
                              const <ModelSpec>[])
                            s.family: s}))
                        DropdownMenuItem(
                          value: m.packageId,
                          child: Text(m.displayName),
                        ),
                    ],
                    onChanged: (v) {
                      _rememberModel(v);
                      _noticeTimer?.cancel();
                      // 异步队列：提交后不锁定模型；有任务在跑时不清计时器。
                      final busy = ref.read(generationQueueProvider).busy;
                      setState(() {
                        if (!busy) _clearGenStatus();
                        _selectedPackageId = v;
                        _resetTtsInputs();
                        _result = null;
                        _notice = null;
                      });
                    },
                  ),
                  if (task == 'tts') ...[
                    const SizedBox(height: 16),
                    ..._layoutTop(dict, entry, rule, languages),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _textCtrl,
                      maxLines: 6,
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        hintText:
                            dict['workbench.textHint'] ?? 'Type the text to speak...',
                      ),
                    ),
                  ],
                  if (task == 'asr') ...[
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: _asrLanguageField(dict, languages, rule),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: OutlinedButton.icon(
                            onPressed: _pickAudio,
                            icon: const Icon(Icons.audio_file_outlined),
                            label: Text(
                              _audioPath == null
                                  ? (dict['workbench.pickAudio'] ?? 'Choose audio')
                                  : File(_audioPath!).uri.pathSegments.last,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      if (advanced.isNotEmpty)
                        OutlinedButton.icon(
                          onPressed: () =>
                              _openAdvanced(entry, advanced, dict),
                          icon: const Icon(Icons.tune),
                          label:
                              Text(dict['workbench.advanced'] ?? 'Advanced'),
                        ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: _enqueue,
                        icon: const Icon(Icons.playlist_add),
                        label: Text(dict['workbench.submit'] ?? 'Add task'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_result != null) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            dict['workbench.result'] ?? 'Result',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.content_copy, size: 18),
                          onPressed: () => _copyText(_result!),
                          visualDensity: VisualDensity.compact,
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => setState(() => _result = null),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SelectableText(_result!),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 把 App 音色库中选中的音色解析为服务器请求参数：
  /// 文件音色用 `voice_ref`（参考音频路径），内置/预设音色用 `voice`（预设名）。
  (String?, String?) _resolveVoice() {
    if (_voiceId.isEmpty) return (null, null);
    for (final v in ref.read(voiceLibraryProvider).voices) {
      if (v.id != _voiceId) continue;
      if (v.type == 'file') return (null, v.audioPath);
      return (v.ref, null);
    }
    return (null, null);
  }

  /// 统一的"音色"选择器：本地音色库（模型接受外部音色时）与模型内置音色
  /// 合并为一个下拉，本地在前；内置动态音色用"自定义…"项 + 输入框。
  /// 内置音色下拉项：名称 · 语言 · 描述（有则显示，过长由上层省略）。
  String _voiceItemLabel(String name, VoiceIdRule? vi, String uiLang) {
    final parts = <String>[name];
    final code = vi?.languageFor(name);
    if (code != null && code.isNotEmpty) {
      parts.add(languageLabel(code, uiLang));
    }
    final desc = vi?.descriptionFor(name, uiLang);
    if (desc != null && desc.isNotEmpty) parts.add(desc);
    return parts.join(' · ');
  }

  Widget _voiceSelector(
      Map<String, String> dict, ModelCatalogEntry entry, WorkbenchRule rule) {
    final localVoices = rule.showsReference
        ? ref
            .watch(voiceLibraryProvider)
            .voices
            .where((v) => v.family == null || v.family == entry.family)
            .toList()
        : const <VoiceEntry>[];
    final vi = rule.voiceId;
    final builtinValues = vi?.values ?? const <String>[];
    final builtinDynamic = vi?.isDynamic ?? false;
    final uiLang = ref.watch(localeProvider).code;

    // 当前选中项的编码。
    String? value;
    if (_voiceId.isNotEmpty && localVoices.any((v) => v.id == _voiceId)) {
      value = 'local:$_voiceId';
    } else if (builtinDynamic) {
      value = 'builtin_custom';
    } else if (builtinValues.isNotEmpty) {
      final eff = _effectiveBuiltinVoice(rule);
      if (builtinValues.contains(eff)) value = 'builtin:$eff';
    } else if (rule.showsReference && !rule.referenceRequired) {
      value = '';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          initialValue: value,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            isDense: true,
            labelText: (rule.referenceRequired ? '* ' : '') +
                (dict['workbench.voice'] ?? 'Voice'),
          ),
          items: [
            if (rule.showsReference && !rule.referenceRequired)
              DropdownMenuItem(
                value: '',
                child: Text(dict['workbench.defaultVoice'] ?? 'Default',
                    overflow: TextOverflow.ellipsis),
              ),
            for (final v in localVoices)
              DropdownMenuItem(
                value: 'local:${v.id}',
                child: Text(v.name, overflow: TextOverflow.ellipsis),
              ),
            for (final v in builtinValues)
              DropdownMenuItem(
                value: 'builtin:$v',
                child: Text(_voiceItemLabel(v, vi, uiLang),
                    overflow: TextOverflow.ellipsis),
              ),
            if (builtinDynamic)
              DropdownMenuItem(
                value: 'builtin_custom',
                child: Text(dict['workbench.customVoice'] ?? 'Custom…',
                    overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) => setState(() {
            _refTextCtrl.text = '';
            if (v == null || v.isEmpty) {
              _voiceId = '';
              _builtinVoice = '';
              _builtinVoiceCtrl.text = '';
            } else if (v.startsWith('local:')) {
              _voiceId = v.substring(6);
              _builtinVoice = '';
              _builtinVoiceCtrl.text = '';
              for (final sel in localVoices) {
                if (sel.id != _voiceId) continue;
                final t = sel.text?.trim();
                if (t != null && t.isNotEmpty) _refTextCtrl.text = t;
                break;
              }
            } else if (v == 'builtin_custom') {
              _voiceId = '';
            } else if (v.startsWith('builtin:')) {
              _voiceId = '';
              _builtinVoice = v.substring(8);
              _builtinVoiceCtrl.text = _builtinVoice;
              // 音色与语言对齐时自动填入语言（仍可手动修改）。
              final lang = vi?.languageFor(_builtinVoice);
              if (lang != null) _ttsLanguage = lang;
            }
          }),
        ),
        if (value == 'builtin_custom') ...[
          const SizedBox(height: 8),
          TextField(
            controller: _builtinVoiceCtrl,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              isDense: true,
              labelText: dict['workbench.voiceId'] ?? 'Voice id',
            ),
            onChanged: (v) => _builtinVoice = v.trim(),
          ),
        ],
      ],
    );
  }

  /// 参考文本输入（选自定义音色时显示）。
  Widget _referenceTextField(Map<String, String> dict, WorkbenchRule rule) =>
      TextField(
        controller: _refTextCtrl,
        maxLines: 2,
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          labelText: (rule.referenceTextRequired ? '* ' : '') +
              (dict['workbench.referenceText'] ?? 'Reference text'),
          hintText: dict['workbench.referenceTextHint'] ??
              'Optional: transcript of the reference audio',
        ),
      );

  /// 规则未提供 `layout` 时的通用顺序。
  static const List<String> _defaultLayout = [
    'voice',
    'language',
    'referenceText',
    'emotion',
    'instruction',
    'inputs',
  ];

  /// 顶层布局：规则 `layout`（缺省通用顺序），返回带纵向间距的控件列表。
  List<Widget> _layoutTop(Map<String, String> dict, ModelCatalogEntry entry,
      WorkbenchRule rule, List<String> languages) {
    final nodes = rule.layout.isNotEmpty
        ? rule.layout
        : [for (final t in _defaultLayout) LayoutNode(type: t)];
    return _layoutChildrenOf(nodes, 12, dict, entry, rule, languages);
  }

  /// 依次渲染节点（不适用者跳过），相邻项插入纵向 `spacing`。
  List<Widget> _layoutChildrenOf(List<LayoutNode> nodes, double spacing,
      Map<String, String> dict, ModelCatalogEntry entry, WorkbenchRule rule,
      List<String> languages) {
    final out = <Widget>[];
    for (final n in nodes) {
      final w = _layoutWidget(n, dict, entry, rule, languages);
      if (w == null) continue;
      if (out.isNotEmpty) out.add(SizedBox(height: spacing));
      out.add(w);
    }
    return out;
  }

  /// 渲染子节点为控件列表（不含间距）。
  List<Widget> _layoutWidgetsOf(List<LayoutNode> nodes, Map<String, String> dict,
      ModelCatalogEntry entry, WorkbenchRule rule, List<String> languages) {
    final out = <Widget>[];
    for (final n in nodes) {
      final w = _layoutWidget(n, dict, entry, rule, languages);
      if (w != null) out.add(w);
    }
    return out;
  }

  /// 渲染单个布局节点（容器或控件）；不适用返回 null。
  Widget? _layoutWidget(LayoutNode n, Map<String, String> dict,
      ModelCatalogEntry entry, WorkbenchRule rule, List<String> languages) {
    if (!_whenOk(n.when, rule)) return null;
    switch (n.type) {
      case 'column':
        final kids = _layoutChildrenOf(
            n.children, n.spacing, dict, entry, rule, languages);
        if (kids.isEmpty) return null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: kids,
        );
      case 'fieldset':
        final kids = _layoutChildrenOf(
            n.children, n.spacing, dict, entry, rule, languages);
        if (kids.isEmpty) return null;
        final label =
            ref.read(localeProvider).code == 'zh' ? n.labelZh : n.labelEn;
        return InputDecorator(
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: label.isNotEmpty ? label : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: kids,
          ),
        );
      case 'row':
        final kids = _layoutWidgetsOf(n.children, dict, entry, rule, languages);
        if (kids.isEmpty) return null;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < kids.length; i++) ...[
              if (i > 0) SizedBox(width: n.spacing),
              Expanded(child: kids[i]),
            ],
          ],
        );
      case 'grid':
        final items = _layoutWidgetsOf(n.children, dict, entry, rule, languages);
        if (items.isEmpty) return null;
        return _grid(
            items, n.minItemWidth, n.spacing, n.runSpacing, n.columns);
      case 'spacer':
        return SizedBox(height: n.spacing);
      case 'voice':
        return (rule.showsVoiceId || rule.showsReference)
            ? _voiceSelector(dict, entry, rule)
            : null;
      case 'referenceText':
        return (rule.showsReferenceText && _voiceId.isNotEmpty)
            ? _referenceTextField(dict, rule)
            : null;
      case 'emotion':
        return rule.emotion != null ? _emotionSection(dict, rule.emotion!) : null;
      case 'instruction':
        return rule.instructionShownWithVoice(_hasVoiceSelected(rule))
            ? _instructionField(dict, rule)
            : null;
      case 'inputs':
        return rule.inputs.isNotEmpty ? _inputsSection(dict, rule) : null;
      case 'language':
        return rule.showsLanguage
            ? _ttsLanguageField(dict, languages, rule)
            : null;
      case 'instructionGroup':
        for (final g in rule.instructionGroups) {
          if (g.id == n.group) {
            return _instructionGroupField(dict, g, rule);
          }
        }
        return null;
      default:
        return null;
    }
  }

  /// 自适应栅格：按 `minItemWidth` 决定列数并等宽排布。
  /// `gap` = 列间距；`runSpacing` = 行间距（默认 12）。
  Widget _grid(List<Widget> items, double minItemWidth, double gap,
      [double runSpacing = 12, int columns = 0]) {
    return LayoutBuilder(
      builder: (context, cons) {
        final w = cons.maxWidth.isFinite ? cons.maxWidth : 600.0;
        final minW = minItemWidth <= 0 ? 280.0 : minItemWidth;
        final cols = columns > 0
            ? columns.clamp(1, items.length)
            : ((w + gap) / (minW + gap)).floor().clamp(1, items.length);
        final cellW = (w - gap * (cols - 1)) / cols;
        final rows = <Widget>[];
        for (var i = 0; i < items.length; i += cols) {
          final cells = <Widget>[];
          for (var j = 0; j < cols && i + j < items.length; j++) {
            if (j > 0) cells.add(SizedBox(width: gap));
            cells.add(SizedBox(width: cellW, child: items[i + j]));
          }
          if (rows.isNotEmpty) rows.add(SizedBox(height: runSpacing));
          rows.add(
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: cells));
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: rows,
        );
      },
    );
  }

  /// `when` 条件求值（空=始终；未知条件不拦截）。
  bool _whenOk(String when, WorkbenchRule rule) {
    switch (when) {
      case '':
        return true;
      case 'voice':
        return _hasVoiceSelected(rule);
      case 'noVoice':
        return !_hasVoiceSelected(rule);
      case 'customVoice':
        return _voiceId.isNotEmpty;
      case 'noCustomVoice':
        return _voiceId.isEmpty;
      default:
        return true;
    }
  }

  Widget _ttsLanguageField(
      Map<String, String> dict, List<String> languages, WorkbenchRule rule) {
    final opts = <String>['auto'];
    if (rule.languageDefault.isNotEmpty && rule.languageDefault != 'auto') {
      opts.add(rule.languageDefault);
    }
    // 语言取值：规则 languageValues 覆盖优先，否则规格 languages。
    final src = rule.languageValues.isNotEmpty ? rule.languageValues : languages;
    for (final l in src) {
      if (!opts.contains(l)) opts.add(l);
    }
    // 自动填入的音色语言可能不在列表里，补进去以保证下拉可选。
    if (_ttsLanguage != null &&
        _ttsLanguage!.isNotEmpty &&
        !opts.contains(_ttsLanguage)) {
      opts.add(_ttsLanguage!);
    }
    final raw = _ttsLanguage ?? (rule.languageDefault.isNotEmpty ? rule.languageDefault : 'auto');
    final value = opts.contains(raw) ? raw : 'auto';
    return InputDecorator(
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        isDense: true,
        labelText: dict['workbench.language'] ?? 'Language',
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          isDense: true,
          items: [
            for (final l in opts)
              DropdownMenuItem(value: l, child: Text(l)),
          ],
          onChanged: (v) => setState(() =>
              _ttsLanguage = (v == null || v == 'auto' || v.isEmpty) ? null : v),
        ),
      ),
    );
  }

  /// ASR 通用语言控件：`auto` +（规则 `languageValues` 覆盖，否则规格 `languages`）。
  Widget _asrLanguageField(
      Map<String, String> dict, List<String> languages, WorkbenchRule rule) {
    final opts = <String>['auto'];
    final vals = rule.languageValues.isNotEmpty ? rule.languageValues : languages;
    for (final l in vals) {
      if (!opts.contains(l)) opts.add(l);
    }
    final raw = _asrLanguage ??
        (rule.languageDefault.isNotEmpty ? rule.languageDefault : 'auto');
    final value = opts.contains(raw) ? raw : 'auto';
    return InputDecorator(
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        isDense: true,
        labelText: dict['workbench.language'] ?? 'Language',
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          isDense: true,
          items: [
            for (final l in opts) DropdownMenuItem(value: l, child: Text(l)),
          ],
          onChanged: (v) => setState(() => _asrLanguage =
              (v == null || v == 'auto' || v.isEmpty) ? null : v),
        ),
      ),
    );
  }

}

/// 「高级参数」弹窗：按规格 request options 渲染控件。
/// 返回非 null = 保存（空 map 表示全部用默认）；返回 null = 取消。
class _AdvancedDialog extends StatefulWidget {
  const _AdvancedDialog({
    required this.title,
    required this.options,
    required this.saved,
    required this.dict,
    required this.describe,
    this.extensions = const {},
  });

  final String title;
  final List<SpecOption> options;
  final Map<String, String> saved;
  final Map<String, String> dict;
  final String Function(SpecOption) describe;

  /// 路径参数的允许后缀：option 名 → 后缀列表（不含点）。
  final Map<String, List<String>> extensions;

  @override
  State<_AdvancedDialog> createState() => _AdvancedDialogState();
}

class _AdvancedDialogState extends State<_AdvancedDialog> {
  final Map<String, TextEditingController> _text = {};
  final Map<String, String?> _choice = {};
  final Map<String, double> _numbers = {};
  final Map<String, String> _error = {};

  /// 有上下界的数值参数用滑动条。
  bool _isSlider(SpecOption o) =>
      (o.isInt || o.isFloat) && o.min != null && o.max != null;

  double _defaultNumber(SpecOption o) {
    final min = o.min!.toDouble();
    final max = o.max!.toDouble();
    final d = o.defaultValue;
    final v = d is num ? d.toDouble() : min;
    return v.clamp(min, max);
  }

  /// 值是否等于规格默认值（按类型比较）；无默认值则视为「非默认」。
  bool _isDefault(SpecOption o, String value) {
    final d = o.defaultValue;
    if (d == null) return false;
    if (o.isInt || o.isFloat) {
      final v = num.tryParse(value);
      final dv = d is num ? d : num.tryParse(d.toString());
      if (v == null || dv == null) return false;
      return (v - dv).abs() < 1e-9;
    }
    return value == d.toString();
  }

  @override
  void initState() {
    super.initState();
    for (final o in widget.options) {
      final saved = widget.saved[o.name];
      if (_isSlider(o)) {
        final min = o.min!.toDouble();
        final max = o.max!.toDouble();
        final parsed = double.tryParse(saved ?? '');
        _numbers[o.name] =
            (parsed ?? _defaultNumber(o)).clamp(min, max).toDouble();
      } else if (o.isEnum) {
        _choice[o.name] =
            (saved != null && o.values.contains(saved)) ? saved : '';
      } else if (o.isBool) {
        _choice[o.name] = (saved == 'true' || saved == 'false') ? saved : '';
      } else {
        _text[o.name] = TextEditingController(text: saved ?? '');
      }
    }
  }

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _defaultOf(SpecOption o) =>
      o.defaultValue == null ? '' : o.defaultValue.toString();

  String _defaultLabel(SpecOption o) {
    final v = _defaultOf(o);
    if (v.isEmpty) return widget.dict['workbench.default'] ?? 'Default';
    return dictTpl(widget.dict, 'workbench.defaultValue', {'value': v});
  }

  void _reset() {
    setState(() {
      for (final o in widget.options) {
        if (_isSlider(o)) {
          _numbers[o.name] = _defaultNumber(o);
        } else if (o.isEnum || o.isBool) {
          _choice[o.name] = '';
        } else {
          _text[o.name]?.text = '';
        }
      }
      _error.clear();
    });
  }

  void _save() {
    final out = <String, String>{};
    final errs = <String, String>{};
    for (final o in widget.options) {
      if (_isSlider(o)) {
        final v = _numbers[o.name] ?? _defaultNumber(o);
        final s = o.isInt ? v.round().toString() : v.toString();
        if (_isDefault(o, s)) continue; // 等于规格默认值：不提交
        out[o.name] = s;
        continue;
      }
      if (o.isEnum || o.isBool) {
        final v = _choice[o.name];
        if (v != null && v.isNotEmpty && !_isDefault(o, v)) out[o.name] = v;
        continue;
      }
      final raw = _text[o.name]?.text.trim() ?? '';
      if (raw.isEmpty) continue;
      if (o.isInt || o.isFloat) {
        final n = num.tryParse(raw);
        if (n == null ||
            (o.min != null && n < o.min!) ||
            (o.max != null && n > o.max!)) {
          errs[o.name] = dictTpl(
              widget.dict, 'workbench.invalidValue', {'name': o.name});
          continue;
        }
      }
      // 与规格默认值相同（按类型比较）：视为未设置，不提交。
      if (_isDefault(o, raw)) continue;
      out[o.name] = raw;
    }
    if (errs.isNotEmpty) {
      setState(() {
        _error
          ..clear()
          ..addAll(errs);
      });
      return;
    }
    Navigator.of(context).pop(out);
  }

  Widget _dropdown(SpecOption o, List<DropdownMenuItem<String>> items) {
    return InputDecorator(
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
        isDense: true,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _choice[o.name] ?? '',
          isExpanded: true,
          isDense: true,
          items: items,
          onChanged: (v) => setState(() => _choice[o.name] = v ?? ''),
        ),
      ),
    );
  }

  Widget _slider(SpecOption o) {
    final min = o.min!.toDouble();
    final max = o.max!.toDouble();
    final v = (_numbers[o.name] ?? _defaultNumber(o)).clamp(min, max).toDouble();
    final divisions =
        o.isInt ? ((max - min).round()).clamp(1, 1000).toInt() : null;
    final display = o.isInt ? v.round().toString() : v.toStringAsFixed(3);
    return Row(
      children: [
        Expanded(
          child: Slider(
            value: v,
            min: min,
            max: max,
            divisions: divisions,
            label: display,
            onChanged: (nv) => setState(() {
              _numbers[o.name] = o.isInt ? nv.roundToDouble() : nv;
            }),
          ),
        ),
        SizedBox(
          width: 56,
          child: Text(display, textAlign: TextAlign.end),
        ),
      ],
    );
  }

  Widget _control(SpecOption o) {
    if (_isSlider(o)) {
      return _slider(o);
    }
    if (o.isEnum) {
      return _dropdown(o, [
        DropdownMenuItem<String>(value: '', child: Text(_defaultLabel(o))),
        for (final v in o.values)
          DropdownMenuItem<String>(value: v, child: Text(v)),
      ]);
    }
    if (o.isBool) {
      return _dropdown(o, [
        DropdownMenuItem<String>(value: '', child: Text(_defaultLabel(o))),
        const DropdownMenuItem<String>(value: 'true', child: Text('true')),
        const DropdownMenuItem<String>(value: 'false', child: Text('false')),
      ]);
    }
    return TextField(
      controller: _text[o.name],
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        isDense: true,
        hintText: _defaultOf(o),
        errorText: _error[o.name],
        suffixIcon: o.isPath
            ? IconButton(
                icon: const Icon(Icons.folder_open, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: () => _pickPath(o),
              )
            : null,
      ),
    );
  }

  Future<void> _pickPath(SpecOption o) async {
    // audio_path 直接提交路径（不转码）→ 缺省仅 WAV。
    const audioExt = ['wav'];
    final override = widget.extensions[o.name] ?? const <String>[];
    final ext = override.isNotEmpty
        ? override
        : (o.type == 'audio_path' ? audioExt : const <String>[]);
    final f = await openFile(acceptedTypeGroups: [
      if (ext.isNotEmpty)
        XTypeGroup(
            label: o.type == 'audio_path' ? 'Audio' : 'File', extensions: ext),
    ]);
    if (f == null) return;
    setState(() => _text[o.name]?.text = f.path);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final o in widget.options)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 168,
                        child: Tooltip(
                          message: widget.describe(o),
                          child: Text(
                            o.name,
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: _control(o)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _reset,
          child: Text(widget.dict['workbench.reset'] ?? 'Reset'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.dict['common.cancel'] ?? 'Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: Text(widget.dict['common.save'] ?? 'Save'),
        ),
      ],
    );
  }
}