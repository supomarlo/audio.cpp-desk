import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_config.dart';
import '../../core/app_info.dart';
import '../../core/app_logger.dart';
import '../../providers/app_providers.dart';
import '../../providers/library_providers.dart';
import '../../providers/server_providers.dart';
import '../common/busy_guard.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }
  late final TextEditingController _audioCppCtrl;
  late final TextEditingController _modelsCtrl;
  late final TextEditingController _dataCtrl;
  Timer? _timeoutDebounce;
  // 拖动过程中的本地草稿值（即时反馈用；应用/未变更后清空，回到配置值）。
  int? _timeoutDraft;
  // 串行化：同一时刻只跑一个"应用超时 + 重启服务端"流程；
  // 期间到来的新改动合并为"最新的待应用值"，待当前流程结束后再执行。
  bool _timeoutApplying = false;
  int? _timeoutPending;

  @override
  void initState() {
    super.initState();
    final cfg = ref.read(appConfigProvider);
    final paths = ref.read(appPathsProvider);
    _audioCppCtrl = TextEditingController(
      text: AppConfig.normalizeStored(paths, cfg.audioCppPath),
    );
    _modelsCtrl = TextEditingController(
      text: AppConfig.normalizeStored(paths, cfg.modelsPath),
    );
    _dataCtrl = TextEditingController(
      text: AppConfig.normalizeStored(paths, cfg.dataPath),
    );
  }

  @override
  void dispose() {
    _timeoutDebounce?.cancel();
    _timeoutPending = null; // 停止串行流程的后续迭代
    _audioCppCtrl.dispose();
    _modelsCtrl.dispose();
    _dataCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    // 有任务生成时拦截：改目录/重启服务端都会打断当前生成。
    AppLogger.info('settings.save: begin');
    if (!await confirmWhileBusy(ref, context)) {
      AppLogger.info('settings.save: blocked by busy task');
      return;
    }
    final paths = ref.read(appPathsProvider);
    final cfgBefore = ref.read(appConfigProvider);
    final modelsBefore = cfgBefore.modelsPath;
    final audioCppBefore = cfgBefore.audioCppPath;
    final dataBefore = cfgBefore.dataPath;
    await ref.read(appConfigProvider.notifier).update((c) {
      c.audioCppPath = AppConfig.normalizeStored(
        paths,
        _audioCppCtrl.text.trim().isEmpty ? r'audio.cpp' : _audioCppCtrl.text,
      );
      c.modelsPath = AppConfig.normalizeStored(
        paths,
        _modelsCtrl.text.trim().isEmpty ? r'models' : _modelsCtrl.text,
      );
      c.dataPath = AppConfig.normalizeStored(
        paths,
        _dataCtrl.text.trim().isEmpty ? r'data' : _dataCtrl.text,
      );
    });
    final cfgAfter = ref.read(appConfigProvider);
    final dataChanged = cfgAfter.dataPath != dataBefore;
    final serverChanged = cfgAfter.modelsPath != modelsBefore ||
        cfgAfter.audioCppPath != audioCppBefore;
    AppLogger.info(
        'settings.save: models $modelsBefore -> ${cfgAfter.modelsPath}; '
        'audioCpp $audioCppBefore -> ${cfgAfter.audioCppPath}; '
        'data $dataBefore -> ${cfgAfter.dataPath}; '
        'dataChanged=$dataChanged, serverChanged=$serverChanged');
    // 目录可能已改变：重新扫描版本并重建模型库，按新目录重建"已安装"列表。
    rescanVersions(ref);
    AppLogger.info('settings.save: invalidated versions + modelLibrary');
    if (mounted) {
      final dict = ref.read(stringsProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(dict['settings.saved'] ?? '')),
      );
    }
    if (dataChanged) {
      // 数据目录变更需重启软件（只重启服务端不够）。
      if (mounted) {
        final dict = ref.read(stringsProvider);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(dict['settings.dataRestart'] ??
              'Data directory changed. Please restart the app.'),
        ));
      }
      return;
    }
    if (serverChanged) {
      // 按新目录重启服务端：等模型库重建完成后，带最新模型启动。
      try {
        await ref.read(modelLibraryProvider.notifier).ready;
      } catch (_) {}
      try {
        await ref.read(serverControllerProvider.notifier).stop();
        await ensureServerStarted(ref);
      } catch (_) {}
    }
  }

  // 单次任务超时范围（分钟），滑动条按 1 分钟步进。
  static const int _timeoutMin = 1;
  static const int _timeoutMax = 30;

  // 右侧数值格：与上面的 SwitchListTile 对齐。
  // M3 的 ListTile contentPadding 默认为 EdgeInsetsDirectional.only(start:16, end:24)；
  // Switch(M3) 盒宽 = switchWidth(52) + padding(4*2) = 60（轨道 52 居中）。
  // 本格与开关盒等宽、右缘同在该内边距 end(24) 处 ⇒ 两中心一致。
  static const double _timeoutValueWidth = 60;

  /// 当前时长（分钟），钳制在滑条范围 [min, max] 内。
  int _timeoutMinutes(int seconds) {
    final m = (seconds / 60).round();
    return m < _timeoutMin
        ? _timeoutMin
        : (m > _timeoutMax ? _timeoutMax : m);
  }

  /// 过滤未变更的值 + 防抖：点击或滑动都一样，静置 500ms 后再应用（必要时重启服务端）。
  void _scheduleTaskTimeout(int minutes) {
    // 参数没变：不处理，并取消挂起的计划。
    if (minutes * 60 == ref.read(appConfigProvider).taskTimeoutSeconds) {
      _timeoutDebounce?.cancel();
      if (_timeoutDraft != null) setState(() => _timeoutDraft = null);
      return;
    }
    _timeoutDebounce?.cancel();
    _timeoutDebounce = Timer(const Duration(milliseconds: 500), () {
      _runTimeoutApply(minutes);
    });
  }

  /// 串行应用：已有流程在跑时只记录"最新待应用值"，待其结束后再执行（合并为最后一次）。
  Future<void> _runTimeoutApply(int minutes) async {
    _timeoutPending = minutes;
    if (_timeoutApplying) return;
    _timeoutApplying = true;
    try {
      while (_timeoutPending != null) {
        final next = _timeoutPending!;
        _timeoutPending = null;
        await _applyTimeout(next);
      }
    } finally {
      _timeoutApplying = false;
    }
  }

  /// 应用单次任务超时（写进 server.json 的 busy_timeout_ms；服务端非停止态时重启以生效）。
  Future<void> _applyTimeout(int minutes) async {
    if (!await confirmWhileBusy(ref, context)) return;
    if (!mounted) return;
    final snap = ref.read(serverControllerProvider);
    // 只要不在“已停止”态（含 starting/stopping/running/error）都需重启一次来套用新配置。
    final needsRestart = !snap.isStopped;
    await ref.read(appConfigProvider.notifier).update((c) {
      c.taskTimeoutSeconds = minutes * 60;
    });
    // 应用后清空草稿，滑条回到（新的）配置值。
    if (mounted) setState(() => _timeoutDraft = null);
    AppLogger.info(
        'settings.taskTimeout: ${minutes}min; needsRestart=$needsRestart');
    if (!needsRestart) return;
    try {
      await ref.read(serverControllerProvider.notifier).stop();
      await ensureServerStarted(ref);
    } catch (_) {}
  }

  Future<void> _pickDirectory(TextEditingController ctrl) async {
    final paths = ref.read(appPathsProvider);
    final initial = ctrl.text.trim();
    String? abs;
    if (initial.isNotEmpty) {
      final r = paths.resolve(initial);
      abs = Directory(r).existsSync() ? r : null;
    }
    final dir = await getDirectoryPath(initialDirectory: abs);
    if (dir != null && mounted) {
      setState(() => ctrl.text = AppConfig.normalizeStored(paths, dir));
    }
  }

  InputDecoration _dirDecoration(
    String hint,
    TextEditingController ctrl,
  ) {
    return InputDecoration(
      border: const OutlineInputBorder(),
      hintText: hint,
      suffixIcon: IconButton(
        tooltip: ref.read(stringsProvider)['settings.pickDir'] ?? 'Choose directory',
        icon: const Icon(Icons.folder_open),
        onPressed: () => _pickDirectory(ctrl),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final paths = ref.watch(appPathsProvider);
    final config = ref.watch(appConfigProvider);
    final dict = ref.watch(stringsProvider);
    final textTheme = Theme.of(context).textTheme;
    final cur = _timeoutMinutes(config.taskTimeoutSeconds);
    // 拖动过程中用本地草稿值做即时反馈；防抖应用后再回到配置值。
    final shown = _timeoutDraft ?? cur;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(dict['settings.title'] ?? 'Settings', style: textTheme.headlineSmall),
          const SizedBox(height: 16),
          Expanded(
            child: ListView(
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(dict['settings.directories'] ?? 'Directories',
                            style: textTheme.titleMedium),
                        const SizedBox(height: 8),
                        Text(dict['settings.audioCppDesc'] ?? '',
                            style: textTheme.bodySmall),
                        TextField(
                          controller: _audioCppCtrl,
                          decoration: _dirDecoration(
                            dict['settings.audioCppHint'] ?? 'audio.cpp or absolute path',
                            _audioCppCtrl,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(dict['settings.modelsLabel'] ?? 'Default model directory',
                            style: textTheme.bodySmall),
                        TextField(
                          controller: _modelsCtrl,
                          decoration: _dirDecoration(
                            dict['settings.modelsHint'] ?? 'models or absolute path',
                            _modelsCtrl,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(dict['settings.dataLabel'] ?? 'Data directory (backup = copy this directory)',
                            style: textTheme.bodySmall),
                        TextField(
                          controller: _dataCtrl,
                          decoration: _dirDecoration(
                            dict['settings.dataHint'] ?? 'data or absolute path',
                            _dataCtrl,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton.icon(
                            onPressed: _save,
                            icon: const Icon(Icons.save_outlined),
                            label: Text(dict['common.save'] ?? 'Save'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Column(
                    children: [
                      SwitchListTile(
                        title: Text(dict['settings.showExperimental'] ?? 'Show experimental entries'),
                        subtitle: Text(
                            dict['settings.showExperimental.subtitle'] ?? ''),
                        value: config.showExperimental,
                        onChanged: (v) => ref
                            .read(appConfigProvider.notifier)
                            .update((c) => c.showExperimental = v),
                      ),
                      SwitchListTile(
                        title: Text(dict['settings.appLog'] ??
                            'Write app logs to file'),
                        subtitle: Text(
                          dictTpl(dict, 'settings.appLog.subtitle',
                              {'dir': paths.logDir.path}),
                        ),
                        value: config.appLogToFile,
                        onChanged: (v) async {
                          await ref
                              .read(appConfigProvider.notifier)
                              .update((c) => c.appLogToFile = v);
                          AppLogger.configure(
                              logDir: paths.logDir, enabled: v);
                          if (v) AppLogger.info('app logging enabled');
                        },
                      ),
                      SwitchListTile(
                        title: Text(dict['settings.serverLog'] ?? 'Write server logs to file'),
                        subtitle: Text(
                          dictTpl(dict, 'settings.serverLog.subtitle',
                              {'dir': paths.logDir.path}),
                        ),
                        value: config.serverLogToFile,
                        onChanged: (v) => ref
                            .read(appConfigProvider.notifier)
                            .update((c) => c.serverLogToFile = v),
                      ),
                      // 与上面的 SwitchListTile 对齐：M3 下 ListTile 的 contentPadding 默认为
                      // EdgeInsetsDirectional.only(start: 16, end: 24)，故右边距用 24（不是 16）。
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 24, 8),
                        child: Row(
                          children: [
                            // 左栏：标题 + 描述（宽度按内容，即"以描述长度为分界"）。
                            IntrinsicWidth(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                      dict['settings.taskTimeout'] ??
                                          'Task timeout',
                                      style: textTheme.titleMedium),
                                  const SizedBox(height: 2),
                                  Text(
                                      dict['settings.taskTimeout.subtitle'] ??
                                          '',
                                      style: textTheme.bodySmall),
                                ],
                              ),
                            ),
                            const SizedBox(width: 16),
                            // 右栏：滑动条（注意：Slider 在 IndexedStack 的 offstage 页会触发
                            // Windows 缩放崩溃，见 doc/slider_crash_investigation.md）。
                            Expanded(
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Slider(
                                      value: shown.toDouble(),
                                      min: _timeoutMin.toDouble(),
                                      max: _timeoutMax.toDouble(),
                                      divisions: _timeoutMax - _timeoutMin,
                                      label: '$shown min',
                                      onChanged: (v) {
                                        final m = v.round();
                                        setState(() => _timeoutDraft = m);
                                        _scheduleTaskTimeout(m);
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    width: _timeoutValueWidth,
                                    child: Text('$shown min',
                                        textAlign: TextAlign.center),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(dict['settings.about'] ?? 'About',
                            style: textTheme.titleMedium),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Image.asset('assets/icon/app_icon.png',
                                width: 48, height: 48),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(AppInfo.name,
                                      style: textTheme.titleMedium),
                                  const SizedBox(height: 2),
                                  Text(
                                    'v${AppInfo.version}',
                                    style: textTheme.bodySmall?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          dict['settings.about.desc'] ??
                              'A desktop client for audio.cpp.',
                          style: textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          dict['settings.about.source'] ??
                              'Model specs and descriptions are derived from the official audio.cpp repository and documentation.',
                          style: textTheme.bodySmall?.copyWith(
                              color:
                                  Theme.of(context).colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${dict['settings.about.homepage'] ?? 'Homepage'}: ',
                              style: textTheme.bodySmall,
                            ),
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  child: GestureDetector(
                                    onTap: () => _openUrl(AppInfo.homepage),
                                    child: Text(
                                      AppInfo.homepage,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: textTheme.bodySmall?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${dict['settings.about.upstream'] ?? 'Upstream'}: ',
                              style: textTheme.bodySmall,
                            ),
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: MouseRegion(
                                  cursor: SystemMouseCursors.click,
                                  child: GestureDetector(
                                    onTap: () => _openUrl(AppInfo.upstream),
                                    child: Text(
                                      AppInfo.upstream,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: textTheme.bodySmall?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () => showLicensePage(
                              context: context,
                              applicationName: AppInfo.name,
                              applicationVersion: 'v${AppInfo.version}',
                            ),
                            icon: const Icon(Icons.description_outlined,
                                size: 18),
                            label: Text(
                                dict['settings.about.license'] ??
                                    'Open-source licenses'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}