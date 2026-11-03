import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/onboarding.dart';
import '../core/server_version.dart';
import '../models/server_snapshot.dart';
import '../providers/app_providers.dart';
import '../providers/catalog_providers.dart';
import '../providers/library_providers.dart';
import '../providers/server_providers.dart';
import 'history/history_page.dart';
import 'models_view/models_page.dart';
import 'server/server_page.dart';
import 'settings/language_switch.dart';
import 'settings/settings_page.dart';
import 'voices/voices_page.dart';
import 'workbench/workbench_page.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  String? _versionNoticeKey;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _versionSnackBar;

  void _dismissVersionSnackBar() {
    _versionSnackBar?.close();
    _versionSnackBar = null;
  }

  @override
  void initState() {
    super.initState();
    // 启动后按当前配置主动启动服务端（lazy_load：首次生成才加载模型）。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // 等模型库就绪后再启动服务端（否则会因未读到已安装模型而跳过）。
      await ref.read(modelLibraryProvider.notifier).ready;
      ensureServerStarted(ref).catchError((_) {});
      // 首次运行引导：未引导过且未找到服务端版本时，跳“服务”页一次。
      final paths = ref.read(appPathsProvider);
      if (Onboarding.isDone(paths)) return;
      try {
        final versions = await ref.read(versionsProvider.future);
        if (versions.isEmpty && mounted) {
          ref.read(homeTabProvider.notifier).state = 4;
        }
      } catch (_) {}
      Onboarding.markDone(paths);
    });
  }

  static const _pages = [
    WorkbenchPage(),
    HistoryPage(),
    VoicesPage(),
    ModelsPage(),
    ServerPage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    final dict = ref.watch(stringsProvider);
    final index = ref.watch(homeTabProvider);
    ref.listen<ServerSnapshot>(serverControllerProvider, (_, next) {
      if (!(next.isRunning && next.healthy)) {
        _versionNoticeKey = null;
        _dismissVersionSnackBar();
        return;
      }
      final status = serverVersionStatus(next.version);
      if (status == ServerVersionStatus.supported) {
        _versionNoticeKey = null;
        _dismissVersionSnackBar();
        return;
      }
      final key = '${status.name}:${next.version}';
      if (_versionNoticeKey == key) return;
      _versionNoticeKey = key;
      final message = switch (status) {
        ServerVersionStatus.tooOld => (dict['server.version.tooOld'] ??
                'The audio.cpp server is below the minimum {min}. Upgrade the server.')
            .replaceAll('{min}', kMinimumAudioCppVersion),
        _ => dict['server.version.unknown'] ??
            'The audio.cpp server version could not be identified; compatibility was not checked.',
      };
      final tooOld = status == ServerVersionStatus.tooOld;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        final controller = messenger.showSnackBar(
          SnackBar(
            content: Text(message),
            duration:
                tooOld ? const Duration(hours: 24) : const Duration(seconds: 6),
            showCloseIcon: tooOld,
          ),
        );
        _versionSnackBar = controller;
        controller.closed.then((_) {
          if (identical(_versionSnackBar, controller)) {
            _versionSnackBar = null;
          }
        });
      });
    });
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: index,
            onDestinationSelected: (i) =>
                ref.read(homeTabProvider.notifier).state = i,
            labelType: NavigationRailLabelType.all,
            destinations: [
              NavigationRailDestination(
                icon: const Icon(Icons.build_outlined),
                selectedIcon: const Icon(Icons.build),
                label: Text(dict['nav.workbench'] ?? 'Workbench'),
              ),
              NavigationRailDestination(
                icon: const Icon(Icons.history_outlined),
                selectedIcon: const Icon(Icons.history),
                label: Text(dict['nav.history'] ?? 'History'),
              ),
              NavigationRailDestination(
                icon: const Icon(Icons.record_voice_over_outlined),
                selectedIcon: const Icon(Icons.record_voice_over),
                label: Text(dict['nav.voices'] ?? 'Voices'),
              ),
              NavigationRailDestination(
                icon: const Icon(Icons.memory_outlined),
                selectedIcon: const Icon(Icons.memory),
                label: Text(dict['nav.models'] ?? 'Models'),
              ),
              NavigationRailDestination(
                icon: const Icon(Icons.play_circle_outline),
                selectedIcon: const Icon(Icons.play_circle),
                label: Text(dict['nav.server'] ?? 'Server'),
              ),
              NavigationRailDestination(
                icon: const Icon(Icons.settings_outlined),
                selectedIcon: const Icon(Icons.settings),
                label: Text(dict['nav.settings'] ?? 'Settings'),
              ),
            ],
            trailing: const Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: LanguageSwitch(),
              ),
            ),
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(child: IndexedStack(index: index, children: _pages)),
        ],
      ),
    );
  }
}
