import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:path/path.dart' as p;

import '../core/app_logger.dart';
import '../core/audio_transcoder.dart';
import '../core/variant_key.dart';
import '../models/model_catalog_entry.dart';
import '../models/server_snapshot.dart';
import '../models/session.dart';
import '../models/workbench_rule.dart';
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
  String? _lastText;

  /// 中止锁：一旦置位，队列不再推进、服务端返回也不再落库。
  bool _aborted = false;

  /// 暂停中：用户点了暂停，正在等当前任务完成。
  bool _pausing = false;

  /// 已暂停：当前任务已完成，队列停住（排队项保留）。
  bool _paused = false;

  List<GenQueueItem> get items => List.unmodifiable(_items);
  String? get runningId => _runningId;
  DateTime? get runningSince => _runningSince;
  String? get lastText => _lastText;
  bool get busy => _runningId != null;
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

  Future<void> _ensureServer(String packageId, Map<String, String> dict) async {
    final versions = await _ref.read(versionsProvider.future);
    if (versions.isNotEmpty) {
      try {
        await ensureServerStartedRef(_ref, requireModelId: packageId);
      } catch (_) {}
    }
    // （重）启动后需等待就绪，避免"没等好就跑"导致误报未就绪（最多 ~30s）。
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      final snap = _ref.read(serverControllerProvider);
      if (snap.isRunning && snap.healthy) return;
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
    record.status = 'generating';
    _persist(it, record);
    AppLogger.info(
        'task start: session=${it.sessionId}, record=${it.recordId}, '
        'type=${record.type}, model=${record.packageId}');
    // 显存不足（模型常驻、新模型权重分配失败）时：重启一次服务端后重试一次；
    // 每个任务最多重试一次，重试再失败即判失败，绝不循环。
    var retried = false;
    while (true) {
      try {
        final entry = _entryFor(record.packageId);
        if (entry == null) {
          throw _Msg(dict['workbench.modelMissing'] ?? 'Model not available');
        }
        await _ensureServer(record.packageId, dict);
        if (record.type == RecordType.asr) {
          await _runAsr(it, record, entry, dict);
        } else {
          await _runTts(it, record, entry);
        }
        if (_aborted) return;
        record.status = 'done';
        if (record.type == RecordType.asr && record.text.isNotEmpty) {
          _lastText = record.text;
        }
        AppLogger.info('task done: record=${it.recordId}');
        break;
      } catch (e) {
        if (_aborted) return;
        final msg = e is _Msg ? e.message : '$e';
        if (!retried && _isAllocFailure(msg)) {
          retried = true;
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
        // 连接类错误（服务端正在重启 / 端口未就绪等）：再确保一次服务端就绪并重试一次。
        if (!retried && _isContactFailure(msg)) {
          retried = true;
          AppLogger.info(
              'contact failure, re-ensure server and retry: record=${it.recordId}');
          record.outputs.clear();
          record.error = '';
          continue;
        }
        // 重试后仍是连接类错误 → 视为"服务端不可用"（起不来 / 中途异常退出）：
        // 本次判失败，并**暂停整个队列**（保留排队项），避免批量失败。
        if (_isContactFailure(msg)) {
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
        _ref.read(workbenchErrorNoticeProvider.notifier).state = msg;
        break;
      }
    }
    _persist(it, record);
    notifyListeners();
  }

  Future<void> _runTts(
      GenQueueItem it, GenerationRecord record, ModelCatalogEntry entry) async {
    // 模型规则：提供字段名覆盖与指令伴随选项（通用代码，模型差异在规则）。
    final rules = _ref.read(workbenchRulesProvider).value ?? const {};
    final rule = rules[VariantKey.of(record.packageId)] ??
        rules[record.family] ??
        WorkbenchRule.none;
    final extra = <String, dynamic>{};
    final rt = _nz(record.inputs['reference_text']);
    if (rt != null) {
      extra[rule.fieldFor('referenceText', 'reference_text')] = rt;
    }
    final ins = _nz(record.inputs['instruction']);
    if (ins != null) {
      extra[record.inputs['instruction_key'] ?? 'instruction'] = ins;
      extra.addAll(rule.instructionOptions);
    }
    // 高级参数（记录快照里的 request options）；不覆盖专用字段。
    final paramsRaw = record.inputs['params'];
    if (paramsRaw != null && paramsRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(paramsRaw);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            final key = k.toString();
            final value = v?.toString() ?? '';
            if (value.isNotEmpty && !extra.containsKey(key)) {
              extra[key] = value;
            }
          });
        }
      } catch (_) {}
    }

    final client = _ref.read(serverClientProvider);
    final language = _nz(record.inputs['language']);
    // 语言提交位置由规则声明：languageKey 非空 → 提交到 options.<languageKey>；
    // 否则走顶层 `language`（通用 + Fallback）。
    final languageInOptions = language != null && rule.languageKey.isNotEmpty;
    if (languageInOptions) {
      extra[rule.languageKey] = language;
    }
    final topLevelLanguage = languageInOptions ? null : language;
    // 情感参考音频：需转码 WAV 并走通用任务路由（可携带 audio_input）。
    final emotionAudio = _nz(record.inputs['emotion_audio']);
    late final List<int> bytes;
    if (emotionAudio != null) {
      final paths = _ref.read(appPathsProvider);
      final transcoder =
          AudioTranscoder(tmpDir: paths.tmpDir, appRoot: paths.appRoot);
      final tool = await transcoder.toolPath();
      File? tmp;
      var wav = emotionAudio;
      if (tool != null) {
        try {
          tmp = await transcoder.toWav(emotionAudio, tool);
          wav = tmp.path;
        } on AudioTranscodeException catch (e) {
          throw _Msg('emotion audio transcode failed: ${e.message}');
        }
      } else if (p.extension(emotionAudio).toLowerCase() != '.wav') {
        throw _Msg('emotion reference audio requires WAV (no transcoder)');
      }
      try {
        bytes = await client.taskAudio(
          model: entry.packageId,
          request: {
            'text': record.inputs['text'] ?? '',
            'audio': wav,
            if (_nz(record.inputs['voice_ref']) != null)
              'voice_ref': record.inputs['voice_ref'],
            if (_nz(record.inputs['voice']) != null) 'voice': record.inputs['voice'],
            if (_nz(record.inputs['voice_id']) != null)
              'voice_id': record.inputs['voice_id'],
            if (topLevelLanguage != null) 'language': topLevelLanguage,
            if (extra.isNotEmpty) 'options': extra,
          },
        );
      } finally {
        if (tmp != null) {
          try {
            if (tmp.existsSync()) tmp.deleteSync();
          } catch (_) {}
        }
      }
    } else {
      // 内置音色（speaker / cached_voice_id）走顶层 `voice`；voice 库预设优先。
      final voice = _nz(record.inputs['voice']) ?? _nz(record.inputs['voice_id']);
      bytes = await client.speech(
        model: entry.packageId,
        input: record.inputs['text'] ?? '',
        voice: voice,
        voiceRef: _nz(record.inputs['voice_ref']),
        language: topLevelLanguage,
        responseFormat: 'wav',
        extra: extra,
      );
    }
    final store = _ref.read(sessionStoreProvider);
    final outPath = store.audioPath(it.sessionId, record.id);
    await File(outPath).parent.create(recursive: true);
    await File(outPath).writeAsBytes(bytes);
    record.outputs.add(RecordOutput(
      kind: 'audio',
      path: store.relativeAudioPath(it.sessionId, record.id),
    ));
    // 播放器已可见（用户在试听）时不抢占，避免打断。
    final player = _ref.read(audioPlayerProvider);
    if (player.currentPath == null) {
      player.load(outPath, title: record.inputs['text'] ?? entry.family);
    }
  }

  Future<void> _runAsr(GenQueueItem it, GenerationRecord record,
      ModelCatalogEntry entry, Map<String, String> dict) async {
    final path = record.inputs['audio'] ?? '';
    final file = File(path);
    final paths = _ref.read(appPathsProvider);
    final transcoder = AudioTranscoder(
      tmpDir: paths.tmpDir,
      appRoot: paths.appRoot,
    );
    final tool = await transcoder.toolPath();
    File? tmp;
    var upload = file;
    if (tool != null) {
      try {
        tmp = await transcoder.toWav(path, tool, rate: 16000, channels: 1);
      } on AudioTranscodeException catch (e) {
        throw _Msg(
            '${dict['workbench.transcodeFailed'] ?? 'Audio transcode failed'}: ${e.message}');
      }
      upload = tmp;
    } else if (p.extension(path).toLowerCase() != '.wav') {
      throw _Msg(dict['workbench.wavOnly'] ?? 'Only WAV audio is supported');
    }

    try {
      final client = _ref.read(serverClientProvider);
      final text = await client.transcription(
        model: entry.packageId,
        audioBytes: await upload.readAsBytes(),
        filename: upload.uri.pathSegments.last,
        language: _nz(record.inputs['language']),
      );
      final store = _ref.read(sessionStoreProvider);
      try {
        final ext = p.extension(path);
        final dst = p.join(
            store.audioDir(it.sessionId).path, '${record.id}_in$ext');
        await File(dst).parent.create(recursive: true);
        await file.copy(dst);
        record.outputs.add(RecordOutput(
          kind: 'audio',
          path: p.join('audio', it.sessionId, '${record.id}_in$ext'),
        ));
      } catch (_) {}
      record.text = text;
    } finally {
      if (tmp != null) {
        try {
          if (tmp.existsSync()) tmp.deleteSync();
        } catch (_) {}
      }
    }
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
  static bool _isContactFailure(String msg) {
    final m = msg.toLowerCase();
    return m.contains('dioexception') ||
        m.contains('socketexception') ||
        m.contains('connection') ||
        m.contains('refused') ||
        m.contains('远程计算机拒绝') ||
        m.contains('not ready');
  }

  static String? _nz(String? s) => (s == null || s.isEmpty) ? null : s;
}

class _Msg implements Exception {
  _Msg(this.message);
  final String message;
  @override
  String toString() => message;
}

final generationQueueProvider =
    ChangeNotifierProvider<GenerationQueue>((ref) => GenerationQueue(ref));
