import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/legacy.dart';
import 'package:path/path.dart' as pathlib;

import 'app_config.dart';
import 'app_logger.dart';
import 'app_paths.dart';
import 'port_arbiter.dart';
import 'server_client.dart';
import '../models/audio_cpp_version.dart';
import '../models/health_info.dart';
import '../models/server_snapshot.dart';

class ServerController extends StateNotifier<ServerSnapshot> {
  ServerController({required AppPaths paths, required AppConfig config})
      : _paths = paths,
        _config = config,
        super(const ServerSnapshot());

  final AppPaths _paths;
  AppConfig _config;

  Process? _process;
  StreamSubscription<String>? _outSub;
  StreamSubscription<String>? _errSub;
  Timer? _healthTimer;
  bool _stopRequested = false;
  int? _adoptPid;
  File? _runLogFile;
  IOSink? _logSink;
  final List<String> _pendingLog = [];
  Timer? _logTimer;

  ServerClient get client =>
      ServerClient('http://${_config.host}:${_config.port}');

  void updateConfig(AppConfig config) => _config = config;

  File get _serverRecordFile =>
      File(pathlib.join(_paths.dataDir.path, 'server.json'));

  /// 读取"本应用拉起的 server"记录（pid/port/exe），用于意外中断后只接管自身实例。
  Future<Map<String, dynamic>?> _readServerRecord() async {
    try {
      final f = _serverRecordFile;
      if (!f.existsSync()) return null;
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeServerRecord(int pid, int port, String exePath) async {
    try {
      final f = _serverRecordFile;
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode({
        'pid': pid,
        'port': port,
        'exe_path': exePath,
        'backend': _config.backend,
      }));
    } catch (_) {}
  }

  void _clearServerRecord() {
    try {
      final f = _serverRecordFile;
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  void _log(String line) {
    // 应用日志（与服务端日志分开落盘）：记录服务端事件，便于排查。
    AppLogger.info('[server] $line');
    // 缓冲 + 批量刷新：避免服务端日志突发时逐行同步写盘/通知导致 UI 卡顿。
    _pendingLog.add(line);
    if (_pendingLog.length >= 400) {
      _flushLog();
    } else {
      _logTimer ??= Timer(const Duration(milliseconds: 250), _flushLog);
    }
  }

  void _flushLog() {
    _logTimer?.cancel();
    _logTimer = null;
    if (_pendingLog.isEmpty) return;
    final batch = List<String>.of(_pendingLog);
    _pendingLog.clear();
    var snap = state;
    for (final line in batch) {
      snap = snap.withLog(line);
    }
    state = snap;
    final sink = _logSink;
    if (sink != null) {
      for (final line in batch) {
        sink.writeln(line);
      }
    }
  }

  Future<void> start(
    AudioCppVersion version,
    AppConfig config, {
    List<Map<String, dynamic>> models = const [],
  }) async {
    _config = config;
    _stopRequested = false;
    _adoptPid = null;
    _healthTimer?.cancel();
    _healthTimer = null;

    // audio.cpp 服务端要求 models 为非空数组（--no-ui 下未启用 ui_management）。
    if (models.isEmpty) {
      _log('No installed models; server not started '
          '(audio.cpp requires at least one model).');
      state = ServerSnapshot(
        lifecycle: ServerLifecycle.stopped,
        exeName: version.name,
        logLines: state.logLines,
      );
      return;
    }

    state = ServerSnapshot(
      lifecycle: ServerLifecycle.starting,
      exeName: version.name,
      error: null,
      healthy: false,
      startedAt: DateTime.now(),
      logLines: const [],
    );
    _logSink?.close();
    _logSink = null;
    if (_config.serverLogToFile) {
      await _paths.logDir.create(recursive: true);
      _runLogFile = File(
        pathlib.join(_paths.logDir.path, 'server-${_timestamp()}.log'),
      );
      _logSink = _runLogFile!.openWrite(mode: FileMode.append);
    } else {
      _runLogFile = null;
    }
    _log('Starting audiocpp_server: ${version.name}');
    _log('Config backend=${_config.backend} '
        '${AppConfig.gpuBackends.contains(_config.backend) ? 'device=${_config.device} ' : ''}'
        'threads=${_config.threads} models=${models.length}');
    _log('Working directory: ${version.path}');

    var effectivePort = _config.port;
    var adoptPid = 0;
    HealthInfo? adoptedHealth;

    // 只接管"本应用之前拉起并记录"的实例，避免误接管其它管理端的 audio.cpp。
    final rec = await _readServerRecord();
    if (rec != null) {
      final recPid = (rec['pid'] as num?)?.toInt() ?? 0;
      final recPort = (rec['port'] as num?)?.toInt() ?? 0;
      if (recPid > 0 && recPort > 0) {
        final occ = await PortArbiter.probe(_config.host, recPort);
        if (occ != null &&
            occ.pid == recPid &&
            PortArbiter.sameExe(occ.exePath, version.serverExe.path)) {
          _log('Detected our own instance (PID=$recPid) on port $recPort');
          final h = await _waitHealth(_config.host, recPort);
          if (h != null && h.status == 'ok' && h.backend == _config.backend) {
            adoptPid = recPid;
            adoptedHealth = h;
            effectivePort = recPort;
          } else {
            _log('Our recorded instance does not match configuration; restarting');
          }
        }
      }
      if (adoptPid == 0) _clearServerRecord();
    }

    if (adoptPid > 0) {
      _adoptPid = adoptPid;
      final h = adoptedHealth!;
      _log('Server ready (adopted our instance) '
          'configured_backend=${h.backend} loaded_models=${h.models}');
      state = state.copyWith(
        lifecycle: ServerLifecycle.running,
        healthy: true,
        backend: h.backend,
        loadedModelsCount: h.models,
      );
      return;
    }

    // 端口被其它实例占用（非本应用记录的）：用备用端口，不抢占其它管理端的服务。
    final occupied = await PortArbiter.probe(_config.host, effectivePort);
    if (occupied != null) {
      _log('Port $effectivePort is in use by ${occupied.description}');
      final spare =
          await PortArbiter.findFreePort(_config.host, effectivePort + 1);
      if (spare == null) {
        _log('No spare port available above $effectivePort; giving up');
        state = state.copyWith(
          lifecycle: ServerLifecycle.error,
          error:
              'Port $effectivePort is in use by ${occupied.description} and no spare port is available',
        );
        return;
      }
      _log('Using spare port $spare instead');
      effectivePort = spare;
      _config.port = spare;
    }

    final serverJson = <String, dynamic>{
      'host': _config.host,
      'port': effectivePort,
      'backend': _config.backend,
      if (AppConfig.gpuBackends.contains(_config.backend))
        'device': _config.device,
      'threads': _config.threads,
      // 单次任务超时：服务端"忙等待"上限（启动时写入；与客户端接收超时配套，客户端稍大）。
      'busy_timeout_ms': _config.taskTimeoutSeconds * 1000,
      'lazy_load': true,
      // 限制常驻模型数：超出自动卸载，避免小显存下多模型叠加导致权重分配失败。
      'max_loaded_models': 1,
      'models': models,
      if (_paths.voiceDir.existsSync()) 'voice_dir': _paths.voiceDir.path,
    };
    final cfgFile = _paths.serverConfigFile();
    await cfgFile.parent.create(recursive: true);
    await cfgFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(serverJson),
    );

    final args = <String>['--config', cfgFile.path, '--no-ui'];

    try {
      _process = await Process.start(
        version.serverExe.path,
        args,
        workingDirectory: version.path,
        mode: ProcessStartMode.normal,
      );
    } catch (e) {
      _log('Start failed: $e');
      state = state.copyWith(
        lifecycle: ServerLifecycle.error,
        error: 'Start failed: $e',
      );
      return;
    }

    final p = _process!;
    _log('Server PID=${p.pid}');
    await _writeServerRecord(p.pid, effectivePort, version.serverExe.path);
    _outSub = p.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_log);
    _errSub = p.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_log);

    unawaited(p.exitCode.then((code) {
      if (!identical(p, _process)) return;
      if (_stopRequested) {
        _log('Server stopped by user (exit code=$code)');
      } else if (code == 0) {
        _log('Server exited (code=0)');
      } else {
        _log('Server exited abnormally (code=$code)');
      }
      _outSub?.cancel();
      _errSub?.cancel();
      _outSub = null;
      _errSub = null;
      _process = null;
      state = state.copyWith(
        lifecycle: ServerLifecycle.stopped,
        healthy: false,
        error: _stopRequested || code == 0
            ? null
            : 'Server process exited abnormally (code=$code)',
      );
    }));

    unawaited(_pollHealth());
  }

  Future<void> _pollHealth() async {
    var attempts = 0;
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      attempts++;
      if (_process == null || state.lifecycle != ServerLifecycle.starting) {
        _healthTimer?.cancel();
        _healthTimer = null;
        return;
      }
      if (attempts > 90) {
        _healthTimer?.cancel();
        _healthTimer = null;
        _log('Timed out waiting for server readiness (90s)');
        state = state.copyWith(
          lifecycle: ServerLifecycle.error,
          error: 'Timed out waiting for server readiness (90s)',
        );
        return;
      }
      try {
        final h = await client.health();
        if (h.status == 'ok') {
          _healthTimer?.cancel();
          _healthTimer = null;
          if (h.backend != _config.backend) {
            _log('WARNING: health reports backend=${h.backend} but configured '
                'backend=${_config.backend}; an existing instance may be '
                'holding the port');
          }
          _log('Server ready (health ok) configured_backend=${h.backend} '
              'loaded_models=${h.models}');
          state = state.copyWith(
            lifecycle: ServerLifecycle.running,
            healthy: true,
            backend: h.backend,
            loadedModelsCount: h.models,
          );
        }
      } catch (_) {}
    });
  }

  Future<void> stop() async {
    _clearServerRecord();
    _healthTimer?.cancel();
    _healthTimer = null;
    final adoptedPid = _adoptPid;
    if (adoptedPid != null && adoptedPid > 0) {
      _log('Stopping adopted instance (PID=$adoptedPid)...');
      _stopRequested = true;
      state = state.copyWith(
        lifecycle: ServerLifecycle.stopping,
        healthy: false,
        error: null,
      );
      try {
        Process.killPid(adoptedPid);
        _adoptPid = null;
        _log('Adopted instance stopped');
      } catch (e) {
        _log('Failed to stop adopted instance: $e');
      }
      state = state.copyWith(lifecycle: ServerLifecycle.stopped, healthy: false);
      return;
    }
    final p = _process;
    if (p == null) {
      state = state.copyWith(lifecycle: ServerLifecycle.stopped, healthy: false);
      return;
    }
    _log('Stopping server...');
    _stopRequested = true;
    state = state.copyWith(
      lifecycle: ServerLifecycle.stopping,
      healthy: false,
      error: null,
    );
    try {
      p.kill();
      await p.exitCode.timeout(const Duration(seconds: 5));
    } catch (_) {
      // 5s 内未退出（卡死的推理无法优雅退出）：强制终止。
      _log('Server did not exit within 5s; force-terminating');
      try {
        p.kill(ProcessSignal.sigkill);
      } catch (_) {}
    } finally {
      // 不依赖 exitCode 回调：确保清理并落到 stopped，
      // 避免状态卡在 stopping 导致无法再启动（KI-1）。
      if (identical(_process, p)) {
        _outSub?.cancel();
        _errSub?.cancel();
        _outSub = null;
        _errSub = null;
        _process = null;
      }
      if (state.lifecycle != ServerLifecycle.stopped) {
        state = state.copyWith(
          lifecycle: ServerLifecycle.stopped,
          healthy: false,
        );
      }
    }
  }

  void clearLog() {
    _pendingLog.clear();
    state = state.copyWith(logLines: const []);
  }

  Future<HealthInfo?> _waitHealth(
    String host,
    int port, {
    int attempts = 10,
  }) async {
    for (var i = 0; i < attempts; i++) {
      try {
        final h = await ServerClient('http://$host:$port').health();
        if (h.status == 'ok') return h;
      } catch (_) {}
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    return null;
  }

  static String _timestamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}'
        '.${three(now.millisecond)}';
  }

  @override
  void dispose() {
    _healthTimer?.cancel();
    _process?.kill();
    _outSub?.cancel();
    _errSub?.cancel();
    _flushLog();
    _logTimer?.cancel();
    _logSink?.close();
    _logSink = null;
    super.dispose();
  }
}