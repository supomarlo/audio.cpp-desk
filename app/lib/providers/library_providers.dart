import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:path/path.dart' as p;

import '../core/app_config.dart';
import '../core/app_logger.dart';
import '../core/app_paths.dart';
import '../core/model_library_store.dart';
import '../core/voice_library_store.dart';
import '../models/model_catalog_entry.dart';
import '../models/model_spec.dart';
import '../models/voice_entry.dart';
import 'app_providers.dart';
import 'catalog_providers.dart';

class VoiceLibraryState {
  const VoiceLibraryState({this.voices = const []});

  final List<VoiceEntry> voices;

  VoiceLibraryState copyWith({List<VoiceEntry>? voices}) => VoiceLibraryState(
        voices: voices ?? this.voices,
      );
}

class VoiceLibraryController extends StateNotifier<VoiceLibraryState> {
  VoiceLibraryController({required AppPaths paths})
      : _paths = paths,
        _store = VoiceLibraryStore(paths),
        super(VoiceLibraryState(voices: VoiceLibraryStore(paths).load()));

  final AppPaths _paths;
  final VoiceLibraryStore _store;

  Future<void> add(VoiceEntry entry) async {
    state = state.copyWith(voices: [...state.voices, entry]);
    _store.save(state.voices);
  }

  Future<void> addAll(Iterable<VoiceEntry> entries) async {
    state = state.copyWith(voices: [...state.voices, ...entries]);
    _store.save(state.voices);
  }

  Future<void> remove(String id) async {
    VoiceEntry? entry;
    for (final v in state.voices) {
      if (v.id == id) {
        entry = v;
        break;
      }
    }
    if (entry?.audioPath != null) {
      try {
        final f = File(entry!.audioPath!);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    state = state.copyWith(
      voices: state.voices.where((v) => v.id != id).toList(),
    );
    _store.save(state.voices);
  }

  Future<VoiceEntry> createFromFile({
    required String name,
    required String sourcePath,
    String? text,
    String? description,
    String? language,
  }) async {
    final id = 'v${DateTime.now().millisecondsSinceEpoch}';
    final source = File(sourcePath);
    final target = File(p.join(_paths.voiceDir.path, '$id.wav'));
    await target.parent.create(recursive: true);
    await source.copy(target.path);
    final entry = VoiceEntry(
      id: id,
      name: name.trim(),
      type: 'file',
      audioPath: target.path,
      text: (text == null || text.trim().isEmpty) ? null : text.trim(),
      description: (description == null || description.trim().isEmpty)
          ? null
          : description.trim(),
      language:
          (language == null || language.trim().isEmpty) ? null : language.trim(),
      createdAt: DateTime.now(),
    );
    state = state.copyWith(voices: [...state.voices, entry]);
    _store.save(state.voices);
    return entry;
  }

  bool containsRef(String type, String value) =>
      state.voices.any((v) => v.type == type && v.ref == value);

  Future<void> update(String id,
      {String? name,
      String? text,
      String? description,
      String? language}) async {
    state = state.copyWith(
      voices: state.voices.map((v) {
        if (v.id != id) return v;
        return v.copyWith(
          name: name == null || name.trim().isEmpty ? v.name : name.trim(),
          text: text == null
              ? v.text
              : (text.trim().isEmpty ? null : text.trim()),
          description: description == null
              ? v.description
              : (description.trim().isEmpty ? null : description.trim()),
          language: language == null
              ? v.language
              : (language.trim().isEmpty ? null : language.trim()),
        );
      }).toList(),
    );
    _store.save(state.voices);
  }
}

class ModelLibraryState {
  const ModelLibraryState({this.entries = const []});

  final List<ModelCatalogEntry> entries;

  ModelLibraryState copyWith({List<ModelCatalogEntry>? entries}) =>
      ModelLibraryState(entries: entries ?? this.entries);
}

class ModelLibraryController extends StateNotifier<ModelLibraryState> {
  ModelLibraryController(
      {required AppPaths paths, required Ref ref, String modelsDir = ''})
      : _store = ModelLibraryStore(paths),
        _ref = ref,
        _modelsDir = modelsDir,
        super(const ModelLibraryState()) {
    AppLogger.info('ModelLibraryController created: modelsDir=$_modelsDir');
    _init();
  }

  final ModelLibraryStore _store;
  final Ref _ref;
  final String _modelsDir;
  List<ModelSpec> _specs = const [];
  final Completer<void> _readyCompleter = Completer<void>();

  /// 首次加载完成（成功或失败）后完成，供启动流程等待模型库就绪。
  Future<void> get ready => _readyCompleter.future;

  Future<void> _init() async {
    try {
      _specs = await _ref.read(specsProvider.future);
      final entries = await _store.load(specs: _specs, modelsRoot: _modelsDir);
      state = ModelLibraryState(entries: entries);
      _store.save(entries);
      AppLogger.info(
          'model library loaded: modelsRoot=$_modelsDir, entries=${entries.length}, '
          'installed=${entries.where((e) => e.installed).length}');
    } finally {
      if (!_readyCompleter.isCompleted) _readyCompleter.complete();
    }
  }

  Future<void> reloadSpecs() async {
    final entries = await _store.load(specs: _specs, modelsRoot: _modelsDir);
    state = state.copyWith(entries: entries);
    _store.save(entries);
  }

  Future<void> uninstall(String packageId) async {
    ModelCatalogEntry? entry;
    for (final e in state.entries) {
      if (e.packageId == packageId) {
        entry = e;
        break;
      }
    }
    if (entry == null) return;
    _store.uninstall(modelsRoot: _modelsDir, entry: entry);
    await reloadSpecs();
  }

  Future<void> setActiveVersion(String packageId) async {
    ModelCatalogEntry? target;
    for (final e in state.entries) {
      if (e.packageId == packageId) {
        target = e;
        break;
      }
    }
    if (target == null || !target.installed || target.family.isEmpty) return;
    final family = target.family;
    final entries = state.entries.map((e) {
      if (e.family != family) return e;
      return e.copyWith(activeVersion: e.packageId == packageId);
    }).toList();
    state = state.copyWith(entries: entries);
    _store.save(entries);
  }
}

final voiceLibraryProvider =
    StateNotifierProvider<VoiceLibraryController, VoiceLibraryState>((ref) {
  return VoiceLibraryController(paths: ref.watch(appPathsProvider));
});

final modelLibraryProvider =
    StateNotifierProvider<ModelLibraryController, ModelLibraryState>((ref) {
  final paths = ref.watch(appPathsProvider);
  final modelsPath = ref.watch(appConfigProvider.select((c) => c.modelsPath));
  // 选中版本变化时重建，重新加载该版本的模型规格。
  ref.watch(appConfigProvider.select((c) => c.activeVersionPath));
  return ModelLibraryController(
    paths: paths,
    ref: ref,
    modelsDir: AppConfig.normalizeAgainst(paths, modelsPath),
  );
});
