import 'models/breeze_tts/breeze_tts_workbench.dart';
import 'models/index_tts2/index_tts2_workbench.dart';
import 'models/meanvc2/meanvc2_workbench.dart';
import 'models/ming3_tts/ming3_tts_workbench.dart';
import 'models/omnivoice/omnivoice_workbench.dart';
import 'models/qwen3_asr/qwen3_asr_workbench.dart';
import 'models/qwen3_tts/qwen3_tts_workbench.dart';
import 'workbench_registry.dart';

/// 工作台模型注册入口。
///
/// 新增模型：在 `models/<family>/` 下新建 Widget，然后在这里加一行注册。
/// 外壳、通用控制台、其他模型都不需要改动。
void registerWorkbenchModels() {
  WorkbenchRegistry.register(
    'meanvc2',
    'vc',
    controller: (packageId, spec) => MeanVc2Controller(packageId, spec),
    builder: buildMeanVc2Workbench,
  );
  WorkbenchRegistry.register(
    'qwen3_asr',
    'asr',
    controller: (packageId, spec) => Qwen3AsrController(packageId, spec),
    builder: buildQwen3AsrWorkbench,
  );
  WorkbenchRegistry.register(
    'breeze_tts',
    'tts',
    controller: (packageId, spec) => BreezeTtsController(packageId, spec),
    builder: buildBreezeTtsWorkbench,
  );
  WorkbenchRegistry.register(
    'omnivoice',
    'tts',
    controller: (packageId, spec) => OmniVoiceController(packageId, spec),
    builder: buildOmniVoiceWorkbench,
  );
  WorkbenchRegistry.register(
    'qwen3_tts',
    'tts',
    controller: (packageId, spec) => Qwen3TtsController(packageId, spec),
    builder: buildQwen3TtsWorkbench,
  );
  WorkbenchRegistry.register(
    'ming3_tts',
    'tts',
    controller: (packageId, spec) => Ming3TtsController(packageId, spec),
    builder: buildMing3TtsWorkbench,
  );
  WorkbenchRegistry.register(
    'index_tts2',
    'tts',
    controller: (packageId, spec) => IndexTts2Controller(packageId, spec),
    builder: buildIndexTts2Workbench,
  );
}
