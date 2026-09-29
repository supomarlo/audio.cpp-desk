import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_config.dart';
import '../../core/app_info.dart';
import '../../core/app_logger.dart';
import '../../core/gpu_probe.dart';
import '../../models/audio_cpp_version.dart';
import '../../models/server_snapshot.dart';
import '../../providers/app_providers.dart';
import '../../providers/catalog_providers.dart';
import '../../providers/library_providers.dart';
import '../../providers/server_providers.dart';
import '../common/busy_guard.dart';

class ServerPage extends ConsumerStatefulWidget {
  const ServerPage({super.key});

  @override
  ConsumerState<ServerPage> createState() => _ServerPageState();
}

class _ServerPageState extends ConsumerState<ServerPage> {
  late final TextEditingController _threadsCtrl;
  String? _selectedPath;
  String _backend = 'vulkan';
  int _device = 0;

  @override
  void initState() {
    super.initState();
    final cfg = ref.read(appConfigProvider);
    _threadsCtrl = TextEditingController(text: '${cfg.threads}');
    _backend = cfg.backend;
    _device = cfg.device;
    _selectedPath = cfg.activeVersionPath;
  }

  @override
  void dispose() {
    _threadsCtrl.dispose();
    super.dispose();
  }

  InputDecoration _dec(String label) =>
      InputDecoration(labelText: label, border: const OutlineInputBorder());

  static String _regName(String backend) => GpuProbe.regNameFor(backend);

  Future<void> _saveConfig({String? activeVersion}) async {
    await ref.read(appConfigProvider.notifier).update((c) {
      c.device = _device.clamp(0, 16).toInt();
      c.threads = (int.tryParse(_threadsCtrl.text.trim()) ?? 4).clamp(1, 256).toInt();
      c.backend = _backend;
      if (activeVersion != null) c.activeVersionPath = activeVersion;
    });
  }

  Future<void> _start() async {
    // 统一以 activeVersionProvider 解析版本（匹配 activeVersionPath，否则回退第一个），
    // 避免 loading 空窗 / 路径口径不一致导致「点了没反应」（KI-1）。
    final version = await ref.read(activeVersionProvider.future);
    if (!mounted) return;
    if (version == null) {
      AppLogger.info('[server] start aborted: no audiocpp_server version found');
      final dict = ref.read(stringsProvider);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(dict['server.startNoVersion'] ??
            'No audio.cpp server version found. Check the directory or rescan.'),
      ));
      return;
    }
    // 回写选中路径，保持下拉与配置一致。
    if (_selectedPath != version.path) {
      setState(() => _selectedPath = version.path);
    }

    await _saveConfig(activeVersion: version.path);
    final cfg = ref.read(appConfigProvider);
    final notifier = ref.read(serverControllerProvider.notifier);
    notifier.updateConfig(cfg);

    // 等待模型库首次加载完成，避免重载空窗被误判为"没有已安装模型"；
    // 模型条目构建与工作台自动启动共用 buildServerModels，保证口径一致。
    await ref.read(modelLibraryProvider.notifier).ready;
    if (!mounted) return;
    final models = buildServerModels(ref);
    if (models.isEmpty) {
      AppLogger.info('[server] start aborted: no installed model');
      final dict = ref.read(stringsProvider);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(dict['server.needModel'] ??
            'Install a model from the model library first'),
      ));
      return;
    }

    await notifier.start(version, cfg, models: models);
  }

  Future<void> _stop() async {
    // 停止服务端会打断正在生成的任务：busy 时先拦截提示。
    if (!await confirmWhileBusy(ref, context)) return;
    await ref.read(serverControllerProvider.notifier).stop();
  }

  @override
  Widget build(BuildContext context) {
    final versions = ref.watch(versionsProvider);
    final snapshot = ref.watch(serverControllerProvider);
    final dict = ref.watch(stringsProvider);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(dict['server.title'] ?? 'Server Control',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 5,
                  child: _buildControlPanel(context, versions, snapshot),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 4,
                  child: _buildLogPanel(context, snapshot),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlPanel(
    BuildContext context,
    AsyncValue<List<AudioCppVersion>> versions,
    ServerSnapshot snapshot,
  ) {
    final running = snapshot.isRunning;
    final starting = snapshot.isStarting;
    final busy = running || starting || snapshot.lifecycle == ServerLifecycle.stopping;
    final dict = ref.watch(stringsProvider);
    // 运行中/启动中禁止修改版本、后端、设备、线程等参数（改了对正在跑的实例不生效）。
    final locked = running || starting;
    final lockHint = dict['server.lockHint'] ??
        'The server is running. Stop it first to change this.';
    final registeredBackends = ref.watch(availableBackendsProvider).value;
    // 仅用于显示"探测后端中"指示；不用它禁用 Start（探测可能因显卡状态变慢，不应阻塞启动）。
    final capsLoading = ref.watch(availableBackendsProvider).isLoading;
    final backendOptions = AppConfig.backendOptions
        .where((b) =>
            registeredBackends == null ||
            registeredBackends.isEmpty ||
            registeredBackends.contains(_regName(b)))
        .toList();
    if (backendOptions.isNotEmpty && !backendOptions.contains(_backend)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _backend = backendOptions.first);
        _saveConfig();
      });
    }

    return Card(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
            _buildVersionPicker(versions, locked, lockHint),
            const Divider(height: 28),
            if (capsLoading)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        dict['server.readingBackends'] ??
                            'Reading backend capabilities…',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            _lockable(
              locked,
              lockHint,
              DropdownButtonFormField<String>(
                initialValue: _backend,
                decoration: _dec(dict['server.backend'] ?? 'Backend'),
                items: [
                  for (final b in backendOptions)
                    DropdownMenuItem(
                      value: b,
                      child: Text(b),
                    ),
                ],
                onChanged: locked
                    ? null
                    : (v) {
                        if (v != null) {
                          setState(() => _backend = v);
                          _saveConfig();
                        }
                      },
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildDeviceField(context, locked, lockHint),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _lockable(
                    locked,
                    lockHint,
                    TextField(
                      controller: _threadsCtrl,
                      enabled: !locked,
                      decoration: _dec(dict['server.threads'] ?? 'Threads'),
                      keyboardType: TextInputType.number,
                      onSubmitted: (_) => _saveConfig(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _backend == 'cpu'
                  ? (dict['server.threads.hintCpu'] ??
                      'CPU threads for inference; keep it at or below your '
                          'physical core count (e.g. 6-8 on a 10-core CPU)')
                  : (dict['server.threads.hintGpu'] ??
                      'Inference runs mainly on the GPU; 4-8 is enough, '
                          'leaving CPU for the system and audio'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: busy || _selectedPath == null ? null : _start,
                    icon: const Icon(Icons.play_arrow),
                    label: Text(dict['server.start'] ?? 'Start'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: !(running || starting) ? null : _stop,
                    icon: const Icon(Icons.stop),
                    label: Text(dict['server.stop'] ?? 'Stop'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildStatusCard(context, snapshot),
            ],
          ),
        ),
      ),
    );
  }

  /// 运行中/启动中时给参数控件套一层 Tooltip 提示（控件本身应已禁用）。
  Widget _lockable(bool locked, String hint, Widget child) =>
      locked ? Tooltip(message: hint, child: child) : child;

  Widget _buildDeviceField(BuildContext context, bool locked, String lockHint) {
    final dict = ref.watch(stringsProvider);
    if (_backend == 'cpu') {
      return TextFormField(
        key: const ValueKey('device-cpu'),
        initialValue: dict['server.device.cpu'] ?? 'CPU',
        enabled: false,
        decoration: _dec(dict['server.device'] ?? 'Device'),
      );
    }
    final gpuNames =
        ref.watch(gpuNamesProvider(_backend)).value ?? const <String>[];
    if (gpuNames.isEmpty) {
      return TextFormField(
        key: const ValueKey('device-gpu-unavailable'),
        initialValue: 'GPU 0',
        enabled: false,
        decoration: _dec(dict['server.device'] ?? 'Device'),
      );
    }
    final maxIndex = gpuNames.length - 1;
    final device = _device.clamp(0, maxIndex).toInt();
    if (device != _device) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _device = device);
      });
    }
    final items = <DropdownMenuItem<int>>[
      for (var i = 0; i <= maxIndex; i++)
        DropdownMenuItem(
          value: i,
          child: Text(
            dictTpl(dict, 'server.device.gpuItem',
                {'index': '$i', 'name': gpuNames[i]}),
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ];
    return _lockable(
      locked,
      lockHint,
      DropdownButtonFormField<int>(
        initialValue: device,
        isExpanded: true,
        decoration: _dec(dict['server.device'] ?? 'Device'),
        items: items,
        onChanged: locked
            ? null
            : (v) {
                if (v == null) return;
                setState(() => _device = v);
                _saveConfig();
              },
      ),
    );
  }

  Future<void> _openVersionsDir() async {
    final cfg = ref.read(appConfigProvider);
    final resolved =
        AppConfig.normalizeAgainst(ref.read(appPathsProvider), cfg.audioCppDir);
    try {
      await Directory(resolved).create(recursive: true);
    } catch (_) {}
    try {
      await Process.start('explorer', [resolved]);
    } catch (_) {}
  }

  Future<void> _openUpstream() async {
    final uri = Uri.tryParse(AppInfo.upstream);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Widget _buildVersionPicker(
      AsyncValue<List<AudioCppVersion>> versions, bool locked, String lockHint) {
    final dict = ref.watch(stringsProvider);
    return versions.when(
      loading: () => const LinearProgressIndicator(),
      error: (e, _) => Text(trF(ref, 'server.scanFailed', {'error': '$e'})),
      data: (list) {
        if (list.isEmpty) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(dict['server.exeNotFound'] ??
                        'audiocpp_server.exe not found'),
                    Text(
                      trF(ref, 'server.exeNotFoundHint',
                          {'dir': ref.read(appConfigProvider).audioCppDir}),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Row(
                      children: [
                        TextButton.icon(
                          onPressed: _openVersionsDir,
                          icon: const Icon(Icons.folder_open_outlined),
                          label: Text(
                              dict['server.openDir'] ?? 'Open directory'),
                        ),
                        TextButton.icon(
                          onPressed: () => rescanVersions(ref),
                          icon: const Icon(Icons.refresh),
                          label: Text(dict['server.rescan'] ?? 'Rescan'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              TextButton.icon(
                onPressed: _openUpstream,
                icon: const Icon(Icons.download_outlined),
                label: Text(dict['server.getServer'] ?? 'Get server'),
              ),
            ],
          );
        }
        final effective = list.any((v) => v.path == _selectedPath)
            ? _selectedPath
            : list.first.path;
        return _lockable(
          locked,
          lockHint,
          DropdownButtonFormField<String>(
            initialValue: effective,
            decoration: _dec(dict['server.versionDir'] ?? 'Version directory'),
            isExpanded: true,
            items: [
              for (final v in list)
                DropdownMenuItem(
                  value: v.path,
                  child:
                      Text(p.basename(v.path), overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: locked
                ? null
                : (p) {
                    if (p != null) {
                      setState(() => _selectedPath = p);
                      _saveConfig(activeVersion: p);
                    }
                  },
          ),
        );
      },
    );
  }

  Widget _buildStatusCard(BuildContext context, ServerSnapshot s) {
    final scheme = Theme.of(context).colorScheme;
    final dict = ref.watch(stringsProvider);
    final (label, color) = switch (s.lifecycle) {
      ServerLifecycle.running => (dict['server.status.running'] ?? 'Running', Colors.green),
      ServerLifecycle.starting => (dict['server.status.starting'] ?? 'Starting', Colors.orange),
      ServerLifecycle.stopping => (dict['server.status.stopping'] ?? 'Stopping', Colors.orange),
      ServerLifecycle.error => (dict['server.status.error'] ?? 'Error', scheme.error),
      ServerLifecycle.stopped => (dict['server.status.stopped'] ?? 'Stopped', Colors.grey),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.circle, size: 12, color: color),
            const SizedBox(width: 8),
            Text(label,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            if (s.startedAt != null) ...[
              const SizedBox(width: 8),
              Text(_fmtTime(s.startedAt!),
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
        if (s.exeName != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
                trF(ref, 'server.version',
                    {'name': p.basename(s.exeName!)}),
                style: Theme.of(context).textTheme.bodySmall),
          ),
        if (s.isRunning)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              trF(ref, 'server.backendInfo',
                  {'backend': s.backend ?? '-', 'count': '${s.loadedModelsCount}'}),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        if (s.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(s.error!,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.error)),
          ),
      ],
    );
  }

  Widget _buildLogPanel(BuildContext context, ServerSnapshot s) {
    final dict = ref.watch(stringsProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(dict['server.logTitle'] ?? 'Server log',
                    style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                TextButton(
                  onPressed: () =>
                      ref.read(serverControllerProvider.notifier).clearLog(),
                  child: Text(dict['server.logClear'] ?? 'Clear'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: s.logLines.isEmpty
                    ? Text(dict['server.logEmpty'] ?? 'No logs',
                        style: const TextStyle(color: Colors.white54, fontSize: 12))
                    : ListView.builder(
                        reverse: true,
                        itemCount: s.logLines.length,
                        itemBuilder: (context, i) {
                          final line = s.logLines[s.logLines.length - 1 - i];
                          return Text(
                            line,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontFamily: 'monospace',
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _fmtTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}