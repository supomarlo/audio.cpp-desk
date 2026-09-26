import 'dart:convert';

import 'package:flutter/services.dart' show AssetManifest, rootBundle;

/// 解析 `instructionLabelTooltip`：`none` / `title` / 自定义字符串 / `{en,zh}`。
({String mode, String en, String zh}) _tooltipCfg(dynamic raw) {
  if (raw is Map) {
    return (
      mode: 'custom',
      en: raw['en']?.toString() ?? '',
      zh: raw['zh']?.toString() ?? ''
    );
  }
  if (raw is String) {
    if (raw == 'none') return (mode: 'none', en: '', zh: '');
    if (raw == 'title' || raw.isEmpty) {
      return (mode: 'title', en: '', zh: '');
    }
    return (mode: 'custom', en: raw, zh: raw);
  }
  return (mode: 'title', en: '', zh: '');
}

/// 内置音色（voiceId）规则。
class VoiceIdRule {
  const VoiceIdRule(
      {this.values,
      this.defaultValue = '',
      this.isDynamic = false,
      this.option = '',
      this.voiceLanguage = const {},
      this.voiceDesc = const {}});

  final List<String>? values;
  final String defaultValue;
  final bool isDynamic;

  /// 内置音色提交到的 request option 名；为空则走顶层 `voice`。
  final String option;

  /// 音色 → 语言代码（键为音色名或其前缀，如 "af_"→"en-us"）。
  final Map<String, String> voiceLanguage;

  /// 音色 → 多语言描述（键为音色名或前缀；值为 {语言: 文本}）。
  final Map<String, Map<String, String>> voiceDesc;

  static T? _match<T>(Map<String, T> map, String voice) {
    if (voice.isEmpty || map.isEmpty) return null;
    if (map.containsKey(voice)) return map[voice];
    String? bestKey;
    var bestLen = -1;
    map.forEach((k, _) {
      if (k.isNotEmpty && voice.startsWith(k) && k.length > bestLen) {
        bestKey = k;
        bestLen = k.length;
      }
    });
    return bestKey == null ? null : map[bestKey];
  }

  /// 按音色名查语言代码。
  String? languageFor(String voice) => _match(voiceLanguage, voice);

  /// 按音色名查描述（按界面语言，回退英文）。
  String? descriptionFor(String voice, String uiLang) {
    final m = _match(voiceDesc, voice);
    if (m == null || m.isEmpty) return null;
    return m[uiLang] ?? m['en'] ?? m.values.first;
  }

  static Map<String, String> _langs(dynamic raw) => raw is Map
      ? raw.map((k, v) => MapEntry(k.toString(), v.toString()))
      : const {};

  static Map<String, Map<String, String>> _descs(dynamic raw) => raw is Map
      ? raw.map((k, v) => MapEntry(
          k.toString(),
          v is Map
              ? v.map((k2, v2) => MapEntry(k2.toString(), v2.toString()))
              : const <String, String>{}))
      : const {};

  static VoiceIdRule fromJson(Map<String, dynamic> json) {
    final langs = _langs(json['voiceLanguage']);
    final descs = _descs(json['voiceDesc']);
    final option = json['option'] as String? ?? '';
    if (json['dynamic'] == true) {
      return VoiceIdRule(
          isDynamic: true,
          option: option,
          voiceLanguage: langs,
          voiceDesc: descs);
    }
    final raw = json['values'];
    return VoiceIdRule(
      values: raw is List ? raw.map((e) => e.toString()).toList() : null,
      defaultValue: json['default'] as String? ?? '',
      option: option,
      voiceLanguage: langs,
      voiceDesc: descs,
    );
  }
}

/// 常见语言代码 → 名称（按界面语言，中/英）。
const Map<String, Map<String, String>> kLanguageLabels = {
  'zh': {'zh': '中文', 'en': 'Chinese'},
  'en': {'zh': '英语', 'en': 'English'},
  'en-us': {'zh': '美式英语', 'en': 'American English'},
  'en-gb': {'zh': '英式英语', 'en': 'British English'},
  'ja': {'zh': '日语', 'en': 'Japanese'},
  'ko': {'zh': '韩语', 'en': 'Korean'},
  'de': {'zh': '德语', 'en': 'German'},
  'fr': {'zh': '法语', 'en': 'French'},
  'es': {'zh': '西班牙语', 'en': 'Spanish'},
  'ru': {'zh': '俄语', 'en': 'Russian'},
  'pt': {'zh': '葡萄牙语', 'en': 'Portuguese'},
  'it': {'zh': '意大利语', 'en': 'Italian'},
  'hi': {'zh': '印地语', 'en': 'Hindi'},
  'ar': {'zh': '阿拉伯语', 'en': 'Arabic'},
  'vi': {'zh': '越南语', 'en': 'Vietnamese'},
  'nl': {'zh': '荷兰语', 'en': 'Dutch'},
  'pl': {'zh': '波兰语', 'en': 'Polish'},
  'tr': {'zh': '土耳其语', 'en': 'Turkish'},
};

/// 语言代码 → 界面语言下的名称。
String languageLabel(String code, String uiLang) {
  final m = kLanguageLabels[code];
  return m?[uiLang] ?? m?['en'] ?? code;
}

/// 情感向量的一维：id 为写入顺序中的标识，label 由规则提供（中英）。
class EmotionDim {
  const EmotionDim({required this.id, this.en = '', this.zh = ''});

  final String id;
  final String en;
  final String zh;

  String label(String locale) {
    final v = locale == 'zh' ? zh : en;
    if (v.isNotEmpty) return v;
    return en.isNotEmpty ? en : id;
  }

  static EmotionDim fromJson(dynamic json) {
    if (json is String) return EmotionDim(id: json);
    if (json is Map) {
      return EmotionDim(
        id: json['id']?.toString() ?? '',
        en: json['en']?.toString() ?? '',
        zh: json['zh']?.toString() ?? '',
      );
    }
    return const EmotionDim(id: '');
  }
}

/// 情感控制的一个模式（由规则声明）：参考音频 / 向量 / 文本 等。
class EmotionMode {
  const EmotionMode({
    required this.id,
    this.audio = false,
    this.option = '',
    this.enabledOption = '',
    this.dimensions = const [],
    this.strength = false,
  });

  /// 模式 id（通用：reference / vector / text）。
  final String id;

  /// 参考音频模式（经 inputs['emotion_audio'] 提交）。
  final bool audio;

  /// 写入的字段（vector / text）。
  final String option;

  /// 启用开关字段（text，如 use_emotion_text）。
  final String enabledOption;

  /// 向量维度（vector；顺序即写入顺序）。
  final List<EmotionDim> dimensions;

  /// 该模式是否显示 / 提交强度。
  final bool strength;

  static EmotionMode? fromJson(dynamic json) {
    if (json is! Map) return null;
    final id = json['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    return EmotionMode(
      id: id,
      audio: json['audio'] == true,
      option: json['option']?.toString() ?? '',
      enabledOption: json['enabledOption']?.toString() ?? '',
      dimensions: json['dimensions'] is List
          ? (json['dimensions'] as List)
              .map(EmotionDim.fromJson)
              .where((d) => d.id.isNotEmpty)
              .toList()
          : const [],
      strength: json['strength'] == true,
    );
  }
}

/// 通用「情感」控件规则（由模型规则声明，desk 通用渲染）。
///
/// 「无」+ 规则声明的各模式（reference/vector/text…）；强度字段与范围可选。
class EmotionRule {
  const EmotionRule({
    this.noneLabelEn = '',
    this.noneLabelZh = '',
    this.strengthOption = '',
    this.strengthDefault = 1.0,
    this.strengthMin = 0.0,
    this.strengthMax = 1.0,
    this.modes = const [],
  });

  /// 「不指定情感」这一项的文案（模型相关；缺省用通用「默认」）。
  final String noneLabelEn;
  final String noneLabelZh;

  /// 强度字段（如 emotion_alpha）与范围。
  final String strengthOption;
  final double strengthDefault;
  final double strengthMin;
  final double strengthMax;

  /// 模式列表（顺序即下拉顺序）。
  final List<EmotionMode> modes;

  String? noneLabel(String locale) {
    final v = locale == 'zh' ? noneLabelZh : noneLabelEn;
    return v.isEmpty ? null : v;
  }

  /// 本控件占用的所有 request option 名（用于从「高级」中排除）。
  Set<String> get occupiedOptions {
    final s = <String>{};
    if (strengthOption.isNotEmpty) s.add(strengthOption);
    for (final m in modes) {
      if (m.option.isNotEmpty) s.add(m.option);
      if (m.enabledOption.isNotEmpty) s.add(m.enabledOption);
    }
    return s;
  }

  EmotionMode? modeById(String id) {
    for (final m in modes) {
      if (m.id == id) return m;
    }
    return null;
  }

  int get maxDimensions =>
      modes.fold(0, (a, m) => m.dimensions.length > a ? m.dimensions.length : a);

  static EmotionRule? fromJson(dynamic json) {
    if (json is! Map) return null;
    double d(dynamic v, double fallback) => v is num ? v.toDouble() : fallback;
    final none = json['noneLabel'];
    String noneV(String k) => (none is Map ? none[k]?.toString() : null) ?? '';
    final st = json['strength'];
    final modes = json['modes'] is List
        ? (json['modes'] as List)
            .map(EmotionMode.fromJson)
            .whereType<EmotionMode>()
            .toList()
        : <EmotionMode>[];
    if (modes.isEmpty) return null;
    return EmotionRule(
      noneLabelEn: noneV('en'),
      noneLabelZh: noneV('zh'),
      strengthOption: (st is Map ? st['option']?.toString() : null) ?? '',
      strengthDefault: st is Map ? d(st['default'], 1.0) : 1.0,
      strengthMin: st is Map ? d(st['min'], 0.0) : 0.0,
      strengthMax: st is Map ? d(st['max'], 1.0) : 1.0,
      modes: modes,
    );
  }
}

/// 规则声明的额外文件输入（音频 / 视频 / 路径）：独立控件，提交到 `options.<option>`。
class InputSpec {
  const InputSpec({
    required this.option,
    this.type = 'path',
    this.labelEn = '',
    this.labelZh = '',
    this.extensions = const [],
  });

  /// 提交的 request option 名。
  final String option;

  /// `audio_path` | `path`。
  final String type;
  final String labelEn;
  final String labelZh;

  /// 允许的后缀（不含点）；为空则按类型取默认（audio→音频后缀，path→任意）。
  final List<String> extensions;

  bool get isAudio => type == 'audio_path';

  String label(String locale) {
    final v = locale == 'zh' ? labelZh : labelEn;
    if (v.isNotEmpty) return v;
    return labelEn.isNotEmpty ? labelEn : option;
  }

  static InputSpec? fromJson(dynamic json) {
    if (json is! Map) return null;
    final option = json['option']?.toString() ?? '';
    if (option.isEmpty) return null;
    final label = json['label'];
    String lv(String k) => (label is Map ? label[k]?.toString() : null) ?? '';
    return InputSpec(
      option: option,
      type: json['type']?.toString() ?? 'path',
      labelEn: lv('en'),
      labelZh: lv('zh'),
      extensions: (json['extensions'] as List<dynamic>? ?? [])
          .map((e) => e.toString().replaceAll('.', ''))
          .toList(),
    );
  }
}

/// 「分组属性」指令（`instructionType: attributes`）中的一个可选值。
class InstructionOption {
  const InstructionOption({required this.value, this.en = '', this.zh = ''});

  /// 提交给后端的值（原样）。
  final String value;
  final String en;
  final String zh;

  String label(String locale) {
    final v = locale == 'zh' ? zh : en;
    if (v.isNotEmpty) return v;
    return en.isNotEmpty ? en : value;
  }

  static InstructionOption? fromJson(dynamic json) {
    if (json is String) return InstructionOption(value: json);
    if (json is Map) {
      final value = json['value']?.toString() ?? '';
      if (value.isEmpty) return null;
      return InstructionOption(
        value: value,
        en: json['en']?.toString() ?? '',
        zh: json['zh']?.toString() ?? '',
      );
    }
    return null;
  }
}

/// 「分组属性」指令的一个类别（类别内单选，类别间可组合）。
class InstructionGroup {
  const InstructionGroup(
      {required this.id,
      this.en = '',
      this.zh = '',
      this.values = const []});

  final String id;
  final String en;
  final String zh;
  final List<InstructionOption> values;

  String label(String locale) {
    final v = locale == 'zh' ? zh : en;
    if (v.isNotEmpty) return v;
    return en.isNotEmpty ? en : id;
  }

  static InstructionGroup? fromJson(dynamic json) {
    if (json is! Map) return null;
    final id = json['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    return InstructionGroup(
      id: id,
      en: json['en']?.toString() ?? '',
      zh: json['zh']?.toString() ?? '',
      values: (json['values'] as List<dynamic>? ?? [])
          .map(InstructionOption.fromJson)
          .whereType<InstructionOption>()
          .toList(),
    );
  }
}

/// 工作台布局节点（声明式、可递归）。
///
/// 容器：`column` / `row` / `grid`（按 `minItemWidth` 自适应列数）
/// 控件：`voice` / `referenceText` / `emotion` / `instruction` /
/// `language` / `inputs`；`spacer` 为占位。
class LayoutNode {
  const LayoutNode({
    required this.type,
    this.when = '',
    this.spacing = 12,
    this.runSpacing = 12,
    this.minItemWidth = 280,
    this.columns = 0,
    this.flex = 1,
    this.group = '',
    this.labelEn = '',
    this.labelZh = '',
    this.children = const [],
  });

  final String type;

  /// `instructionGroup`：分组属性的组 id。
  final String group;

  /// `fieldset`：容器标题。
  final String labelEn;
  final String labelZh;

  /// 附加显隐条件（空=始终显示）。见文档 `when`。
  final String when;

  /// 容器（column/row/grid）内**列间距**。
  final double spacing;

  /// `grid`：**行间距**（默认 12）。
  final double runSpacing;

  /// `grid`：每项最小宽度（据此**自适应列数**；被 `columns` 覆盖）。
  final double minItemWidth;

  /// `grid`：**固定列数**（>0 时不自适应，恒为该列数）。
  final int columns;

  /// `spacer`：占位权重。
  final int flex;

  final List<LayoutNode> children;

  static LayoutNode? fromJson(dynamic json) {
    if (json is! Map) return null;
    final type = json['type']?.toString() ?? '';
    if (type.isEmpty) return null;
    final label = json['label'];
    String lv(String k) => (label is Map ? label[k]?.toString() : '') ?? '';
    return LayoutNode(
      type: type,
      when: json['when']?.toString() ?? '',
      spacing: (json['spacing'] as num?)?.toDouble() ?? 12,
      runSpacing: (json['runSpacing'] as num?)?.toDouble() ?? 12,
      minItemWidth: (json['minItemWidth'] as num?)?.toDouble() ?? 280,
      columns: (json['columns'] as num?)?.toInt() ?? 0,
      flex: (json['flex'] as num?)?.toInt() ?? 1,
      group: json['group']?.toString() ?? '',
      labelEn: lv('en'),
      labelZh: lv('zh'),
      children: (json['children'] as List<dynamic>? ?? [])
          .map(LayoutNode.fromJson)
          .whereType<LayoutNode>()
          .toList(),
    );
  }
}

/// 单个 family / 变体的工作台字段规则（见 assets/workbench_rules/ 下同名文件）。
///
/// 决定工作台控件的显示 / 隐藏 / 必填，以及提交给 audio.cpp 的字段。
class WorkbenchRule {
  const WorkbenchRule({
    this.reference = 'hidden',
    this.referenceText = 'hidden',
    this.voiceId,
    this.instruction = 'hidden',
    this.instructionKey = 'instruction',
    this.instructionType = 'text',
    this.instructionValues = const [],
    this.instructionGroups = const [],
    this.instructionLabelWidth = 84,
    this.instructionLabelTooltipMode = 'title',
    this.instructionLabelTooltipEn = '',
    this.instructionLabelTooltipZh = '',
    this.instructionOptions = const {},
    this.instructionWhen = 'always',
    this.emotion,
    this.inputs = const [],
    this.layout = const [],
    this.hiddenOptions = const [],
    this.optionTypes = const {},
    this.optionExtensions = const {},
    this.fields = const {},
    this.language = 'hidden',
    this.languageDefault = '',
    this.languageValues = const [],
    this.requiredInputs = const [],
    this.source = '',
  });

  /// required | optional | hidden
  final String reference;

  /// required | optional | hidden
  final String referenceText;

  final VoiceIdRule? voiceId;

  /// required | optional | hidden
  final String instruction;

  /// 指令字段名（如 instruction / instruct / emotion_text / system_prompt）
  final String instructionKey;

  /// 指令控件类型：`text`（默认）或 `enum`。
  final String instructionType;

  /// 指令为 enum 时的可选值。
  final List<String> instructionValues;

  /// `instructionType='attributes'` 时的分组属性（组内单选、跨组组合）。
  final List<InstructionGroup> instructionGroups;

  /// 分组属性**标签宽度**（像素；默认 84，可放宽以容纳较长的英文标题）。
  final double instructionLabelWidth;

  /// 分组属性**标签 tooltip 模式**（仅标题过长时触发）：
  /// `none` 不输出 / `title` 显示完整标题（默认）/ `custom` 显示自定义文案。
  final String instructionLabelTooltipMode;
  final String instructionLabelTooltipEn;
  final String instructionLabelTooltipZh;

  /// 自定义 tooltip 文案（按界面语言；空则回退完整标题）。
  String instructionLabelTooltip(String locale) {
    final v = locale == 'zh' ? instructionLabelTooltipZh : instructionLabelTooltipEn;
    if (v.isNotEmpty) return v;
    return instructionLabelTooltipEn.isNotEmpty
        ? instructionLabelTooltipEn
        : instructionLabelTooltipZh;
  }

  /// 指令的伴随固定选项：指令非空时随指令一并提交（如 {"use_emotion_text":"true"}）。
  final Map<String, String> instructionOptions;

  /// 指令控件的显示条件：`always`（默认，始终显示）| `no-voice`
  /// （已选音色时不显示、也不提交；用于「给了参考音色后指令无效」的模型）。
  final String instructionWhen;

  /// 通用情感控制（为 null 则无此控件）。
  final EmotionRule? emotion;

  /// 规则声明的额外文件输入（音频/视频/路径）。
  final List<InputSpec> inputs;

  /// 音色相关控件的**布局树**（模型专属；为空用软件通用顺序）。
  /// 顶层为节点列表（隐式纵向排列）；节点见 `LayoutNode`。
  final List<LayoutNode> layout;

  /// 从「高级」中隐藏的 request option 名（已由其它方式覆盖或无需展示）。
  final List<String> hiddenOptions;

  /// 「高级」里某参数的控件类型覆盖：option 名 → type（如 path/audio_path）。
  final Map<String, String> optionTypes;

  /// 「高级」里路径参数允许的后缀：option 名 → ["pth","pt"]（不含点）。
  final Map<String, List<String>> optionExtensions;

  /// 模型相关的提交字段名覆盖：控制项 → audio.cpp 的 request option 名。
  /// 缺省用软件内置的通用名（如 referenceText→reference_text）。
  final Map<String, String> fields;

  /// 取某控制项对应的提交字段名（规则覆盖优先）。
  String fieldFor(String control, String fallback) =>
      fields[control] ?? fallback;

  /// required | optional | hidden
  final String language;

  /// 默认语言（可为空）
  final String languageDefault;

  /// 语言下拉的取值覆盖（模型相关，如完整语言名）；为空则用规格 `languages`。
  final List<String> languageValues;

  /// 其它必需输入（记录，工作台暂不渲染）
  final List<String> requiredInputs;

  /// 依据来源（spec / docs / 上游）
  final String source;

  static const none = WorkbenchRule();

  bool get showsReference => reference != 'hidden';
  bool get showsReferenceText => referenceText != 'hidden';
  bool get showsVoiceId => voiceId != null;
  bool get showsInstruction => instruction != 'hidden';

  /// 在 [showsInstruction] 基础上叠加 `instructionWhen` 条件：
  /// `no-voice` 时仅在未选音色（[hasVoice] 为 false）时显示 / 提交。
  bool instructionShownWithVoice(bool hasVoice) =>
      showsInstruction && (instructionWhen != 'no-voice' || !hasVoice);
  bool get showsLanguage => language != 'hidden';

  bool get referenceRequired => reference == 'required';
  bool get referenceTextRequired => referenceText == 'required';
  bool get instructionRequired => instruction == 'required';
  bool get languageRequired => language == 'required';

  static WorkbenchRule fromJson(Map<String, dynamic> json) => WorkbenchRule(
        reference: json['reference'] as String? ?? 'hidden',
        referenceText: json['referenceText'] as String? ?? 'hidden',
        voiceId: json['voiceId'] is Map
            ? VoiceIdRule.fromJson(
                Map<String, dynamic>.from(json['voiceId'] as Map))
            : null,
        instruction: json['instruction'] as String? ?? 'hidden',
        instructionKey: json['instructionKey'] as String? ?? 'instruction',
        instructionType: json['instructionType'] as String? ?? 'text',
        instructionValues: (json['instructionValues'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
        instructionGroups: (json['instructionGroups'] as List<dynamic>? ?? [])
            .map(InstructionGroup.fromJson)
            .whereType<InstructionGroup>()
            .toList(),
        instructionLabelWidth:
            (json['instructionLabelWidth'] as num?)?.toDouble() ?? 84,
        instructionLabelTooltipMode:
            _tooltipCfg(json['instructionLabelTooltip']).mode,
        instructionLabelTooltipEn: _tooltipCfg(json['instructionLabelTooltip']).en,
        instructionLabelTooltipZh: _tooltipCfg(json['instructionLabelTooltip']).zh,
        instructionOptions: json['instructionOptions'] is Map
            ? (json['instructionOptions'] as Map)
                .map((k, v) => MapEntry(k.toString(), v.toString()))
            : const {},
        instructionWhen: json['instructionWhen'] as String? ?? 'always',
        emotion: EmotionRule.fromJson(json['emotion']),
        inputs: (json['inputs'] as List<dynamic>? ?? [])
            .map(InputSpec.fromJson)
            .whereType<InputSpec>()
            .toList(),
        layout: (json['layout'] as List<dynamic>? ?? [])
            .map(LayoutNode.fromJson)
            .whereType<LayoutNode>()
            .toList(),
        hiddenOptions: (json['hiddenOptions'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
        optionTypes: json['optionTypes'] is Map
            ? (json['optionTypes'] as Map)
                .map((k, v) => MapEntry(k.toString(), v.toString()))
            : const {},
        optionExtensions: json['optionExtensions'] is Map
            ? (json['optionExtensions'] as Map).map((k, v) => MapEntry(
                k.toString(),
                v is List
                    ? v.map((e) => e.toString().replaceAll('.', '')).toList()
                    : const <String>[]))
            : const {},
        fields: json['fields'] is Map
            ? (json['fields'] as Map)
                .map((k, v) => MapEntry(k.toString(), v.toString()))
            : const {},
        language: json['language'] as String? ?? 'hidden',
        languageDefault: json['languageDefault'] as String? ?? '',
        languageValues: (json['languageValues'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
        requiredInputs: (json['requiredInputs'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
        source: json['source'] as String? ?? '',
      );
}

class WorkbenchRules {
  static Map<String, WorkbenchRule>? _cache;

  static Future<Map<String, WorkbenchRule>> load() async {
    if (_cache != null) return _cache!;
    final out = <String, WorkbenchRule>{};
    try {
      // 规则按模型分文件：assets/workbench_rules/<family>.json，
      // 与 assets/model_specs_app/ 对应，便于按模型增量维护。
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final files = manifest
          .listAssets()
          .where((k) =>
              k.startsWith('assets/workbench_rules/') && k.endsWith('.json'))
          .toList();
      for (final path in files) {
        try {
          final raw = await rootBundle.loadString(path);
          final json = jsonDecode(raw);
          if (json is Map) {
            json.forEach((k, v) {
              if (v is Map) {
                out[k.toString()] =
                    WorkbenchRule.fromJson(Map<String, dynamic>.from(v));
              }
            });
          }
        } catch (_) {}
      }
    } catch (_) {}
    return _cache = out;
  }
}
