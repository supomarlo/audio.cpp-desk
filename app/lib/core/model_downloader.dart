import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

enum ModelSource { huggingface, hfMirror, modelscope }

extension ModelSourceX on ModelSource {
  String get label {
    switch (this) {
      case ModelSource.huggingface:
        return 'Hugging Face';
      case ModelSource.hfMirror:
        return 'HF-Mirror';
      case ModelSource.modelscope:
        return 'ModelScope';
    }
  }

  String get key {
    switch (this) {
      case ModelSource.huggingface:
        return 'huggingface';
      case ModelSource.hfMirror:
        return 'hf_mirror';
      case ModelSource.modelscope:
        return 'modelscope';
    }
  }

  String get baseUrl {
    switch (this) {
      case ModelSource.huggingface:
        return 'https://huggingface.co';
      case ModelSource.hfMirror:
        return 'https://hf-mirror.com';
      case ModelSource.modelscope:
        return 'https://www.modelscope.cn';
    }
  }
}

ModelSource? modelSourceFromKey(String key) => switch (key) {
      'huggingface' => ModelSource.huggingface,
      'hf_mirror' => ModelSource.hfMirror,
      'modelscope' => ModelSource.modelscope,
      _ => null,
    };

class RemoteFileInfo {
  const RemoteFileInfo({
    this.size,
    this.revision = '',
    this.etag = '',
    this.localPath = '',
  });

  final int? size;
  final String revision;
  final String etag;
  final String localPath;

  factory RemoteFileInfo.fromJson(Map<String, dynamic> json) => RemoteFileInfo(
        size: (json['size'] as num?)?.toInt(),
        revision: json['revision'] as String? ?? '',
        etag: json['etag'] as String? ?? '',
        localPath: json['local_path'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'size': size,
        'revision': revision,
        'etag': etag,
        if (localPath.isNotEmpty) 'local_path': localPath,
      };
}

class DownloadCancelled implements Exception {
  @override
  String toString() => 'download cancelled';
}

class ModelDownloadRequest {
  ModelDownloadRequest({
    required this.packageId,
    required this.repo,
    required this.revision,
    required this.files,
    required this.targetDirectory,
    this.stripPrefix = '',
    required this.source,
    this.token = '',
    required this.modelsRoot,
    this.preKnownSizes = const {},
  });

  final String packageId;
  final String repo;
  final String revision;
  final List<String> files;
  final String targetDirectory;
  final String stripPrefix;
  final ModelSource source;
  final String token;
  final String modelsRoot;
  final Map<String, int> preKnownSizes;

  ModelDownloadRequest copyWith({
    String? modelsRoot,
    String? token,
    ModelSource? source,
    Map<String, int>? preKnownSizes,
  }) =>
      ModelDownloadRequest(
        packageId: packageId,
        repo: repo,
        revision: revision,
        files: files,
        targetDirectory: targetDirectory,
        stripPrefix: stripPrefix,
        source: source ?? this.source,
        token: token ?? this.token,
        modelsRoot: modelsRoot ?? this.modelsRoot,
        preKnownSizes: preKnownSizes ?? this.preKnownSizes,
      );
}

class ModelDownloader {
  ModelDownloader(this._dio);

  final Dio _dio;

  String _quote(String value) => Uri.encodeComponent(value);

  String _remoteUrl(
      ModelSource source, String repo, String revision, String remotePath) {
    final encoded =
        '${_quote(revision)}/${remotePath.split('/').map(_quote).join('/')}';
    switch (source) {
      case ModelSource.huggingface:
      case ModelSource.hfMirror:
        return '${source.baseUrl}/$repo/resolve/$encoded';
      case ModelSource.modelscope:
        return '${source.baseUrl}/models/$repo/resolve/$encoded';
    }
  }

  Options _options(String token, {int rangeStart = 0}) => Options(
        headers: {
          if (token.isNotEmpty) 'Authorization': 'Bearer $token',
          'User-Agent': 'audio-cpp-desk',
          if (rangeStart > 0) 'Range': 'bytes=$rangeStart-',
        },
        validateStatus: (status) => status != null && status < 500,
      );

  Future<void> download(
    ModelDownloadRequest request, {
    String? stagingRoot,
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
    void Function(Map<String, int> sizes)? onSizes,
  }) async {
    final modelsRoot = Directory(request.modelsRoot);
    modelsRoot.createSync(recursive: true);
    final staging = Directory(p.join(
      stagingRoot ?? p.join(modelsRoot.path, '.partial'),
      request.packageId,
    ));
    staging.createSync(recursive: true);

    String stripped(String remote) =>
        _strippedPath(remote, request.stripPrefix);

    final knownSizes = <String, int>{...request.preKnownSizes};
    for (final remote in request.files) {
      if (knownSizes.containsKey(remote)) continue;
      final info = await _remoteSize(request, remote);
      if (info != null) knownSizes[remote] = info;
    }
    final totalKnown = knownSizes.values.fold<int>(0, (a, b) => a + b);
    onSizes?.call(Map<String, int>.unmodifiable(knownSizes));
    var completedBefore = 0;

    for (final remote in request.files) {
      final local = File(p.join(staging.path, stripped(remote)));
      local.parent.createSync(recursive: true);
      final sizeHint = knownSizes[remote];
      var offset = local.existsSync() ? await local.length() : 0;
      if (sizeHint != null && offset > sizeHint) {
        local.deleteSync();
        offset = 0;
      }
      if (sizeHint != null && offset >= sizeHint) {
        completedBefore += sizeHint;
        onProgress?.call(completedBefore, totalKnown);
        continue;
      }
      final url =
          _remoteUrl(request.source, request.repo, request.revision, remote);
      var response = await _downloadFile(
        url: url,
        path: local.path,
        token: request.token,
        offset: offset,
        cancelToken: cancelToken,
        onChunk: (count) {
          var done = completedBefore + offset + count;
          if (sizeHint != null && done > completedBefore + sizeHint) {
            done = completedBefore + sizeHint;
          }
          onProgress?.call(done, totalKnown);
        },
      );
      if (response.statusCode == 200 && offset > 0 && local.existsSync()) {
        local.deleteSync();
        offset = 0;
        await _downloadFile(
          url: url,
          path: local.path,
          token: request.token,
          offset: 0,
          cancelToken: cancelToken,
          onChunk: (count) {
            var done = completedBefore + count;
            if (sizeHint != null && done > completedBefore + sizeHint) {
              done = completedBefore + sizeHint;
            }
            onProgress?.call(done, totalKnown);
          },
        );
      }
      completedBefore += sizeHint ?? local.lengthSync();
      onProgress?.call(completedBefore, totalKnown);
    }

    final finalRoot =
        Directory(p.join(modelsRoot.path, request.targetDirectory));
    finalRoot.createSync(recursive: true);
    for (final entry in staging.listSync(recursive: true)) {
      if (entry is! File) continue;
      final relative = p.relative(entry.path, from: staging.path);
      final destination = File(p.join(finalRoot.path, relative));
      destination.parent.createSync(recursive: true);
      if (!destination.existsSync()) {
        entry.copySync(destination.path);
      }
    }
    staging.deleteSync(recursive: true);
    _writeManifest(modelsRoot.path, request, knownSizes, totalKnown);
  }

  Future<Response> _downloadFile({
    required String url,
    required String path,
    required String token,
    required int offset,
    CancelToken? cancelToken,
    required void Function(int count) onChunk,
  }) async {
    return _dio.download(
      url,
      path,
      options: _options(token, rangeStart: offset),
      fileAccessMode: offset > 0 ? FileAccessMode.append : FileAccessMode.write,
      deleteOnError: false,
      cancelToken: cancelToken,
      onReceiveProgress: (count, total) => onChunk(count),
    );
  }

  Future<int?> _remoteSize(ModelDownloadRequest request, String remote) async {
    const fallbackLast = ModelSource.huggingface;
    final preferred = ModelSource.values
        .where((s) => s != fallbackLast)
        .toList();
    final candidates = <ModelSource>[
      request.source,
      ...preferred.where((s) => s != request.source),
      if (request.source != fallbackLast) fallbackLast,
    ];
    for (final source in candidates) {
      final size =
          await _sizeFromHead(request.copyWith(source: source), remote);
      if (size != null) return size;
    }
    if (request.source == ModelSource.modelscope) {
      return _sizeFromModelScopeApi(request, remote);
    }
    return null;
  }

  Future<int?> _sizeFromHead(
      ModelDownloadRequest request, String remote) async {
    try {
      final response = await _dio.head(
        _remoteUrl(request.source, request.repo, request.revision, remote),
        options: _options(request.token),
      );
      final status = response.statusCode ?? 0;
      if (status == 200 || status == 206) {
        final length = response.headers.value('content-length');
        return length != null ? int.tryParse(length) : null;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<int?> _sizeFromModelScopeApi(
    ModelDownloadRequest request,
    String remote,
  ) async {
    final revisions = {request.revision, 'master'};
    for (final revision in revisions) {
      try {
        final response = await _dio.get<Map<String, dynamic>>(
          '${request.source.baseUrl}/api/v1/models/${request.repo}/repo/raw'
          '?Revision=${_quote(revision)}&FilePath=${_quote(remote)}',
          options: _options(request.token),
        );
        final data = response.data;
        final dataMap = data?['Data'];
        final meta = dataMap is Map ? dataMap['MetaContent'] : null;
        final size = meta is Map ? (meta['Size'] as num?)?.toInt() : null;
        final success = data?['Success'] == true;
        if (success && size != null && size > 0) return size;
      } catch (_) {
        // try next revision
      }
    }
    return null;
  }

  void _writeManifest(
    String modelsRoot,
    ModelDownloadRequest request,
    Map<String, int> knownSizes,
    int totalBytes,
  ) {
    final root = Directory(p.join(modelsRoot, request.targetDirectory));
    final manifest =
        File(p.join(root.path, '.audiocpp-package-${request.packageId}.json'));
    manifest.parent.createSync(recursive: true);
    final remoteInfo = <String, RemoteFileInfo>{};
    for (final remote in request.files) {
      remoteInfo[remote] = RemoteFileInfo(
        size: knownSizes[remote],
        localPath: _strippedPath(remote, request.stripPrefix),
      );
    }
    final payload = <String, dynamic>{
      'schema_version': 1,
      'package_id': request.packageId,
      'repo': request.repo,
      'requested_revision': request.revision,
      'resolved_revision': request.revision,
      'installed_at_unix': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'weights_path': root.path,
      'directory': request.targetDirectory,
      'files': {for (final e in remoteInfo.entries) e.key: e.value.toJson()},
      if (totalBytes > 0) 'installed_size': totalBytes,
    };
    final temporary = '${manifest.path}.tmp';
    File(temporary).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(payload),
      encoding: utf8,
    );
    File(temporary).renameSync(manifest.path);
  }

  String _strippedPath(String remote, String stripPrefix) {
    var result = remote;
    final prefix = stripPrefix.replaceAll(RegExp(r'/+$'), '');
    if (prefix.isNotEmpty && result.startsWith('$prefix/')) {
      result = result.substring(prefix.length + 1);
    }
    return result;
  }
}
