import 'package:flutter_riverpod/legacy.dart';

import '../core/audio_player.dart';

final audioPlayerProvider =
    ChangeNotifierProvider<AudioPlayerController>((ref) {
  final c = AudioPlayerController();
  ref.onDispose(c.dispose);
  return c;
});
