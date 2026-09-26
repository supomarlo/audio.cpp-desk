import 'dart:io';

class GpuProbe {
  static String regNameFor(String backend) {
    switch (backend.toLowerCase()) {
      case 'metal':
        return 'mtl';
      case 'hip':
        return 'rocm';
      default:
        return backend.toLowerCase();
    }
  }

  static Future<List<String>> listRegisteredBackends({
    required String serverExe,
  }) async {
    final backends = <String>[];
    try {
      final result = await Process.run(
        serverExe,
        const ['--list-devices'],
      ).timeout(const Duration(seconds: 15));
      if (result.exitCode != 0) return const <String>[];
      final names = <String>{};
      final re = RegExp(
        r'^([A-Za-z]+):\d+\s+"[^"]*"',
        multiLine: true,
      );
      for (final m in re.allMatches(result.stdout as String)) {
        names.add(m.group(1)!.toLowerCase());
      }
      backends.addAll(names);
    } catch (_) {}
    return backends;
  }

  static Future<List<String>> listGpuNames({
    required String serverExe,
    required String backend,
  }) async {
    final want = regNameFor(backend);
    final names = <String>[];
    try {
      final result = await Process.run(
        serverExe,
        const ['--list-devices'],
      ).timeout(const Duration(seconds: 15));
      if (result.exitCode != 0) return const <String>[];
      final re = RegExp(
        r'^([A-Za-z]+):(\d+)\s+"([^"]*)"',
        multiLine: true,
      );
      for (final m in re.allMatches(result.stdout as String)) {
        if (m.group(1)!.toLowerCase() != want) continue;
        final index = int.parse(m.group(2)!);
        final name = m.group(3)!.trim();
        if (name.isEmpty) continue;
        while (names.length <= index) {
          names.add('');
        }
        names[index] = name;
      }
    } catch (_) {}
    return names.where((n) => n.isNotEmpty).toList();
  }
}