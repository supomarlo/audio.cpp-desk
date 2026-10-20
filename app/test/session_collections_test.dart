import 'dart:io';

import 'package:audio_cpp_desk/core/app_paths.dart';
import 'package:audio_cpp_desk/core/session_store.dart';
import 'package:audio_cpp_desk/providers/session_providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('新建会话继承当前集合，并在首次落盘后写入集合成员', () {
    final temp = Directory.systemTemp.createTempSync('session_inherit_');
    addTearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final store = SessionStore(AppPaths(temp));
    final cc = CollectionsController(store);
    final col = store.createCollection(name: 'Project A');
    cc.reload();

    final ctrl = CurrentSessionController(
      store,
      onSessionPersisted: (sid, cid) => cc.addSession(sid, cid),
    );
    ctrl.setCollectionId(col.id);
    ctrl.newSession();

    expect(ctrl.session.collectionId, col.id);

    ctrl.addRecord(type: 'tts');

    final reloaded = store.listCollections().first;
    expect(reloaded.sessionIds, contains(ctrl.session.id));
    expect(cc.collectionOf(ctrl.session.id)?.id, col.id);
  });

  test('当前会话未归属集合时，新建会话保持未归属', () {
    final temp = Directory.systemTemp.createTempSync('session_no_col_');
    addTearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final store = SessionStore(AppPaths(temp));
    final ctrl = CurrentSessionController(store);
    ctrl.newSession();
    expect(ctrl.session.collectionId, isNull);
  });

  test('载入会话也触发会话切换回调（停止播放器）', () {
    final temp = Directory.systemTemp.createTempSync('session_open_');
    addTearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final store = SessionStore(AppPaths(temp));
    final target = store.createSession();
    store.saveMeta(target);
    var switched = 0;
    final ctrl = CurrentSessionController(
      store,
      onSessionSwitch: () => switched++,
    );
    ctrl.openSession(target.id);
    expect(switched, 1);
    expect(ctrl.session.id, target.id);
  });
}
