enum ServerLifecycle { stopped, starting, running, stopping, error }

class ServerSnapshot {
  const ServerSnapshot({
    this.lifecycle = ServerLifecycle.stopped,
    this.exeName,
    this.error,
    this.healthy = false,
    this.backend,
    this.loadedModelsCount = 0,
    this.logLines = const [],
    this.startedAt,
  });

  final ServerLifecycle lifecycle;
  final String? exeName;
  final String? error;
  final bool healthy;
  final String? backend;
  final int loadedModelsCount;
  final List<String> logLines;
  final DateTime? startedAt;

  static const initial = ServerSnapshot();

  static const maxLogLines = 2000;

  bool get isStopped => lifecycle == ServerLifecycle.stopped;
  bool get isStarting => lifecycle == ServerLifecycle.starting;
  bool get isRunning => lifecycle == ServerLifecycle.running;

  ServerSnapshot copyWith({
    ServerLifecycle? lifecycle,
    String? exeName,
    String? error,
    bool? healthy,
    String? backend,
    int? loadedModelsCount,
    List<String>? logLines,
    DateTime? startedAt,
  }) {
    return ServerSnapshot(
      lifecycle: lifecycle ?? this.lifecycle,
      exeName: exeName ?? this.exeName,
      error: error ?? this.error,
      healthy: healthy ?? this.healthy,
      backend: backend ?? this.backend,
      loadedModelsCount: loadedModelsCount ?? this.loadedModelsCount,
      logLines: logLines ?? this.logLines,
      startedAt: startedAt ?? this.startedAt,
    );
  }

  ServerSnapshot withLog(String line) {
    final lines = [...logLines, line];
    if (lines.length > maxLogLines) {
      lines.removeRange(0, lines.length - maxLogLines);
    }
    return copyWith(logLines: lines);
  }
}