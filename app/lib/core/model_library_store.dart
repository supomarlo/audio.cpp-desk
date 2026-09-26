import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_paths.dart';
import '../models/model_catalog_entry.dart';
import '../models/model_spec.dart';

class ModelLibraryStore {
  ModelLibraryStore(this.paths);

  final AppPaths paths;

  File get _stateFile => File(p.join(paths.dataDir.path, 'model_catalog.json'));

  Future<List<ModelCatalogEntry>> load({
    required List<ModelSpec> specs,
    String modelsRoot = '',
  }) async {
    final saved = <String, ModelCatalogEntry>{};
    if (_stateFile.existsSync()) {
      try {
        final raw =
            jsonDecode(_stateFile.readAsStringSync()) as Map<String, dynamic>;
        final list = raw['packages'] as List<dynamic>? ?? [];
        for (final e in list) {
          final entry =
              ModelCatalogEntry.fromJson(Map<String, dynamic>.from(e as Map));
          saved[entry.packageId] = entry;
        }
      } catch (_) {}
    }

    final entries = <String, ModelCatalogEntry>{};
    for (final spec in specs) {
      for (final pkg in spec.packages) {
        final prev = saved[pkg.id];
        final available = pkg.availableDownloads;
        final primary = available.isNotEmpty
            ? available.first
            : (pkg.downloads.isNotEmpty ? pkg.downloads.first : null);
        entries[pkg.id] = (prev ??
                ModelCatalogEntry(
                  packageId: pkg.id,
                  family: spec.family,
                  displayName:
                      pkg.displayName.isNotEmpty ? pkg.displayName : pkg.id,
                  category: spec.category,
                  installed: false,
                  addedAt: DateTime.now(),
                ))
            .copyWith(
          family: spec.family,
          displayName: pkg.displayName.isNotEmpty ? pkg.displayName : pkg.id,
          category: spec.category,
          status: spec.status,
          description: spec.description,
          descriptionZh: spec.descriptionZh,
          packageDescription: pkg.description,
          packageDescriptionZh: pkg.descriptionZh,
          isDefault: pkg.isDefault,
          sourceRepo: primary?.repo ?? pkg.downloadRepo,
          targetDirectory: pkg.targetDirectory,
          files: pkg.files,
          stripPrefix: pkg.stripPrefix,
          downloadKind: primary?.kind ?? pkg.downloadKind,
          revision: primary?.revision ?? pkg.revision,
          sizeBytes: pkg.sizes?.sizeBytes ?? prev?.sizeBytes,
          estMemoryBytes: pkg.sizes?.estMemoryBytes ?? prev?.estMemoryBytes,
          estVramBytes: pkg.sizes?.estVramBytes ?? prev?.estVramBytes,
          sources: available.map((e) => e.source).toList(),
          downloads: pkg.downloads,
          task: pkg.task,
          installed: _locallyInstalled(pkg, modelsRoot),
        );
      }
    }

    final list = entries.values.toList();
    list.sort((a, b) => a.displayName.compareTo(b.displayName));
    return _recomputeActiveVersion(list);
  }

  List<ModelCatalogEntry> _recomputeActiveVersion(
      List<ModelCatalogEntry> list) {
    final byFamily = <String, List<ModelCatalogEntry>>{};
    for (final e in list) {
      if (!e.installed || e.family.isEmpty) continue;
      byFamily.putIfAbsent(e.family, () => []).add(e);
    }
    final activeIds = <String>{};
    for (final pkgs in byFamily.values) {
      pkgs.sort((a, b) {
        final r = (a.isDefault ? 0 : 1).compareTo(b.isDefault ? 0 : 1);
        if (r != 0) return r;
        return a.packageId.compareTo(b.packageId);
      });
      final saved = pkgs.where((e) => e.activeVersion).take(1).toList();
      activeIds.add((saved.isNotEmpty ? saved.first : pkgs.first).packageId);
    }
    if (activeIds.isEmpty) return list;
    return list
        .map((e) => e.copyWith(activeVersion: activeIds.contains(e.packageId)))
        .toList();
  }

  bool _locallyInstalled(SpecPackage pkg, String modelsRoot) {
    if (modelsRoot.isEmpty || pkg.targetDirectory.isEmpty) return false;
    final root = Directory(p.join(modelsRoot, pkg.targetDirectory));
    if (!root.existsSync()) return false;
    final prefix = pkg.stripPrefix.replaceAll(RegExp(r'/+$'), '');
    String strip(String name) =>
        prefix.isNotEmpty && name.startsWith('$prefix/')
            ? name.substring(prefix.length + 1)
            : name;
    for (final f in pkg.files) {
      if (!File(p.join(root.path, strip(f))).existsSync()) return false;
    }
    return true;
  }

  void save(List<ModelCatalogEntry> entries) {
    _stateFile.parent.createSync(recursive: true);
    _stateFile.writeAsStringSync(
      jsonEncode({
        'version': 1,
        'packages': entries.map((e) => e.toJson()).toList(),
      }),
    );
  }

  void uninstall(
      {required String modelsRoot, required ModelCatalogEntry entry}) {
    if (modelsRoot.isEmpty || entry.packageId.isEmpty) return;
    final target = Directory(p.join(modelsRoot, entry.targetDirectory));
    if (target.existsSync()) {
      final rels = <String>{};
      final manifest = File(
        p.join(target.path, '.audiocpp-package-${entry.packageId}.json'),
      );
      if (manifest.existsSync()) {
        try {
          final raw =
              jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
          final files = raw['files'] as Map<String, dynamic>? ?? {};
          for (final v in files.values) {
            if (v is Map) {
              final lp = v['local_path'] as String? ?? '';
              if (lp.isNotEmpty) rels.add(lp);
            }
          }
        } catch (_) {}
      }
      if (rels.isEmpty) {
        final prefix = entry.stripPrefix.replaceAll(RegExp(r'/+$'), '');
        for (final f in entry.files) {
          rels.add(prefix.isNotEmpty && f.startsWith('$prefix/')
              ? f.substring(prefix.length + 1)
              : f);
        }
      }
      for (final rel in rels) {
        try {
          final f = File(p.join(target.path, rel));
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
      try {
        if (manifest.existsSync()) manifest.deleteSync();
      } catch (_) {}
      _pruneEmptyUpTo(target, modelsRoot);
    }
  }

  void _pruneEmptyUpTo(Directory start, String stop) {
    var dir = start;
    while (p.isWithin(stop, dir.path)) {
      if (!dir.existsSync()) return;
      try {
        if (dir.listSync().isNotEmpty) return;
        dir.deleteSync();
      } catch (_) {
        return;
      }
      dir = dir.parent;
    }
  }
}
