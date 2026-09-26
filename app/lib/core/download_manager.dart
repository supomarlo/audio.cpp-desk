import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'model_downloader.dart';

enum DownloadPhase { downloading, done, failed, cancelled, paused, installed }

const kProgressRefreshInterval = Duration(seconds: 1);

class DownloadTask {
  DownloadTask({
    required this.packageId,
    required this.groupName,
    required this.repo,
    required this.source,
  });

  final String packageId;
  final String groupName;
  final String repo;
  final ModelSource source;

  ModelDownloadRequest? request;

  DownloadPhase phase = DownloadPhase.downloading;
  int receivedBytes = 0;
  int totalBytes = 0;
  double speedBytesPerSec = 0;
  String? error;
  Map<String, int> knownSizes = <String, int>{};
  final CancelToken cancelToken = CancelToken();
  bool _cancelRequested = false;
  bool _pauseRequested = false;
  DateTime lastSampleAt = DateTime.now();
  int lastSampleBytes = 0;

  bool get active => phase == DownloadPhase.downloading;
  bool get cancelRequested => _cancelRequested;
  bool get pauseRequested => _pauseRequested;
  bool get processing => active || phase == DownloadPhase.paused;
  void markCancelRequested() => _cancelRequested = true;
  void markPauseRequested() => _pauseRequested = true;

  double get progressPercent {
    if (totalBytes <= 0) return -1;
    return (receivedBytes / totalBytes * 100).clamp(0.0, 100.0);
  }
}

DownloadPhase _phaseFromName(String name) => DownloadPhase.values.firstWhere(
      (e) => e.name == name,
      orElse: () => DownloadPhase.paused,
    );

class DownloadManager extends ChangeNotifier {
  DownloadManager({
    required String Function() modelsRootOf,
    required String Function() recordsRootOf,
    required String Function() partialRootOf,
    Future<void> Function(String packageId)? onInstalled,
    required Dio dio,
  })  : _modelsRootOf = modelsRootOf,
        _recordsRootOf = recordsRootOf,
        _partialRootOf = partialRootOf,
        _onInstalled = onInstalled,
        _downloader = ModelDownloader(dio) {
    _restoreTasks();
  }

  final String Function() _modelsRootOf;
  final String Function() _recordsRootOf;
  final String Function() _partialRootOf;
  final Future<void> Function(String packageId)? _onInstalled;
  final ModelDownloader _downloader;
  final Map<String, DownloadTask> _tasks = {};

  Map<String, DownloadTask> get tasks => Map.unmodifiable(_tasks);

  int get activeCount => _tasks.values.where((t) => t.active).length;

  DownloadTask? taskOf(String packageId) => _tasks[packageId];

  void reset() {
    for (final t in _tasks.values) {
      t.cancelToken.cancel();
    }
    _tasks.clear();
    notifyListeners();
  }

  Future<void> start({
    required ModelDownloadRequest request,
    required String groupName,
  }) async {
    final existing = _tasks.remove(request.packageId);
    existing?.cancelToken.cancel();
    final prior = existing != null
        ? _TaskRecord.fromTask(existing)
        : _loadRecord(request.packageId);
    final task = DownloadTask(
      packageId: request.packageId,
      groupName: groupName,
      repo: request.repo,
      source: request.source,
    );
    task.request = request;
    if (prior != null) {
      task.knownSizes = <String, int>{...prior.knownSizes};
      task.receivedBytes = prior.receivedBytes;
      task.totalBytes = prior.totalBytes;
    }
    _tasks[request.packageId] = task;
    notifyListeners();

    try {
      await _downloader.download(
        request.copyWith(
          modelsRoot: _modelsRootOf(),
          preKnownSizes: task.knownSizes,
        ),
        cancelToken: task.cancelToken,
        stagingRoot: _partialRootOf(),
        onSizes: (sizes) {
          task.knownSizes = sizes;
          _persist(task);
        },
        onProgress: (received, total) {
          task.receivedBytes = received;
          task.totalBytes = total;
          final now = DateTime.now();
          final dtMs = now.difference(task.lastSampleAt).inMilliseconds;
          if (dtMs >= kProgressRefreshInterval.inMilliseconds ||
              (total > 0 && received >= total)) {
            final dtSeconds = dtMs <= 0 ? 0.001 : dtMs / 1000.0;
            final deltaBytes = task.lastSampleBytes <= 0
                ? received
                : received - task.lastSampleBytes;
            task.speedBytesPerSec = deltaBytes / dtSeconds;
            task.lastSampleAt = now;
            task.lastSampleBytes = received;
            notifyListeners();
            _persist(task);
          }
        },
      );
      task.receivedBytes = task.totalBytes > 0 ? task.totalBytes : 0;
      task.phase = _filesInstalled(task)
          ? DownloadPhase.installed
          : DownloadPhase.failed;
      if (task.phase == DownloadPhase.failed) {
        task.error = 'Checksum verification failed';
      }
      _removeRecord(task.packageId);
    } on DioException catch (e) {
      if (task.pauseRequested) {
        task.phase = DownloadPhase.paused;
        task.speedBytesPerSec = 0;
      } else if (CancelToken.isCancel(e) || task.cancelRequested) {
        task.phase = DownloadPhase.cancelled;
      } else {
        task.phase = DownloadPhase.failed;
        task.error = _dioErrorMessage(e);
      }
    } catch (e) {
      task.phase = DownloadPhase.failed;
      task.error = e.toString();
    }
    if (task.phase == DownloadPhase.installed) {
      try {
        await _onInstalled?.call(request.packageId);
      } catch (_) {}
      _tasks.remove(request.packageId);
      _removeRecord(request.packageId);
    } else if (task.phase != DownloadPhase.done) {
      _persist(task);
    }
    notifyListeners();
  }

  Future<void> cancel(String packageId) async {
    final task = _tasks[packageId];
    if (task == null || !task.active) return;
    task.markCancelRequested();
    task.speedBytesPerSec = 0;
    task.cancelToken.cancel();
    task.phase = DownloadPhase.cancelled;
    notifyListeners();
  }

  Future<void> pause(String packageId) async {
    final task = _tasks[packageId];
    if (task == null || !task.active) return;
    task.markPauseRequested();
    task.speedBytesPerSec = 0;
    task.cancelToken.cancel();
    task.phase = DownloadPhase.paused;
    notifyListeners();
  }

  Future<void> resume(String packageId) async {
    final task = _tasks[packageId];
    if (task == null || task.active) return;
    final request = task.request;
    if (request == null) return;
    await start(request: request, groupName: task.groupName);
  }

  void remove(String packageId) {
    if (_tasks.remove(packageId) != null) {
      _deletePartial(packageId);
      _removeRecord(packageId);
      notifyListeners();
    }
  }

  void _restoreTasks() {
    final dir = Directory(_recordDir());
    if (!dir.existsSync()) return;
    for (final f in dir.listSync().whereType<File>()) {
      try {
        final rec = _TaskRecord.fromJson(jsonDecode(f.readAsStringSync()));
        if (rec.files.isEmpty) continue;
        final source = modelSourceFromKey(rec.sourceKey);
        if (source == null) continue;
        var phase = rec.phase;
        if (phase == DownloadPhase.downloading) phase = DownloadPhase.paused;
        if (phase == DownloadPhase.done) continue;
        final task = DownloadTask(
          packageId: rec.packageId,
          groupName: rec.groupName,
          repo: rec.repo,
          source: source,
        );
        task.phase = phase;
        task.receivedBytes = rec.receivedBytes;
        task.totalBytes = rec.totalBytes;
        task.knownSizes = <String, int>{...rec.knownSizes};
        task.request = ModelDownloadRequest(
          packageId: rec.packageId,
          repo: rec.repo,
          revision: rec.revision,
          files: rec.files,
          targetDirectory: rec.targetDirectory,
          stripPrefix: rec.stripPrefix,
          source: source,
          token: rec.token,
          modelsRoot: '',
        );
        _tasks[rec.packageId] = task;
      } catch (_) {}
    }
  }

  String _recordDir() => _recordsRootOf();

  File _recordFile(String packageId) => File(p.join(
        _recordDir(),
        '${base64Url.encode(utf8.encode(packageId))}.json',
      ));

  _TaskRecord? _loadRecord(String packageId) {
    try {
      final f = _recordFile(packageId);
      if (!f.existsSync()) return null;
      return _TaskRecord.fromJson(jsonDecode(f.readAsStringSync()));
    } catch (_) {
      return null;
    }
  }

  void _persist(DownloadTask task) {
    try {
      final file = _recordFile(task.packageId);
      file.parent.createSync(recursive: true);
      final temporary = '${file.path}.tmp';
      File(temporary).writeAsStringSync(
        const JsonEncoder.withIndent('  ')
            .convert(_TaskRecord.fromTask(task).toJson()),
        encoding: utf8,
      );
      File(temporary).renameSync(file.path);
    } catch (_) {}
  }

  void _removeRecord(String packageId) {
    try {
      final f = _recordFile(packageId);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  void _deletePartial(String packageId) {
    try {
      final dir = Directory(p.join(_partialRootOf(), packageId));
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  }

  bool _filesInstalled(DownloadTask task) {
    final request = task.request;
    if (request == null || request.files.isEmpty) return false;
    final root = Directory(p.join(_modelsRootOf(), request.targetDirectory));
    if (!root.existsSync()) return false;
    final prefix = request.stripPrefix.replaceAll(RegExp(r'/+$'), '');
    for (final f in request.files) {
      var rel = f;
      if (prefix.isNotEmpty && rel.startsWith('$prefix/')) {
        rel = rel.substring(prefix.length + 1);
      }
      if (!File(p.join(root.path, rel)).existsSync()) return false;
    }
    return true;
  }

  String _dioErrorMessage(DioException e) {
    switch (e.type) {
      case DioExceptionType.cancel:
        return 'Cancelled';
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return 'Network connection failed';
      case DioExceptionType.badResponse:
        return 'Download failed (HTTP ${e.response?.statusCode ?? 'Unknown'})';
      default:
        return 'Download failed';
    }
  }
}

class _TaskRecord {
  const _TaskRecord({
    required this.packageId,
    required this.groupName,
    required this.repo,
    required this.sourceKey,
    required this.token,
    required this.revision,
    required this.files,
    required this.targetDirectory,
    required this.stripPrefix,
    required this.phase,
    required this.receivedBytes,
    required this.totalBytes,
    required this.knownSizes,
  });

  final String packageId;
  final String groupName;
  final String repo;
  final String sourceKey;
  final String token;
  final String revision;
  final List<String> files;
  final String targetDirectory;
  final String stripPrefix;
  final DownloadPhase phase;
  final int receivedBytes;
  final int totalBytes;
  final Map<String, int> knownSizes;

  factory _TaskRecord.fromTask(DownloadTask t) => _TaskRecord(
        packageId: t.packageId,
        groupName: t.groupName,
        repo: t.repo,
        sourceKey: t.source.key,
        token: t.request?.token ?? '',
        revision: t.request?.revision ?? '',
        files: t.request?.files ?? const [],
        targetDirectory: t.request?.targetDirectory ?? '',
        stripPrefix: t.request?.stripPrefix ?? '',
        phase: t.phase,
        receivedBytes: t.receivedBytes,
        totalBytes: t.totalBytes,
        knownSizes: <String, int>{...t.knownSizes},
      );

  factory _TaskRecord.fromJson(Map<String, dynamic> json) => _TaskRecord(
        packageId: json['package_id'] as String,
        groupName: json['group_name'] as String? ?? '',
        repo: json['repo'] as String,
        sourceKey: json['source'] as String,
        token: json['token'] as String? ?? '',
        revision: json['revision'] as String? ?? 'main',
        files: (json['files'] as List<dynamic>? ?? const []).cast<String>(),
        targetDirectory: json['target_directory'] as String? ?? '',
        stripPrefix: json['strip_prefix'] as String? ?? '',
        phase: _phaseFromName(json['phase'] as String? ?? 'paused'),
        receivedBytes: (json['received_bytes'] as num?)?.toInt() ?? 0,
        totalBytes: (json['total_bytes'] as num?)?.toInt() ?? 0,
        knownSizes: <String, int>{
          for (final e
              in (json['known_sizes'] as Map<dynamic, dynamic>? ?? const {})
                  .entries)
            e.key as String: (e.value as num).toInt(),
        },
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': 1,
        'package_id': packageId,
        'group_name': groupName,
        'repo': repo,
        'source': sourceKey,
        'token': token,
        'revision': revision,
        'files': files,
        'target_directory': targetDirectory,
        'strip_prefix': stripPrefix,
        'phase': phase.name,
        'received_bytes': receivedBytes,
        'total_bytes': totalBytes,
        'known_sizes': knownSizes,
        'updated_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      };
}
