import 'dart:io';

import 'package:audio_cpp_desk/core/audio_transcoder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('toWav 对不存在的输入抛出可读错误（不调用转码器）', () async {
    final tmp = Directory.systemTemp.createTempSync('at_test');
    addTearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    final transcoder = AudioTranscoder(tmpDir: tmp, appRoot: tmp);
    final missing =
        '${tmp.path}${Platform.pathSeparator}missing_ref.wav';

    await expectLater(
      transcoder.toWav(missing, 'audio2wav'),
      throwsA(isA<AudioTranscodeException>().having(
        (e) => e.message,
        'message',
        contains('input audio not found'),
      )),
    );
  });
}
