import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../core/app_config.dart';
import '../core/app_paths.dart';
import '../localization/strings.dart';

final appPathsProvider = Provider<AppPaths>((ref) {
  throw StateError('appPathsProvider must be overridden in main()');
});

/// 主界面当前页索引（侧栏导航；供跨页跳转使用）。
final homeTabProvider = StateProvider<int>((ref) => 0);

/// 跨页一次性提示：其它页面写入后，工作台在页内 SnackBar 展示并清空。
final workbenchNoticeProvider = StateProvider<String?>((ref) => null);

/// 跨页持久提示（不自动关闭）：如服务端多次启动失败导致队列停止。
/// 工作台读取后以页内固定提示条展示，需用户手动关闭。
final workbenchErrorNoticeProvider = StateProvider<String?>((ref) => null);

final appConfigProvider =
    StateNotifierProvider<ConfigNotifier, AppConfig>((ref) {
  throw StateError('appConfigProvider must be overridden in main()');
});

class ConfigNotifier extends StateNotifier<AppConfig> {
  ConfigNotifier({required AppPaths paths, required AppConfig initial})
      : _paths = paths,
        super(initial);

  final AppPaths _paths;

  Future<void> update(void Function(AppConfig config) apply) async {
    apply(state);
    state = AppConfig.fromJson(state.toJson());
    await state.save(_paths);
  }

  Future<void> save() => state.save(_paths);
}

final localeProvider = Provider<AppLocale>((ref) {
  final code = ref.watch(appConfigProvider.select((c) => c.locale));
  return localeFromCode(code);
});

final stringsProvider = Provider<Map<String, String>>((ref) {
  return Dictionary.of(ref.watch(localeProvider));
});

String tr(WidgetRef ref, String key) =>
    ref.watch(stringsProvider)[key] ?? key;

String trF(WidgetRef ref, String key, Map<String, String> args) {
  var s = ref.watch(stringsProvider)[key] ?? key;
  for (final e in args.entries) {
    s = s.replaceAll('{${e.key}}', e.value);
  }
  return s;
}

String dictTpl(Map<String, String> dict, String key, Map<String, String> args) {
  var s = dict[key] ?? key;
  for (final e in args.entries) {
    s = s.replaceAll('{${e.key}}', e.value);
  }
  return s;
}