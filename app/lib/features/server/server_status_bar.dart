import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/server_snapshot.dart';
import '../../providers/app_providers.dart';
import '../../providers/server_providers.dart';

/// 底部服务端状态栏：显示生命周期/后端/已加载模型，并可启动/停止。
class ServerStatusBar extends ConsumerWidget {
  const ServerStatusBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dict = ref.watch(stringsProvider);
    final snap = ref.watch(serverControllerProvider);
    final theme = Theme.of(context);

    final (color, text) = switch (snap.lifecycle) {
      ServerLifecycle.running when snap.healthy => (
          Colors.green,
          dict['server.status.running'] ?? 'Running'
        ),
      ServerLifecycle.running => (
          Colors.orange,
          dict['server.status.starting'] ?? 'Starting…'
        ),
      ServerLifecycle.starting => (
          Colors.orange,
          dict['server.status.starting'] ?? 'Starting…'
        ),
      ServerLifecycle.stopping => (
          Colors.orange,
          dict['server.status.starting'] ?? 'Starting…'
        ),
      ServerLifecycle.error => (
          Colors.red,
          snap.error ?? (dict['server.status.error'] ?? 'Error')
        ),
      ServerLifecycle.stopped => (
          Colors.grey,
          dict['server.status.stopped'] ?? 'Stopped'
        ),
    };

    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: SizedBox(
        height: 32,
        child: Row(
          children: [
            const SizedBox(width: 12),
            Icon(Icons.circle, size: 10, color: color),
            const SizedBox(width: 8),
            Text('${dict['server.status.label'] ?? 'Server'}: ',
                style: theme.textTheme.bodySmall),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: color),
              ),
            ),
            if (snap.isRunning && snap.healthy) ...[
              if (snap.backend != null)
                Text(
                  '${dict['server.status.backend'] ?? 'Backend'} ${snap.backend}',
                  style: theme.textTheme.bodySmall,
                ),
              const SizedBox(width: 12),
              Text(
                (dict['server.status.models'] ?? 'Models {count}')
                    .replaceAll('{count}', '${snap.loadedModelsCount}'),
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }
}
