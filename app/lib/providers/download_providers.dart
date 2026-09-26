import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../core/app_config.dart';
import '../core/download_manager.dart';
import 'app_providers.dart';
import 'library_providers.dart';

final downloadDioProvider = Provider<Dio>((ref) {
  return Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(minutes: 5),
  ));
});

final downloadManagerProvider =
    ChangeNotifierProvider<DownloadManager>((ref) {
  final paths = ref.watch(appPathsProvider);
  final modelsPath = ref.watch(appConfigProvider.select((c) => c.modelsPath));
  return DownloadManager(
    modelsRootOf: () => AppConfig.normalizeAgainst(paths, modelsPath),
    recordsRootOf: () => paths.downloadRecordsDir.path,
    partialRootOf: () => paths.downloadPartialDir.path,
    onInstalled: (packageId) async {
      try {
        await ref.read(modelLibraryProvider.notifier).reloadSpecs();
      } catch (_) {}
    },
    dio: ref.watch(downloadDioProvider),
  );
});