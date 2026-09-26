import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../providers/player_providers.dart';

String _fmt(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}

/// 播放器：无播放内容时不占位。
class PlayerBar extends ConsumerWidget {
  const PlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(audioPlayerProvider);
    if (player.currentPath == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final total = player.duration.inMilliseconds <= 0
        ? 1.0
        : player.duration.inMilliseconds.toDouble();
    final pos = player.position.inMilliseconds
        .clamp(0, player.duration.inMilliseconds)
        .toDouble();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
          child: Row(
          children: [
            IconButton.filled(
              onPressed: player.toggle,
              icon: Icon(player.playing ? Icons.pause : Icons.play_arrow),
              style: IconButton.styleFrom(
                backgroundColor: scheme.primary,
                foregroundColor: scheme.onPrimary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    player.title.isNotEmpty
                        ? player.title
                        : p.basename(player.currentPath ?? ''),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      SizedBox(
                        width: 40,
                        child: Text(_fmt(player.position),
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant)),
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 2,
                            thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6),
                            overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 12),
                          ),
                          child: Slider(
                            value: pos,
                            max: total,
                            onChanged: (v) => player
                                .seek(Duration(milliseconds: v.toInt())),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 40,
                        child: Text(
                          _fmt(player.duration),
                          textAlign: TextAlign.end,
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              visualDensity: VisualDensity.compact,
              onPressed: player.stop,
            ),
          ],
        ),
      ),
    ),
  );
  }
}
