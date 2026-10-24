import 'dart:io';

import 'package:audio_cpp_desk/core/app_paths.dart';
import 'package:audio_cpp_desk/core/session_store.dart';
import 'package:audio_cpp_desk/models/session.dart';
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

  test('会话内序号递增，删除记录不重排', () {
    final temp = Directory.systemTemp.createTempSync('session_seq_');
    addTearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final store = SessionStore(AppPaths(temp));
    final ctrl = CurrentSessionController(store);
    final r1 = ctrl.addRecord(type: RecordType.tts);
    final r2 = ctrl.addRecord(type: RecordType.tts);
    expect(r1.seq, 1);
    expect(r2.seq, 2);

    ctrl.deleteRecord(r1.id);
    final r3 = ctrl.addRecord(type: RecordType.tts);
    expect(r3.seq, 3);
    expect(store.loadRecords(ctrl.session.id).map((r) => r.seq), [2, 3]);
  });

  test('旧记录加载时按创建顺序补写序号', () {
    final temp = Directory.systemTemp.createTempSync('session_seq_legacy_');
    addTearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final store = SessionStore(AppPaths(temp));
    final session = store.createSession();
    store.saveMeta(session);
    store.saveRecord(
      session.id,
      GenerationRecord(
        id: 'r1',
        type: RecordType.tts,
        createdAtMs: 1000,
      ),
    );
    store.saveRecord(
      session.id,
      GenerationRecord(
        id: 'r2',
        type: RecordType.tts,
        createdAtMs: 2000,
      ),
    );

    expect(store.loadRecords(session.id).map((r) => r.seq), [1, 2]);
    expect(store.loadRecords(session.id).map((r) => r.seq), [1, 2]);
  });
}
