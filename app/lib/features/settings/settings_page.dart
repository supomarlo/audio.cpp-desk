import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_config.dart';
import '../../core/app_info.dart';
import '../../core/app_logger.dart';
import '../../providers/app_providers.dart';
import '../../providers/catalog_providers.dart';
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
    ref.invalidate(versionsProvider);
    // 目录可能已改变：重建模型库，按新目录重新扫描并重建"已安装"列表。
    ref.invalidate(modelLibraryProvider);
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