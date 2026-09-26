import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_config.dart';
import '../../core/app_info.dart';
import '../../core/gpu_probe.dart';
import '../../models/audio_cpp_version.dart';
import '../../models/model_spec.dart';
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
    final path = _selectedPath;
    if (path == null) return;
    final versions = ref.read(versionsProvider).value ?? [];
    AudioCppVersion? version;
    for (final v in versions) {
      if (v.path == path) {
        version = v;
        break;
      }
    }
    if (version == null) return;

    await _saveConfig(activeVersion: path);
    final cfg = ref.read(appConfigProvider);
    final notifier = ref.read(serverControllerProvider.notifier);
    notifier.updateConfig(cfg);

    final installed = ref
        .read(modelLibraryProvider)
        .entries
        .where((e) => e.installed)
        .toList();
    if (installed.isEmpty) {
      final dict = ref.read(stringsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(dict['server.needModel'] ??
              'Install a model from the model library first'),
        ));
      }
      return;
    }
    final specs = ref.read(specsProvider).value ?? const <ModelSpec>[];
    final specByFamily = {for (final s in specs) s.family: s};
    final modelsDir = cfg.modelsDir(ref.read(appPathsProvider));
    final models = <Map<String, dynamic>>[
      for (final e in installed)
        {
          'id': e.packageId,
          'family': e.family,
          'path': p.join(modelsDir.path, e.targetDirectory),
          'task': (specByFamily[e.family]?.tasks.isNotEmpty ?? false)
              ? specByFamily[e.family]!.tasks.first
              : (e.category.isEmpty ? 'tts' : e.category),
          'mode': 'offline',
        },
    ];

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
    final registeredBackends = ref.watch(availableBackendsProvider).value;
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
            _buildVersionPicker(versions),
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
              onChanged: (v) {
                if (v != null) {
                  setState(() => _backend = v);
                  _saveConfig();
                }
              },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildDeviceField(context),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _threadsCtrl,
                    decoration: _dec(dict['server.threads'] ?? 'Threads'),
                    keyboardType: TextInputType.number,
                    onSubmitted: (_) => _saveConfig(),
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
                    onPressed: busy || capsLoading || _selectedPath == null
                        ? null
                        : _start,
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

  Widget _buildDeviceField(BuildContext context) {
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
    return DropdownButtonFormField<int>(
      initialValue: device,
      isExpanded: true,
      decoration: _dec(dict['server.device'] ?? 'Device'),
      items: items,
      onChanged: (v) {
        if (v == null) return;
        setState(() => _device = v);
        _saveConfig();
      },
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

  Widget _buildVersionPicker(AsyncValue<List<AudioCppVersion>> versions) {
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
                          onPressed: () => ref.invalidate(versionsProvider),
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
        return DropdownButtonFormField<String>(
          initialValue: effective,
          decoration: _dec(dict['server.versionDir'] ?? 'Version directory'),
          isExpanded: true,
          items: [
            for (final v in list)
              DropdownMenuItem(
                value: v.path,
                child: Text(p.basename(v.path), overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (p) {
            if (p != null) {
              setState(() => _selectedPath = p);
              _saveConfig(activeVersion: p);
            }
          },
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