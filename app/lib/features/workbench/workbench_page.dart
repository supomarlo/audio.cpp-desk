import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../models/model_catalog_entry.dart';
import '../../models/model_spec.dart';
import '../../models/session.dart';
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
import 'generic/generic_asr_workbench.dart';
import 'generic/generic_controller.dart';
import 'generic/generic_tts_workbench.dart';
import 'generic/generic_vc_workbench.dart';
import 'widgets/asr_srt.dart';
import 'widgets/workbench_fields.dart';
import 'workbench_contract.dart';
import 'workbench_models.dart';
import 'workbench_registry.dart';

class WorkbenchPage extends ConsumerStatefulWidget {
  const WorkbenchPage({super.key});

  @override
  ConsumerState<WorkbenchPage> createState() => _WorkbenchPageState();
}

class _WorkbenchPageState extends ConsumerState<WorkbenchPage> {
  String? _selectedPackageId;
  String _selectedTask = '';
  String? _selectedRecordId;
  final GlobalKey _selectorKey = GlobalKey();
  double _selectorHeight = 80;

  /// 专属模型 Widget 的控制器（key = `packageId|task`）。
  final Map<String, WorkbenchModelController> _modelCtrls = {};

  static const String _issueUrl =
      'https://github.com/supomarlo/audio.cpp-desk/issues';

  double _panelWidth = 360;

  /// 会话面板可拖动的最大宽度（由可用宽度 - 控制区最小宽度 动态决定）。
  double _maxPanelWidth = 900;

  /// 分隔条宽度。
  static const double _resizerWidth = 6;

  /// 控制区最小宽度（保证操作区不被挤压）。
  static const double _minControlWidth = 520;
  bool _queueBusy = false;
  int _queueRetries = 0;
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
    _queueRetries = 0;
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
    registerWorkbenchModels();
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
    _nameCtrl.dispose();
    _nameFocus.dispose();
    for (final c in _modelCtrls.values) {
      c.dispose();
    }
    _modelCtrls.clear();
    _genTicker?.cancel();
    _noticeTimer?.cancel();
    _copyTimer?.cancel();
    super.dispose();
  }

  void _scheduleSelectorMeasure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _selectorKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      if ((box.size.height - _selectorHeight).abs() < 1) return;
      setState(() => _selectorHeight = box.size.height);
    });
  }

  ModelSpec? _specFor(String family) {
    for (final s in ref.read(specsProvider).value ?? const <ModelSpec>[]) {
      if (s.family == family) return s;
    }
    return null;
  }

  /// 记录最后使用的模型（写入 config），下次打开工作台默认选中它。
  void _rememberModel(String? packageId) {
    if (packageId == null || packageId.isEmpty) return;
    if (ref.read(appConfigProvider).lastUsedPackageId == packageId) return;
    ref
        .read(appConfigProvider.notifier)
        .update((c) => c.lastUsedPackageId = packageId);
  }

  List<ModelCatalogEntry> _workModels(
    List<ModelCatalogEntry> entries,
    Map<String, ModelSpec> specByFamily,
  ) {
    return entries.where((e) {
      if (!e.installed || !e.activeVersion) return false;
      final tasks = specByFamily[e.family]?.tasks ?? const <String>[];
      return tasks.contains('tts') ||
          tasks.contains('asr') ||
          tasks.contains('vc');
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

  /// 页内提示。`autoHide=true` 仅用于"已载入工作台"这类短暂提示（1.5s 自动消失、
  /// 无按钮）；否则保留（可复制/关闭/点空白关闭），便于用户看清错误文本。
  void _toast(String msg, {bool autoHide = false, int autoHideMs = 1500}) {
    if (!mounted) return;
    _noticeTimer?.cancel();
    setState(() {
      _notice = msg;
      _noticeAutoHide = autoHide;
    });
    if (autoHide) {
      _noticeTimer = Timer(Duration(milliseconds: autoHideMs), () {
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
      _copyFeedback = dict[ok ? 'common.copied' : 'common.copyFailed'] ??
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
        final autoHideMs = ref.read(workbenchNoticeDurationProvider);
        _toast(next, autoHide: true, autoHideMs: autoHideMs);
        ref.read(workbenchNoticeProvider.notifier).state = null;
        ref.read(workbenchNoticeDurationProvider.notifier).state = 1500;
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
      } else if (busy && next.retryCount != _queueRetries) {
        // 重试：计时从 0 重新开始（重试次数显示在标题里）。
        _startGenTimer();
      }
      _queueBusy = busy;
      _queueRetries = next.retryCount;
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
    final tasks = current == null
        ? const <String>[]
        : workbenchTasksOf(
            specByFamily[current.family]?.tasks ?? const <String>[]);
    if (!tasks.contains(_selectedTask)) {
      _selectedTask = tasks.isNotEmpty ? tasks.first : '';
    }
    final task = _selectedTask;
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
      _selectedRecordId = null;
    }
    GenerationRecord? selectedRecord;
    if (_selectedRecordId != null) {
      for (final r in session.records) {
        if (r.id == _selectedRecordId) {
          selectedRecord = r;
          break;
        }
      }
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
                          child: lib.loading
                              // 首次加载中：显示"读取中"，不要把空列表当成"没有模型"。
                              ? Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2.5),
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                          dict['workbench.loadingModels'] ??
                                              'Loading models...',
                                          style: textTheme.bodyLarge),
                                    ],
                                  ),
                                )
                              : workModels.isEmpty
                                  ? Center(
                                      child: Text(
                                          dict['workbench.noModels'] ??
                                              'No TTS / ASR models installed. Install and load one from the model library first.',
                                          style: textTheme.bodyLarge),
                                    )
                                  : LayoutBuilder(
                                      builder: (context, body) => _buildBody(
                                        dict,
                                        current!,
                                        task,
                                        languages,
                                        selectedRecord,
                                        body.maxHeight,
                                      ),
                                    ),
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
    final c = ref.read(collectionsProvider).create(name, addSessionId: sid);
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
            ref
                .read(appConfigProvider.notifier)
                .update((c) => c.sessionPanelWidth = _panelWidth.round());
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
              child: Text(title, style: Theme.of(context).textTheme.titleSmall),
            ),
            if (trailing != null) trailing,
          ],
        ),
      );

  Widget _taskTile(Map<String, String> dict, GenerationRecord r) {
    final q = ref.watch(generationQueueProvider);
    final running = q.runningId == r.id;
    final subtitle = running
        ? (q.retryCount > 0
            ? dictTpl(dict, 'workbench.generatingRetry', {
                'count': '${q.retryCount}',
                'time': _fmtDur(_genElapsed),
              })
            : dictTpl(
                dict, 'workbench.generating', {'time': _fmtDur(_genElapsed)}))
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
      title: Row(
        children: [
          if (r.seq > 0) ...[
            Text(
              '#${r.seq}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(_recordTitle(r),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
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
        final tasks = specByFamily[e.family]?.tasks ?? const <String>[];
        if (workbenchTasksOf(tasks).contains(r.type)) {
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
    final busy = ref.read(generationQueueProvider).busy;
    final spec = specByFamily[r.family];
    final reg = WorkbenchRegistry.registrationFor(r.family, r.type);
    final genericCtrl = (reg == null && target != null && spec != null)
        ? _genericController(target.packageId, r.type, spec)
        : null;
    final modelCtrl = (reg != null && target != null && spec != null)
        ? _modelController(target.packageId, r.type, reg, spec)
        : null;
    setState(() {
      if (!busy) _clearGenStatus();
      _noticeTimer?.cancel();
      _notice = null;
      _selectedRecordId = r.id;
      _selectedTask = r.type;
      if (target != null) _selectedPackageId = target.packageId;
      if (modelCtrl != null) {
        modelCtrl.restore(r);
      } else {
        genericCtrl?.restore(r);
      }
    });
    if (target == null) {
      _toast(dict['workbench.modelMissing'] ?? 'Model not available');
    }
    if (audioAbs != null) {
      final player = ref.read(audioPlayerProvider);
      final current = player.currentPath;
      if (current == null || !p.equals(current, audioAbs)) {
        player.load(audioAbs, title: _recordTitle(r));
      }
    }
  }

  Widget _recordTile(Map<String, String> dict, GenerationRecord r) {
    final hasAudio = r.outputs.any((o) => o.kind == 'audio');
    final selected = r.id == _selectedRecordId;
    return ListTile(
      dense: true,
      // 选中态常驻：便于知道当前试听/阅读的是哪条（弹跳高亮点击后即消失）。
      tileColor:
          selected ? Theme.of(context).colorScheme.primaryContainer : null,
      // 点击记录：把该次的类型/模型/参数填回工作台（便于直接重新生成）；
      // 有结果的优先展示——TTS 载入播放器（不自动播放），ASR 展示文本。
      onTap: () => _applyRecord(dict, r),
      leading: RecordAvatar(record: r),
      title: Row(
        children: [
          if (r.seq > 0) ...[
            Text(
              '#${r.seq}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(_recordTitle(r),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
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
            onPressed: () async {
              final path = _recordAudioAbs(r);
              if (path != null) {
                await ref.read(audioPlayerProvider).stopIfPath(path);
              }
              ref.read(currentSessionProvider).deleteRecord(r.id);
            },
          ),
          if (r.type == RecordType.asr) ...[
            // ASR：删除、播放（输入音频）、下载（文本）
            if (hasAudio)
              AuditionButton(
                path: _recordAudioAbs(r),
                title: _recordTitle(r),
              ),
            if (r.displayText.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.save_alt),
                tooltip: dict['session.export'] ?? 'Export',
                onPressed: () => _showRecordExport(r),
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
      _toast(dict['session.saved'] ?? 'Saved', autoHide: true);
    } catch (e) {
      _toast('$e');
    }
  }

  Future<void> _saveRecordText(GenerationRecord r) async {
    final text = r.displayText;
    if (text.isEmpty) return;
    final dict = ref.read(stringsProvider);
    final save = await getSaveLocation(suggestedName: 'transcript_${r.id}.txt');
    if (save == null) return;
    try {
      await File(save.path).writeAsString(text);
      _toast(dict['session.saved'] ?? 'Saved', autoHide: true);
    } catch (e) {
      _toast('$e');
    }
  }

  List<dynamic> _recordWords(GenerationRecord r) {
    final words = r.ret?['words'];
    return words is List ? words : const [];
  }

  Future<void> _showRecordExport(GenerationRecord r) async {
    if (r.type != RecordType.asr || _recordWords(r).isEmpty) {
      await _saveRecordText(r);
      return;
    }
    final dict = ref.read(stringsProvider);
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(dict['session.export'] ?? 'Export'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'raw'),
            child: ListTile(
              leading: const Icon(Icons.data_object),
              title: Text(
                  dict['workbench.exportRaw'] ?? 'Export source data (JSON)'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'srt'),
            child: ListTile(
              leading: const Icon(Icons.subtitles_outlined),
              title: Text(dict['workbench.exportSrt'] ?? 'Export SRT'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'text'),
            child: ListTile(
              leading: const Icon(Icons.save_alt),
              title: Text(dict['workbench.exportText'] ?? 'Text'),
            ),
          ),
        ],
      ),
    );
    switch (action) {
      case 'raw':
        await _saveRecordRaw(r);
      case 'srt':
        await _saveRecordSrt(r);
      case 'text':
        await _saveRecordText(r);
    }
  }

  Future<void> _saveRecordRaw(GenerationRecord r) async {
    final dict = ref.read(stringsProvider);
    final ret = Map<String, dynamic>.from(
      r.ret ?? const <String, dynamic>{},
    )..remove('timing');
    if (ret.isEmpty) ret['text'] = r.displayText;
    final save = await getSaveLocation(
      suggestedName: 'transcript_${r.id}_raw.json',
    );
    if (save == null) return;
    try {
      await File(save.path).writeAsString(
        const JsonEncoder.withIndent('  ').convert(ret),
      );
      _toast(dict['session.saved'] ?? 'Saved', autoHide: true);
    } catch (e) {
      _toast('$e');
    }
  }

  Future<void> _saveRecordSrt(GenerationRecord r) async {
    final dict = ref.read(stringsProvider);
    final save = await getSaveLocation(
      suggestedName: 'transcript_${r.id}.srt',
    );
    if (save == null) return;
    try {
      await File(save.path).writeAsString(AsrSrt(r).srt);
      _toast(dict['session.saved'] ?? 'Saved', autoHide: true);
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
    if (r.displayText.isNotEmpty) return r.displayText;
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
    GenerationRecord? selectedRecord,
    double availableHeight,
  ) {
    _scheduleSelectorMeasure();
    final spec = _specFor(entry.family);
    final specByFamily = {
      for (final s in ref.read(specsProvider).value ?? const <ModelSpec>[])
        s.family: s,
    };
    final models =
        _workModelsSorted(ref.read(modelLibraryProvider).entries, specByFamily);
    final tasks = workbenchTasksOf(spec?.tasks ?? const <String>[]);
    final reg = WorkbenchRegistry.registrationFor(entry.family, task);
    final modelCtrl = (reg == null || spec == null)
        ? null
        : _modelController(entry.packageId, task, reg, spec);
    final ctrl = (reg == null && spec != null)
        ? _genericController(entry.packageId, task, spec)
        : null;
    final recordForEntry = selectedRecord?.packageId == entry.packageId &&
            selectedRecord?.type == task
        ? selectedRecord
        : null;
    final voices = ref
        .watch(voiceLibraryProvider)
        .voices
        .where((v) =>
            v.type == 'file' && (v.family == null || v.family == entry.family))
        .toList();
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
                  Container(
                    key: _selectorKey,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: WorkbenchDropdown(
                            label: dict['workbench.model'] ?? 'Model',
                            value: entry.packageId,
                            items: _modelMenuItems(models, specByFamily, dict),
                            onChanged: (v) {
                              _rememberModel(v);
                              _noticeTimer?.cancel();
                              final busy =
                                  ref.read(generationQueueProvider).busy;
                              setState(() {
                                if (!busy) _clearGenStatus();
                                _selectedPackageId = v;
                                _notice = null;
                              });
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 148,
                          child: _taskSelector(
                            task: task,
                            tasks: tasks,
                            dict: dict,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (spec == null)
                    Text(dict['workbench.noSpec'] ??
                        'Model specification is unavailable.')
                  else if (reg != null)
                    reg.builder(
                      context,
                      WorkbenchWidgetContext(
                        spec: spec,
                        dict: dict,
                        selectedRecord: recordForEntry,
                        availableHeight: availableHeight - _selectorHeight - 48,
                        submit: (ctrl) => _enqueueModel(entry, task, ctrl),
                      ),
                      modelCtrl!,
                    )
                  else if (task == 'tts')
                    GenericTtsWorkbench(
                      controller: ctrl!,
                      spec: spec,
                      dict: dict,
                      voices: voices,
                      onSubmit: () => _enqueueModel(entry, task, ctrl),
                    )
                  else if (task == 'asr')
                    GenericAsrWorkbench(
                      controller: ctrl!,
                      spec: spec,
                      dict: dict,
                      selectedRecord: recordForEntry,
                      onPickAudio: () => _pickGenericAudio(ctrl),
                      onSubmit: () => _enqueueModel(entry, task, ctrl),
                    )
                  else if (task == 'vc')
                    GenericVcWorkbench(
                      controller: ctrl!,
                      dict: dict,
                      voices: voices,
                      onPickAudio: () => _pickGenericAudio(ctrl),
                      onSubmit: () => _enqueueModel(entry, task, ctrl),
                    )
                  else
                    Text(dict['workbench.noSpec'] ??
                        'Model specification is unavailable.'),
                  if (reg == null) ...[
                    const SizedBox(height: 16),
                    WorkbenchUnadaptedHint(
                      message: dict['workbench.unadaptedNotice'] ??
                          'This model is not specifically adapted.',
                      reportLabel:
                          dict['workbench.reportIssue'] ?? 'Report an issue',
                      onReportIssue: _openIssue,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 模型下拉项：已适配 / 未适配分组（禁用项作为分组标题）。
  List<DropdownMenuItem<String>> _modelMenuItems(
    List<ModelCatalogEntry> models,
    Map<String, ModelSpec> specByFamily,
    Map<String, String> dict,
  ) {
    final adapted = <ModelCatalogEntry>[];
    final unadapted = <ModelCatalogEntry>[];
    for (final m in models) {
      final tasks = specByFamily[m.family]?.tasks ?? const <String>[];
      (WorkbenchRegistry.hasAnyAdapted(m.family, tasks) ? adapted : unadapted)
          .add(m);
    }
    final style = Theme.of(context)
        .textTheme
        .labelSmall
        ?.copyWith(fontWeight: FontWeight.bold);
    return [
      for (final m in adapted)
        DropdownMenuItem(value: m.packageId, child: Text(m.displayName)),
      if (unadapted.isNotEmpty && adapted.isNotEmpty)
        DropdownMenuItem(
          value: '__unadapted_group__',
          enabled: false,
          child: Text(
            dict['workbench.unadaptedGroup'] ?? 'Generic console',
            style: style,
          ),
        ),
      for (final m in unadapted)
        DropdownMenuItem(value: m.packageId, child: Text(m.displayName)),
    ];
  }

  /// 能力（任务）下拉；只有一个能力时显示但禁用。
  Widget _taskSelector({
    required String task,
    required List<String> tasks,
    required Map<String, String> dict,
  }) {
    if (task.isEmpty) return const SizedBox.shrink();
    final values = tasks.isEmpty ? <String>[task] : tasks;
    final value = values.contains(task) ? task : values.first;
    final enabled = values.length > 1;
    return InputDecorator(
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        isDense: true,
        enabled: enabled,
        labelText: dict['workbench.task'] ?? 'Capability',
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          isDense: true,
          items: [
            for (final t in values)
              DropdownMenuItem(
                value: t,
                child: Text(workbenchTaskLabel(dict, t)),
              ),
          ],
          onChanged: enabled
              ? (v) {
                  if (v == null || v == _selectedTask) return;
                  setState(() {
                    _selectedTask = v;
                    _notice = null;
                  });
                }
              : null,
        ),
      ),
    );
  }

  Future<void> _openIssue() async {
    await launchUrl(
      Uri.parse(_issueUrl),
      mode: LaunchMode.externalApplication,
    );
  }

  WorkbenchModelController _modelController(
    String packageId,
    String task,
    WorkbenchRegistration reg,
    ModelSpec spec,
  ) {
    final key = '$packageId|$task';
    return _modelCtrls.putIfAbsent(key, () {
      final controller = reg.controller(packageId, spec);
      final saved = ref.read(appConfigProvider).modelParams[spec.family];
      if (saved != null && saved.isNotEmpty) {
        controller.setAdvancedValues(Map<String, String>.from(saved));
      }
      controller.onAdvancedSaved = () => _saveAdvanced(spec.family, controller);
      return controller;
    });
  }

  GenericWorkbenchController _genericController(
    String packageId,
    String task,
    ModelSpec spec,
  ) {
    final key = '$packageId|$task';
    final existing = _modelCtrls[key];
    if (existing is GenericWorkbenchController) return existing;
    final controller = GenericWorkbenchController(packageId, spec, task);
    _modelCtrls[key] = controller;
    return controller;
  }

  Future<void> _pickGenericAudio(GenericWorkbenchController ctrl) async {
    final f = await openFile(acceptedTypeGroups: const [
      XTypeGroup(
        label: 'Audio',
        extensions: kWorkbenchAudioExtensions,
      ),
    ]);
    if (f == null) return;
    ctrl.setAudio(f.path);
    ref.read(audioPlayerProvider).load(f.path, title: f.name);
  }

  void _saveAdvanced(String family, WorkbenchModelController ctrl) {
    final advanced = Map<String, String>.from(ctrl.advancedValues());
    if (_sameMap(ref.read(appConfigProvider).modelParams[family], advanced)) {
      return;
    }
    unawaited(ref.read(appConfigProvider.notifier).update((c) {
      if (advanced.isEmpty) {
        c.modelParams.remove(family);
      } else {
        c.modelParams[family] = advanced;
      }
    }));
  }

  void _enqueueModel(
    ModelCatalogEntry entry,
    String task,
    WorkbenchModelController ctrl,
  ) {
    final error = ctrl.validate();
    if (error != null) {
      _toast(tr(ref, error), autoHide: true);
      return;
    }
    final call = ctrl.buildCall();
    if (call == null) {
      _toast(tr(ref, 'workbench.incomplete'), autoHide: true);
      return;
    }
    _enqueueCall(entry, task, call);
  }

  bool _sameMap(Map<String, String>? a, Map<String, String> b) {
    if (a == null || a.length != b.length) return false;
    for (final e in b.entries) {
      if (a[e.key] != e.value) return false;
    }
    return true;
  }

  void _enqueueCall(
    ModelCatalogEntry entry,
    String task,
    WorkbenchCall call,
  ) {
    _noticeTimer?.cancel();
    if (_notice != null) setState(() => _notice = null);
    _rememberModel(entry.packageId);
    final type = switch (task) {
      'tts' => RecordType.tts,
      'asr' => RecordType.asr,
      'vc' => RecordType.vc,
      _ => RecordType.other,
    };
    final sessionCtrl = ref.read(currentSessionProvider);
    final record = sessionCtrl.addRecord(
      type: type,
      family: entry.family,
      packageId: entry.packageId,
      status: 'queued',
      inputs: call.recordInputs,
    );
    setState(() => _selectedRecordId = record.id);
    ref
        .read(generationQueueProvider)
        .enqueue(sessionCtrl.session.id, record.id);
  }
}
