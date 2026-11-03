import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/health_info.dart';
import '../models/openai_model.dart';

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
    return data.map((e) => OpenAIModel.fromJson(_map(e))).toList();
  }

  Future<void> unloadAllModels() async {
    try {
      await _dio.post('/v1/tasks/unload_all_models');
    } on DioException catch (e) {
      throw ServerError(
        _serverMessage(e) ?? '$e',
        statusCode: e.response?.statusCode,
      );
    }
  }

  /// 通用 JSON 请求，返回二进制响应（TTS / 流式前的离线音频）。
  Future<Uint8List> postJsonBytes(
    String path,
    Map<String, dynamic> data,
  ) async {
    try {
      final resp = await _dio.post(
        path,
        data: data,
        options: Options(responseType: ResponseType.bytes),
      );
      return resp.data as Uint8List;
    } on DioException catch (e) {
      throw ServerError(
        _serverMessage(e) ?? '$e',
        statusCode: e.response?.statusCode,
      );
    }
  }

  /// 通用 JSON 请求，返回 JSON 响应。
  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> data,
  ) async {
    try {
      final resp = await _dio.post(path, data: data);
      return _map(resp.data);
    } on DioException catch (e) {
      throw ServerError(
        _serverMessage(e) ?? '$e',
        statusCode: e.response?.statusCode,
      );
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
      throw ServerError(
        _serverMessage(e) ?? '$e',
        statusCode: e.response?.statusCode,
      );
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
    } else if (data is String && data.isNotEmpty) {
      try {
        data = jsonDecode(data);
      } catch (_) {
        return data;
      }
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
  ServerError(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}
