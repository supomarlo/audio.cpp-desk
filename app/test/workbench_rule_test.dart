import 'dart:convert';
import 'dart:io';

import 'package:audio_cpp_desk/models/workbench_rule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('派生选项', () {
    WorkbenchRule buildRule() => WorkbenchRule.fromJson({
          'reference': 'optional',
          'voiceId': {
            'values': ['US_Emma', 'US_James'],
            'option': 'voice_id',
            'allowEmpty': true,
          },
          'derivedOptions': {
            'option': 'template_name',
            'default': 'tts',
            'defaultClear': ['speed', 'emotion', 'dialect', 'voice_id'],
            'rules': [
              {
                'when': {'voice': 'builtin'},
                'set': {'template_name': 'ip'},
                'clear': ['reference_text', 'instruct'],
              },
              {
                'when': {'option': 'dialect'},
                'set': {'template_name': 'dialect'},
                'clear': ['reference_text', 'instruct'],
              },
              {
                'when': {'option': 'emotion'},
                'set': {'template_name': 'emotion'},
                'clear': ['instruct'],
              },
              {
                'when': {
                  'any': ['speed', 'pitch', 'volume'],
                },
                'set': {'template_name': 'basic'},
                'clear': ['instruct'],
              },
              {
                'when': {'option': 'instruct', 'voice': 'none'},
                'set': {'template_name': 'voice_design'},
                'clear': ['speed'],
              },
            ],
          },
        });

    test('未选择时使用声明的默认模板', () {
      final rule = buildRule();
      final result = rule.derivedOptions!.resolve(
        {},
        builtinVoice: false,
        referenceVoice: false,
      );
      expect(result, isNotNull);
      expect(result!.set['template_name'], 'tts');
      expect(result.clear,
          containsAll(['speed', 'emotion', 'dialect', 'voice_id']));
    });

    test('内置音色优先并清理冲突字段', () {
      final rule = buildRule();
      final result = rule.derivedOptions!.resolve(
        {'voice_id': 'US_Emma', 'dialect': 'cantonese'},
        builtinVoice: true,
        referenceVoice: false,
      );
      expect(result!.set['template_name'], 'ip');
      expect(result.clear, contains('reference_text'));
      expect(result.clear, contains('instruct'));
    });

    test('结构化控件推导对应模板', () {
      final rule = buildRule();
      final d = rule.derivedOptions!;
      expect(
        d.resolve({'dialect': 'cantonese'},
            builtinVoice: false, referenceVoice: false)!.set['template_name'],
        'dialect',
      );
      expect(
        d.resolve({'emotion': 'happy'},
            builtinVoice: false, referenceVoice: false)!.set['template_name'],
        'emotion',
      );
      final dialect = d.resolve({'dialect': 'cantonese'},
          builtinVoice: false, referenceVoice: false)!;
      expect(dialect.set['template_name'], 'dialect');
      expect(dialect.clear, contains('reference_text'));
    });

    test('无音色时指令推导 voice_design', () {
      final rule = buildRule();
      final result = rule.derivedOptions!.resolve(
        {'instruct': 'calm adult voice'},
        builtinVoice: false,
        referenceVoice: false,
      );
      expect(result!.set['template_name'], 'voice_design');
    });

    test('参考音色保持默认模板', () {
      final rule = buildRule();
      final result = rule.derivedOptions!.resolve(
        {},
        builtinVoice: false,
        referenceVoice: true,
      );
      expect(result!.set['template_name'], 'tts');
    });

    test('allowEmpty 默认关闭且可开启', () {
      final oldRule = WorkbenchRule.fromJson({
        'voiceId': {
          'values': ['A']
        },
      });
      expect(oldRule.voiceId!.allowEmpty, isFalse);

      final newRule = WorkbenchRule.fromJson({
        'voiceId': {
          'values': ['A'],
          'allowEmpty': true
        },
      });
      expect(newRule.voiceId!.allowEmpty, isTrue);
    });
  });

  group('布局 option 控件', () {
    test('解析 option、取值与中英文标签', () {
      final node = LayoutNode.fromJson({
        'type': 'option',
        'option': 'emotion',
        'exclusiveGroup': 'emotion_dialect',
        'whenOptionsEmpty': ['dialect'],
        'label': {'en': 'Emotion', 'zh': '情绪'},
        'values': [
          {'value': '高兴', 'en': 'Happy', 'zh': '高兴'},
          {'value': '中性', 'en': 'Neutral'},
        ],
      })!;
      expect(node.type, 'option');
      expect(node.option, 'emotion');
      expect(node.exclusiveGroup, 'emotion_dialect');
      expect(node.whenOptionsEmpty, ['dialect']);
      expect(node.labelEn, 'Emotion');
      expect(node.labelZh, '情绪');
      expect(node.values.map((c) => c.value), ['高兴', '中性']);
      expect(node.values.first.label('en'), 'Happy');
      expect(node.values.first.label('zh'), '高兴');
      expect(node.values.last.label('zh'), 'Neutral');
    });

    test('递归收集 option 名称', () {
      final rule = WorkbenchRule.fromJson({
        'layout': [
          {
            'type': 'grid',
            'children': [
              {
                'type': 'option',
                'option': 'emotion',
                'values': ['高兴']
              },
              {
                'type': 'option',
                'option': 'dialect',
                'values': ['cantonese']
              },
            ],
          },
        ],
      });
      expect(rule.layoutOptionNames, containsAll(['emotion', 'dialect']));
      expect(rule.layoutOptionNames.length, 2);
      expect(
          rule.layoutOptionNodes.map((n) => n.option), ['emotion', 'dialect']);
    });
  });

  group('Ming 3.0 TTS 自适应规则', () {
    late WorkbenchRule rule;

    setUpAll(() {
      final decoded = jsonDecode(
        File('assets/workbench_rules/ming3_tts.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      rule = WorkbenchRule.fromJson(
        Map<String, dynamic>.from(decoded['ming3_tts'] as Map),
      );
    });

    test('内置音色在列表中且默认为空', () {
      expect(rule.voiceId, isNotNull);
      expect(rule.voiceId!.values, contains('US_Emma'));
      expect(rule.voiceId!.option, 'voice_id');
      expect(rule.voiceId!.allowEmpty, isTrue);
    });

    test('情绪规格为官方枚举值', () {
      final decoded = jsonDecode(
        File('assets/model_specs_app/ming3_tts.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final request = (decoded['options'] as Map)['request'] as List<dynamic>;
      final emotion = request.firstWhere((o) => o['name'] == 'emotion')
          as Map<String, dynamic>;
      expect(emotion['type'], 'enum');
      expect(emotion['values'], [
        '高兴',
        '悲伤',
        '愤怒',
        '恐惧',
        '厌恶',
        '惊讶',
        '中性',
      ]);
    });

    test('情绪与方言为主界面 option 控件', () {
      expect(rule.layoutOptionNames, containsAll(['emotion', 'dialect']));
      expect(rule.layoutOptionNames.length, 2);
      final grid = rule.layout.firstWhere((n) => n.type == 'grid');
      expect(grid.when, 'noBuiltinVoice');
      final instruction =
          rule.layout.firstWhere((n) => n.type == 'instruction');
      expect(instruction.whenOptionsEmpty, ['emotion', 'dialect']);
      final emotion =
          rule.layoutOptionNodes.firstWhere((n) => n.option == 'emotion');
      expect(emotion.exclusiveGroup, 'emotion_dialect');
      expect(emotion.labelEn, 'Emotion');
      expect(emotion.labelZh, '情绪');
      expect(emotion.values.map((c) => c.value), [
        '高兴',
        '悲伤',
        '愤怒',
        '恐惧',
        '厌恶',
        '惊讶',
        '中性',
      ]);
      expect(emotion.values.first.label('en'), 'Happy');
      expect(emotion.values.first.label('zh'), '高兴');

      final dialect =
          rule.layoutOptionNodes.firstWhere((n) => n.option == 'dialect');
      expect(dialect.exclusiveGroup, 'emotion_dialect');
      expect(dialect.labelEn, 'Dialect');
      expect(dialect.labelZh, '方言');
      expect(
          dialect.values.map((c) => c.value), ['chuanyu dialect', 'cantonese']);
      expect(dialect.values.first.label('zh'), '川渝话');
      expect(dialect.values.last.label('en'), 'Cantonese');
    });

    test('推导 tts / ip / dialect / emotion / basic / voice_design', () {
      final d = rule.derivedOptions!;

      expect(
        d.resolve({},
            builtinVoice: false, referenceVoice: false)!.set['template_name'],
        'tts',
      );
      final ip = d.resolve({'voice_id': 'US_Emma', 'dialect': 'cantonese'},
          builtinVoice: true, referenceVoice: false)!;
      expect(ip.set['template_name'], 'ip');
      expect(ip.clear, contains('emotion'));
      expect(
        d.resolve({},
            builtinVoice: false, referenceVoice: true)!.set['template_name'],
        'tts',
      );
      expect(
        d.resolve({'dialect': 'cantonese'},
            builtinVoice: false, referenceVoice: false)!.set['template_name'],
        'dialect',
      );
      expect(
        d.resolve({'emotion': 'happy'},
            builtinVoice: false, referenceVoice: false)!.set['template_name'],
        'emotion',
      );
      expect(
        d.resolve({'volume': '高'},
            builtinVoice: false, referenceVoice: false)!.set['template_name'],
        'basic',
      );
      expect(
        d.resolve({'instruct': 'calm voice'},
            builtinVoice: false, referenceVoice: false)!.set['template_name'],
        'voice_design',
      );
    });
  });

  group('已有适配规则保持默认关闭', () {
    const files = [
      'breeze_tts.json',
      'omnivoice.json',
      'qwen3_tts.json',
      'index_tts2.json',
      'index_tts2_5.json',
      'qwen3_asr.json',
      'meanvc2.json',
    ];

    test('未启用新的派生或允许空音色', () {
      for (final name in files) {
        final file = File('assets/workbench_rules/$name');
        expect(file.existsSync(), isTrue, reason: name);
        final decoded =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        for (final entry in decoded.entries) {
          final rule = WorkbenchRule.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          );
          expect(
            rule.derivedOptions,
            isNull,
            reason: '$name/${entry.key} 不应使用 derivedOptions',
          );
          expect(
            rule.voiceId?.allowEmpty,
            isNot(true),
            reason: '$name/${entry.key} 应保持默认音色行为',
          );
          expect(
            rule.layoutOptionNames,
            isEmpty,
            reason: '$name/${entry.key} 不应使用布局 option 控件',
          );
        }
      }
    });
  });
}
