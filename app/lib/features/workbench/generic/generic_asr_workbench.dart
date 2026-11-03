import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../../models/model_spec.dart';
import '../../../models/session.dart';
import '../widgets/workbench_fields.dart';
import 'generic_controller.dart';

/// 未适配 ASR 的通用控制台：音频 + 语言。
class GenericAsrWorkbench extends StatelessWidget {
  const GenericAsrWorkbench({
    super.key,
    required this.controller,
    required this.spec,
    required this.dict,
    required this.onPickAudio,
    required this.onSubmit,
    this.selectedRecord,
  });

  final GenericWorkbenchController controller;
  final ModelSpec spec;
  final Map<String, String> dict;
  final VoidCallback onPickAudio;
  final VoidCallback onSubmit;
  final GenerationRecord? selectedRecord;

  Future<void> _copy(BuildContext context, GenerationRecord record) async {
    try {
      await Clipboard.setData(ClipboardData(text: record.displayText));
      if (context.mounted) {
        _copyNotice(context, dict['common.copied'] ?? 'Copied');
      }
    } catch (_) {
      if (context.mounted) {
        _copyNotice(context, dict['common.copyFailed'] ?? 'Copy failed');
      }
    }
  }

  Future<void> _export(BuildContext context, GenerationRecord record) async {
    final save = await getSaveLocation(
      suggestedName: 'transcript_${record.id}.txt',
    );
    if (save == null || !context.mounted) return;
    try {
      await File(save.path).writeAsString(record.displayText);
      if (context.mounted) _notice(context, dict['session.saved'] ?? 'Saved');
    } catch (e) {
      if (context.mounted) _notice(context, '$e');
    }
  }

  void _notice(BuildContext context, String text) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _copyNotice(BuildContext context, String text) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        width: 160,
        duration: const Duration(milliseconds: 1500),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showLanguage = spec.languages.isNotEmpty;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          WorkbenchAudioButton(
            label: dict['workbench.pickAudio'] ?? 'Choose audio',
            path: controller.audioPath,
            onPressed: onPickAudio,
          ),
          const SizedBox(height: 12),
          if (showLanguage) ...[
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
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: onSubmit,
              icon: const Icon(Icons.playlist_add),
              label: Text(dict['workbench.submit'] ?? 'Add task'),
            ),
          ),
          if (selectedRecord != null &&
              selectedRecord!.displayText.isNotEmpty) ...[
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
                          tooltip: dict['common.copy'] ?? 'Copy',
                          onPressed: () => _copy(context, selectedRecord!),
                          visualDensity: VisualDensity.compact,
                        ),
                        IconButton(
                          icon: const Icon(Icons.save_alt, size: 18),
                          tooltip: dict['session.export'] ?? 'Export',
                          onPressed: () => _export(context, selectedRecord!),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SelectableText(selectedRecord!.displayText),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
