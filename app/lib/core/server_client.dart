import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/health_info.dart';
import '../models/openai_model.dart';
import 'app_logger.dart';

class ServerClient {
  ServerClient(
    String baseUrl, {
    Duration receiveTimeout = const Duration(minutes: 5),
  }) : _dio = Dio(
          BaseOptions(
            baseUrl: baseUrl,
            connectTimeout: const Duration(seconds: 5),
            receiveTimeout: receiveTimeout,
          ),
        );

  final Dio _dio;

  /// 实际请求的基地址（host:port），用于失败诊断。
  String get baseUrl => _dio.options.baseUrl;

  Future<HealthInfo> health() async {
    final resp = await _dio.get('/health');
    return HealthInfo.fromJson(_map(resp.data));
  }

  Future<List<OpenAIModel>> models() async {
    final resp = await _dio.get('/v1/models');
    final data = (resp.data as Map?)?['data'] as List<dynamic>? ?? [];
    return data
        .map((e) => OpenAIModel.fromJson(_map(e)))
        .toList();
  }

  Future<List<String>> voices({String? model}) async {
    final query = model == null ? null : {'model': model};
    final resp = await _dio.get('/v1/audio/voices', queryParameters: query);
    final data = resp.data as Map?;
    final list = data?['voices'] as List<dynamic>? ?? [];
    return list.map((e) => e.toString()).toList();
  }

  Future<Uint8List> speech({
    required String model,
    required String input,
    String? voice,
    String? voiceRef,
    String? language,
    String? responseFormat,
    Map<String, dynamic> extra = const {},
  }) async {
    try {
      final resp = await _dio.post(
        '/v1/audio/speech',
        data: {
          'model': model,
          'input': input,
          if (voice != null) 'voice': voice,
          if (voiceRef != null) 'voice_ref': voiceRef,
          if (language != null) 'language': language,
          if (responseFormat != null) 'response_format': responseFormat,
          // audio.cpp 从 body 的 `options` 对象读取 request options
          // （instruction / reference_text / voice_id 等）；平铺到顶层会被忽略。
          if (extra.isNotEmpty) 'options': extra,
        },
        options: Options(responseType: ResponseType.bytes),
      );
      return resp.data as Uint8List;
    } on DioException catch (e) {
      throw ServerError(_serverMessage(e) ?? '$e');
    }
  }

  /// 卸载所有常驻模型以释放显存（API-only 模式可用）。
  Future<void> unloadAllModels() async {
    try {
      await _dio.post('/v1/tasks/unload_all_models');
    } on DioException catch (e) {
      throw ServerError(_serverMessage(e) ?? '$e');
    }
  }

  /// 通用任务路由（`/v1/tasks/run`）：可携带 `request.audio`（进入 `audio_input`，
  /// 用于模型的额外音频输入，如情感参考音频），返回结果里的 base64 WAV。
  Future<Uint8List> taskAudio({
    required String model,
    required Map<String, dynamic> request,
  }) async {
    AppLogger.info('task request: model=$model, request=$request');
    try {
      final resp = await _dio.post(
        '/v1/tasks/run',
        data: {'model': model, 'request': request},
      );
      final m = _map(resp.data);
      final audio = m['audio'];
      if (audio is! String || audio.isEmpty) {
        throw ServerError('task result has no audio');
      }
      return base64Decode(audio);
    } on DioException catch (e) {
      throw ServerError(_serverMessage(e) ?? '$e');
    }
  }

  Future<String> transcription({
    required String model,
    required List<int> audioBytes,
    required String filename,
    String? language,
  }) async {
    final form = FormData.fromMap({
      'model': model,
      if (language != null) 'language': language,
      'file': MultipartFile.fromBytes(
        audioBytes,
        filename: _asciiFilename(filename),
      ),
    });
    try {
      final resp = await _dio.post(
        '/v1/audio/transcriptions',
        data: form,
        options: Options(responseType: ResponseType.json),
      );
      final m = _map(resp.data);
      return m['text'] as String? ?? '';
    } on DioException catch (e) {
      throw ServerError(_serverMessage(e) ?? '$e');
    }
  }

  /// 服务端（audio.cpp）无法处理 multipart 里的非 ASCII 文件名：会触发
  /// Unicode→ANSI 转换失败并返回 500。这里只保留 ASCII 扩展名用于格式识别。
  static String _asciiFilename(String filename) {
    final dot = filename.lastIndexOf('.');
    final ext = dot >= 0 ? filename.substring(dot) : '';
    return RegExp(r'^\.[A-Za-z0-9]{1,5}$').hasMatch(ext)
        ? 'audio$ext'
        : 'audio.wav';
  }

  static String? _serverMessage(DioException e) {
    dynamic data = e.response?.data;
    if (data is List<int>) {
      try {
        data = jsonDecode(utf8.decode(data));
      } catch (_) {}
    }
    if (data is Map) {
      final err = data['error'];
      if (err is Map && err['message'] is String) {
        return err['message'] as String;
      }
    }
    return null;
  }

  Map<String, dynamic> _map(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    return <String, dynamic>{};
  }
}

/// 服务端返回的可读错误（取 `error.message`）。
class ServerError implements Exception {
  ServerError(this.message);

  final String message;

  @override
  String toString() => message;
}