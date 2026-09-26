import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../../models/session.dart';
import '../../providers/app_providers.dart';
import '../../providers/player_providers.dart';
import '../../providers/session_providers.dart';
import '../common/audition_button.dart';
import '../common/busy_guard.dart';
import '../common/record_avatar.dart';

class HistoryPage extends ConsumerStatefulWidget {
  const HistoryPage({super.key});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<HistoryPage> {
  String? _notice;

  /// 用户显式展开 / 折叠的集合 id；未操作过的按"最近活动"自动展开。
  final Set<String> _expandedCollections = {};
  final Set<String> _collapsedCollections = {};

  /// 未归类区的展开状态：null 表示自动（最新会话未归类时展开）。
  bool? _unfiledOpen;

  bool _collectionOpen(String id, String? latestId) {
    if (_expandedCollections.contains(id)) return true;
    if (_collapsedCollections.contains(id)) return false;
    return id == latestId;
  }

  /// 本地时区 + 本地化格式：日期按语言（zh：2026年9月26日 / en：Sep 26, 2026），
  /// 时间制式跟随系统（alwaysUse24HourFormat；中文缺省 24 小时制，其余 12 小时制）。
  String _fmtTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final use24 = MediaQuery.of(context).alwaysUse24HourFormat ||
        Localizations.localeOf(context).languageCode == 'zh';
    final date = DateFormat.yMMMd(locale).format(d);
    final time = DateFormat(use24 ? 'HH:mm:ss' : 'h:mm:ss a', locale).format(d);
    return '$date $time';
  }

  void _refresh() => ref.invalidate(sessionListProvider);

  void _showNotice(String text) {
    setState(() => _notice = text);
    Future.delayed(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  Future<void> _open(String sid) async {
    if (!await confirmWhileBusy(ref, context)) return;
    ref.read(currentSessionProvider).openSession(sid);
    final dict = ref.read(stringsProvider);
    // 直接跳工作台，由工作台的页内提示（SnackBar）显示"已载入"。
    ref.read(workbenchNoticeProvider.notifier).state =
        dict['history.opened'] ?? 'Loaded into workbench';
    ref.read(homeTabProvider.notifier).state = 0;
  }

  Future<String?> _promptName(String title, String initial) async {
    final dict = ref.read(stringsProvider);
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
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
  }

  Future<void> _renameSession(SessionSummary s) async {
    final dict = ref.read(stringsProvider);
    final name =
        await _promptName(dict['session.name'] ?? 'Session name', s.name);
    if (name == null) return;
    ref.read(sessionStoreProvider).renameSession(s.id, name);
    if (ref.read(currentSessionProvider).session.id == s.id) {
      ref.read(currentSessionProvider).rename(name);
    }
    _refresh();
  }

  Future<bool> _confirm(String title, String body) async {
    final dict = ref.read(stringsProvider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(dict['common.cancel'] ?? 'Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(dict['common.delete'] ?? 'Delete')),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _deleteSession(String sid) async {
    final dict = ref.read(stringsProvider);
    if (!await _confirm(dict['session.delete'] ?? 'Delete session',
        dict['session.deleteConfirm'] ?? 'Delete this session and its audio?')) {
      return;
    }
    ref.read(collectionsProvider).removeSession(sid);
    ref.read(sessionStoreProvider).deleteSession(sid);
    if (ref.read(currentSessionProvider).session.id == sid) {
      ref.read(currentSessionProvider).newSession();
    }
    _refresh();
  }

  Future<void> _confirmClear() async {
    final dict = ref.read(stringsProvider);
    if (!await _confirm(dict['history.clear'] ?? 'Clear history',
        dict['history.clearConfirm'] ?? 'Delete all sessions and audio?')) {
      return;
    }
    ref.read(sessionStoreProvider).clearAll();
    ref.read(collectionsProvider).reload();
    ref.read(currentSessionProvider).newSession();
    _refresh();
  }

  Future<void> _renameCollection(String cid, String current) async {
    final dict = ref.read(stringsProvider);
    final name = await _promptName(
        dict['collection.label'] ?? 'Collection', current);
    if (name == null) return;
    ref.read(collectionsProvider).rename(cid, name);
  }

  Future<void> _deleteCollection(String cid) async {
    final dict = ref.read(stringsProvider);
    if (!await _confirm(dict['collection.delete'] ?? 'Delete collection',
        dict['collection.deleteConfirm'] ??
            'Remove this collection? Sessions are kept as unfiled.')) {
      return;
    }
    ref.read(collectionsProvider).delete(cid);
    _refresh();
  }

  Future<void> _newCollection() async {
    final dict = ref.read(stringsProvider);
    final name =
        await _promptName(dict['collection.new'] ?? 'New collection', '');
    if (name == null) return;
    ref.read(collectionsProvider).create(name);
  }

  Future<void> _moveSession(String sid) async {
    final dict = ref.read(stringsProvider);
    final cc = ref.read(collectionsProvider);
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(dict['collection.move'] ?? 'Move to collection'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, ''),
            child: Text(dict['collection.none'] ?? 'Unfiled'),
          ),
          for (final c in cc.collections)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, c.id),
              child: Text(c.name.isNotEmpty
                  ? c.name
                  : (dict['collection.unnamed'] ?? 'Collection')),
            ),
        ],
      ),
    );
    if (result == null) return;
    if (result.isEmpty) {
      cc.removeSession(sid);
      if (ref.read(currentSessionProvider).session.id == sid) {
        ref.read(currentSessionProvider).setCollectionId(null);
      }
    } else {
      cc.addSession(sid, result);
      if (ref.read(currentSessionProvider).session.id == sid) {
        ref.read(currentSessionProvider).setCollectionId(result);
      }
    }
  }

  void _move(String cid, List<String> ids, int index, int delta) {
    final target = index + delta;
    if (target < 0 || target >= ids.length) return;
    final list = List<String>.of(ids);
    final tmp = list[index];
    list[index] = list[target];
    list[target] = tmp;
    ref.read(collectionsProvider).reorder(cid, list);
  }

  String? _recordAudioAbs(GenerationRecord r) {
    final store = ref.read(sessionStoreProvider);
    for (final o in r.outputs) {
      if (o.kind == 'audio') return p.join(store.baseDir.path, o.path);
    }
    return null;
  }

  Future<void> _saveRecord(Map<String, String> dict, GenerationRecord r) async {
    final store = ref.read(sessionStoreProvider);
    String? abs;
    for (final o in r.outputs) {
      if (o.kind == 'audio') {
        abs = p.join(store.baseDir.path, o.path);
        break;
      }
    }
    if (abs == null) return;
    final save = await getSaveLocation(suggestedName: 'audio_${r.id}.wav');
    if (save == null) return;
    try {
      await File(abs).copy(save.path);
      if (mounted) _showNotice(dict['session.saved'] ?? 'Saved');
    } catch (_) {}
  }

  Future<void> _saveRecordText(Map<String, String> dict, GenerationRecord r) async {
    if (r.text.isEmpty) return;
    final save = await getSaveLocation(suggestedName: 'transcript_${r.id}.txt');
    if (save == null) return;
    try {
      await File(save.path).writeAsString(r.text);
      if (mounted) _showNotice(dict['session.saved'] ?? 'Saved');
    } catch (_) {}
  }

  Widget _recordBadge(String text, Color color) => Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text, style: TextStyle(fontSize: 11, color: color)),
      );

  String _recordTitle(GenerationRecord r) {
    final t = r.inputs['text'] ?? '';
    if (t.isNotEmpty) return t;
    if (r.text.isNotEmpty) return r.text;
    return r.family.isEmpty ? r.type : r.family;
  }

  Future<void> _showSession(SessionSummary s) async {
    final dict = ref.read(stringsProvider);
    final store = ref.read(sessionStoreProvider);
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final records = store.loadRecords(s.id).reversed.toList();
          return AlertDialog(
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    s.name.isNotEmpty
                        ? s.name
                        : (dict['session.unnamed'] ?? 'New session'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  _fmtTime(s.updatedAtMs),
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
            content: SizedBox(
              width: 560,
              height: 420,
              child: records.isEmpty
                  ? Center(
                      child: Text(dict['session.empty'] ?? 'No records yet'))
                  : ListView.builder(
                      itemCount: records.length,
                      itemBuilder: (c, i) {
                        final r = records[i];
                        final hasAudio =
                            r.outputs.any((o) => o.kind == 'audio');
                        final isAsr = r.type == RecordType.asr;
                        final failed = r.status == 'failed';
                        final hasResource = hasAudio || r.text.isNotEmpty;
                        final meta =
                            '${r.type.toUpperCase()} · ${_fmtTime(r.createdAtMs)}';
                        return ListTile(
                          dense: true,
                          leading: RecordAvatar(record: r),
                          // ASR：标题为 "ASR · 时间"，正文是转写文本；其它：标题为文本。
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(isAsr ? meta : _recordTitle(r),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                              ),
                              if (failed)
                                _recordBadge(
                                    dict['record.status.failed'] ?? 'Failed',
                                    Colors.red),
                              if (!failed && !hasResource)
                                _recordBadge(
                                    dict['record.noOutput'] ?? 'No output',
                                    Colors.grey),
                            ],
                          ),
                          subtitle: Text(
                            failed
                                ? (r.error.isNotEmpty
                                    ? r.error
                                    : (dict['record.status.failed'] ??
                                        'Failed'))
                                : (isAsr ? r.text : meta),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                tooltip:
                                    dict['session.record.delete'] ?? 'Delete',
                                onPressed: () {
                                  final ctrl = ref.read(currentSessionProvider);
                                  if (ctrl.session.id == s.id) {
                                    // 当前会话：走控制器（同步内存与 meta）。
                                    ctrl.deleteRecord(r.id);
                                  } else {
                                    store.deleteRecord(s.id, r.id);
                                    store.syncSessionAfterRecordDelete(s.id);
                                  }
                                  setDialogState(() {});
                                  _refresh();
                                },
                              ),
                              // 历史里以"下载"为主：统一 删除 · 播放 · 下载
                              // （TTS 下载音频，ASR 下载文本）。
                              if (hasAudio)
                                AuditionButton(
                                  path: _recordAudioAbs(r),
                                  title: _recordTitle(r),
                                ),
                              if (isAsr) ...[
                                if (r.text.isNotEmpty)
                                  IconButton(
                                    icon: const Icon(Icons.save_alt),
                                    tooltip: dict['session.export'] ?? 'Export',
                                    onPressed: () => _saveRecordText(dict, r),
                                  ),
                              ] else ...[
                                if (hasAudio)
                                  IconButton(
                                    icon: const Icon(Icons.save_alt),
                                    tooltip: dict['session.export'] ?? 'Export',
                                    onPressed: () => _saveRecord(dict, r),
                                  ),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  _open(s.id);
                },
                child: Text(dict['session.open'] ?? 'Open'),
              ),
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(dict['common.close'] ?? 'Close')),
            ],
          );
        },
      ),
    );
    // 弹窗关闭后主动停止试听。
    ref.read(audioPlayerProvider).stop();
  }

  Widget _sessionTile(Map<String, String> dict, SessionSummary s,
      {String? cid, int? index, int? count}) {
    final title =
        s.name.isNotEmpty ? s.name : (dict['session.unnamed'] ?? 'New session');
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.history),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${dictTpl(dict, 'history.records', {'count': '${s.recordCount}'})} · ${_fmtTime(s.updatedAtMs)}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        onTap: () => _showSession(s),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (cid != null && index != null && count != null) ...[
              IconButton(
                icon: const Icon(Icons.arrow_upward, size: 18),
                tooltip: dict['collection.up'] ?? 'Up',
                onPressed: index > 0
                    ? () => _move(cid, _idsOf(cid), index, -1)
                    : null,
              ),
              IconButton(
                icon: const Icon(Icons.arrow_downward, size: 18),
                tooltip: dict['collection.down'] ?? 'Down',
                onPressed: index < count - 1
                    ? () => _move(cid, _idsOf(cid), index, 1)
                    : null,
              ),
            ],
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: dict['session.delete'] ?? 'Delete session',
              onPressed: () => _deleteSession(s.id),
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: dict['session.name'] ?? 'Session name',
              onPressed: () => _renameSession(s),
            ),
            IconButton(
              icon: const Icon(Icons.drive_file_move_outline),
              tooltip: dict['collection.move'] ?? 'Move to collection',
              onPressed: () => _moveSession(s.id),
            ),
            IconButton(
              icon: const Icon(Icons.open_in_new),
              tooltip: dict['session.open'] ?? 'Open',
              onPressed: () => _open(s.id),
            ),
          ],
        ),
      ),
    );
  }

  List<String> _idsOf(String cid) {
    final c = ref.read(collectionsProvider).byId(cid);
    return c == null ? const [] : List<String>.of(c.sessionIds);
  }

  @override
  Widget build(BuildContext context) {
    final dict = ref.watch(stringsProvider);
    final async = ref.watch(sessionListProvider);
    final cc = ref.watch(collectionsProvider);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(dict['nav.history'] ?? 'History',
                    style: Theme.of(context).textTheme.headlineSmall),
              ),
              TextButton.icon(
                onPressed: _newCollection,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: Text(dict['collection.new'] ?? 'New collection'),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: _confirmClear,
                icon: const Icon(Icons.delete_sweep_outlined),
                label: Text(dict['history.clear'] ?? 'Clear history'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: async.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
              data: (list) {
                if (list.isEmpty) {
                  return Center(
                    child: Text(dict['history.empty'] ?? 'No sessions yet',
                        style: const TextStyle(color: Colors.grey)),
                  );
                }
                final byId = {for (final s in list) s.id: s};
                final unfiled = list
                    .where((s) => cc.collectionOf(s.id) == null)
                    .toList();
                // 仅当最新会话属于某个集合时，才默认展开那个集合；否则全部折叠。
                final latestId = list.isEmpty
                    ? null
                    : cc.collectionOf(list.first.id)?.id;
                // 未归类区默认展开（最新会话未归类时），否则折叠；可手动切换。
                final unfiledOpen = _unfiledOpen ?? (latestId == null);
                return ListView(
                  children: [
                    // 未归类 / 最近会话置顶，避免集合多时被压到后面。
                    if (unfiled.isNotEmpty) ...[
                      InkWell(
                        onTap: () =>
                            setState(() => _unfiledOpen = !unfiledOpen),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              Icon(
                                  unfiledOpen
                                      ? Icons.expand_less
                                      : Icons.expand_more,
                                  size: 18),
                              const SizedBox(width: 2),
                              Text(dict['collection.none'] ?? 'Unfiled',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleSmall),
                              const SizedBox(width: 6),
                              Text('(${unfiled.length})',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(color: Colors.grey)),
                            ],
                          ),
                        ),
                      ),
                      if (unfiledOpen)
                        for (final s in unfiled) _sessionTile(dict, s),
                      const SizedBox(height: 8),
                    ],
                    // 集合：默认折叠，点击展开其会话。
                    for (final c in cc.collections) ...[
                      _collectionHeader(
                        dict,
                        c,
                        expanded: _collectionOpen(c.id, latestId),
                        onToggle: () => setState(() {
                          if (_collectionOpen(c.id, latestId)) {
                            _expandedCollections.remove(c.id);
                            _collapsedCollections.add(c.id);
                          } else {
                            _expandedCollections.add(c.id);
                            _collapsedCollections.remove(c.id);
                          }
                        }),
                      ),
                      if (_collectionOpen(c.id, latestId))
                        for (var i = 0; i < c.sessionIds.length; i++)
                          if (byId[c.sessionIds[i]] != null)
                            _sessionTile(dict, byId[c.sessionIds[i]]!,
                                cid: c.id,
                                index: i,
                                count: c.sessionIds.length),
                    ],
                  ],
                );
              },
            ),
          ),
          if (_notice != null) _noticeBanner(_notice!),
        ],
      ),
    );
  }

  Widget _noticeBanner(String text) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.check_circle_outline,
                  size: 16, color: scheme.onSecondaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(text,
                    style: TextStyle(color: scheme.onSecondaryContainer)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _collectionHeader(Map<String, String> dict, Collection c,
      {required bool expanded, required VoidCallback onToggle}) {
    final title = c.name.isNotEmpty
        ? c.name
        : (dict['collection.unnamed'] ?? 'Collection');
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 2),
        child: Row(
          children: [
            Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 18),
            const Icon(Icons.folder_outlined, size: 18),
            const SizedBox(width: 6),
            Expanded(
              child: Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            if (c.note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Tooltip(
                  message: c.note,
                  child: const Icon(Icons.sticky_note_2_outlined, size: 16),
                ),
              ),
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 18),
              tooltip: dict['collection.label'] ?? 'Collection',
              onPressed: () => _renameCollection(c.id, c.name),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              tooltip: dict['collection.delete'] ?? 'Delete collection',
              onPressed: () => _deleteCollection(c.id),
            ),
          ],
        ),
      ),
    );
  }
}
