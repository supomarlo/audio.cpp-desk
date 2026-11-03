import '../../models/model_spec.dart';

/// 工作台当前支持的任务（顺序即优先级）。
const List<String> kWorkbenchTasks = ['tts', 'asr', 'vc'];

/// 规格 `tasks` 与工作台支持任务的交集，保持工作台固定顺序。
List<String> workbenchTasksOf(List<String> tasks) => [
      for (final task in kWorkbenchTasks)
        if (tasks.contains(task)) task,
    ];

String workbenchTaskLabel(Map<String, String> dict, String task) {
  switch (task) {
    case 'tts':
      return dict['workbench.task.tts'] ?? 'TTS';
    case 'asr':
      return dict['workbench.task.asr'] ?? 'ASR';
    case 'vc':
      return dict['workbench.task.vc'] ?? 'VC';
    default:
      return task;
  }
}

/// 服务端模型 id：多能力模型用 `packageId@task`，单能力保持 packageId。
String workbenchModelId(String packageId, String task, ModelSpec? spec) {
  final tasks = workbenchTasksOf(spec?.tasks ?? const <String>[]);
  return tasks.length > 1 ? '$packageId@$task' : packageId;
}

String workbenchEndpointFor(String task) {
  switch (task) {
    case 'tts':
      return '/v1/audio/speech';
    case 'asr':
      return '/v1/audio/transcriptions';
    default:
      return '/v1/tasks/run';
  }
}

/// 一次提交的完整方案：由 Widget / 通用控制台产出，外壳只负责执行与记录。
class WorkbenchCall {
  const WorkbenchCall({
    required this.endpoint,
    required this.modelId,
    required this.request,
    this.recordInputs = const {},
    this.transport = 'json',
    this.responseFormat = 'bytes',
    this.audioPath,
    this.audioRate = 16000,
    this.audioChannels = 1,
  });

  /// `/v1/audio/speech` / `/v1/audio/transcriptions` / `/v1/tasks/run`。
  final String endpoint;

  /// 服务端模型条目 id。
  final String modelId;

  /// 最终请求体；执行器原样提交。
  final Map<String, dynamic> request;

  /// 记录参数（标准字段 + params），不含 call。
  final Map<String, String> recordInputs;

  /// `json` | `multipart`。
  final String transport;

  /// `bytes` | `json_base64` | `json_text`。
  final String responseFormat;

  /// 需要转码后提交的音频路径（执行器负责转码并写回 request）。
  final String? audioPath;

  /// 源音频转码目标采样率/声道；默认 16k mono。
  final int audioRate;
  final int audioChannels;
}

bool workbenchHasOption(ModelSpec spec, String name) =>
    spec.requestOptions.any((o) => o.name == name);

bool workbenchHasSpeakerReference(ModelSpec spec) =>
    spec.capabilities.values.any((c) => c.contains('speaker_reference')) ||
    spec.tasks.contains('clone') ||
    workbenchHasOption(spec, 'reference_text');

bool workbenchShowsReferenceText(ModelSpec spec) =>
    workbenchHasOption(spec, 'reference_text');
