import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/player_providers.dart';

/// 试听按钮（无进度条场景）：未播放显示播放图标，播放中显示停止图标，
/// 点击即中止播放（非暂停）；[path] 为空时禁用。
///
/// 带进度条的底部播放器另用暂停/继续逻辑，不适用本组件。
class AuditionButton extends ConsumerWidget {
  const AuditionButton({super.key, required this.path, this.title = ''});

  final String? path;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = path != null && path!.isNotEmpty;
    final player = ref.watch(audioPlayerProvider);
    final playing = enabled && player.playing && player.currentPath == path;
    return IconButton(
      icon: Icon(playing ? Icons.stop : Icons.play_arrow),
      onPressed: !enabled
          ? null
          : () {
              final ctrl = ref.read(audioPlayerProvider);
              if (playing) {
                ctrl.stop();
              } else {
                ctrl.play(path!, title: title);
              }
            },
    );
  }
}
