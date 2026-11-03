import 'dart:io';

import 'package:audio_cpp_desk/core/app_paths.dart';
import 'package:audio_cpp_desk/features/workbench/generic/generic_controller.dart';
import 'package:audio_cpp_desk/features/workbench/models/breeze_tts/breeze_tts_workbench.dart';
import 'package:audio_cpp_desk/features/workbench/models/index_tts2/index_tts2_workbench.dart';
import 'package:audio_cpp_desk/features/workbench/models/meanvc2/meanvc2_workbench.dart';
import 'package:audio_cpp_desk/features/workbench/models/ming3_tts/ming3_tts_workbench.dart';
import 'package:audio_cpp_desk/features/workbench/models/omnivoice/omnivoice_workbench.dart';
import 'package:audio_cpp_desk/features/workbench/models/qwen3_asr/qwen3_asr_workbench.dart';
import 'package:audio_cpp_desk/features/workbench/models/qwen3_tts/qwen3_tts_workbench.dart';
import 'package:audio_cpp_desk/features/workbench/widgets/workbench_fields.dart';
import 'package:audio_cpp_desk/features/workbench/workbench_contract.dart';
import 'package:audio_cpp_desk/features/workbench/workbench_registry.dart';
import 'package:audio_cpp_desk/localization/strings.dart';
import 'package:audio_cpp_desk/models/model_spec.dart';
import 'package:audio_cpp_desk/models/session.dart';
import 'package:audio_cpp_desk/models/voice_entry.dart';
import 'package:audio_cpp_desk/providers/app_providers.dart';
import 'package:audio_cpp_desk/providers/library_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _DummyController extends WorkbenchModelController {
  @override
  WorkbenchCall? buildCall() => null;

  @override
  String? validate() => null;

  @override
  void restore(GenerationRecord record) {}
}

ModelSpec buildSpec(List<String> tasks) => ModelSpec.fromJson({
      'family': 'x',
      'tasks': tasks,
      'languages': ['en'],
    });

void main() {
  group('能力枚举', () {
    test('按工作台顺序取交集', () {
      expect(workbenchTasksOf(['vc', 'tts', 'asr']), ['tts', 'asr', 'vc']);
      expect(workbenchTasksOf(['clone', 'tts', 'design']), ['tts']);
      expect(workbenchTasksOf(['separate']), isEmpty);
    });

    test('未命中时回退原值', () {
      expect(workbenchTaskLabel(const {}, 'unknown'), 'unknown');
    });
  });

  group('WorkbenchCall', () {
    test('记录参数不含 call', () {
      const call = WorkbenchCall(
        endpoint: '/v1/audio/speech',
        modelId: 'pkg',
        request: {'model': 'pkg', 'input': 'hi'},
        recordInputs: {'text': 'hi'},
      );
      final inputs = call.recordInputs;
      expect(inputs, {'text': 'hi'});
      expect(inputs.containsKey('call'), isFalse);
    });
  });

  group('通用控制台', () {
    test('TTS 单能力保持 packageId', () {
      final ctrl = GenericWorkbenchController(
        'pkg',
        buildSpec(['tts']),
        'tts',
      );
      addTearDown(ctrl.dispose);
      ctrl.textCtrl.text = 'hello';
      ctrl.setLanguage('en');
      final call = ctrl.buildCall()!;
      expect(call.endpoint, '/v1/audio/speech');
      expect(call.modelId, 'pkg');
      expect(call.request['input'], 'hello');
      expect(call.request['language'], 'en');
      expect(call.responseFormat, 'bytes');
    });

    test('TTS 多能力 modelId 带 task', () {
      final ctrl = GenericWorkbenchController(
        'pkg',
        buildSpec(['tts', 'asr']),
        'tts',
      );
      addTearDown(ctrl.dispose);
      ctrl.textCtrl.text = 'hello';
      final call = ctrl.buildCall()!;
      expect(call.modelId, 'pkg@tts');
    });

    test('参考文本仅参考音色时提交', () {
      final ctrl = GenericWorkbenchController(
        'pkg',
        buildSpec(['tts']),
        'tts',
      );
      addTearDown(ctrl.dispose);
      ctrl.textCtrl.text = 'hello';
      ctrl.refTextCtrl.text = 'reference';
      final noRef = ctrl.buildCall()!;
      expect(noRef.request.containsKey('voice_ref'), isFalse);
      expect(noRef.request.containsKey('options'), isFalse);

      ctrl.setVoice(VoiceEntry(
        id: 'v1',
        name: 'voice',
        type: 'file',
        audioPath: 'v.wav',
        text: 'reference',
        createdAt: DateTime(2026),
      ));
      final withRef = ctrl.buildCall()!;
      expect(withRef.request['voice_ref'], 'v.wav');
      expect(
        (withRef.request['options'] as Map)['reference_text'],
        'reference',
      );
    });

    test('ASR 走 multipart 转写', () {
      final ctrl = GenericWorkbenchController(
        'pkg',
        buildSpec(['tts', 'asr']),
        'asr',
      );
      addTearDown(ctrl.dispose);
      ctrl.setAudio('a.wav');
      final call = ctrl.buildCall()!;
      expect(call.endpoint, '/v1/audio/transcriptions');
      expect(call.modelId, 'pkg@asr');
      expect(call.transport, 'multipart');
      expect(call.request['audio'], 'a.wav');
      expect(call.responseFormat, 'json_text');
    });

    test('VC 走 tasks/run', () {
      final ctrl = GenericWorkbenchController(
        'pkg',
        buildSpec(['tts', 'vc']),
        'vc',
      );
      addTearDown(ctrl.dispose);
      ctrl.setAudio('a.wav');
      final call = ctrl.buildCall()!;
      expect(call.endpoint, '/v1/tasks/run');
      expect(call.responseFormat, 'json_base64');
      expect(call.request['request']['audio'], 'a.wav');
    });
  });

  group('注册表', () {
    test('未注册即未适配', () {
      expect(WorkbenchRegistry.isAdapted('__unregistered_family__', 'tts'),
          isFalse);
    });

    test('注册专属 Widget 后命中', () {
      WorkbenchRegistry.register(
        '__test_family__',
        'tts',
        controller: (packageId, spec) => _DummyController(),
        builder: (context, ctx, controller) => const SizedBox.shrink(),
      );
      expect(
        WorkbenchRegistry.registrationFor('__test_family__', 'tts'),
        isNotNull,
      );
      expect(WorkbenchRegistry.isAdapted('__test_family__', 'tts'), isTrue);
      expect(WorkbenchRegistry.isAdapted('__test_family__', 'asr'), isFalse);
    });
  });

  group('MeanVC2', () {
    test('提交 audio + voice_ref + seed', () {
      final spec = ModelSpec.fromJson({
        'family': 'meanvc2',
        'tasks': ['vc'],
        'languages': ['language_agnostic'],
        'capabilities': {
          'vc': ['speaker_reference'],
        },
      });
      final ctrl = MeanVc2Controller('pkg', spec);
      addTearDown(ctrl.dispose);
      ctrl.setAudio('a.wav');
      ctrl.setVoice(VoiceEntry(
        id: 'v1',
        name: 'voice',
        type: 'file',
        audioPath: 'v.wav',
        createdAt: DateTime(2026),
      ));
      ctrl.seedCtrl.text = '7';
      final call = ctrl.buildCall()!;
      expect(call.endpoint, '/v1/tasks/run');
      expect(call.modelId, 'pkg');
      expect(call.request['request']['audio'], 'a.wav');
      expect(call.request['request']['voice_ref'], 'v.wav');
      expect(call.request['request']['seed'], '7');
      expect(call.recordInputs['voice_ref'], 'v.wav');
    });
  });

  group('BreezeTTS 2', () {
    ModelSpec spec() => ModelSpec.fromJson({
          'family': 'breeze_tts',
          'tasks': ['tts', 'clone', 'design'],
          'languages': ['zh', 'en'],
          'capabilities': {
            'tts': ['style_control'],
            'clone': ['speaker_reference'],
          },
          'options': {
            'request': [
              {'name': 'instruct', 'type': 'string'},
              {'name': 'reference_text', 'type': 'string'},
              {'name': 'max_tokens', 'type': 'int'},
            ],
          },
        });

    test('参考音色必须带参考文本', () {
      final ctrl = BreezeTtsController('pkg', spec());
      addTearDown(ctrl.dispose);
      ctrl.textCtrl.text = 'hello';
      ctrl.setVoice(VoiceEntry(
        id: 'v1',
        name: 'voice',
        type: 'file',
        audioPath: 'v.wav',
        createdAt: DateTime(2026),
      ));
      expect(ctrl.validate(), 'workbench.needReferenceText');
      expect(ctrl.buildCall(), isNull);
      ctrl.refTextCtrl.text = 'reference';
      expect(ctrl.validate(), isNull);
    });

    test('提交 speech 字段', () {
      final ctrl = BreezeTtsController('pkg', spec());
      addTearDown(ctrl.dispose);
      ctrl.textCtrl.text = 'hello';
      ctrl.instrCtrl.text = 'warm narrator';
      ctrl.setLanguage('en');
      ctrl.setVoice(VoiceEntry(
        id: 'v1',
        name: 'voice',
        type: 'file',
        audioPath: 'v.wav',
        text: 'reference',
        createdAt: DateTime(2026),
      ));
      ctrl.setAdvancedValues({'max_tokens': '256'});
      final call = ctrl.buildCall()!;
      expect(call.endpoint, '/v1/audio/speech');
      expect(call.modelId, 'pkg');
      expect(call.request['input'], 'hello');
      expect(call.request['voice_ref'], 'v.wav');
      expect(call.request['language'], 'en');
      expect(call.request['options']['instruct'], 'warm narrator');
      expect(call.request['options']['reference_text'], 'reference');
      expect(call.request['options']['max_tokens'], '256');
    });
  });

  group('OmniVoice', () {
    ModelSpec spec() => ModelSpec.fromJson({
          'family': 'omnivoice',
          'tasks': ['tts', 'clone', 'design'],
          'languages': ['600+ languages'],
          'capabilities': {
            'clone': ['speaker_reference'],
            'design': ['voice_design'],
          },
          'options': {
            'request': [
              {'name': 'language', 'type': 'string'},
              {'name': 'reference_text', 'type': 'string'},
              {'name': 'instruct', 'type': 'string'},
              {
                'name': 'seed',
                'type': 'int',
                'min': 0,
                'max': 4294967295,
              },
              {'name': 'num_inference_steps', 'type': 'int', 'min': 1},
              {'name': 'guidance_scale', 'type': 'float'},
              {'name': 'speed', 'type': 'float'},
              {'name': 'duration_sec', 'type': 'float', 'min': 0},
              {'name': 'shift', 'type': 'float'},
              {'name': 'denoise', 'type': 'bool'},
              {'name': 'preprocess_prompt', 'type': 'bool'},
              {'name': 'postprocess_output', 'type': 'bool'},
              {'name': 'layer_penalty_factor', 'type': 'float'},
              {'name': 'position_temperature', 'type': 'float'},
              {'name': 'class_temperature', 'type': 'float', 'min': 0},
              {'name': 'audio_chunk_duration_sec', 'type': 'float', 'min': 0},
              {'name': 'audio_chunk_threshold_sec', 'type': 'float', 'min': 0},
              {'name': 'text_chunk_size', 'type': 'int', 'min': 1},
              {'name': 'text_chunk_mode', 'type': 'enum'},
            ],
          },
        });

    test('克隆与设计字段', () {
      final ctrl = OmniVoiceController('pkg', spec());
      addTearDown(ctrl.dispose);
      ctrl.textCtrl.text = 'hello';
      ctrl.languageCtrl.text = 'zh';
      ctrl.setVoice(VoiceEntry(
        id: 'v1',
        name: 'voice',
        type: 'file',
        audioPath: 'v.wav',
        text: 'reference',
        createdAt: DateTime(2026),
      ));
      ctrl.setAdvancedValues({'seed': '1'});
      final call = ctrl.buildCall()!;
      expect(call.endpoint, '/v1/audio/speech');
      expect(call.modelId, 'pkg');
      expect(call.request['input'], 'hello');
      expect(call.request['voice_ref'], 'v.wav');
      expect(call.request['language'], 'zh');
      expect(call.request['options']['reference_text'], 'reference');
      expect(call.request['options']['seed'], '1');
      expect(call.request['options'].containsKey('instruct'), isFalse);
    });

    test('设计属性拼接', () {
      final ctrl = OmniVoiceController('pkg', spec());
      addTearDown(ctrl.dispose);
      ctrl.textCtrl.text = 'hello';
      ctrl.setInstructAttr('gender', 'female');
      ctrl.setInstructAttr('age', 'young adult');
      final call = ctrl.buildCall()!;
      expect(call.request['options']['instruct'], 'female, young adult');
      expect(call.request.containsKey('voice_ref'), isFalse);
    });

    test('东北话版本门槛', () {
      expect(omniVoiceSupportsNortheasternDialect('0.9.3'), isFalse);
      expect(omniVoiceSupportsNortheasternDialect('dev'), isFalse);
      expect(omniVoiceSupportsNortheasternDialect('0.9.4'), isTrue);
      expect(omniVoiceSupportsNortheasternDialect('0.10.0'), isTrue);
      expect(omniVoiceSupportsNortheasternDialect('1.0.0'), isTrue);
    });

    test('高级参数完整且按组排序', () {
      final ctrl = OmniVoiceController('pkg', spec());
      addTearDown(ctrl.dispose);
      final names = ctrl.advancedOptions().map((o) => o.name).toList();
      expect(
          names,
          containsAll(const [
            'seed',
            'speed',
            'duration_sec',
            'num_inference_steps',
            'guidance_scale',
            'shift',
            'class_temperature',
            'position_temperature',
            'layer_penalty_factor',
            'denoise',
            'preprocess_prompt',
            'postprocess_output',
            'text_chunk_size',
            'text_chunk_mode',
            'audio_chunk_duration_sec',
            'audio_chunk_threshold_sec',
          ]));
      expect(names.first, 'seed');
      expect(names.indexOf('duration_sec'), lessThan(names.indexOf('speed')));
      expect(names.indexOf('text_chunk_size'),
          lessThan(names.indexOf('text_chunk_mode')));
      expect(names.indexOf('class_temperature'),
          lessThan(names.indexOf('position_temperature')));
    });

    test('拒绝非数字高级参数', () {
      final ctrl = OmniVoiceController('pkg', spec());
      addTearDown(ctrl.dispose);
      ctrl.textCtrl.text = 'hello';
      for (final name in const [
        'speed',
        'guidance_scale',
        'shift',
        'layer_penalty_factor',
        'position_temperature',
      ]) {
        ctrl.setAdvancedValues({name: 'not-a-number'});
        expect(ctrl.validate(), 'workbench.invalidValue', reason: name);
      }
    });

    test('过滤当前模式无关的高级参数', () {
      final ctrl = OmniVoiceController('pkg', spec());
      addTearDown(ctrl.dispose);
      ctrl.textCtrl.text = 'hello';
      ctrl.setAdvancedValues({
        'speed': '1.5',
        'duration_sec': '2.0',
        'denoise': 'false',
        'preprocess_prompt': 'false',
        'text_chunk_size': '20',
        'audio_chunk_duration_sec': '5',
        'audio_chunk_threshold_sec': '8',
        'text_chunk_mode': 'japanese',
      });
      final options =
          ctrl.buildCall()!.request['options'] as Map<String, dynamic>;
      expect(options.containsKey('speed'), isFalse);
      expect(options.containsKey('denoise'), isFalse);
      expect(options.containsKey('preprocess_prompt'), isFalse);
      expect(options.containsKey('audio_chunk_duration_sec'), isFalse);
      expect(options.containsKey('audio_chunk_threshold_sec'), isFalse);
      expect(options['duration_sec'], '2.0');
      expect(options['text_chunk_size'], '20');
      expect(options['text_chunk_mode'], 'japanese');
    });

    test('英文口音与中文方言互斥', () {
      final ctrl = OmniVoiceController('pkg', spec());
      addTearDown(ctrl.dispose);
      ctrl.textCtrl.text = 'hello';
      ctrl.setInstructAttr('accent', 'american accent');
      ctrl.setInstructAttr('dialect', '四川话');
      final call = ctrl.buildCall()!;
      expect(call.request['options']['instruct'], '四川话');

      ctrl.setInstructAttr('accent', 'british accent');
      expect(
          ctrl.buildCall()!.request['options']['instruct'], 'british accent');
    });

    test('首次按界面语言选择口音 Tab', () {
      final zh = OmniVoiceController('pkg', spec());
      addTearDown(zh.dispose);
      zh.ensureAccentTab('zh');
      expect(zh.accentTab, 'dialect');
      zh.ensureAccentTab('en');
      expect(zh.accentTab, 'dialect');

      final en = OmniVoiceController('pkg', spec());
      addTearDown(en.dispose);
      en.ensureAccentTab('en');
      expect(en.accentTab, 'accent');
    });

    test('参考音色必须填写参考文本', () {
      final ctrl = OmniVoiceController('pkg', spec());
      addTearDown(ctrl.dispose);
      ctrl.textCtrl.text = 'hello';
      ctrl.setVoice(VoiceEntry(
        id: 'v1',
        name: 'voice',
        type: 'file',
        audioPath: 'v.wav',
        createdAt: DateTime(2026),
      ));
      expect(ctrl.validate(), 'workbench.needReferenceText');

      ctrl.refTextCtrl.text = 'reference';
      expect(ctrl.validate(), isNull);
    });

    test('seed 使用文本输入而非滑块', () {
      final ctrl = OmniVoiceController('pkg', spec());
      addTearDown(ctrl.dispose);
      final seed = ctrl.advancedOptions().firstWhere((o) => o.name == 'seed');
      expect(seed.min, 0);
      expect(seed.max, isNull);
    });
  });

  group('Qwen3-TTS', () {
    ModelSpec spec() => ModelSpec.fromJson({
          'family': 'qwen3_tts',
          'tasks': ['tts', 'clone', 'design'],
          'languages': ['zh', 'en'],
          'capabilities': {
            'clone': ['speaker_reference'],
            'design': ['voice_design'],
          },
          'options': {
            'request': [
              {'name': 'reference_text', 'type': 'string'},
              {'name': 'instruct', 'type': 'string'},
              {
                'name': 'voice_id',
                'type': 'enum',
                'values': ['vivian', 'ryan'],
              },
              {'name': 'seed', 'type': 'int'},
            ],
          },
        });

    test('Base 参考文本为空时自动走向量克隆', () {
      final ctrl = Qwen3TtsController('qwen3_tts_1_7b_base_q8_0', spec());
      addTearDown(ctrl.dispose);
      ctrl.textCtrl.text = 'hello';
      expect(ctrl.validate(), 'workbench.needReference');
      ctrl.setVoice(VoiceEntry(
        id: 'v1',
        name: 'voice',
        type: 'file',
        audioPath: 'v.wav',
        createdAt: DateTime(2026),
      ));

      final vectorCall = ctrl.buildCall()!;
      expect(vectorCall.endpoint, '/v1/audio/speech');
      expect(vectorCall.request['voice_ref'], 'v.wav');
      expect(vectorCall.request['options']['x_vector_only_mode'], 'true');
      expect(
          vectorCall.request['options'].containsKey('reference_text'), isFalse);

      ctrl.refTextCtrl.text = 'reference';
      final cloneCall = ctrl.buildCall()!;
      expect(cloneCall.request['options']['x_vector_only_mode'], 'false');
      expect(cloneCall.request['options']['reference_text'], 'reference');
    });

    test('CustomVoice 提交内置音色', () {
      final ctrl =
          Qwen3TtsController('qwen3_tts_1_7b_customvoice_q8_0', spec());
      addTearDown(ctrl.dispose);
      ctrl.textCtrl.text = 'hello';
      expect(ctrl.validate(), 'workbench.needBuiltinVoice');
      ctrl.setBuiltinVoice('vivian');
      ctrl.instrCtrl.text = 'happy';
      final call = ctrl.buildCall()!;
      expect(call.request.containsKey('voice_ref'), isFalse);
      expect(call.request['options']['voice_id'], 'vivian');
      expect(call.request['options']['instruct'], 'happy');
    });

    test('CustomVoice 兼容旧记录音色大小写', () {
      final ctrl =
          Qwen3TtsController('qwen3_tts_1_7b_customvoice_q8_0', spec());
      addTearDown(ctrl.dispose);
      ctrl.restore(GenerationRecord(
        id: 'r',
        type: RecordType.tts,
        createdAtMs: 0,
        inputs: {
          'text': 'hello',
          'voice_id': 'Vivian',
        },
      ));
      expect(ctrl.voiceId, 'vivian');
      expect(ctrl.validate(), isNull);
      expect(ctrl.buildCall()!.request['options']['voice_id'], 'vivian');
    });

    test('VoiceDesign 提交指令', () {
      final ctrl =
          Qwen3TtsController('qwen3_tts_1_7b_voicedesign_q8_0', spec());
      addTearDown(ctrl.dispose);
      ctrl.textCtrl.text = 'hello';
      ctrl.instrCtrl.text = 'warm narrator';
      final call = ctrl.buildCall()!;
      expect(call.request.containsKey('voice_ref'), isFalse);
      expect(call.request['options']['instruct'], 'warm narrator');
    });
  });

  group('Ming 3.0 TTS', () {
    ModelSpec spec() => ModelSpec.fromJson({
          'family': 'ming3_tts',
          'tasks': ['tts', 'clone', 'design'],
          'languages': ['zh', 'en'],
          'capabilities': {
            'tts': ['built_in_voices', 'emotion_control'],
          },
          'options': {
            'request': [
              {
                'name': 'voice_id',
                'type': 'enum',
                'values': ['US_Emma', 'US_James'],
              },
              {'name': 'emotion', 'type': 'string'},
              {
                'name': 'dialect',
                'type': 'enum',
                'values': ['chuanyu dialect', 'cantonese'],
              },
              {
                'name': 'speed',
                'type': 'enum',
                'values': ['慢速', '中速', '快速'],
              },
              {
                'name': 'pitch',
                'type': 'enum',
                'values': ['低', '中', '高'],
              },
              {
                'name': 'volume',
                'type': 'enum',
                'values': ['低', '中', '高'],
              },
              {'name': 'reference_text', 'type': 'string'},
              {'name': 'instruct', 'type': 'string'},
              {
                'name': 'template_name',
                'type': 'enum',
                'values': [
                  'tts',
                  'multilingual',
                  'basic',
                  'emotion',
                  'dialect',
                  'ip',
                  'voice_design',
                  'freeform',
                ],
              },
              {
                'name': 'instruction_schema',
                'type': 'enum',
                'values': ['en', 'zh'],
              },
              {'name': 'max_tokens', 'type': 'int', 'min': 1},
              {'name': 'guidance_scale', 'type': 'float'},
              {'name': 'sigma', 'type': 'float', 'min': 0},
              {'name': 'temperature', 'type': 'float', 'min': 0},
              {'name': 'seed', 'type': 'int', 'min': 0},
              {'name': 'raw_text', 'type': 'bool'},
              {'name': 'text_chunk_size', 'type': 'int', 'min': 1},
              {
                'name': 'text_chunk_mode',
                'type': 'enum',
                'values': ['default', 'tag_aware', 'japanese', 'endline'],
              },
              {'name': 'trim_silence', 'type': 'bool'},
              {'name': 'use_speaker_embedding', 'type': 'bool'},
              {'name': 'zero_speaker_embedding', 'type': 'bool'},
              {'name': 'stream_frames_per_event', 'type': 'int'},
              {
                'name': 'stream_chunk_policy',
                'type': 'enum',
                'values': ['grow', 'fixed']
              },
            ],
          },
        });

    Ming3TtsController build() {
      final ctrl = Ming3TtsController('ming_3_0_tts_0_5b_bf16', spec());
      addTearDown(ctrl.dispose);
      ctrl.textCtrl.text = 'hello';
      return ctrl;
    }

    test('默认模板为 basic', () {
      final ctrl = build();
      expect(ctrl.templateMode, 'basic');
      expect(ctrl.effectiveTemplate, 'basic');
    });

    test('内置音色模板提交 ip', () {
      final ctrl = build();
      ctrl.setTemplate('ip');
      ctrl.setBuiltinVoice('US_Emma');
      final call = ctrl.buildCall()!;
      expect(call.request['options']['template_name'], 'ip');
      expect(call.request['options']['voice_id'], 'US_Emma');
      expect(call.request.containsKey('voice_ref'), isFalse);
    });

    test('情绪模板提交 emotion', () {
      final ctrl = build();
      ctrl.setTemplate('emotion');
      ctrl.setEmotion('高兴');
      final call = ctrl.buildCall()!;
      expect(call.request['options']['template_name'], 'emotion');
      expect(call.request['options']['emotion'], '高兴');
      expect(call.request['options'].containsKey('dialect'), isFalse);
    });

    test('方言模板提交 dialect', () {
      final ctrl = build();
      ctrl.setTemplate('dialect');
      ctrl.setDialect('cantonese');
      final call = ctrl.buildCall()!;
      expect(call.request['options']['template_name'], 'dialect');
      expect(call.request['options']['dialect'], 'cantonese');
    });

    test('基础模板提交 basic', () {
      final ctrl = build();
      ctrl.setTemplate('basic');
      ctrl.setAdvancedValues({'speed': '快速'});
      final call = ctrl.buildCall()!;
      expect(call.request['options']['template_name'], 'basic');
      expect(call.request['options']['speed'], '快速');
    });

    test('高级参数保存与重置保留基础控制', () {
      final ctrl = build();
      ctrl.setTemplate('basic');
      ctrl.setAdvancedValue('speed', 'fast');
      ctrl.setAdvancedValues({'seed': '1'});
      expect(ctrl.advanced['speed'], 'fast');
      expect(ctrl.advanced['seed'], '1');

      ctrl.setAdvancedValues({});
      expect(ctrl.advanced['speed'], 'fast');
      expect(ctrl.advanced.containsKey('seed'), isFalse);

      ctrl.setAdvancedValues({'seed': '1'});
      final call = ctrl.buildCall()!;
      final restored = build();
      restored.restore(GenerationRecord(
        id: 'r',
        type: RecordType.tts,
        createdAtMs: 0,
        inputs: call.recordInputs,
      ));
      expect(restored.advanced['speed'], 'fast');
      expect(restored.advanced['seed'], '1');
    });

    test('声音设计模板提交指令', () {
      final ctrl = build();
      ctrl.setTemplate('voice_design');
      ctrl.instrCtrl.text = 'calm narrator';
      final call = ctrl.buildCall()!;
      expect(call.request['options']['template_name'], 'voice_design');
      expect(call.request['options']['instruct'], 'calm narrator');
    });

    test('参考音色保持 tts 并带参考文本', () {
      final ctrl = build();
      ctrl.setTemplate('tts');
      ctrl.setVoice(VoiceEntry(
        id: 'v1',
        name: 'voice',
        type: 'file',
        audioPath: 'v.wav',
        text: 'reference',
        createdAt: DateTime(2026),
      ));
      final call = ctrl.buildCall()!;
      expect(call.request['options']['template_name'], 'tts');
      expect(call.request['options']['reference_text'], 'reference');
      expect(call.request['voice_ref'], 'v.wav');
    });

    test('高级参数覆盖新规格并隐藏流式参数', () {
      final ctrl = build();
      final names =
          ctrl.advancedOptions().map((option) => option.name).toList();
      expect(
        names.take(5).toList(),
        [
          'raw_text',
          'text_chunk_size',
          'text_chunk_mode',
          'trim_silence',
          'max_tokens'
        ],
      );
      expect(
        names,
        containsAll([
          'instruction_schema',
          'seed',
          'guidance_scale',
          'sigma',
          'temperature',
          'use_speaker_embedding',
          'zero_speaker_embedding',
        ]),
      );
      expect(names, isNot(contains('speed')));
      expect(names, isNot(contains('pitch')));
      expect(names, isNot(contains('volume')));
      expect(names, isNot(contains('template_name')));
      expect(names, isNot(contains('stream_frames_per_event')));
      expect(names, isNot(contains('stream_chunk_policy')));
    });

    test('语言与指令推导多语言和自由指令', () {
      final ctrl = build();
      expect(Ming3TtsController.templates, isNot(contains('multilingual')));
      expect(Ming3TtsController.templates, isNot(contains('freeform')));
      ctrl.setTemplate('tts');
      expect(ctrl.effectiveTemplate, 'tts');
      var call = ctrl.buildCall()!;
      expect(call.request['options']['template_name'], 'tts');
      expect(call.request.containsKey('language'), isFalse);

      ctrl.setTemplate('tts');
      ctrl.setLanguage('en');
      expect(ctrl.effectiveTemplate, 'multilingual');
      call = ctrl.buildCall()!;
      expect(call.request['options']['template_name'], 'multilingual');
      expect(call.request['language'], 'en');

      ctrl.instrCtrl.text = 'soft tone';
      expect(ctrl.effectiveTemplate, 'freeform');
      expect(ctrl.validate(), isNull);
      call = ctrl.buildCall()!;
      expect(call.request['options']['template_name'], 'freeform');
      expect(call.request['options']['instruct'], 'soft tone');
      expect(call.request['language'], 'en');
    });

    test('无语言有指令自动使用自由指令', () {
      final ctrl = build();
      ctrl.setTemplate('tts');
      expect(ctrl.effectiveTemplate, 'tts');
      ctrl.instrCtrl.text = 'whispered narration';
      expect(ctrl.effectiveTemplate, 'freeform');
      final call = ctrl.buildCall()!;
      expect(call.request['options']['template_name'], 'freeform');
      expect(
        call.request['options']['instruct'],
        'whispered narration',
      );

      ctrl.instrCtrl.clear();
      expect(ctrl.effectiveTemplate, 'tts');
    });

    test('显式基础模板要求至少一个控制项', () {
      final ctrl = build();
      ctrl.setTemplate('basic');
      expect(ctrl.validate(), 'workbench.incomplete');
      ctrl.setAdvancedValues({'speed': 'fast'});
      final call = ctrl.buildCall()!;
      expect(call.request['options']['template_name'], 'basic');
      expect(call.request['options']['speed'], 'fast');
    });

    test('无指令时保持 tts', () {
      final ctrl = build();
      ctrl.setTemplate('tts');
      expect(ctrl.effectiveTemplate, 'tts');
      final call = ctrl.buildCall()!;
      expect(call.request['options']['template_name'], 'tts');
      expect(call.request['options'].containsKey('instruct'), isFalse);
    });

    test('零说话人嵌入覆盖参考音色', () {
      final ctrl = build();
      ctrl.setTemplate('tts');
      ctrl.setVoice(VoiceEntry(
        id: 'v1',
        name: 'voice',
        type: 'file',
        audioPath: 'v.wav',
        createdAt: DateTime(2026),
      ));
      ctrl.setAdvancedValues({
        'zero_speaker_embedding': 'true',
      });
      final call = ctrl.buildCall()!;
      expect(call.request.containsKey('voice_ref'), isFalse);
      expect(call.request['options']['zero_speaker_embedding'], 'true');
    });

    test('raw_text 时不提交分块参数', () {
      final ctrl = build();
      ctrl.setTemplate('tts');
      ctrl.setAdvancedValues({
        'raw_text': 'true',
        'text_chunk_size': '100',
        'text_chunk_mode': 'endline',
      });
      final call = ctrl.buildCall()!;
      expect(call.request['options']['raw_text'], 'true');
      expect(
        call.request['options'].containsKey('text_chunk_size'),
        isFalse,
      );
      expect(
        call.request['options'].containsKey('text_chunk_mode'),
        isFalse,
      );
    });

    test('指令字段语言仅用于结构化模板', () {
      final ctrl = build();
      ctrl.setTemplate('tts');
      ctrl.setAdvancedValues({'instruction_schema': 'en'});
      var options = ctrl.buildCall()!.request['options'] as Map;
      expect(options.containsKey('instruction_schema'), isFalse);

      ctrl.setTemplate('dialect');
      ctrl.setDialect('cantonese');
      options = ctrl.buildCall()!.request['options'] as Map;
      expect(options['instruction_schema'], 'en');
    });

    test('恢复 0.1.4 旧记录模板', () {
      final cases = [
        (
          <String, String>{'text': 'hello', 'params': '{"emotion":"高兴"}'},
          'emotion',
        ),
        (
          <String, String>{
            'text': 'hello',
            'params': '{"dialect":"cantonese"}',
          },
          'dialect',
        ),
        (
          <String, String>{'text': 'hello', 'params': '{"voice_id":"US_Emma"}'},
          'ip',
        ),
        (
          <String, String>{'text': 'hello', 'params': '{"speed":"快速"}'},
          'basic',
        ),
        (
          <String, String>{'text': 'hello', 'instruction': 'calm narrator'},
          'voice_design',
        ),
        (<String, String>{'text': 'hello'}, 'tts'),
        (
          <String, String>{
            'text': 'hello',
            'voice_ref': 'v.wav',
            'reference_text': 'reference',
          },
          'tts',
        ),
      ];
      for (final item in cases) {
        final ctrl = build();
        ctrl.restore(GenerationRecord(
          id: 'legacy',
          type: RecordType.tts,
          createdAtMs: 0,
          inputs: item.$1,
        ));
        expect(ctrl.templateMode, item.$2);
      }
    });

    test('显式模板可记录并恢复', () {
      final ctrl = build();
      ctrl.setTemplate('voice_design');
      ctrl.instrCtrl.text = 'raw style';
      final call = ctrl.buildCall()!;

      final restored = build();
      restored.restore(GenerationRecord(
        id: 'r',
        type: RecordType.tts,
        createdAtMs: 0,
        inputs: call.recordInputs,
      ));
      expect(restored.templateMode, 'voice_design');
      expect(restored.instrCtrl.text, 'raw style');
      final restoredCall = restored.buildCall()!;
      expect(restoredCall.request['options']['template_name'], 'voice_design');
    });

    test('非法高级参数不可提交', () {
      final ctrl = build();
      for (final params in [
        {'max_tokens': '0'},
        {'text_chunk_size': '0'},
        {'sigma': '-1'},
        {'temperature': '-1'},
        {'seed': '-1'},
        {'guidance_scale': 'nan'},
      ]) {
        ctrl.setAdvancedValues(params);
        expect(ctrl.validate(), 'workbench.invalidNumber');
      }
    });

    testWidgets('切换模板后字段显示跟随变化', (tester) async {
      final temp = Directory.systemTemp.createTempSync('ming3_ui_');
      addTearDown(() {
        try {
          temp.deleteSync(recursive: true);
        } catch (_) {}
      });
      final modelSpec = spec();
      final ctrl = Ming3TtsController(
        'ming_3_0_tts_0_5b_bf16',
        modelSpec,
      );
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localeProvider.overrideWithValue(AppLocale.zh),
            voiceLibraryProvider.overrideWith(
              (ref) => VoiceLibraryController(paths: AppPaths(temp)),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: Ming3TtsWorkbench(
                  controller: ctrl,
                  spec: modelSpec,
                  dict: const {},
                  onSubmit: () {},
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('Auto'), findsNothing);
      expect(find.byType(WorkbenchDropdown), findsNWidgets(5));
      expect(find.byType(WorkbenchVoiceField), findsOneWidget);

      await tester.tap(find.text('tts'));
      await tester.pump();
      expect(find.byType(WorkbenchDropdown), findsNWidgets(2));
      expect(find.byType(WorkbenchVoiceField), findsOneWidget);

      await tester.tap(find.text('ip'));
      await tester.pump();
      expect(find.byType(WorkbenchDropdown), findsNWidgets(2));
      expect(find.byType(WorkbenchVoiceField), findsNothing);

      await tester.tap(find.text('basic'));
      await tester.pump();
      expect(find.byType(WorkbenchDropdown), findsNWidgets(5));
      expect(find.byType(WorkbenchVoiceField), findsOneWidget);
    });
  });

  group('IndexTTS2 / 2.5', () {
    ModelSpec spec() => ModelSpec.fromJson({
          'family': 'index_tts2',
          'tasks': ['tts', 'clone'],
          'languages': ['zh', 'en', 'ja', 'es', 'ar'],
          'capabilities': {
            'tts': ['emotion_control'],
            'clone': ['speaker_reference', 'emotion_control'],
          },
          'options': {
            'request': [
              {'name': 'language', 'type': 'string'},
              {'name': 'emotion_alpha', 'type': 'float'},
              {'name': 'emotion_vector', 'type': 'string'},
              {'name': 'use_emotion_text', 'type': 'bool'},
              {'name': 'emotion_text', 'type': 'string'},
              {'name': 'use_random_emotion', 'type': 'bool'},
              {'name': 'seed', 'type': 'int'},
              {'name': 'top_p', 'type': 'float', 'default': 0.8},
              {'name': 'text_chunk_size', 'type': 'int'},
              {'name': 'temperature', 'type': 'float'},
              {'name': 'duration_scale', 'type': 'float'},
            ],
          },
        });

    IndexTts2Controller build(String packageId) {
      final ctrl = IndexTts2Controller(packageId, spec());
      addTearDown(ctrl.dispose);
      ctrl.textCtrl.text = 'hello';
      ctrl.setVoice(VoiceEntry(
        id: 'v1',
        name: 'voice',
        type: 'file',
        audioPath: 'v.wav',
        createdAt: DateTime(2026),
      ));
      return ctrl;
    }

    test('2.0 不提交语言，文本情感走 tasks/run', () {
      final ctrl = build('index_tts2_q8_0');
      ctrl.setEmotionMode('text');
      ctrl.emotionTextCtrl.text = 'sad';
      ctrl.setLanguage('ja');
      final call = ctrl.buildCall()!;
      expect(call.endpoint, '/v1/tasks/run');
      expect(call.request['request']['voice_ref'], 'v.wav');
      expect(call.request['request']['options']['use_emotion_text'], 'true');
      expect(call.request['request']['options']['emotion_text'], 'sad');
      expect(
        call.request['request']['options'].containsKey('language'),
        isFalse,
      );
    });

    test('2.5 提交语言与情感参考音频', () {
      final ctrl = build('index_tts2_5_q8_0');
      ctrl.setLanguage('ja');
      ctrl.setEmotionMode('reference');
      ctrl.setEmotionAudio('emotion.wav');
      ctrl.setEmotionAlpha(0.5);
      final call = ctrl.buildCall()!;
      expect(call.request['request']['audio'], 'emotion.wav');
      expect(call.request['request']['options']['language'], 'ja');
      expect(call.request['request']['options']['emotion_alpha'], '0.5');
      expect(call.audioPath, 'emotion.wav');
    });

    test('情感向量按 8 维提交', () {
      final ctrl = build('index_tts2_5_q8_0');
      ctrl.setEmotionMode('vector');
      ctrl.setEmotionVector(0, 0.5);
      final call = ctrl.buildCall()!;
      expect(call.request['request']['options']['emotion_vector'],
          startsWith('[0.500,'));
    });

    test('情感向量写入记录并可恢复', () {
      final ctrl = build('index_tts2_5_q8_0');
      ctrl.setEmotionMode('vector');
      ctrl.setEmotionVector(0, 0.5);
      final call = ctrl.buildCall()!;
      expect(
          call.recordInputs['params'], contains('"emotion_vector":"[0.500,'));

      final restored = build('index_tts2_5_q8_0');
      restored.restore(GenerationRecord(
        id: 'r',
        type: RecordType.tts,
        createdAtMs: 0,
        inputs: call.recordInputs,
      ));
      expect(restored.emotionMode, 'vector');
      expect(restored.emotionVector[0], 0.5);
    });

    test('非法高级参数不可提交', () {
      final ctrl = build('index_tts2_5_q8_0');
      for (final params in [
        {'text_chunk_size': '0'},
        {'duration_scale': '-1'},
        {'temperature': '0'},
        {'top_p': '0'},
        {'top_k': '0'},
      ]) {
        ctrl.setAdvancedValues(params);
        expect(ctrl.validate(), 'workbench.invalidValue');
      }
    });

    test('关闭采样后不提交采样参数', () {
      final ctrl = build('index_tts2_5_q8_0');
      ctrl.setAdvancedValues({
        'do_sample': 'false',
        'temperature': '1.1',
        'top_k': '20',
        'top_p': '0.9',
      });
      expect(ctrl.validate(), isNull);
      final call = ctrl.buildCall()!;
      final options = call.request['request']['options'] as Map;
      expect(options['do_sample'], 'false');
      expect(options.containsKey('temperature'), isFalse);
      expect(options.containsKey('top_k'), isFalse);
      expect(options.containsKey('top_p'), isFalse);
    });

    test('高级参数使用专属范围', () {
      final ctrl = build('index_tts2_5_q8_0');
      final options = ctrl.advancedOptions();
      final topP = options.firstWhere((o) => o.name == 'top_p');
      expect(topP.min, 0.01);
      expect(topP.max, 1);
      final seed = options.firstWhere((o) => o.name == 'seed');
      expect(seed.min, 0);
      expect(seed.max, isNull);
      final chunk = options.firstWhere((o) => o.name == 'text_chunk_size');
      expect(chunk.min, 1);
      expect(chunk.max, isNull);
      for (final name in ['temperature', 'duration_scale']) {
        final option = options.firstWhere((o) => o.name == name);
        expect(option.min, greaterThan(0));
        expect(option.max, isNull);
      }
    });
  });

  group('Qwen3-ASR', () {
    test('语言空格规则', () {
      for (final language in [
        'Chinese',
        'Cantonese',
        'Japanese',
        'Thai',
        'zh-Hans',
        'yue',
      ]) {
        expect(Qwen3AsrController.languageUsesSpaces(language), isFalse);
      }
      for (final language in [
        'English',
        'Korean',
        'Vietnamese',
        'Arabic',
        'auto',
        '',
      ]) {
        expect(Qwen3AsrController.languageUsesSpaces(language), isTrue);
      }
    });

    test('走 tasks/run 并提交 ASR 参数', () {
      final spec = ModelSpec.fromJson({
        'family': 'qwen3_asr',
        'tasks': ['asr'],
        'languages': ['en', 'zh'],
        'capabilities': {
          'asr': ['vad_chunking'],
        },
        'options': {
          'request': [
            {'name': 'max_tokens', 'type': 'int'},
            {'name': 'audio_chunk_mode', 'type': 'enum'},
            {'name': 'audio_chunk_duration_sec', 'type': 'float'},
          ],
        },
      });
      final ctrl = Qwen3AsrController('pkg', spec);
      addTearDown(ctrl.dispose);
      ctrl.setAudio('a.wav');
      ctrl.setLanguage('zh');
      ctrl.setAdvancedValues({
        'max_tokens': '128',
        'audio_chunk_mode': 'vad',
        'audio_chunk_duration_sec': '15',
        'return_timestamps': 'true',
      });
      final call = ctrl.buildCall()!;
      expect(call.endpoint, '/v1/tasks/run');
      expect(call.modelId, 'pkg');
      expect(call.responseFormat, 'json_text');
      expect(call.request['request']['audio'], 'a.wav');
      expect(call.request['request']['language'], 'zh');
      expect(call.request['request']['options']['max_tokens'], '128');
      expect(call.request['request']['options']['audio_chunk_mode'], 'vad');
      expect(
        call.request['request']['options']['audio_chunk_duration_sec'],
        '15.0',
      );
      expect(call.request['request']['options']['return_timestamps'], 'true');
    });

    test('记录参数可重建 call，不依赖 call 字段', () {
      final spec = ModelSpec.fromJson({
        'family': 'qwen3_asr',
        'tasks': ['asr'],
        'languages': ['en', 'zh'],
      });
      final ctrl = Qwen3AsrController('pkg', spec);
      addTearDown(ctrl.dispose);
      ctrl.setAudio('a.wav');
      ctrl.setLanguage('zh');
      ctrl.setAdvancedValues({
        'audio_chunk_mode': 'fixed',
        'return_timestamps': 'true',
      });
      final call = ctrl.buildCall()!;
      final inputs = call.recordInputs;
      expect(inputs.containsKey('call'), isFalse);
      final record = GenerationRecord(
        id: 'r1',
        type: RecordType.asr,
        family: 'qwen3_asr',
        packageId: 'pkg',
        createdAtMs: 1,
        inputs: inputs,
      );
      final rebuiltCtrl = Qwen3AsrController('pkg', spec);
      addTearDown(rebuiltCtrl.dispose);
      rebuiltCtrl.restore(record);
      final rebuilt = rebuiltCtrl.buildCall()!;
      expect(rebuilt.request['request']['audio'], 'a.wav');
      expect(rebuilt.request['request']['language'], 'zh');
      expect(
        rebuilt.request['request']['options']['audio_chunk_mode'],
        'fixed',
      );
      expect(
        rebuilt.request['request']['options']['return_timestamps'],
        'true',
      );
    });

    test('缺音频时不可提交', () {
      final spec = ModelSpec.fromJson({
        'family': 'qwen3_asr',
        'tasks': ['asr'],
        'languages': ['en'],
      });
      final ctrl = Qwen3AsrController('pkg', spec);
      addTearDown(ctrl.dispose);
      expect(ctrl.validate(), 'workbench.needAudio');
      expect(ctrl.buildCall(), isNull);
    });
  });

  test('空 audio_cpp_version 不写入记录', () {
    final empty = GenerationRecord(
      id: 'r1',
      type: RecordType.tts,
      createdAtMs: 1,
    );
    expect(empty.toJson().containsKey('audio_cpp_version'), isFalse);

    final known = GenerationRecord(
      id: 'r2',
      type: RecordType.tts,
      createdAtMs: 1,
      audioCppVersion: '0.9.3',
    );
    expect(known.toJson()['audio_cpp_version'], '0.9.3');
  });

  test('ASR ret 文本优先，旧记录回退 text', () {
    final record = GenerationRecord(
      id: 'r1',
      type: RecordType.asr,
      createdAtMs: 1,
      text: 'old',
      ret: {'text': 'new', 'words': []},
    );
    expect(record.displayText, 'new');
    final round = GenerationRecord.fromJson(record.toJson());
    expect(round.ret?['text'], 'new');
    expect(round.displayText, 'new');

    final legacy = GenerationRecord(
      id: 'r2',
      type: RecordType.asr,
      createdAtMs: 1,
      text: 'legacy',
    );
    expect(legacy.displayText, 'legacy');
  });

  test('ModelSpec 解析 capabilities', () {
    final spec = ModelSpec.fromJson({
      'family': 'x',
      'tasks': ['tts', 'asr'],
      'languages': <String>[],
      'capabilities': {
        'tts': ['long_form'],
        'asr': ['timestamps'],
      },
    });
    expect(spec.capabilitiesOf('tts'), ['long_form']);
    expect(spec.capabilitiesOf('asr'), ['timestamps']);
    expect(spec.capabilitiesOf('vc'), isEmpty);
  });

  test('ModelSpec 解析许可信息', () {
    final spec = ModelSpec.fromJson({
      'family': 'x',
      'tasks': ['tts'],
      'languages': <String>[],
      'licenses': [
        {
          'name': 'CC-BY-4.0',
          'url': 'https://example.com/license',
          'commercial_use': 'yes',
          'notes': 'Keep attribution.',
          'checked_at': '2026-11-02',
          'source_urls': ['https://example.com/model'],
        },
        {
          'name': 'Custom',
          'commercial_use': 'unknown',
        },
      ],
    });
    expect(spec.licenses.length, 2);
    expect(spec.licenses.first.name, 'CC-BY-4.0');
    expect(spec.licenses.first.commercialUse, 'yes');
    expect(spec.licenses.first.sourceUrls, ['https://example.com/model']);
    expect(spec.licenses.last.commercialUse, 'unclear');
  });

  test('ModelSpec 解析枚举值元数据', () {
    final spec = ModelSpec.fromJson({
      'family': 'x',
      'tasks': ['tts'],
      'languages': <String>[],
      'i18n': {
        'options': {
          'voice_id': {
            'en': 'Voice',
            'zh': '音色',
            'values': {
              'vivian': {
                'label': {'en': 'Vivian', 'zh': 'Vivian'},
                'native_language': {'en': 'Chinese', 'zh': '中文'},
                'description': {
                  'en': 'Bright young female voice',
                  'zh': '明亮年轻女声',
                },
              },
            },
          },
        },
      },
      'options': {
        'request': [
          {
            'name': 'voice_id',
            'type': 'enum',
            'values': ['vivian'],
          },
        ],
      },
    });
    final meta = spec.optionValueMetaFor('voice_id', 'vivian');
    expect(meta?.label('zh'), 'Vivian');
    expect(meta?.nativeLanguage('zh'), '中文');
    expect(meta?.description('en'), 'Bright young female voice');
    expect(spec.optionDescription(spec.requestOptions.single, 'zh'), '音色');
  });

  test('ModelSpec 解析模型 UI 文案', () {
    final spec = ModelSpec.fromJson({
      'family': 'x',
      'i18n': {
        'ui': {
          'emotion.title': {'en': 'Emotion', 'zh': '情感'},
        },
      },
    });
    expect(spec.uiText('emotion.title', 'zh'), '情感');
    expect(spec.uiText('emotion.title', 'en'), 'Emotion');
    expect(spec.uiText('missing', 'zh', fallback: 'fallback'), 'fallback');
  });
}
