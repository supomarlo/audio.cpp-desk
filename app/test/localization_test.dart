import 'dart:convert';
import 'dart:io';

import 'package:audio_cpp_desk/core/app_config.dart';
import 'package:audio_cpp_desk/core/app_paths.dart';
import 'package:audio_cpp_desk/features/settings/language_switch.dart';
import 'package:audio_cpp_desk/localization/strings.dart';
import 'package:audio_cpp_desk/providers/app_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('语言判定', () {
    test('系统语言名以 zh 开头归中文，其余归英文', () {
      expect(localeFromName('zh_CN'), AppLocale.zh);
      expect(localeFromName('zh-CN'), AppLocale.zh);
      expect(localeFromName('zh-Hans-CN'), AppLocale.zh);
      expect(localeFromName('en_US'), AppLocale.en);
      expect(localeFromName('ja_JP'), AppLocale.en);
      expect(localeFromName(''), AppLocale.en);
    });

    test('配置码映射', () {
      expect(localeFromCode('zh'), AppLocale.zh);
      expect(localeFromCode('en'), AppLocale.en);
      expect(localeFromCode(null), AppLocale.en);
      expect(localeFromCode('fr'), AppLocale.en);
    });
  });

  group('字典', () {
    test('中英文字典词条齐全且不同语言文案一致对应', () {
      for (final key in Dictionary.zh.keys) {
        expect(Dictionary.en.containsKey(key), isTrue,
            reason: '英文词典缺少 $key');
        expect(Dictionary.en[key], isNotEmpty);
        expect(Dictionary.zh[key], isNotEmpty);
      }
    });

    test('未命中的 key 原样返回', () {
      expect(Dictionary.t(AppLocale.zh, 'not.exist'), 'not.exist');
      expect(Dictionary.t(AppLocale.en, 'not.exist'), 'not.exist');
    });

    test('中文词典缺失词条时回退英文值', () {
      final zhDict = Dictionary.of(AppLocale.zh);
      final zhKeys = Dictionary.zh.keys.toSet();
      final enKeys = Dictionary.en.keys.toSet();
      for (final key in enKeys) {
        final hasZh = zhKeys.contains(key);
        if (hasZh) {
          expect(zhDict[key], Dictionary.zh[key],
              reason: '$key 已有中文词条应优先返回中文');
        } else {
          expect(zhDict[key], Dictionary.en[key],
              reason: '$key 中文缺词条应回退英文');
        }
      }
    });
  });

  group('配置持久化', () {
    test('locale 序列化往返保真', () {
      final cfg = AppConfig(locale: 'zh');
      final round = AppConfig.fromJson(cfg.toJson());
      expect(round.locale, 'zh');
    });

    test('normalizedFor 透传 locale', () async {
      final temp = Directory.systemTemp.createTempSync('i18n_cfg_');
      addTearDown(() {
        try {
          temp.deleteSync(recursive: true);
        } catch (_) {}
      });
      final paths = AppPaths(temp);
      final cfg = AppConfig(locale: 'en').normalizedFor(paths);
      expect(cfg.locale, 'en');
    });
  });

  testWidgets('侧边栏语言切换并写入配置', (tester) async {
    final temp = Directory.systemTemp.createTempSync('i18n_page_');
    addTearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final paths = AppPaths(temp);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appPathsProvider.overrideWithValue(paths),
          appConfigProvider.overrideWith(
            (ref) => ConfigNotifier(
              paths: paths,
              initial: AppConfig(locale: 'zh'),
            ),
          ),
        ],
        child: const MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(body: Column(children: [LanguageSwitch()])),
        ),
      ),
    );
    await tester.pump();

    // 前台仅一个语言图标；当前只有两种语言，点击直接切换。
    expect(find.byIcon(Icons.language), findsOneWidget);

    await tester.tap(find.byIcon(Icons.language));
    await tester.pumpAndSettle();

    String? readLocale() {
      final f = paths.configFile();
      if (!f.existsSync()) return null;
      try {
        final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        return m['locale'] as String?;
      } catch (_) {
        return null;
      }
    }

    String? got;
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      got = readLocale();
      if (got == 'en') break;
    }
    expect(got, 'en',
        reason: '切换语言后应写入配置文件，后续启动直接读取');
  }, timeout: const Timeout(Duration(seconds: 60)));
}