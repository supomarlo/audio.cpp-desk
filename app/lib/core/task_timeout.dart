/// 单次任务超时：
/// - 服务端 `busy_timeout_ms` = 该时长（A 方案：写进 server.json，启动时生效）；
/// - 客户端 `receiveTimeout` = 该时长 + [taskTimeoutMargin]（让"忙"时由服务端先返回 503，
///   客户端随后收到并主动失败，而不是客户端先静默超时、把服务端锁留下）。
///
/// 余量按设置时长线性取值并夹在 5~30 秒、向上取整到 5 秒：
///   1min -> 5s（下限），30min -> 30s（上限）。
Duration taskTimeoutMargin(Duration timeout) {
  final sec = timeout.inSeconds.clamp(60, 1800);
  final raw = 5 + (sec - 60) * 25 / (1800 - 60);
  final margin = (raw / 5).ceil() * 5;
  return Duration(seconds: margin);
}

/// 客户端接收超时 = 单次任务超时 + 余量。
Duration taskReceiveTimeout(Duration timeout) =>
    timeout + taskTimeoutMargin(timeout);
