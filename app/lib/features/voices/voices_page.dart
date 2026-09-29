import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/audio_transcoder.dart';
import '../../core/glyph.dart';
import '../../localization/strings.dart';
import '../../models/voice_entry.dart';
import '../../providers/app_providers.dart';
import '../../providers/library_providers.dart';
import '../../providers/player_providers.dart';
import '../common/audition_button.dart';

/// 音色列表副标题：语言 · 描述（有则显示，过长省略）。
Widget? _voiceSubtitle(BuildContext context, VoiceEntry v) {
  final lang = v.language?.trim() ?? '';
  final desc = v.description?.trim() ?? '';
  final parts = <String>[
    if (lang.isNotEmpty) lang,
    if (desc.isNotEmpty) desc,
  ];
  if (parts.isEmpty) return null;
  return Text(
    parts.join(' · '),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: Theme.of(context).textTheme.bodySmall,
  );
}

class VoicesPage extends ConsumerWidget {
  const VoicesPage({super.key});

  Future<void> _addVoice(WidgetRef ref, BuildContext context) async {
    final result = await showDialog<_NewVoiceData>(
      context: context,
      builder: (_) => const _AddVoiceDialog(),
    );
    if (result == null) return;
    final dict = ref.read(stringsProvider);
    var sourcePath = result.sourcePath;
    File? tmp;
    if (p.extension(sourcePath).toLowerCase() != '.wav') {
      // 非 WAV 先解码为标准 PCM WAV（保留源采样率/声道，保真）。
      final paths = ref.read(appPathsProvider);
      final transcoder =
          AudioTranscoder(tmpDir: paths.tmpDir, appRoot: paths.appRoot);
      final tool = await transcoder.toolPath();
      if (tool == null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(dict['workbench.wavOnly'] ??
                  'Only WAV audio is supported')));
        }
        return;
      }
      try {
        tmp = await transcoder.toWav(sourcePath, tool);
        sourcePath = tmp.path;
      } on AudioTranscodeException catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(
                  '${dict['workbench.transcodeFailed'] ?? 'Audio transcode failed'}: ${e.message}')));
        }
        return;
      }
    }
    try {
      await ref.read(voiceLibraryProvider.notifier).createFromFile(
            name: result.name,
            sourcePath: sourcePath,
            text: result.text,
            description: result.description,
            language: result.language,
          );
    } finally {
      if (tmp != null) {
        try {
          if (tmp.existsSync()) tmp.deleteSync();
        } catch (_) {}
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final voices = ref.watch(voiceLibraryProvider).voices;
    final dict = ref.watch(stringsProvider);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(dict['voices.title'] ?? 'Voice Library',
                    style: Theme.of(context).textTheme.headlineSmall),
              ),
              TextButton.icon(
                onPressed: () => _addVoice(ref, context),
                icon: const Icon(Icons.add),
                label: Text(dict['voices.add'] ?? 'Add'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: voices.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.record_voice_over,
                            size: 48, color: Colors.grey),
                        const SizedBox(height: 12),
                        Text(dict['voices.empty'] ?? 'No voices'),
                        const SizedBox(height: 4),
                        Text(
                            dict['voices.emptyHint'] ??
                                'Click "Add" at the top right to create a voice.',
                            style: const TextStyle(color: Colors.grey)),
                      ],
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final cols =
                          (constraints.maxWidth / 300).floor().clamp(1, 6);
                      return GridView.builder(
                        padding: EdgeInsets.zero,
                        gridDelegate:
                            SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: cols,
                          mainAxisExtent: 72,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                        ),
                        itemCount: voices.length,
                        itemBuilder: (context, i) => _VoiceCard(
                          voice: voices[i],
                          onEdit: () => showDialog<void>(
                            context: context,
                            builder: (_) =>
                                _ManageVoiceDialog(voice: voices[i]),
                          ),
                          onDelete: () =>
                              _confirmDelete(context, ref, voices[i]),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    VoiceEntry v,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final dict = ref.read(stringsProvider);
        return AlertDialog(
          title: Text(dict['voices.deleteTitle'] ?? 'Delete voice'),
          content: Text(
              trF(ref, 'voices.deleteConfirm', {'name': v.name})),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(dict['common.cancel'] ?? 'Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(dict['common.delete'] ?? 'Delete'),
            ),
          ],
        );
      },
    );
    if (ok == true) {
      await ref.read(voiceLibraryProvider.notifier).remove(v.id);
    }
  }
}

class _VoiceCard extends ConsumerWidget {
  const _VoiceCard({
    required this.voice,
    required this.onEdit,
    required this.onDelete,
  });

  final VoiceEntry voice;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dict = ref.watch(stringsProvider);
    final v = voice;
    final hasAudio = (v.audioPath ?? '').isNotEmpty;
    final subtitle = _voiceSubtitle(context, v);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor:
                    Theme.of(context).colorScheme.primaryContainer,
                child: Text(
                  firstGlyph(v.name) ?? '?',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      v.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    if (subtitle != null) subtitle,
                  ],
                ),
              ),
              if (hasAudio)
                AuditionButton(path: v.audioPath, title: v.name),
              PopupMenuButton<String>(
                tooltip: '',
                icon: const Icon(Icons.more_vert, size: 20),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onSelected: (val) {
                  if (val == 'edit') onEdit();
                  if (val == 'delete') onDelete();
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'edit',
                    child: Row(
                      children: [
                        const Icon(Icons.edit_outlined, size: 18),
                        const SizedBox(width: 8),
                        Text(dict['voices.editTooltip'] ?? 'Edit'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        const Icon(Icons.delete_outline, size: 18),
                        const SizedBox(width: 8),
                        Text(dict['voices.deleteTooltip'] ?? 'Delete'),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NewVoiceData {
  const _NewVoiceData(
      {required this.name,
      required this.sourcePath,
      this.text,
      this.description,
      this.language});
  final String name;
  final String sourcePath;
  final String? text;
  final String? description;
  final String? language;
}

class _ManageVoiceDialog extends ConsumerStatefulWidget {
  const _ManageVoiceDialog({required this.voice});

  final VoiceEntry voice;

  @override
  ConsumerState<_ManageVoiceDialog> createState() =>
      _ManageVoiceDialogState();
}

class _ManageVoiceDialogState extends ConsumerState<_ManageVoiceDialog> {
  late final _nameCtrl = TextEditingController(text: widget.voice.name);
  late final _textCtrl = TextEditingController(text: widget.voice.text ?? '');
  late final _descCtrl =
      TextEditingController(text: widget.voice.description ?? '');
  late final _languageCtrl =
      TextEditingController(text: widget.voice.language ?? '');

  @override
  void dispose() {
    _nameCtrl.dispose();
    _textCtrl.dispose();
    _descCtrl.dispose();
    _languageCtrl.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    final dict = ref.read(stringsProvider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(dict['voices.deleteTitle'] ?? 'Delete voice'),
        content: Text(trF(ref, 'voices.deleteConfirm',
            {'name': widget.voice.name})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(dict['common.cancel'] ?? 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(dict['common.delete'] ?? 'Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(voiceLibraryProvider.notifier).remove(widget.voice.id);
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dict = ref.read(stringsProvider);
    return AlertDialog(
      title: Text(dict['voices.editLabel'] ?? 'Edit'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: InputDecoration(
                labelText: dict['voices.name'] ?? 'Name *',
                helperText: dict['voices.nameHelper'] ?? 'Required, used as an identifier for the reference voice',
                border: const OutlineInputBorder(),
              ),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _languageCtrl,
              decoration: InputDecoration(
                labelText: dict['voices.langLabel'] ?? 'Language (optional)',
                helperText: dict['voices.langHelper'] ?? 'e.g. zh / en / ja',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _textCtrl,
              decoration: InputDecoration(
                labelText: dict['voices.textLabel'] ?? 'Reference text (optional)',
                helperText: dict['voices.textHelper'] ?? 'Audio transcript, useful as a reference for voice cloning',
                border: const OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descCtrl,
              decoration: InputDecoration(
                labelText: dict['voices.descLabel'] ?? 'Description (optional)',
                border: const OutlineInputBorder(),
              ),
              maxLength: 128,
              maxLines: 2,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: _delete,
          child: Text(dict['common.delete'] ?? 'Delete'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(dict['common.cancel'] ?? 'Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final name = _nameCtrl.text.trim();
            if (name.isEmpty) return;
            ref.read(voiceLibraryProvider.notifier).update(
                  widget.voice.id,
                  name: name,
                  text: _textCtrl.text,
                  description: _descCtrl.text,
                  language: _languageCtrl.text,
                );
            Navigator.pop(context);
          },
          child: Text(dict['common.save'] ?? 'Save'),
        ),
      ],
    );
  }
}

class _AddVoiceDialog extends ConsumerStatefulWidget {
  const _AddVoiceDialog();

  @override
  ConsumerState<_AddVoiceDialog> createState() => _AddVoiceDialogState();
}

class _AddVoiceDialogState extends ConsumerState<_AddVoiceDialog> {
  final _nameCtrl = TextEditingController();
  final _textCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _languageCtrl = TextEditingController();
  String? _selectedPath;

  @override
  void initState() {
    super.initState();
    // 语言默认按软件当前语言，可选。
    _languageCtrl.text = ref.read(localeProvider).code;
  }

  @override
  void dispose() {
    // 弹窗关闭（取消/保存/点空白）时，若正在试听本弹窗的音频则中止。
    final player = ref.read(audioPlayerProvider);
    if (_selectedPath != null && player.currentPath == _selectedPath) {
      player.stop();
    }
    _nameCtrl.dispose();
    _textCtrl.dispose();
    _descCtrl.dispose();
    _languageCtrl.dispose();
    super.dispose();
  }

  InputDecoration _dec(String label, {String? helper}) => InputDecoration(
        labelText: label,
        helperText: helper,
        border: const OutlineInputBorder(),
      );

  Future<void> _pickFile() async {
    // 与 ASR 一致：WAV / MP3 / FLAC / M4A / AAC（非 WAV 在保存时转成 WAV）。
    const typeGroup = XTypeGroup(
        label: 'Audio', extensions: ['wav', 'mp3', 'flac', 'm4a', 'aac']);
    final file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file == null) return;
    setState(() => _selectedPath = file.path);
  }

  @override
  Widget build(BuildContext context) {
    final dict = ref.read(stringsProvider);
    final path = _selectedPath;
    return AlertDialog(
      title: Text(dict['voices.addTitle'] ?? 'Add voice'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _nameCtrl,
                decoration: _dec(dict['voices.name'] ?? 'Name *',
                    helper: dict['voices.nameHelper'] ?? 'Required, used as an identifier for the reference voice'),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _languageCtrl,
                decoration: _dec(dict['voices.langLabel'] ?? 'Language (optional)',
                    helper: dict['voices.langHelper'] ?? 'e.g. zh / en / ja'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      path == null
                          ? (dict['voices.noFile'] ?? 'No reference audio selected')
                          : p.basename(path),
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _pickFile,
                    icon: const Icon(Icons.folder_open),
                    label: Text(dict['voices.pickFile'] ?? 'Choose file'),
                  ),
                  AuditionButton(
                    path: path,
                    title: _nameCtrl.text.trim(),
                  ),
                ],
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(top: 4, left: 4),
                  child: Text(
                    dict['voices.audioTypes'] ??
                        'WAV / MP3 / FLAC / M4A / AAC',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Colors.grey),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _textCtrl,
                decoration: _dec(dict['voices.textLabel'] ?? 'Reference text (optional)',
                    helper: dict['voices.textHelper'] ?? 'Audio transcript, useful as a reference for voice cloning'),
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _descCtrl,
                decoration: _dec(dict['voices.descLabel'] ?? 'Description (optional)'),
                maxLength: 128,
                maxLines: 2,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(dict['common.cancel'] ?? 'Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final name = _nameCtrl.text.trim();
            if (name.isEmpty || path == null) return;
            final text = _textCtrl.text.trim();
            final description = _descCtrl.text.trim();
            Navigator.pop(
              context,
              _NewVoiceData(
                name: name,
                sourcePath: path,
                text: text.isEmpty ? null : text,
                description: description.isEmpty ? null : description,
                language: _languageCtrl.text.trim().isEmpty
                    ? null
                    : _languageCtrl.text.trim(),
              ),
            );
          },
          child: Text(dict['common.save'] ?? 'Save'),
        ),
      ],
    );
  }
}