import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:path/path.dart' as p;

import '../core/app_logger.dart';
import '../core/audio_transcoder.dart';
import '../core/server_client.dart';
import '../features/workbench/workbench_contract.dart';
import '../models/model_catalog_entry.dart';
import '../models/model_spec.dart';
import '../models/server_snapshot.dart';
import '../models/session.dart';
import '../features/workbench/generic/generic_controller.dart';
import '../features/workbench/workbench_registry.dart';
import 'app_providers.dart';
import 'catalog_providers.dart';
import 'library_providers.dart';
import 'player_providers.dart';
import 'server_providers.dart';
import 'session_providers.dart';

/// 队列里的一项：只记 归属会话 + 记录 id（记录本身已含类型/模型/输入快照）。
class GenQueueItem {
  GenQueueItem({required this.sessionId, required this.recordId});

  final String sessionId;
  final String recordId;
}

/// 生成任务队列：单并发顺序执行；未完成的记录排队、完成的进"会话记录"。
class GenerationQueue extends ChangeNotifier {
  GenerationQueue(this._ref);

  final Ref _ref;
  final List<GenQueueItem> _items = [];
  String? _runningId;
  String? _runningSessionId;
  DateTime? _runningSince;

  /// 当前任务已重试次数（UI 显示"重试 N 次"，并在重试时重置计时）。
  int _retryCount = 0;

  /// 中止锁：一旦置位，队列不再推进、服务端返回也不再落库。
  bool _aborted = false;

  /// 暂停中：用户点了暂停，正在等当前任务完成。
  bool _pausing = false;

  /// 已暂停：当前任务已完成，队列停住（排队项保留）。
  bool _paused = false;

  List<GenQueueItem> get items => List.unmodifiable(_items);
  String? get runningId => _runningId;
  DateTime? get runningSince => _runningSince;
  bool get busy => _runningId != null;
  int get retryCount => _retryCount;
  bool get pausing => _pausing;
  bool get paused => _paused;

  void enqueue(String sessionId, String recordId) {
    // 有新任务时自动恢复队列（清除暂停）。
    _paused = false;
    _pausing = false;
    _items.add(GenQueueItem(sessionId: sessionId, recordId: recordId));
    AppLogger.info('task enqueued: session=$sessionId, record=$recordId');
    notifyListeners();
    unawaited(_pump());
  }

  /// 暂停：等当前任务完成才算真正暂停（空闲则直接暂停）。
  void pause() {
    if (_aborted) return;
    if (_runningId != null) {
      _pausing = true;
    } else {
      _paused = true;
    }
    notifyListeners();
  }

  /// 开始/继续：清除暂停，把当前会话中排队的记录入队并推进。
  void start() {
    if (_aborted) return;
    _paused = false;
    _pausing = false;
    final ctrl = _ref.read(currentSessionProvider);
    final queued = _items.map((it) => it.recordId).toSet();
    for (final r in ctrl.session.records) {
      if (r.status == 'queued' &&
          r.id != _runningId &&
          !queued.contains(r.id)) {
        _items.add(GenQueueItem(sessionId: ctrl.session.id, recordId: r.id));
      }
    }
    notifyListeners();
    unawaited(_pump());
  }

  /// 取消一个尚未开始执行的排队任务。
  void cancelQueued(String recordId) {
    if (_runningId == recordId) return;
    final n = _items.length;
    _items.removeWhere((it) => it.recordId == recordId);
    if (_items.length != n) notifyListeners();
  }

  /// 中止队列（退出时用）：置中止锁、清空内存队列，并把运行中的记录回退为"排队"。
  /// 置锁后队列不再推进，正在执行的请求即便返回也不落库。
  void abort() {
    _aborted = true;
    _items.clear();
    _markQueued(_runningSessionId, _runningId);
    notifyListeners();
  }

  void _markQueued(String? sessionId, String? recordId) {
    if (sessionId == null || recordId == null) return;
    final ctrl = _ref.read(currentSessionProvider);
    if (ctrl.session.id == sessionId) {
      final i = ctrl.session.records.indexWhere((r) => r.id == recordId);
      if (i >= 0) {
        final r = ctrl.session.records[i];
        if (r.status == 'generating' || r.status == 'queued') {
          r.status = 'queued';
          r.outputs.clear();
          ctrl.replaceRecord(r);
        }
      }
      return;
    }
    final store = _ref.read(sessionStoreProvider);
    final s = store.loadSession(sessionId);
    if (s == null) return;
    for (final r in s.records) {
      if (r.id == recordId &&
          (r.status == 'generating' || r.status == 'queued')) {
        r.status = 'queued';
        r.outputs.clear();
        store.saveRecord(sessionId, r);
      }
    }
  }

  Future<void> _pump() async {
    if (_aborted ||
        _paused ||
        _pausing ||
        _runningId != null ||
        _items.isEmpty) {
      return;
    }
    final item = _items.first;
    _runningId = item.recordId;
    _runningSessionId = item.sessionId;
    _runningSince = DateTime.now();
    notifyListeners();
    try {
      await _run(item);
    } catch (_) {}
    _runningId = null;
    _runningSessionId = null;
    _runningSince = null;
    if (_aborted) {
      notifyListeners();
      return;
    }
    _items.removeAt(0);
    // 暂停请求：当前任务已完成，进入"已暂停"。
    if (_pausing) {
      _pausing = false;
      _paused = true;
      notifyListeners();
      return;
    }
    notifyListeners();
    if (!_paused && _items.isNotEmpty) unawaited(_pump());
  }

  Session _sessionOf(GenQueueItem it) {
    final cur = _ref.read(currentSessionProvider).session;
    if (cur.id == it.sessionId) return cur;
    return _ref.read(sessionStoreProvider).loadSession(it.sessionId) ?? cur;
  }

  void _persist(GenQueueItem it, GenerationRecord r) {
    final ctrl = _ref.read(currentSessionProvider);
    if (ctrl.session.id == it.sessionId) {
      ctrl.replaceRecord(r);
    } else {
      _ref.read(sessionStoreProvider).saveRecord(it.sessionId, r);
    }
  }

  ModelCatalogEntry? _entryFor(String packageId) {
    for (final e in _ref.read(modelLibraryProvider).entries) {
      if (e.packageId == packageId) return e;
    }
    return null;
  }

  Future<String> _ensureServer(
    String modelId,
    Map<String, String> dict,
  ) async {
    final versions = await _ref.read(versionsProvider.future);
    if (versions.isNotEmpty) {
      try {
        await ensureServerStartedRef(_ref, requireModelId: modelId);
      } catch (_) {}
    }
    // （重）启动后需等待就绪，避免"没等好就跑"导致误报未就绪（最多 ~30s）。
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      final snap = _ref.read(serverControllerProvider);
      if (snap.isRunning && snap.healthy) return snap.recordVersion;
      if (snap.lifecycle == ServerLifecycle.error ||
          snap.lifecycle == ServerLifecycle.stopped) {
        break;
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }
    final snap = _ref.read(serverControllerProvider);
    if (!(snap.isRunning && snap.healthy)) {
      throw _Msg(dict['workbench.serverNotReady'] ?? 'Server not ready');
    }
    return snap.recordVersion;
  }

  /// 失败时写一次"对接诊断"：客户端实际请求地址 + 生效端口 + 状态，
  /// 便于定位"端口不一致导致连接被拒"。仅在失败时调用。
  void _logContactDiag(String recordId, String msg) {
    final client = _ref.read(serverClientProvider);
    final snap = _ref.read(serverControllerProvider);
    final ctrl = _ref.read(serverControllerProvider.notifier);
    AppLogger.error('task contact diag: record=$recordId, '
        'client=${client.baseUrl}, effectivePort=${ctrl.effectivePort}, '
        'lifecycle=${snap.lifecycle}, healthy=${snap.healthy}, err=$msg');
  }

  Future<void> _run(GenQueueItem it) async {
    final dict = _ref.read(stringsProvider);
    final session = _sessionOf(it);
    final idx = session.records.indexWhere((r) => r.id == it.recordId);
    if (idx < 0) return; // 记录已被删除
    final record = session.records[idx];

    if (_aborted) return;
    _retryCount = 0;
    record.status = 'generating';
    _persist(it, record);
    final call = _buildCallFromRecord(record);
    if (call == null) {
      record.status = 'failed';
      record.error = dict['workbench.unsupportedTask'] ?? 'Unsupported task';
      _persist(it, record);
      notifyListeners();
      return;
    }
    AppLogger.info(
        'task start: session=${it.sessionId}, record=${it.recordId}, '
        'type=${record.type}, model=${call.modelId}');
    // 显存不足（模型常驻、新模型权重分配失败）时：重启一次服务端后重试一次；
    // 每个任务最多重试一次，重试再失败即判失败，绝不循环。
    var retried = false;
    // 卡死恢复：本次任务最多重启服务端一次。
    var restartedForBusy = false;
    // 待重试标记：服务端就绪、真正重新发送请求前才计数并重置计时。
    var pendingRetry = false;
    while (true) {
      try {
        final entry = _entryFor(record.packageId);
        if (entry == null) {
          throw _Msg(dict['workbench.modelMissing'] ?? 'Model not available');
        }
        record.audioCppVersion = await _ensureServer(call.modelId, dict);
        if (pendingRetry) {
          pendingRetry = false;
          _noteRetry(record.id);
        }
        await _runCall(it, record, call, dict);
        if (_aborted) return;
        record.status = 'done';
        AppLogger.info('task done: record=${it.recordId}');
        break;
      } catch (e) {
        if (_aborted) return;
        final msg = e is _Msg ? e.message : '$e';
        if (!retried && _isAllocFailure(msg)) {
          retried = true;
          pendingRetry = true;
          final ok = await _unloadForAlloc(it);
          if (ok) {
            // 显存已释放：重试该任务一次。
            AppLogger.info(
                'memory released, retrying task: record=${it.recordId}');
            record.outputs.clear();
            record.error = '';
            continue;
          }
          // 连续 3 次无法释放显存：判失败 + 停止队列 + 持久提示。
          record.status = 'failed';
          record.error = msg;
          _logContactDiag(record.id, msg);
          AppLogger.error('task failed: record=${it.recordId}', e);
          _stopQueueAfterRecoverFailure(dict);
          break;
        }
        // 模型推理卡死（busy / wedged / 客户端接收超时）：audio.cpp 的 busy_timeout
        // 只拒绝能进入处理线程的新请求，不会中断/释放已卡死的推理；卡死还可能占满
        // 工作线程，连 503 都发不出来。唯一恢复手段是杀进程重启。重启后重试一次；
        // 仍失败则暂停队列（保留排队项），避免后续任务批量失败。
        final wedged = _isBusyStuckFailure(msg) || _isReceiveTimeout(msg);
        if (wedged) {
          if (!restartedForBusy) {
            restartedForBusy = true;
            pendingRetry = true;
            _ref.read(workbenchNoticeProvider.notifier).state =
                dict['workbench.timeoutRestarting'] ?? msg;
            if (await _restartForBusy(call.modelId, dict, it.recordId)) {
              record.outputs.clear();
              record.error = '';
              AppLogger.info(
                  'server restarted after wedged timeout; retrying task: record=${it.recordId}');
              continue;
            }
            // 重启失败：按"服务端不可用"处理（暂停队列，保留排队项）。
            record.status = 'failed';
            record.error = msg;
            _logContactDiag(record.id, msg);
            AppLogger.error(
                'task failed (model wedged, server restart failed): record=${it.recordId}',
                e);
            _pauseQueueForServerDown(record.id, dict, msg);
            break;
          }
          // 重启后仍卡死：判失败并暂停队列，避免后续任务全部失败。
          record.status = 'failed';
          record.error = msg;
          _logContactDiag(record.id, msg);
          AppLogger.error(
              'task failed (model still wedged after restart): record=${it.recordId}',
              e);
          _pauseQueueForBusy(dict, record.id, msg);
          break;
        }
        // 连接类错误（服务端正在重启 / 端口未就绪等）：再确保一次服务端就绪并重试一次。
        if (!retried && _isContactFailure(e, msg)) {
          retried = true;
          pendingRetry = true;
          AppLogger.info(
              'contact failure, re-ensure server and retry: record=${it.recordId}');
          record.outputs.clear();
          record.error = '';
          continue;
        }
        // 重试后仍是连接类错误 → 视为"服务端不可用"（起不来 / 中途异常退出）：
        // 本次判失败，并**暂停整个队列**（保留排队项），避免批量失败。
        if (_isContactFailure(e, msg)) {
          record.status = 'failed';
          record.error = msg;
          _logContactDiag(record.id, msg);
          AppLogger.error('task failed: record=${it.recordId}', e);
          _pauseQueueForServerDown(record.id, dict, msg);
          break;
        }
        // 非分配类错误，或重试后仍失败：判失败并跳到下一个任务。
        record.status = 'failed';
        record.error = msg;
        _logContactDiag(record.id, msg);
        AppLogger.error('task failed: record=${it.recordId}', e);
        // 让错误在界面可见（底部持久提示条，不自动关闭）。
        final serverFailed = e is ServerError && e.statusCode != null;
        _ref.read(workbenchErrorNoticeProvider.notifier).state = serverFailed
            ? '${dict['workbench.serverError'] ?? 'Server error'}\n$msg'
            : msg;
        break;
      }
    }
    _persist(it, record);
    notifyListeners();
  }

  ModelSpec? _specFor(String family) {
    final specs = _ref.read(specsProvider).value ?? const <ModelSpec>[];
    for (final spec in specs) {
      if (spec.family == family) return spec;
    }
    return null;
  }

  /// 由记录参数和当前模型控制器重建提交方案。
  WorkbenchCall? _buildCallFromRecord(GenerationRecord record) {
    final spec = _specFor(record.family);
    if (spec == null) return null;
    final registration =
        WorkbenchRegistry.registrationFor(record.family, record.type);
    if (registration != null) {
      final controller = registration.controller(record.packageId, spec);
      try {
        controller.restore(record);
        return controller.buildCall();
      } finally {
        controller.dispose();
      }
    }
    final controller =
        GenericWorkbenchController(record.packageId, spec, record.type);
    try {
      controller.restore(record);
      return controller.buildCall();
    } finally {
      controller.dispose();
    }
  }

  /// 按 call 执行：只处理传输、转码、落盘，不解释模型字段。
  Future<void> _runCall(
    GenQueueItem it,
    GenerationRecord record,
    WorkbenchCall call,
    Map<String, String> dict,
  ) async {
    final client = _ref.read(serverClientProvider);
    final paths = _ref.read(appPathsProvider);
    final transcoder = AudioTranscoder(
      tmpDir: paths.tmpDir,
      appRoot: paths.appRoot,
    );
    final tool = await transcoder.toolPath();
    File? tmp;
    try {
      final request = _copyJson(call.request);
      if (call.transport == 'multipart') {
        final audio = call.audioPath ?? (request['audio']?.toString() ?? '');
        final upload = await _prepareUpload(
            audio, tool, transcoder, dict, call.audioRate, call.audioChannels);
        tmp = upload.tmp;
        final text = await client.transcription(
          model: call.modelId,
          audioBytes: await upload.file.readAsBytes(),
          filename: upload.file.uri.pathSegments.last,
          language: request['language']?.toString(),
        );
        record.ret = {'text': text};
        await _saveInputAudio(it, record, audio);
        return;
      }

      if (call.audioPath != null && call.audioPath!.isNotEmpty) {
        final upload = await _prepareUpload(call.audioPath!, tool, transcoder,
            dict, call.audioRate, call.audioChannels);
        tmp = upload.tmp;
        _replaceAudio(request, call.audioPath!, upload.file.path);
      }

      if (call.responseFormat == 'bytes') {
        final bytes = await client.postJsonBytes(call.endpoint, request);
        await _saveOutputAudio(it, record, bytes);
      } else if (call.responseFormat == 'json_base64') {
        final m = await client.postJson(call.endpoint, request);
        final audio = m['audio'];
        if (audio is! String || audio.isEmpty) {
          throw _Msg(
              dict['workbench.taskNoAudio'] ?? 'Task result has no audio');
        }
        await _saveOutputAudio(it, record, base64Decode(audio));
      } else if (call.responseFormat == 'json_text') {
        final m = await client.postJson(call.endpoint, request);
        final ret = Map<String, dynamic>.from(m)..remove('timing');
        record.ret = ret;
        final audio = call.audioPath;
        if (audio != null && audio.isNotEmpty) {
          await _saveInputAudio(it, record, audio);
        }
      } else {
        throw _Msg('unsupported response format: ${call.responseFormat}');
      }
    } finally {
      if (tmp != null) {
        try {
          if (tmp.existsSync()) tmp.deleteSync();
        } catch (_) {}
      }
    }
  }

  Map<String, dynamic> _copyJson(Map<String, dynamic> source) {
    try {
      final decoded = jsonDecode(jsonEncode(source));
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return Map<String, dynamic>.from(source);
  }

  void _replaceAudio(
      Map<String, dynamic> request, String original, String wav) {
    if (request['audio']?.toString() == original) request['audio'] = wav;
    final inner = request['request'];
    if (inner is Map && inner['audio']?.toString() == original) {
      inner['audio'] = wav;
    }
  }

  Future<({File file, File? tmp})> _prepareUpload(
    String audio,
    String? tool,
    AudioTranscoder transcoder,
    Map<String, String> dict,
    int rate,
    int channels,
  ) async {
    final file = File(audio);
    if (tool == null) {
      if (p.extension(audio).toLowerCase() != '.wav') {
        throw _Msg(dict['workbench.wavOnly'] ?? 'Only WAV audio is supported');
      }
      return (file: file, tmp: null);
    }
    try {
      final wav =
          await transcoder.toWav(audio, tool, rate: rate, channels: channels);
      return (file: wav, tmp: wav);
    } on AudioTranscodeException catch (e) {
      throw _Msg(
          '${dict['workbench.transcodeFailed'] ?? 'Audio transcode failed'}: ${e.message}');
    }
  }

  Future<void> _saveOutputAudio(
    GenQueueItem it,
    GenerationRecord record,
    List<int> bytes,
  ) async {
    final store = _ref.read(sessionStoreProvider);
    final outPath = store.audioPath(it.sessionId, record.id);
    await File(outPath).parent.create(recursive: true);
    await File(outPath).writeAsBytes(bytes);
    record.outputs.add(RecordOutput(
      kind: 'audio',
      path: store.relativeAudioPath(it.sessionId, record.id),
    ));
    final player = _ref.read(audioPlayerProvider);
    if (player.currentPath == null) {
      player.load(
        outPath,
        title: record.inputs['text'] ??
            record.inputs['voice_name'] ??
            record.family,
      );
    }
  }

  Future<void> _saveInputAudio(
    GenQueueItem it,
    GenerationRecord record,
    String source,
  ) async {
    final file = File(source);
    if (!file.existsSync()) return;
    try {
      final store = _ref.read(sessionStoreProvider);
      final ext = p.extension(source);
      final dst =
          p.join(store.audioDir(it.sessionId).path, '${record.id}_in$ext');
      await File(dst).parent.create(recursive: true);
      await file.copy(dst);
      record.outputs.add(RecordOutput(
        kind: 'audio',
        path: p.join('audio', it.sessionId, '${record.id}_in$ext'),
      ));
    } catch (_) {}
  }

  /// 分配失败后经 API 卸载常驻模型释放显存：最多 3 次，任一次成功即通过。
  Future<bool> _unloadForAlloc(GenQueueItem it) async {
    for (var i = 1; i <= 3; i++) {
      AppLogger.info(
          'allocation failure, unloading models ($i/3): record=${it.recordId}');
      if (await unloadAllModelsRef(_ref)) return true;
    }
    return false;
  }

  /// 无法释放显存：停止队列（保留排队项，便于修复后继续）并给出持久提示。
  void _stopQueueAfterRecoverFailure(Map<String, String> dict) {
    _pausing = true;
    final msg = dict['workbench.memoryReleaseFailed'] ??
        dict['workbench.serverNotReady'] ??
        'Failed to release GPU memory; queue stopped';
    _ref.read(workbenchErrorNoticeProvider.notifier).state = msg;
    AppLogger.error('failed to release memory 3x; generation queue stopped');
    notifyListeners();
  }

  /// 服务端不可用（起不来 / 中途异常退出）：暂停整个队列，保留排队项，
  /// 避免"每个任务逐个失败"的批量失败；恢复后由用户手动继续。
  void _pauseQueueForServerDown(
      String recordId, Map<String, String> dict, String msg) {
    _pausing = true;
    _ref.read(workbenchErrorNoticeProvider.notifier).state =
        dict['workbench.serverNotReady'] ?? 'Server not ready';
    AppLogger.error(
        'server unavailable; generation queue paused: record=$recordId, err=$msg');
    notifyListeners();
  }

  /// 是否为「后端显存 / 权重分配失败」类错误（用于触发一次重启重试）。
  static bool _isAllocFailure(String msg) {
    final m = msg.toLowerCase();
    return m.contains('failed to allocate') ||
        m.contains('out of memory') ||
        m.contains('unable to allocate') ||
        m.contains('backend weight buffer') ||
        m.contains('oom');
  }

  /// 是否为「连接 / 服务端未就绪」类错误（用于再等一次服务端就绪并重试一次）。
  static bool _isContactFailure(Object error, String msg) {
    if (error is ServerError && error.statusCode != null) return false;
    // 接收超时说明请求已送达（服务端在跑但不响应），交给"卡死"分支处理。
    if (_isReceiveTimeout(msg)) return false;
    final m = msg.toLowerCase();
    return m.contains('dioexception') ||
        m.contains('socketexception') ||
        m.contains('connection') ||
        m.contains('refused') ||
        m.contains('远程计算机拒绝') ||
        m.contains('not ready');
  }

  /// 记录一次重试：递增计数并通知 UI（显示"重试 N 次"，同时重置生成计时）。
  void _noteRetry(String recordId) {
    _retryCount++;
    AppLogger.info('retry #$_retryCount: record=$recordId');
    notifyListeners();
  }

  /// 模型卡死后重启服务端（卡死的推理无法取消，只能杀进程释放模型锁）。
  Future<bool> _restartForBusy(
      String modelId, Map<String, String> dict, String recordId) async {
    AppLogger.info(
        'model wedged/busy: restarting server before retry: record=$recordId');
    try {
      await _ref.read(serverControllerProvider.notifier).stop();
    } catch (_) {}
    await _ensureServer(modelId, dict);
    final snap = _ref.read(serverControllerProvider);
    return snap.isRunning && snap.healthy;
  }

  /// 卡死且重启后仍失败：暂停队列（保留排队项）并给出持久提示。
  void _pauseQueueForBusy(
      Map<String, String> dict, String recordId, String msg) {
    _pausing = true;
    _ref.read(workbenchErrorNoticeProvider.notifier).state =
        dict['workbench.busyPaused'] ?? msg;
    AppLogger.error(
        'model still wedged after server restart; queue paused: record=$recordId, err=$msg');
    notifyListeners();
  }

  /// 是否为「模型被卡死推理占用」类错误（audio.cpp 503：busy / wedged）。
  static bool _isBusyStuckFailure(String msg) {
    final m = msg.toLowerCase();
    return m.contains('is busy') ||
        m.contains('wedged') ||
        m.contains('busy_timeout_ms');
  }

  /// 客户端接收超时：请求已发出，但超时内没收到任何响应。
  /// 卡死推理可能占满服务端工作线程，连 503 都发不出来，因此也按卡死处理。
  static bool _isReceiveTimeout(String msg) {
    final m = msg.toLowerCase();
    return m.contains('receive timeout') || m.contains('receivetimeout');
  }
}

class _Msg implements Exception {
  _Msg(this.message);
  final String message;
  @override
  String toString() => message;
}

final generationQueueProvider =
    ChangeNotifierProvider<GenerationQueue>((ref) => GenerationQueue(ref));
