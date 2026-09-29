import 'dart:async';
import 'dart:convert';
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

  /// 运行 `--list-devices` 并收集 stdout。超时或异常则**杀掉子进程**，避免探测进程
  /// 残留/卡住导致调用方（如后端列表）一直处于 loading、进而阻塞界面操作。
  static Future<String?> _listDevices(String serverExe) async {
    Process proc;
    try {
      proc = await Process.start(serverExe, const ['--list-devices']);
    } catch (_) {
      return null;
    }
    final out = StringBuffer();
    final outSub = proc.stdout.transform(utf8.decoder).listen(out.write);
    unawaited(proc.stderr.drain<void>());
    try {
      final code = await proc.exitCode.timeout(const Duration(seconds: 15));
      await outSub.cancel();
      if (code != 0) return null;
      return out.toString();
    } on TimeoutException {
      try {
        proc.kill(ProcessSignal.sigkill);
      } catch (_) {}
      try {
        await outSub.cancel();
      } catch (_) {}
      return null;
    } catch (_) {
      try {
        proc.kill(ProcessSignal.sigkill);
      } catch (_) {}
      return null;
    }
  }

  static Future<List<String>> listRegisteredBackends({
    required String serverExe,
  }) async {
    final backends = <String>[];
    final stdout = await _listDevices(serverExe);
    if (stdout == null) return backends;
    final names = <String>{};
    final re = RegExp(
      r'^([A-Za-z]+):\d+\s+"[^"]*"',
      multiLine: true,
    );
    for (final m in re.allMatches(stdout)) {
      names.add(m.group(1)!.toLowerCase());
    }
    backends.addAll(names);
    return backends;
  }

  static Future<List<String>> listGpuNames({
    required String serverExe,
    required String backend,
  }) async {
    final want = regNameFor(backend);
    final names = <String>[];
    final stdout = await _listDevices(serverExe);
    if (stdout == null) return names;
    final re = RegExp(
      r'^([A-Za-z]+):(\d+)\s+"([^"]*)"',
      multiLine: true,
    );
    for (final m in re.allMatches(stdout)) {
      if (m.group(1)!.toLowerCase() != want) continue;
      final index = int.parse(m.group(2)!);
      final name = m.group(3)!.trim();
      if (name.isEmpty) continue;
      while (names.length <= index) {
        names.add('');
      }
      names[index] = name;
    }
    return names.where((n) => n.isNotEmpty).toList();
  }
}
