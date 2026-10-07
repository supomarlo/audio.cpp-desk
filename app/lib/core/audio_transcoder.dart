import 'dart:io';

import 'package:path/path.dart' as p;

/// 转码失败（携带给用户看的原因）。
class AudioTranscodeException implements Exception {
  AudioTranscodeException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 调用自编的 `audio2wav`（Media Foundation，系统解码）把音频解码成
/// 16-bit PCM WAV：
///   - ASR 上传：`toWav(..., rate: 16000, channels: 1)`（模型要求）；
///   - 音色库参考音频：不传 rate/channels，保留源采样率与声道（保真）。
///
/// 支持：MP3 / M4A·AAC / WAV / FLAC（Windows 自带解码器）。
/// 查找顺序：App 可执行文件同目录（`bin/audio2wav[.exe]`，随包提供）
/// → `<appRoot>/bin/` → 系统 PATH。找不到时由调用方回退为"仅 WAV"。
class AudioTranscoder {
  AudioTranscoder({required this.tmpDir, required this.appRoot});

  final Directory tmpDir;
  final Directory appRoot;

  String? _resolved;
  bool _resolvedOnce = false;

  static String get _exeName =>
      Platform.isWindows ? 'audio2wav.exe' : 'audio2wav';

  Future<String?> toolPath() async {
    if (_resolvedOnce) return _resolved;
    _resolvedOnce = true;
    final candidates = <String>[
      p.join(File(Platform.resolvedExecutable).parent.path, _exeName),
      p.join(appRoot.path, 'bin', _exeName),
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) {
        _resolved = c;
        return _resolved;
      }
    }
    try {
      final r = await Process.run('audio2wav', ['-h'], runInShell: true);
      // 自编程序无 -h；能启动即视为存在（exitCode 非 127）。
      if (r.exitCode != 127) _resolved = 'audio2wav';
    } catch (_) {}
    return _resolved;
  }

  /// 解码为 PCM WAV；成功后返回临时文件（调用方负责删除）。
  ///
  /// [rate] / [channels] 为 null 时保留源采样率与声道；指定时重采样/混音到
  /// 目标（ASR 用 16000 / 1）。
  Future<File> toWav(String inputPath, String tool,
      {int? rate, int? channels}) async {
    // 前置存在性校验：输入不存在时直接给出明确原因，避免把系统级错误码
    // （如 Media Foundation 的 0x80070002 = ERROR_FILE_NOT_FOUND）透传给用户。
    if (!File(inputPath).existsSync()) {
      throw AudioTranscodeException('input audio not found: $inputPath');
    }
    await tmpDir.create(recursive: true);
    final out = File(p.join(
      tmpDir.path,
      'audio_${DateTime.now().microsecondsSinceEpoch}.wav',
    ));
    final args = <String>[inputPath, out.path];
    if (rate != null) args.addAll(['--rate', '$rate']);
    if (channels != null) args.addAll(['--channels', '$channels']);
    final result = await Process.run(tool, args);
    if (result.exitCode != 0 || !out.existsSync()) {
      try {
        if (out.existsSync()) out.deleteSync();
      } catch (_) {}
      final err = (result.stderr as String?)?.trim() ?? '';
      throw AudioTranscodeException(
        err.isEmpty
            ? 'audio2wav exited with code ${result.exitCode}'
            : err,
      );
    }
    return out;
  }
}
