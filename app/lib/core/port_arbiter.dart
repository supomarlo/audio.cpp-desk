import 'dart:io';

class PortOccupant {
  const PortOccupant({this.pid = 0, this.exePath = ''});

  final int pid;
  final String exePath;

  String get description {
    if (exePath.isNotEmpty) return exePath;
    if (pid > 0) return 'PID $pid';
    return 'unknown process';
  }
}

class PortArbiter {
  static Future<PortOccupant?> probe(String host, int port) async {
    final pids = <int>{};
    try {
      final result = await Process.run(
        'netstat',
        const ['-ano'],
      ).timeout(const Duration(seconds: 8));
      if (result.exitCode != 0) return null;
      for (final line in (result.stdout as String).split('\n')) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length < 5) continue;
        if (parts[0] != 'TCP') continue;
        if (!parts[1].endsWith(':$port')) continue;
        final pid = int.tryParse(parts[4]);
        if (pid == null || pid == 0) continue;
        pids.add(pid);
      }
    } catch (_) {}
    for (final pid in pids) {
      return PortOccupant(pid: pid, exePath: await _exePathOf(pid));
    }
    return null;
  }

  static Future<int?> findFreePort(String host, int start,
      {int max = 20}) async {
    for (var p = start; p < start + max; p++) {
      final occupied = await isPortOpen(host, p);
      if (!occupied) return p;
    }
    return null;
  }

  static Future<bool> isPortOpen(String host, int port) async {
    try {
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 1),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<String> _exePathOf(int pid) async {
    try {
      final result = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-Command',
          'Get-Process -Id $pid -ErrorAction SilentlyContinue '
              '| Select-Object -ExpandProperty Path',
        ],
      ).timeout(const Duration(seconds: 5));
      if (result.exitCode != 0) return '';
      final lines = (result.stdout as String)
          .split('\n')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      return lines.isEmpty ? '' : lines.first;
    } catch (_) {
      return '';
    }
  }

  static bool sameExe(String a, String b) {
    if (a.isEmpty || b.isEmpty) return false;
    final normA = a.replaceAll('/', r'\').toLowerCase();
    final normB = b.replaceAll('/', r'\').toLowerCase();
    return normA == normB;
  }
}