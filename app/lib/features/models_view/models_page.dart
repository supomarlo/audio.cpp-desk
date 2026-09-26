import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/download_manager.dart';
import '../../core/format.dart';
import '../../core/model_downloader.dart';
import '../../models/model_catalog_entry.dart';
import '../../models/model_spec.dart';
import '../../localization/strings.dart';
import '../../providers/app_providers.dart';
import '../../providers/catalog_providers.dart';
import '../../providers/download_providers.dart';
import '../../providers/library_providers.dart';

class ModelsPage extends ConsumerStatefulWidget {
  const ModelsPage({super.key});

  @override
  ConsumerState<ModelsPage> createState() => _ModelsPageState();
}

class _ModelsPageState extends ConsumerState<ModelsPage> {
  final GlobalKey _tabBarKey = GlobalKey();
  String _query = '';
  bool _refreshing = false;

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await ref.read(modelLibraryProvider.notifier).reloadSpecs();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  void _jumpToDownloads() {
    final ctx = _tabBarKey.currentContext;
    if (ctx == null) return;
    DefaultTabController.of(ctx).animateTo(1);
  }

  @override
  Widget build(BuildContext context) {
    final lib = ref.watch(modelLibraryProvider);
    final showExp = ref.watch(appConfigProvider).showExperimental;
    final dict = ref.watch(stringsProvider);

    final q = _query.trim().toLowerCase();
    final entries = lib.entries.where((e) {
      if (!showExp && e.isExperimental) return false;
      if (q.isEmpty) return true;
      final hay = '${e.displayName} ${e.packageId} ${e.family}'.toLowerCase();
      final words = q.split(RegExp(r'\s+'));
      return words.every(hay.contains);
    }).toList();

    final groups = _groupModels(entries);
    final installedGroups =
        groups.where((g) => g.packages.any((p) => p.installed)).toList();
    final notInstalledGroups =
        groups.where((g) => g.packages.every((p) => !p.installed)).toList();
    final activeDownloads = ref.watch(downloadManagerProvider).activeCount;

    return DefaultTabController(
      length: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TabBar(
              key: _tabBarKey,
              indicatorSize: TabBarIndicatorSize.label,
              labelStyle:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              unselectedLabelStyle: const TextStyle(fontSize: 18),
              tabs: [
                Tab(text: dict['models.tab.catalog'] ?? 'Model Library'),
                Tab(
                  child: _DownloadTabLabel(count: activeDownloads),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: TabBarView(
                children: [
                  _buildCatalogTab(
                      context, groups, installedGroups, notInstalledGroups, q),
                  _buildDownloadTab(context),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCatalogTab(
      BuildContext context,
      List<_ModelGroup> groups,
      List<_ModelGroup> installedGroups,
      List<_ModelGroup> notInstalledGroups,
      String q) {
    final dict = ref.watch(stringsProvider);
    final versionsAsync = ref.watch(versionsProvider);
    final noServer = !versionsAsync.isLoading &&
        (versionsAsync.value ?? const []).isEmpty;
    final noSpecs = !noServer &&
        q.isEmpty &&
        ref.watch(hasVersionSpecsProvider).value == false;
    final versionPath = ref.watch(activeVersionProvider).value?.path ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  hintText: ref.watch(stringsProvider)['models.searchHint'] ??
                      'Search model name / package / family...',
                  prefixIcon: const Icon(Icons.search),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: dict['models.refresh'] ??
                  'Refresh (rescan local weights directory)',
              onPressed: _refreshing ? null : _refresh,
              icon: _refreshing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: groups.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.search_off,
                          size: 48, color: Colors.grey),
                      const SizedBox(height: 12),
                      Text(
                        q.isEmpty
                            ? (noServer
                                ? (dict['models.noServer.title'] ??
                                    'audio.cpp server not found')
                                : (noSpecs
                                    ? (dict['models.noSpecs.title'] ??
                                        'The current audio.cpp version provides no model specs')
                                    : (dict['models.empty'] ?? 'No models loaded')))
                            : trF(ref, 'models.emptyFiltered',
                                {'query': _query}),
                        textAlign: TextAlign.center,
                      ),
                      if (noServer) ...[
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Text(
                            dict['models.noServer.hint'] ??
                                'No audiocpp_server.exe was found. Configure the audio.cpp version on the Server page first.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.tonal(
                          onPressed: () =>
                              ref.read(homeTabProvider.notifier).state = 4,
                          child: Text(
                              dict['models.noServer.action'] ?? 'Go to Server'),
                        ),
                      ] else if (noSpecs) ...[
                        const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Text(
                            trF(ref, 'models.noSpecs.hint', {'path': versionPath}),
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                        ),
                      ],
                    ],
                  ),
                )
              : _buildCatalogList(context, groups, installedGroups,
                  notInstalledGroups, q.isNotEmpty),
        ),
      ],
    );
  }

  Widget _buildCatalogList(
      BuildContext context,
      List<_ModelGroup> groups,
      List<_ModelGroup> installedGroups,
      List<_ModelGroup> notInstalledGroups,
      bool hasQuery) {
    return ListView(
      children: [
        if (installedGroups.isNotEmpty) ...[
          _SectionHeader(
              title: trF(ref, 'models.section.installed',
                  {'count': '${installedGroups.length}'})),
          for (final g in installedGroups)
            _ModelCard(
              key: ValueKey(g.name),
              group: g,
              onTap: () => _showDetail(context, g),
              onDownload: () => _showDownload(context, g),
              onManage: () => _manageModel(context, g),
            ),
          const SizedBox(height: 8),
        ],
        if (notInstalledGroups.isNotEmpty) ...[
          _SectionHeader(
              title: trF(ref, 'models.section.notInstalled',
                  {'count': '${notInstalledGroups.length}'})),
          ..._buildGroups(context, notInstalledGroups, hasQuery),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _buildDownloadTab(BuildContext context) {
    final dict = ref.watch(stringsProvider);
    final manager = ref.watch(downloadManagerProvider);
    final tasks = manager.tasks.values.toList();
    if (tasks.isEmpty) {
      return Center(child: Text(dict['models.download.empty'] ?? 'No download tasks'));
    }
    final processing = tasks.where((t) => t.processing).toList();
    final finished = tasks.where((t) => !t.processing).toList();
    return ListView(
      children: [
        if (processing.isNotEmpty) ...[
          _SectionHeader(
              title: trF(ref, 'models.download.processing',
                  {'count': '${processing.length}'})),
          for (final t in processing)
            _DownloadTaskCard(task: t, manager: manager),
          const SizedBox(height: 8),
        ],
        if (finished.isNotEmpty) ...[
          _SectionHeader(
              title: trF(ref, 'models.download.finished',
                  {'count': '${finished.length}'})),
          for (final t in finished)
            _DownloadTaskCard(task: t, manager: manager),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  List<Widget> _buildGroups(
      BuildContext context, List<_ModelGroup> groups, bool hasQuery) {
    final byCategory = <String, List<_ModelGroup>>{};
    for (final g in groups) {
      final cat = g.packages.first.category;
      byCategory.putIfAbsent(cat, () => []).add(g);
    }
    const order = ['tts', 'asr', 'clone', 'separation', 'singing', 'music'];
    final list = byCategory.entries.toList();
    list.sort((a, b) {
      final ia = order.indexOf(a.key);
      final ib = order.indexOf(b.key);
      return (ia < 0 ? 99 : ia).compareTo(ib < 0 ? 99 : ib);
    });
    return [
      for (var i = 0; i < list.length; i++)
        _CategorySection(
          title: categoryLabel(list[i].key, ref.watch(stringsProvider)),
          count: list[i].value.length,
          groups: list[i].value,
          onDetail: (g) => _showDetail(context, g),
          onDownload: (g) => _showDownload(context, g),
          onManage: (g) => _manageModel(context, g),
          forceExpanded: hasQuery && list[i].value.isNotEmpty,
        ),
    ];
  }

  static List<_ModelGroup> _groupModels(List<ModelCatalogEntry> entries) {
    final map = <String, _ModelGroup>{};
    for (final e in entries) {
      final base = _stripSpec(e.packageId);
      final key = '${e.family}|$base';
      final g = map.putIfAbsent(
        key,
        () => _ModelGroup(name: _stripSpecName(e.displayName)),
      );
      g.packages.add(e);
    }
    for (final g in map.values) {
      g.packages.sort(
        (a, b) {
          final r = (a.isDefault ? 0 : 1).compareTo(b.isDefault ? 0 : 1);
          if (r != 0) return r;
          final ra = _precisionRank(a.packageId);
          final rb = _precisionRank(b.packageId);
          if (ra != rb) return ra.compareTo(rb);
          return a.packageId.compareTo(b.packageId);
        },
      );
    }
    final list = map.values.toList();
    list.sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  static int _precisionRank(String packageId) {
    final m = _specSuffixRe.firstMatch(packageId);
    final suffix = m?.group(1) ?? '';
    switch (suffix) {
      case 'q8_0':
        return 0;
      case 'safetensors':
        return 3; // Safetensors 高于所有 GGUF 精度
      case 'orig':
        return 4; // 原始权重包放最后
      case 'bf16':
        return 1;
      case 'f16':
        return 2;
      default:
        return 99;
    }
  }

  static String _stripSpec(String id) {
    final m = _specSuffixRe.firstMatch(id);
    return m != null ? id.substring(0, m.start) : id;
  }

  static final RegExp _specSuffixRe =
      RegExp(r'_(q8_0|bf16|f16|safetensors|orig)$');

  static String _stripSpecName(String name) => name.replaceAll(
      RegExp(
          r'\s+(Q8_0|BF16|F16|Original-Dtype|Original|Safetensors)(\s+GGUF)?$'),
      '');

  void _showDetail(BuildContext context, _ModelGroup g) {
    var descExpanded = false;
    final desc = ref.read(localeProvider) == AppLocale.zh &&
            g.familyDescriptionZh.isNotEmpty
        ? g.familyDescriptionZh
        : g.familyDescription;
    final isZh = ref.read(localeProvider) == AppLocale.zh;
    final variantDescs = <String>[];
    for (final p in g.packages) {
      final d = isZh && p.packageDescriptionZh.isNotEmpty
          ? p.packageDescriptionZh
          : p.packageDescription;
      if (d.isNotEmpty && !variantDescs.contains(d)) variantDescs.add(d);
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => Consumer(
        builder: (ctx, ref, _) {
          final dict = ref.watch(stringsProvider);
          return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: Text(g.name),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (desc.isNotEmpty) ...[
                      InkWell(
                        canRequestFocus: false,
                        onTap: () =>
                            setDialogState(() => descExpanded = !descExpanded),
                        child: Text(
                          desc,
                          maxLines: descExpanded ? null : 3,
                          overflow: descExpanded ? null : TextOverflow.ellipsis,
                          style: Theme.of(ctx).textTheme.bodyMedium,
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    for (final p in g.packages) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                 Expanded(
                                   flex: 2,
                                   child: Column(
                                     crossAxisAlignment:
                                         CrossAxisAlignment.start,
                                     children: [
                                       Text(
                                         p.packageId,
                                         maxLines: 1,
                                         overflow: TextOverflow.ellipsis,
                                         style: Theme.of(ctx)
                                             .textTheme
                                             .bodyMedium,
                                       ),
                                       const SizedBox(height: 2),
                                       Text(
                                         [
                                           if (p.sizeBytes != null)
                                             formatBytes(p.sizeBytes),
                                           if (p.estMemoryBytes != null)
                                             trF(ref, 'models.memory', {
                                               'size': formatBytes(
                                                   p.estMemoryBytes)
                                             }),
                                           if (p.estVramBytes != null)
                                             trF(ref, 'models.vram', {
                                               'size': formatBytes(
                                                   p.estVramBytes)
                                             }),
                                         ].join('  ·  '),
                                         maxLines: 1,
                                         overflow: TextOverflow.ellipsis,
                                         style: Theme.of(ctx)
                                             .textTheme
                                             .bodySmall
                                             ?.copyWith(
                                               color: Theme.of(ctx)
                                                   .colorScheme
                                                   .onSurfaceVariant,
                                             ),
                                       ),
                                       if (p.localRevision.isNotEmpty ||
                                           p.remoteRevision.isNotEmpty) ...[
                                         const SizedBox(height: 2),
                                         Text(
                                           [
                                             if (p.localRevision.isNotEmpty)
                                               trF(
                                                   ref,
                                                   'models.revision.local',
                                                   {'rev': p.localRevision}),
                                             if (p.remoteRevision.isNotEmpty)
                                               trF(
                                                   ref,
                                                   'models.revision.remote',
                                                   {'rev': p.remoteRevision}),
                                           ].join(' · '),
                                           style: Theme.of(ctx)
                                               .textTheme
                                               .bodySmall,
                                         ),
                                       ],
                                     ],
                                   ),
                                 ),
                                 Expanded(
                                   flex: 2,
                                   child: Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      if (p.isDefault) ...[
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 10, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: Colors.amber
                                                .withValues(alpha: 0.15),
                                            borderRadius:
                                                BorderRadius.circular(5),
                                          ),
                                          child: Text(
                                            dict['models.badge.recommended'] ?? 'Recommended',
                                            style: const TextStyle(
                                                fontSize: 13,
                                                color: Colors.amber),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                      ],
                                      if (p.installed) ...[
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 10, vertical: 3),
                                          decoration: BoxDecoration(
                                            color: Colors.green
                                                .withValues(alpha: 0.12),
                                            borderRadius:
                                                BorderRadius.circular(5),
                                          ),
                                          child: Text(
                                            dict['models.badge.installed'] ?? 'Installed',
                                            style: const TextStyle(
                                                fontSize: 13,
                                                color: Colors.green),
                                          ),
                                        ),
                                        if (p.activeVersion) ...[
                                          const SizedBox(width: 6),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 10, vertical: 3),
                                            decoration: BoxDecoration(
                                              color: Colors.blue
                                                  .withValues(alpha: 0.12),
                                              borderRadius:
                                                  BorderRadius.circular(5),
                                            ),
                                            child: Text(
                                              dict['models.badge.current'] ?? 'Current',
                                              style: const TextStyle(
                                                  fontSize: 13,
                                                  color: Colors.blue),
                                            ),
                                          ),
                                        ],
                                      ] else if (p.hasSource) ...[
                                        SizedBox(
                                          height: 30,
                                          child: (ref
                                                      .watch(
                                                          downloadManagerProvider)
                                                      .taskOf(p.packageId)
                                                      ?.active ??
                                                  false)
                                              ? FilledButton.tonalIcon(
                                                  onPressed: () {
                                                    Navigator.pop(ctx);
                                                    _jumpToDownloads();
                                                  },
                                                  icon: const Icon(
                                                      Icons.downloading,
                                                      size: 16),
                                                  label: Text(dict['models.downloading'] ?? 'Downloading'),
                                                  style: FilledButton.styleFrom(
                                                    visualDensity:
                                                        VisualDensity.compact,
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                        horizontal: 12),
                                                  ),
                                                )
                                              : FilledButton.tonalIcon(
                                                  onPressed: () async {
                                                    final started =
                                                        await _showDownload(ctx,
                                                            g, p.packageId);
                                                    if (started &&
                                                        ctx.mounted) {
                                                      Navigator.pop(ctx);
                                                    }
                                                  },
                                                  icon: const Icon(
                                                      Icons.download,
                                                      size: 16),
                                                  label: Text(dict['common.download'] ?? 'Download'),
                                                  style: FilledButton.styleFrom(
                                                    visualDensity:
                                                        VisualDensity.compact,
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                        horizontal: 12),
                                                  ),
                                                ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                    ],
                    if (variantDescs.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      for (final d in variantDescs)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            d,
                            style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(ctx)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(dict['common.close'] ?? 'Close'),
              ),
            ],
          ),
          );
        },
      ),
    );
  }

  Future<bool> _showDownload(BuildContext context, _ModelGroup g,
      [String? preselectId]) async {
    final candidates =
        g.packages.where((p) => !p.installed && p.hasSource).toList();
    if (candidates.isEmpty) return false;
    final installed = await showDialog<bool>(
      context: context,
      builder: (_) => _DownloadDialog(group: g, preselectId: preselectId),
    );
    if (installed == true) {
      _refresh();
      return true;
    }
    return false;
  }

  void _manageModel(BuildContext context, _ModelGroup g) {
    showDialog<void>(
      context: context,
      builder: (_) => _ManageModelDialog(
        group: g,
        onDownloadPackage: (id) => _startDownloadForPackage(g, id),
        onUninstallPackage: _uninstallPackage,
        onSwitchVersion: (id) =>
            ref.read(modelLibraryProvider.notifier).setActiveVersion(id),
        onOpenDownloads: _jumpToDownloads,
      ),
    );
  }

  Future<void> _startDownloadForPackage(_ModelGroup g, String packageId) async {
    await _showDownload(context, g, packageId);
  }

  Future<void> _uninstallPackage(String packageId) async {
    final manager = ref.read(downloadManagerProvider);
    final task = manager.taskOf(packageId);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
      final dict = ref.read(stringsProvider);
      return AlertDialog(
        title: Text(dict['models.uninstall.title'] ?? 'Uninstall model'),
        content: Text(trF(ref, 'models.uninstall.confirm', {'id': packageId})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(dict['common.cancel'] ?? 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(dict['common.uninstall'] ?? 'Uninstall'),
          ),
        ],
      );
    },
    );
    if (confirmed != true || !context.mounted) return;
    if (task != null) {
      task.cancelToken.cancel();
      manager.remove(packageId);
    }
    await ref.read(modelLibraryProvider.notifier).uninstall(packageId);
  }
}

class _ModelGroup {
  _ModelGroup({required this.name});

  final String name;
  final List<ModelCatalogEntry> packages = [];

  ModelCatalogEntry get first => packages.first;
  String get familyDescription => first.description;
  String get familyDescriptionZh => first.descriptionZh;
  String get description => first.packageDescription.isNotEmpty
      ? first.packageDescription
      : first.description;
  String get descriptionZh => first.packageDescriptionZh.isNotEmpty
      ? first.packageDescriptionZh
      : first.descriptionZh;
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}

class _CategorySection extends StatefulWidget {
  const _CategorySection({
    required this.title,
    required this.count,
    required this.groups,
    required this.onDetail,
    required this.onDownload,
    required this.onManage,
    required this.forceExpanded,
  });

  final String title;
  final int count;
  final List<_ModelGroup> groups;
  final void Function(_ModelGroup) onDetail;
  final void Function(_ModelGroup) onDownload;
  final void Function(_ModelGroup) onManage;
  final bool forceExpanded;

  @override
  State<_CategorySection> createState() => _CategorySectionState();
}

class _CategorySectionState extends State<_CategorySection> {
  late bool _expanded = widget.forceExpanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.forceExpanded;
  }

  @override
  void didUpdateWidget(covariant _CategorySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.forceExpanded && widget.forceExpanded && !_expanded) {
      setState(() => _expanded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text('${widget.title} (${widget.count})',
                    style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
          ),
        ),
        if (_expanded)
          for (final g in widget.groups)
            _ModelCard(
                key: ValueKey(g.name),
                group: g,
                onTap: () => widget.onDetail(g),
                onDownload: () => widget.onDownload(g),
                onManage: () => widget.onManage(g)),
      ],
    );
  }
}

class _ModelCard extends ConsumerWidget {
  const _ModelCard(
      {super.key,
      required this.group,
      required this.onTap,
      this.onDownload,
      this.onManage});

  final _ModelGroup group;
  final VoidCallback onTap;
  final VoidCallback? onDownload;
  final VoidCallback? onManage;

  String _subtitle(Map<String, String> dict) {
    ModelCatalogEntry? active;
    for (final p in group.packages) {
      if (p.installed && p.activeVersion) {
        active = p;
        break;
      }
    }
    final featured = active ?? group.packages.first;
    final parts = <String>[
      '${dictTpl(dict, 'models.specCount', {'count': '${group.packages.length}'})} · ${featured.packageId}'
    ];
    if (active != null) parts.add(dict['models.currentVersion'] ?? 'Current version');
    final p = featured;
    if (p.sizeBytes != null) parts.add(formatBytes(p.sizeBytes));
    if (p.estMemoryBytes != null) {
      parts.add(dictTpl(dict, 'models.memory', {'size': formatBytes(p.estMemoryBytes)}));
    }
    if (p.estVramBytes != null) {
      parts.add(dictTpl(dict, 'models.vram', {'size': formatBytes(p.estVramBytes)}));
    }
    return parts.join('  ');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = group;
    final dict = ref.watch(stringsProvider);
    final theme = Theme.of(context);
    final installed = g.packages.where((p) => p.installed).length;
    final anyInstalled = installed > 0;
    final hasDownloadable = g.packages.any((p) => !p.installed && p.hasSource);
    final isDownloading = g.packages.any((p) =>
        ref.watch(downloadManagerProvider).taskOf(p.packageId)?.active ??
        false);
    final stateColor = anyInstalled ? Colors.blue : Colors.grey;
    final desc = ref.watch(localeProvider) == AppLocale.zh &&
            g.descriptionZh.isNotEmpty
        ? g.descriptionZh
        : g.description;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Icon(Icons.dataset_outlined, size: 20),
              const SizedBox(width: 12),
              SizedBox(
                width: 240,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            g.name,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        if (g.first.isExperimental) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.orange.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(dict['models.experimental'] ?? 'Experimental',
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.orange)),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _subtitle(dict),
                      style: theme.textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: desc.isEmpty
                    ? const SizedBox.shrink()
                    : Text(
                        desc,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.left,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
              ),
              const SizedBox(width: 16),
              if (isDownloading)
                SizedBox(
                  height: 30,
                  child: FilledButton.tonalIcon(
                    onPressed: () =>
                        DefaultTabController.of(context).animateTo(1),
                    icon: const Icon(Icons.downloading, size: 16),
                    label: Text(dict['models.downloading'] ?? 'Downloading'),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                  ),
                )
              else if (anyInstalled && onManage != null)
                SizedBox(
                  height: 30,
                  child: FilledButton.tonalIcon(
                    onPressed: onManage,
                    icon: const Icon(Icons.tune, size: 16),
                    label: Text(dict['common.manage'] ?? 'Manage'),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                  ),
                )
              else if (!anyInstalled && onDownload != null && hasDownloadable)
                SizedBox(
                  height: 30,
                  child: FilledButton.tonalIcon(
                    onPressed: onDownload,
                    icon: const Icon(Icons.download, size: 16),
                    label: Text(dict['common.download'] ?? 'Download'),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                  ),
                )
              else
                Chip(
                  label: Text(categoryLabel(g.first.category, dict)),
                  labelStyle: TextStyle(
                    color: anyInstalled ? Colors.blue : stateColor,
                    fontSize: 12,
                  ),
                  backgroundColor: stateColor.withValues(alpha: 0.12),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String categoryLabel(String cat, Map<String, String> dict) {
    final key = switch (cat) {
      'tts' => 'models.cat.tts',
      'asr' => 'models.cat.asr',
      'clone' => 'models.cat.clone',
      'voice_conversion' => 'models.cat.vc',
      'separation' => 'models.cat.separation',
      'singing' => 'models.cat.singing',
      'music' => 'models.cat.music',
      'audio_generation' => 'models.cat.audioGeneration',
      'audio_tools' => 'models.cat.audioTools',
      'speech_analysis' => 'models.cat.speechAnalysis',
      'community' => 'models.cat.community',
      _ => cat.isEmpty ? 'models.cat.general' : cat,
    };
    return dict[key] ?? key;
  }

class _DownloadTabLabel extends ConsumerWidget {
  const _DownloadTabLabel({required this.count});

  final int count;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = DefaultTabController.of(context).index == 1;
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          ref.watch(stringsProvider)['models.tab.downloads'] ?? 'Downloads',
          style: TextStyle(
            fontSize: 18,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? scheme.primary : null,
          ),
        ),
        if (count > 0) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: scheme.error,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$count',
              style: const TextStyle(
                fontSize: 11,
                color: Colors.white,
                fontWeight: FontWeight.w600,
                height: 1.0,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

String _formatSpeed(int receivedBytes, double speedBytesPerSec) {
  if (speedBytesPerSec <= 0 || receivedBytes <= 0) return '--';
  double v = speedBytesPerSec;
  const units = ['B/s', 'KB/s', 'MB/s', 'GB/s'];
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  final digits = v >= 100 ? 0 : (v >= 10 ? 1 : 2);
  return '${v.toStringAsFixed(digits)} ${units[i]}';
}

/// 预估剩余下载时长（>1h 用 H:MM:SS，否则 MM:SS）；速度/总量未知或已完成返回 null。
String? _formatEta(int receivedBytes, int totalBytes, double speedBytesPerSec) {
  if (speedBytesPerSec <= 0 || totalBytes <= 0) return null;
  final remaining = totalBytes - receivedBytes;
  if (remaining <= 0) return null;
  final secs = (remaining / speedBytesPerSec).ceil();
  final h = secs ~/ 3600;
  final m = (secs % 3600) ~/ 60;
  final s = secs % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

class _DownloadDialog extends ConsumerStatefulWidget {
  const _DownloadDialog({
    required this.group,
    this.preselectId,
  });

  final _ModelGroup group;
  final String? preselectId;

  @override
  ConsumerState<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends ConsumerState<_DownloadDialog> {
  final List<_DownloadOption> _options = [];
  _DownloadOption? _selected;
  ModelSource? _source;
  String _token = '';

  bool get _isEnglishLocale =>
      WidgetsBinding.instance.platformDispatcher.locale.languageCode
          .toLowerCase() ==
      'en';

  List<ModelSource> get _sources {
    final list = (_selected?.package.sources ?? const [])
        .map(modelSourceFromKey)
        .whereType<ModelSource>()
        .toList();
    return _isEnglishLocale ? list : list.reversed.toList();
  }

  /// 当前所选包 + 来源对应的下载端点（与 [_start] 的挑选逻辑一致）。
  DownloadEndpoint? get _selectedEndpoint {
    final p = _selected?.package;
    final s = _source;
    if (p == null || s == null) return null;
    DownloadEndpoint? endpoint;
    for (final e in p.downloads) {
      if (e.source == s.key) {
        if (endpoint == null || e.available) endpoint = e;
        if (e.available) break;
      }
    }
    return endpoint;
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  /// 端点对应仓库的来源页面 URL。
  String _repoUrl(DownloadEndpoint e) => switch (e.source) {
        'huggingface' => 'https://huggingface.co/${e.repo}',
        'hf_mirror' => 'https://hf-mirror.com/${e.repo}',
        'modelscope' => 'https://www.modelscope.cn/models/${e.repo}',
        _ => '',
      };

  @override
  void initState() {
    super.initState();
    final pkgs =
        widget.group.packages.where((p) => !p.installed && p.hasSource);
    for (final p in pkgs) {
      final opt = _DownloadOption(package: p);
      _options.add(opt);
      if (_selected == null && opt.package.packageId == widget.preselectId) {
        _selected = opt;
      }
    }
    if (_selected == null) {
      for (final opt in _options) {
        if (opt.package.isDefault) {
          _selected = opt;
          break;
        }
      }
    }
    if (_selected == null && _options.isNotEmpty) _selected = _options.first;
    _textController = TextEditingController(text: _token);
    _source = _sources.isNotEmpty ? _sources.first : null;
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _start() {
    final opt = _selected;
    final source = _source;
    if (opt == null || source == null) return;
    final p = opt.package;
    DownloadEndpoint? endpoint;
    for (final e in p.downloads) {
      if (e.source == source.key) {
        if (endpoint == null || e.available) endpoint = e;
        if (e.available) break;
      }
    }
    final manager = ref.read(downloadManagerProvider);
    unawaited(manager.start(
      groupName: widget.group.name,
      request: ModelDownloadRequest(
        packageId: p.packageId,
        repo: endpoint?.repo ?? p.sourceRepo,
        revision: endpoint?.revision ?? p.revision,
        files: p.files,
        targetDirectory: p.targetDirectory,
        stripPrefix: p.stripPrefix,
        source: source,
        token: _token.trim(),
        modelsRoot: '',
      ),
    ));
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final dict = ref.watch(stringsProvider);
    return AlertDialog(
      title: Text(dictTpl(dict, 'models.download.title', {'name': widget.group.name})),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                dict['models.download.chooseSpec'] ?? 'Choose a spec package to download:',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              RadioGroup<_DownloadOption>(
                groupValue: _selected,
                onChanged: (v) {
                  if (v != null && !identical(v, _selected)) {
                    setState(() {
                      _selected = v;
                      final sources = _sources;
                      _source = sources.isNotEmpty ? sources.first : null;
                    });
                  }
                },
                child: Column(
                  children: [
                    for (final opt in _options) _buildOptionTile(context, opt),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _textController,
                obscureText: true,
                onChanged: (v) => setState(() => _token = v),
                decoration: InputDecoration(
                  labelText: dict['models.download.tokenLabel'] ?? 'Access token (optional)',
                  hintText: dict['models.download.tokenHint'] ?? 'Required for private / restricted models',
                  prefixIcon: const Icon(Icons.key),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              InputDecorator(
                decoration: InputDecoration(
                  labelText: dict['models.sourceLabel'] ?? 'Source',
                  prefixIcon: const Icon(Icons.cloud_download_outlined),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<ModelSource>(
                    value: _source,
                    isExpanded: true,
                    isDense: true,
                    items: [
                      for (final s in _sources)
                        DropdownMenuItem(value: s, child: Text(s.label)),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _source = v);
                    },
                  ),
                ),
              ),
              if (_selectedEndpoint != null) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(Icons.folder_outlined,
                        size: 18,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${dict['models.download.sourceRepo'] ?? 'Data source'}: '
                        '${_selectedEndpoint!.repo}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    if (_repoUrl(_selectedEndpoint!).isNotEmpty)
                      TextButton(
                        onPressed: () => _openUrl(_repoUrl(_selectedEndpoint!)),
                        child: Text(dict['models.download.viewLicense'] ??
                            'View license / source'),
                      ),
                  ],
                ),
              ],
              if (_selectedEndpoint?.gated ?? false) ...[
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.lock_outline,
                        size: 18, color: Theme.of(context).colorScheme.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        dict['models.download.gated'] ??
                            'Gated repository: accept its terms on the site '
                                'and provide an access token to download.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(dict['common.cancel'] ?? 'Cancel'),
        ),
        FilledButton.icon(
          onPressed: (_source == null ||
                  ((_selectedEndpoint?.gated ?? false) &&
                      _token.trim().isEmpty))
              ? null
              : _start,
          icon: const Icon(Icons.download, size: 18),
          label: Text(dict['models.startDownload'] ?? 'Start download'),
        ),
      ],
    );
  }

  late TextEditingController _textController;

  Widget _buildOptionTile(BuildContext context, _DownloadOption opt) {
    final dict = ref.watch(stringsProvider);
    final p = opt.package;
    final selected = identical(opt, _selected);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: () {
          if (!selected) {
            setState(() {
              _selected = opt;
              final sources = _sources;
              _source = sources.isNotEmpty ? sources.first : null;
            });
          }
        },
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: selected
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.08)
                : null,
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: Row(
            children: [
              Radio<_DownloadOption>(value: opt),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(p.packageId,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium),
                        ),
                        if (p.isDefault) ...[
                          const SizedBox(width: 6),
                          Text(dict['models.badge.recommended'] ?? 'Recommended',
                              style: const TextStyle(fontSize: 11, color: Colors.amber)),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (p.sizeBytes != null) formatBytes(p.sizeBytes),
                        if (p.estMemoryBytes != null)
                          dictTpl(dict, 'models.memory',
                              {'size': formatBytes(p.estMemoryBytes)}),
                        if (p.estVramBytes != null)
                          dictTpl(dict, 'models.vram',
                              {'size': formatBytes(p.estVramBytes)}),
                      ].join('  ·  '),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DownloadOption {
  _DownloadOption({required this.package});

  final ModelCatalogEntry package;
}

class _DownloadTaskCard extends ConsumerWidget {
  const _DownloadTaskCard({required this.task, required this.manager});

  final DownloadTask task;
  final DownloadManager manager;

  Widget _action(
          {required IconData icon,
          required String tooltip,
          required VoidCallback onPressed}) =>
      IconButton(
        icon: Icon(icon),
        tooltip: tooltip,
        onPressed: onPressed,
        visualDensity: VisualDensity.compact,
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dict = ref.watch(stringsProvider);
    final theme = Theme.of(context);
    final phase = task.phase;
    final downloading = phase == DownloadPhase.downloading;
    final paused = phase == DownloadPhase.paused;
    final processing = downloading || paused;
    final connected = task.receivedBytes > 0;
    final hasProgress = connected && task.progressPercent >= 0;
    final bytes = task.totalBytes > 0
        ? '${formatBytes(task.receivedBytes)} / ${formatBytes(task.totalBytes)}'
        : (task.receivedBytes > 0 ? formatBytes(task.receivedBytes) : '');
    final speedText = _formatSpeed(task.receivedBytes, task.speedBytesPerSec);
    final eta =
        _formatEta(task.receivedBytes, task.totalBytes, task.speedBytesPerSec);
    final metaParts = <String>[
      if (speedText != '--') speedText,
      if (eta != null) dictTpl(dict, 'models.task.eta', {'time': eta}),
    ];
    final metaLine = metaParts.isEmpty ? '--' : metaParts.join('  ·  ');
    final subtitle = [
      task.groupName,
      task.source.label,
    ].join(' · ');

    final (statusText, statusColor) = switch (phase) {
      DownloadPhase.done => (dict['models.task.done'] ?? 'Done', Colors.green),
      DownloadPhase.installed => (dict['models.task.installed'] ?? 'Installed', Colors.green),
      DownloadPhase.failed => (dict['models.task.failed'] ?? 'Failed', Colors.red),
      DownloadPhase.cancelled => (dict['models.task.cancelled'] ?? 'Cancelled', Colors.orange),
      DownloadPhase.paused => (dict['models.task.paused'] ?? 'Paused', Colors.orange),
      DownloadPhase.downloading => (dict['models.task.downloading'] ?? 'Downloading', Colors.blue),
    };

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              flex: 1,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(
                    switch (phase) {
                      DownloadPhase.done => Icons.check_circle,
                      DownloadPhase.installed => Icons.check_circle,
                      DownloadPhase.failed => Icons.error,
                      DownloadPhase.cancelled => Icons.cancel,
                      DownloadPhase.paused => Icons.pause_circle_outline,
                      DownloadPhase.downloading => Icons.downloading,
                    },
                    color: statusColor,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(task.packageId,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall),
                        const SizedBox(height: 2),
                        Text(subtitle,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            )),
                        if (task.error != null && task.error!.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(task.error!,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: Colors.red)),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            if (!processing) ...[
              Expanded(
                flex: 1,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        statusText,
                        style: TextStyle(
                          color: statusColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (phase == DownloadPhase.failed ||
                          phase == DownloadPhase.cancelled)
                        _action(
                          icon: Icons.refresh,
                          tooltip: dict['models.task.redownload'] ?? 'Redownload',
                          onPressed: () => manager.resume(task.packageId),
                        ),
                      _action(
                        icon: Icons.delete_outline,
                        tooltip: dict['models.task.remove'] ?? 'Remove',
                        onPressed: () => manager.remove(task.packageId),
                      ),
                    ],
                  ),
                ),
              ),
            ] else ...[
              Expanded(
                flex: 1,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    LinearProgressIndicator(
                      value: hasProgress
                          ? (task.progressPercent / 100).clamp(0.0, 1.0)
                          : null,
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      hasProgress
                          ? '${task.progressPercent.toStringAsFixed(1)}%  ·  $bytes'
                          : (connected ? bytes : (dict['models.task.preparing'] ?? 'Preparing...')),
                      style: theme.textTheme.bodySmall,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      metaLine,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 1,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (paused) ...[
                        Text(
                          statusText,
                          style: TextStyle(
                            color: statusColor,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],
                      if (downloading)
                        _action(
                          icon: Icons.pause,
                          tooltip: dict['models.task.pause'] ?? 'Pause',
                          onPressed: () => manager.pause(task.packageId),
                        )
                      else
                        _action(
                          icon: Icons.play_arrow,
                          tooltip: dict['models.task.resume'] ?? 'Resume',
                          onPressed: () => manager.resume(task.packageId),
                        ),
                      _action(
                        icon: Icons.close,
                        tooltip: dict['models.task.cancel'] ?? 'Cancel',
                        onPressed: () => manager.cancel(task.packageId),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ManageModelDialog extends ConsumerStatefulWidget {
  const _ManageModelDialog({
    required this.group,
    required this.onDownloadPackage,
    required this.onUninstallPackage,
    required this.onSwitchVersion,
    required this.onOpenDownloads,
  });

  final _ModelGroup group;
  final Future<void> Function(String packageId) onDownloadPackage;
  final Future<void> Function(String packageId) onUninstallPackage;
  final Future<void> Function(String packageId) onSwitchVersion;
  final VoidCallback onOpenDownloads;

  @override
  ConsumerState<_ManageModelDialog> createState() => _ManageModelDialogState();
}

class _ManageModelDialogState extends ConsumerState<_ManageModelDialog> {
  @override
  Widget build(BuildContext context) {
    final dict = ref.watch(stringsProvider);
    final byId = {
      for (final e in ref.watch(modelLibraryProvider).entries) e.packageId: e,
    };
    final manager = ref.watch(downloadManagerProvider);
    final packages = widget.group.packages;
    var installedCount = 0;
    for (final p in packages) {
      final cur = byId[p.packageId];
      final installed = cur?.installed ?? p.installed;
      if (!installed) continue;
      installedCount++;
    }
    final theme = Theme.of(context);
    final hint = installedCount <= 1
        ? dictTpl(dict, 'models.manage.hintSingle', {
            'total': '${packages.length}',
            'installed': '$installedCount',
          })
        : dictTpl(dict, 'models.manage.hintMulti', {
            'total': '${packages.length}',
            'installed': '$installedCount',
          });
    return AlertDialog(
      title: Text(dictTpl(dict, 'models.manage.title', {'name': widget.group.name})),
      content: SizedBox(
        width: 680,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline,
                      size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      hint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (final p in packages) ...[
                _ManagePackageTile(
                  package: p,
                  installed: byId[p.packageId]?.installed ?? p.installed,
                  active:
                      byId[p.packageId]?.activeVersion ?? p.activeVersion,
                  downloading: manager.taskOf(p.packageId)?.active ?? false,
                  onDownload: () => widget.onDownloadPackage(p.packageId),
                  onUninstall: () => widget.onUninstallPackage(p.packageId),
                  onSwitch: () => widget.onSwitchVersion(p.packageId),
                  onOpenDownloads: () {
                    Navigator.pop(context);
                    widget.onOpenDownloads();
                  },
                ),
                const Divider(height: 1),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(dict['common.close'] ?? 'Close'),
        ),
      ],
    );
  }
}

class _ManagePackageTile extends ConsumerWidget {
  const _ManagePackageTile({
    required this.package,
    required this.installed,
    required this.active,
    required this.downloading,
    required this.onDownload,
    required this.onUninstall,
    required this.onSwitch,
    required this.onOpenDownloads,
  });

  final ModelCatalogEntry package;
  final bool installed;
  final bool active;
  final bool downloading;
  final VoidCallback onDownload;
  final VoidCallback onUninstall;
  final VoidCallback onSwitch;
  final VoidCallback onOpenDownloads;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dict = ref.watch(stringsProvider);
    final theme = Theme.of(context);
    final p = package;
    return Padding(
      key: ValueKey('manage-tile-${package.packageId}'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.packageId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                if (p.sizeBytes != null ||
                    p.estMemoryBytes != null ||
                    p.estVramBytes != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (p.sizeBytes != null) formatBytes(p.sizeBytes),
                      if (p.estMemoryBytes != null)
                        dictTpl(dict, 'models.memory',
                            {'size': formatBytes(p.estMemoryBytes)}),
                      if (p.estVramBytes != null)
                        dictTpl(dict, 'models.vram',
                            {'size': formatBytes(p.estVramBytes)}),
                    ].join('  ·  '),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (installed) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    dict['models.badge.installed'] ?? 'Installed',
                    style: const TextStyle(fontSize: 13, color: Colors.green),
                  ),
                ),
                if (active) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      dict['models.currentVersion'] ?? 'Current version',
                      style: const TextStyle(fontSize: 13, color: Colors.blue),
                    ),
                  ),
                ],
                const SizedBox(width: 12),
                if (!active) ...[
                  OutlinedButton.icon(
                    onPressed: onSwitch,
                    icon: const Icon(Icons.swap_horiz, size: 16),
                    label: Text(dict['models.setAsCurrent'] ?? 'Set as current'),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: dict['common.uninstall'] ?? 'Uninstall',
                  onPressed: onUninstall,
                ),
              ] else if (downloading)
                FilledButton.tonalIcon(
                  onPressed: onOpenDownloads,
                  icon: const Icon(Icons.downloading, size: 16),
                  label: Text(dict['models.downloading'] ?? 'Downloading'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                )
              else if (p.hasSource)
                FilledButton.tonalIcon(
                  onPressed: onDownload,
                  icon: const Icon(Icons.download, size: 16),
                  label: Text(dict['common.download'] ?? 'Download'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
