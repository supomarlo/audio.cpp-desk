import 'package:audio_cpp_desk/core/server_version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('服务端版本达到最低版本时兼容', () {
    expect(serverVersionStatus('0.9.3'), ServerVersionStatus.supported);
    expect(serverVersionStatus('0.9.3-beta'), ServerVersionStatus.supported);
    expect(serverVersionStatus('v0.9.4'), ServerVersionStatus.supported);
    expect(serverVersionStatus('1.0.0'), ServerVersionStatus.supported);
  });

  test('服务端版本低于最低版本时提示升级', () {
    expect(serverVersionStatus('0.9.2'), ServerVersionStatus.tooOld);
    expect(serverVersionStatus('0.8.1'), ServerVersionStatus.tooOld);
  });

  test('缺少版本字段时视为旧版本', () {
    expect(serverVersionStatus(''), ServerVersionStatus.tooOld);
  });

  test('版本字段无法解析时视为未知', () {
    expect(serverVersionStatus('dev'), ServerVersionStatus.unknown);
  });
}
