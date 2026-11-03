import 'package:flutter/material.dart';

import '../../../models/model_spec.dart';
import '../../../models/voice_entry.dart';

/// 工作台文件选择器允许的音频格式（与 audio2wav 实际支持一致）。
const List<String> kWorkbenchAudioExtensions = [
  'wav',
  'mp3',
  'flac',
  'm4a',
  'aac',
];

/// 工作台通用下拉（label + 等宽下拉）。
class WorkbenchDropdown extends StatelessWidget {
  const WorkbenchDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final String value;
  final List<DropdownMenuItem<String>> items;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        isDense: true,
        labelText: label,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          isDense: true,
          focusColor: Colors.transparent,
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

/// 工作台音频选择按钮。
class WorkbenchAudioButton extends StatelessWidget {
  const WorkbenchAudioButton({
    super.key,
    required this.label,
    required this.path,
    required this.onPressed,
  });

  final String label;
  final String? path;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.audio_file_outlined),
      label: Text(
        path == null ? label : path!.split(RegExp(r'[\\/]')).last,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

List<String> workbenchLanguageOptions(ModelSpec spec, String? current) {
  final out = <String>['auto'];
  for (final l in spec.languages) {
    if (!out.contains(l)) out.add(l);
  }
  if (current != null && current.isNotEmpty && !out.contains(current)) {
    out.add(current);
  }
  return out;
}

String workbenchLanguageValue(String? current) =>
    (current == null || current.isEmpty) ? 'auto' : current;

/// 未适配提示：说明 + 提交 issue 入口。
class WorkbenchUnadaptedHint extends StatelessWidget {
  const WorkbenchUnadaptedHint({
    super.key,
    required this.message,
    required this.reportLabel,
    required this.onReportIssue,
  });

  final String message;
  final String reportLabel;
  final VoidCallback onReportIssue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      runSpacing: 2,
      children: [
        Icon(
          Icons.info_outline,
          size: 14,
          color: scheme.onSurfaceVariant,
        ),
        Text(
          message,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        TextButton(
          onPressed: onReportIssue,
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: theme.textTheme.bodySmall,
          ),
          child: Text(reportLabel),
        ),
      ],
    );
  }
}

class WorkbenchVoiceField extends StatelessWidget {
  const WorkbenchVoiceField({
    super.key,
    required this.label,
    required this.defaultLabel,
    required this.selectedId,
    required this.voices,
    required this.onChanged,
  });

  final String label;
  final String defaultLabel;
  final String selectedId;
  final List<VoiceEntry> voices;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final ids = [for (final v in voices) v.id];
    final value = ids.contains(selectedId) ? 'local:$selectedId' : '';
    return WorkbenchDropdown(
      label: label,
      value: value,
      items: [
        DropdownMenuItem(value: '', child: Text(defaultLabel)),
        for (final v in voices)
          DropdownMenuItem(
            value: 'local:${v.id}',
            child: Text(v.name, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (v) {
        if (v == null || v.isEmpty) {
          onChanged('');
        } else if (v.startsWith('local:')) {
          onChanged(v.substring(6));
        }
      },
    );
  }
}
