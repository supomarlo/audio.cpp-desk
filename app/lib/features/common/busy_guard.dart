import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/app_providers.dart';
import '../../providers/generation_providers.dart';

/// 通用 busy 守卫：有任务正在生成时，弹「任务进行中」提示并阻止当前操作；
/// 空闲 / 已暂停时返回 true（允许继续）。
///
/// 用于会打断生成的操作（切换会话、修改目录、停止服务端等）。
/// [goWorkbench] 为真时提供「去工作台」入口（已在工作台时传 false）。
Future<bool> confirmWhileBusy(WidgetRef ref, BuildContext context,
    {bool goWorkbench = true}) async {
  final queue = ref.read(generationQueueProvider);
  if (!queue.busy) return true;
  final dict = ref.read(stringsProvider);
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(dict['task.busy.title'] ?? 'Task in progress'),
      content: Text(dict['task.busy.message'] ??
          'A task is generating. You can pause it first, or wait for it to finish before proceeding.'),
      actions: [
        if (goWorkbench)
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(homeTabProvider.notifier).state = 0;
            },
            child: Text(dict['task.busy.goWorkbench'] ?? 'Go to workbench'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(dict['common.close'] ?? 'Close'),
        ),
      ],
    ),
  );
  return false;
}
