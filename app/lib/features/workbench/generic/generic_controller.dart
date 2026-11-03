import 'package:flutter/material.dart';

import '../../../models/model_spec.dart';
import '../../../models/session.dart';
import '../../../models/voice_entry.dart';
import '../workbench_contract.dart';
import '../workbench_registry.dart';

/// 通用控制台：未适配模型的默认控制器，和专属模型使用同一套契约。
class GenericWorkbenchController extends WorkbenchModelController {
  GenericWorkbenchController(this.packageId, this.spec, this.task);

  final String packageId;
  final ModelSpec spec;
  final String task;

  final TextEditingController textCtrl = TextEditingController();
  final TextEditingController refTextCtrl = TextEditingController();

  String? audioPath;
  String voiceEntryId = '';
  String? voiceRef;
  String? voiceName;
  String? language;

  void setAudio(String? path) {
    audioPath = path;
    notifyListeners();
  }

  void setVoice(VoiceEntry? voice) {
    voiceEntryId = voice?.id ?? '';
    voiceRef = voice?.audioPath;
    voiceName = voice?.name;
    refTextCtrl.text = voice?.text?.trim() ?? '';
    notifyListeners();
  }

  void setLanguage(String? value) {
    language = value;
    notifyListeners();
  }

  @override
  String? validate() {
    switch (task) {
      case 'tts':
        if (textCtrl.text.trim().isEmpty) return 'workbench.needText';
      case 'asr':
      case 'vc':
        if (audioPath == null || audioPath!.isEmpty) {
          return 'workbench.needAudio';
        }
      default:
        return 'workbench.unsupportedTask';
    }
    return null;
  }

  @override
  WorkbenchCall? buildCall() {
    if (validate() != null) return null;
    final modelId = workbenchModelId(packageId, task, spec);
    final hasRef = voiceRef != null && voiceRef!.isNotEmpty;
    final recordInputs = <String, String>{
      if (language != null) 'language': language!,
      if (voiceEntryId.isNotEmpty) 'voice_entry': voiceEntryId,
      if (voiceName != null) 'voice_name': voiceName!,
      if (hasRef) 'voice_ref': voiceRef!,
    };

    if (task == 'tts') {
      final text = textCtrl.text.trim();
      recordInputs['text'] = text;
      final refText = refTextCtrl.text.trim();
      final options = <String, dynamic>{};
      if (hasRef && refText.isNotEmpty) {
        options['reference_text'] = refText;
        recordInputs['reference_text'] = refText;
      }
      return WorkbenchCall(
        endpoint: workbenchEndpointFor(task),
        modelId: modelId,
        request: {
          'model': modelId,
          'input': text,
          if (language != null) 'language': language,
          if (hasRef) 'voice_ref': voiceRef,
          if (options.isNotEmpty) 'options': options,
        },
        recordInputs: recordInputs,
        responseFormat: 'bytes',
      );
    }

    final audio = audioPath ?? '';
    recordInputs['audio'] = audio;

    if (task == 'asr') {
      return WorkbenchCall(
        endpoint: workbenchEndpointFor(task),
        modelId: modelId,
        request: {
          'model': modelId,
          if (language != null) 'language': language,
          'audio': audio,
        },
        recordInputs: recordInputs,
        transport: 'multipart',
        responseFormat: 'json_text',
        audioPath: audio,
      );
    }

    return WorkbenchCall(
      endpoint: workbenchEndpointFor(task),
      modelId: modelId,
      request: {
        'model': modelId,
        'request': {
          'audio': audio,
          if (hasRef) 'voice_ref': voiceRef,
        },
      },
      recordInputs: recordInputs,
      responseFormat: 'json_base64',
      audioPath: audio,
    );
  }

  @override
  void restore(GenerationRecord record) {
    final inputs = record.inputs;
    textCtrl.text = inputs['text'] ?? '';
    refTextCtrl.text = inputs['reference_text'] ?? '';
    audioPath = _nz(inputs['audio']);
    voiceEntryId = inputs['voice_entry'] ?? '';
    voiceRef = _nz(inputs['voice_ref']);
    voiceName = inputs['voice_name'];
    language = _nz(inputs['language']);
    notifyListeners();
  }

  @override
  void dispose() {
    textCtrl.dispose();
    refTextCtrl.dispose();
    super.dispose();
  }

  static String? _nz(String? value) =>
      (value == null || value.isEmpty) ? null : value;
}
