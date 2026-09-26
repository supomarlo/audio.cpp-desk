import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart'
    show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'core/app_config.dart';
import 'core/app_logger.dart';
import 'core/app_paths.dart';
import 'features/home_shell.dart';
import 'localization/strings.dart';
import 'providers/app_providers.dart';
import 'providers/generation_providers.dart';
import 'providers/server_providers.dart';

const _uiFontFamily = 'Microsoft YaHei UI';

void _registerThirdPartyLicenses() {
  LicenseRegistry.addLicense(() async* {
    try {
      final text = await rootBundle
          .loadString('assets/licenses/audio.cpp-LICENSE.txt');
      yield LicenseEntryWithLineBreaks(const ['audio.cpp'], text);
    } catch (_) {}
  });
}

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting();
  _registerThirdPartyLicenses();
  final paths0 = await resolveAppRoot(args);
  var config = await AppConfig.load(paths0);
  if (config.locale == null) {
    config = AppConfig.fromJson({
      ...config.toJson(),
      'locale': systemLocale().code,
    });
  }
  config = config.normalizedFor(paths0);
  await config.ensureDirectories(paths0);
  await config.save(paths0);
  final paths = AppPaths(
    paths0.appRoot,
    dataRoot: Directory(config.resolveWith(paths0, config.dataPath)),
  );
  await paths.ensureDirectories();
  AppLogger.configure(logDir: paths.logDir, enabled: config.appLogToFile);
  AppLogger.info(
      'app root=${paths.appRoot.path}; data=${paths.dataRoot.path}; '
      'models=${config.resolveWith(paths, config.modelsPath)}; '
      'audio.cpp=${config.resolveWith(paths, config.audioCppPath)}');
  runApp(
    ProviderScope(
      overrides: [
        appPathsProvider.overrideWithValue(paths),
        appConfigProvider.overrideWith(
          (ref) => ConfigNotifier(paths: paths, initial: config),
        ),
      ],
      child: const AudioCppDeskApp(),
    ),
  );
}

class AudioCppDeskApp extends ConsumerStatefulWidget {
  const AudioCppDeskApp({super.key});

  @override
  ConsumerState<AudioCppDeskApp> createState() => _AudioCppDeskAppState();
}

class _AudioCppDeskAppState extends ConsumerState<AudioCppDeskApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // 关闭软件时主动停止服务端（含本 App 启动的子进程与被接管的实例），用户无需关心服务端。
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        // 先中止任务队列（清队列 + 把未完成记录标为中断 + 置中止锁），
        // 再停服务端；否则队列会在服务端停止后继续提交，把它们逐个标为失败。
        try {
          ref.read(generationQueueProvider).abort();
        } catch (_) {}
        try {
          await ref.read(serverControllerProvider.notifier).stop();
        } catch (_) {}
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 让 Flutter 内置控件（文本框右键菜单等）跟随应用语言。
    final appLocale = ref.watch(localeProvider);
    return MaterialApp(
      title: 'audio.cpp Desk',
      debugShowCheckedModeBanner: false,
      locale: Locale(appLocale == AppLocale.zh ? 'zh' : 'en'),
      supportedLocales: const [Locale('zh'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        fontFamily: _uiFontFamily,
        fontFamilyFallback: const ['Microsoft YaHei', 'Segoe UI'],
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
        useMaterial3: true,
        fontFamily: _uiFontFamily,
        fontFamilyFallback: const ['Microsoft YaHei', 'Segoe UI'],
      ),
      home: const HomeShell(),
    );
  }
}