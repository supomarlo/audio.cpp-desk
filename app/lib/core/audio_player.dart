import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// 全局音频播放器（底部栏用）。
class AudioPlayerController extends ChangeNotifier {
  AudioPlayerController() {
    _subs.add(_player.onPlayerStateChanged.listen((s) {
      _completed = s == PlayerState.completed;
      playing = s == PlayerState.playing;
      notifyListeners();
    }));
    _subs.add(_player.onPositionChanged.listen((p) {
      position = p;
      notifyListeners();
    }));
    _subs.add(_player.onDurationChanged.listen((d) {
      duration = d;
      notifyListeners();
    }));
    _subs.add(_player.onPlayerComplete.listen((_) {
      _completed = true;
      playing = false;
      position = Duration.zero;
      notifyListeners();
    }));
  }

  final AudioPlayer _player = AudioPlayer();
  final List<StreamSubscription> _subs = [];

  String? currentPath;
  String title = '';
  bool playing = false;
  bool _completed = false;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;

  /// 载入音频但不播放。
  Future<void> load(String path, {String title = ''}) async {
    currentPath = path;
    this.title = title;
    _completed = false;
    playing = false;
    position = Duration.zero;
    duration = Duration.zero;
    await _player.stop();
    await _player.setSource(DeviceFileSource(path));
    notifyListeners();
  }

  Future<void> play(String path, {String title = ''}) async {
    await load(path, title: title);
    await _player.resume();
  }

  Future<void> toggle() async {
    if (currentPath == null) return;
    if (playing) {
      await _player.pause();
      return;
    }
    // 播放完成后再次点击：重新载入再播（仅 resume 在部分平台无效）。
    if (_completed || (duration > Duration.zero && position >= duration)) {
      await play(currentPath!, title: title);
      return;
    }
    await _player.resume();
  }

  Future<void> seek(Duration d) async {
    final path = currentPath;
    if (path == null) return;
    // 播放完成后 seek：需先重载，否则后续 resume 无效。
    if (_completed) {
      await load(path, title: title);
    }
    await _player.seek(d);
    position = d;
    _completed = false;
    notifyListeners();
  }

  Future<void> stop() async {
    await _player.stop();
    currentPath = null;
    playing = false;
    _completed = false;
    position = Duration.zero;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }
}
