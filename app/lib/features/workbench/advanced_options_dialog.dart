import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../models/model_spec.dart';
import '../../providers/app_providers.dart';

/// 「高级参数」弹窗：按规格 request options 渲染控件。
/// 返回非 null = 保存（空 map 表示全部用默认）；返回 null = 取消。
class AdvancedOptionsDialog extends StatefulWidget {
  const AdvancedOptionsDialog({
    super.key,
    required this.title,
    required this.options,
    required this.saved,
    required this.dict,
    required this.describe,
    this.extensions = const {},
    this.placeholderFor,
    this.valueLabelFor,
    this.enabledFor,
    this.disabledHintFor,
    this.stepFor,
  });

  final String title;
  final List<SpecOption> options;
  final Map<String, String> saved;
  final Map<String, String> dict;
  final String Function(SpecOption) describe;

  /// 路径参数的允许后缀：option 名 → 后缀列表（不含点）。
  final Map<String, List<String>> extensions;

  /// 动态 placeholder：模型 Widget 可按当前选项值提供。
  final String Function(String name, Map<String, String> values)?
      placeholderFor;

  /// 模型专属的枚举值翻译；返回空表示使用原始值。
  final String Function(SpecOption option, String value)? valueLabelFor;

  /// 模型专属的启用条件；返回 false 时控件仍保留值但不可操作。
  final bool Function(String name, Map<String, String> values)? enabledFor;

  /// 控件禁用时显示在控件上的原因提示。
  final String Function(String name, Map<String, String> values)?
      disabledHintFor;

  /// 滑动条步进；仅对同时具备 min/max 的数值参数生效。
  final double? Function(SpecOption option)? stepFor;

  @override
  State<AdvancedOptionsDialog> createState() => _AdvancedOptionsDialogState();
}

class _AdvancedOptionsDialogState extends State<AdvancedOptionsDialog> {
  final Map<String, TextEditingController> _text = {};
  final Map<String, String?> _choice = {};
  final Map<String, double> _numbers = {};
  final Map<String, String> _error = {};

  bool _isSlider(SpecOption o) =>
      (o.isInt || o.isFloat) && o.min != null && o.max != null;

  double _defaultNumber(SpecOption o) {
    final min = o.min!.toDouble();
    final max = o.max!.toDouble();
    final d = o.defaultValue;
    final v = d is num ? d.toDouble() : min;
    return v.clamp(min, max);
  }

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
        final fallback = _defaultOf(o);
        _choice[o.name] = (saved != null && o.values.contains(saved))
            ? saved
            : (o.values.contains(fallback) ? fallback : '');
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

  bool _enabled(SpecOption o) =>
      widget.enabledFor?.call(o.name, _currentChoices()) ?? true;

  Map<String, String> _currentChoices() {
    final out = <String, String>{
      for (final e in _choice.entries)
        if (e.value != null && e.value!.isNotEmpty) e.key: e.value!,
    };
    for (final e in _text.entries) {
      final value = e.value.text.trim();
      if (value.isNotEmpty) out[e.key] = value;
    }
    for (final e in _numbers.entries) {
      out[e.key] = e.value.toString();
    }
    return out;
  }

  String _valueLabel(SpecOption o, String value) {
    final label = widget.valueLabelFor?.call(o, value) ?? '';
    return label.isEmpty ? value : label;
  }

  String _placeholderOf(SpecOption o) {
    final dynamicValue =
        widget.placeholderFor?.call(o.name, _currentChoices()) ?? '';
    return dynamicValue.isNotEmpty ? dynamicValue : _defaultOf(o);
  }

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
        } else if (o.isEnum) {
          final fallback = _defaultOf(o);
          _choice[o.name] = o.values.contains(fallback) ? fallback : '';
        } else if (o.isBool) {
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
        final step = widget.stepFor?.call(o);
        final s = o.isInt
            ? v.round().toString()
            : step != null && step > 0
                ? (o.min! + ((v - o.min!) / step).round() * step)
                    .toStringAsFixed(
                    step >= 0.1
                        ? 1
                        : step >= 0.01
                            ? 2
                            : step >= 0.001
                                ? 3
                                : 6,
                  )
                : v.toString();
        if (_isDefault(o, s)) continue;
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
          errs[o.name] =
              widget.dict['workbench.invalidValue'] ?? 'Invalid value';
          continue;
        }
      }
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

  Widget _dropdown(
    SpecOption o,
    List<DropdownMenuItem<String>> items,
    bool enabled,
  ) {
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
          focusColor: Colors.transparent,
          items: items,
          onChanged:
              enabled ? (v) => setState(() => _choice[o.name] = v ?? '') : null,
        ),
      ),
    );
  }

  Widget _slider(SpecOption o, bool enabled) {
    final min = o.min!.toDouble();
    final max = o.max!.toDouble();
    final v =
        (_numbers[o.name] ?? _defaultNumber(o)).clamp(min, max).toDouble();
    final step = widget.stepFor?.call(o);
    final divisions = step != null && step > 0
        ? ((max - min) / step).round().clamp(1, 1000).toInt()
        : o.isInt
            ? ((max - min).round()).clamp(1, 1000).toInt()
            : null;
    final display = o.isInt
        ? v.round().toString()
        : step != null && step >= 0.1
            ? v.toStringAsFixed(1)
            : step != null
                ? v.toStringAsFixed(2)
                : v.toStringAsFixed(3);
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Row(
        children: [
          Expanded(
            child: Slider(
              value: v,
              min: min,
              max: max,
              divisions: divisions,
              label: display,
              onChanged: enabled
                  ? (nv) => setState(() {
                        _numbers[o.name] = o.isInt ? nv.roundToDouble() : nv;
                      })
                  : null,
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(display, textAlign: TextAlign.end),
          ),
        ],
      ),
    );
  }

  Widget _boolSwitch(SpecOption o, bool enabled) {
    final raw = _choice[o.name];
    final defaultValue = o.defaultValue == true;
    final value = raw == 'true'
        ? true
        : raw == 'false'
            ? false
            : defaultValue;
    return Align(
      alignment: Alignment.centerRight,
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: Switch(
          value: value,
          onChanged: enabled
              ? (v) => setState(() {
                    _choice[o.name] = v ? 'true' : 'false';
                  })
              : null,
        ),
      ),
    );
  }

  Widget _control(SpecOption o) {
    final enabled = _enabled(o);
    late final Widget control;
    if (_isSlider(o)) {
      control = _slider(o, enabled);
    } else if (o.isEnum) {
      final defaultValue = _defaultOf(o);
      final hasDefaultValue =
          defaultValue.isNotEmpty && o.values.contains(defaultValue);
      control = _dropdown(
          o,
          [
            if (!hasDefaultValue)
              DropdownMenuItem<String>(
                  value: '', child: Text(_defaultLabel(o))),
            for (final v in o.values)
              DropdownMenuItem<String>(
                value: v,
                child: Text(_valueLabel(o, v)),
              ),
          ],
          enabled);
    } else if (o.isBool) {
      control = _boolSwitch(o, enabled);
    } else {
      control = TextField(
        controller: _text[o.name],
        enabled: enabled,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          isDense: true,
          hintText: _placeholderOf(o),
          errorText: _error[o.name],
          suffixIcon: o.isPath
              ? IconButton(
                  icon: const Icon(Icons.folder_open, size: 18),
                  visualDensity: VisualDensity.compact,
                  onPressed: enabled ? () => _pickPath(o) : null,
                )
              : null,
        ),
      );
    }
    if (enabled) return control;
    final hint = widget.disabledHintFor?.call(o.name, _currentChoices()) ?? '';
    return hint.isEmpty ? control : Tooltip(message: hint, child: control);
  }

  Future<void> _pickPath(SpecOption o) async {
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
      constraints: const BoxConstraints(minWidth: 480),
      title: Text(widget.title),
      content: SingleChildScrollView(
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
                    Expanded(
                      flex: 3,
                      child: Tooltip(
                        message: widget.describe(o),
                        child: Text(
                          o.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(flex: 2, child: _control(o)),
                  ],
                ),
              ),
          ],
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
