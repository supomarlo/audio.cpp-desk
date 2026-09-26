import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../core/session_store.dart';
import '../models/session.dart';
import 'app_providers.dart';

final sessionStoreProvider = Provider<SessionStore>(
    (ref) => SessionStore(ref.watch(appPathsProvider)));

/// 当前会话（ChangeNotifier：字段可变，变更后 notifyListeners + 落盘）。
class CurrentSessionController extends ChangeNotifier {
  CurrentSessionController(this._store) : session = _store.createSession();

  final SessionStore _store;
  Session session;
  bool _persisted = false;

  void _touch() {
    session.updatedAtMs = DateTime.now().millisecondsSinceEpoch;
    if (_persisted) _store.saveMeta(session);
    notifyListeners();
  }

  GenerationRecord addRecord({
    required String type,
    String family = '',
    String packageId = '',
    Map<String, String>? inputs,
    String status = 'generating',
  }) {
    final r = GenerationRecord(
      id: SessionStore.newId(),
      type: type,
      family: family,
      packageId: packageId,
      status: status,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      inputs: inputs ?? {},
    );
    session.records.add(r);
    // 有第一条记录时才把会话落盘（空会话不进历史）。
    session.updatedAtMs = r.createdAtMs;
    _store.saveMeta(session);
    _persisted = true;
    _store.saveRecord(session.id, r);
    notifyListeners();
    return r;
  }

  void updateRecord(GenerationRecord r) {
    _store.saveRecord(session.id, r);
    _touch();
  }

  /// 用同 id 的新对象替换内存中的记录（队列后台更新时用）。
  void replaceRecord(GenerationRecord r) {
    final i = session.records.indexWhere((x) => x.id == r.id);
    if (i < 0) return;
    session.records[i] = r;
    _store.saveRecord(session.id, r);
    _touch();
  }

  void rename(String name) {
    session.name = name;
    _touch();
  }

  void setCollectionId(String? cid) {
    session.collectionId = cid;
    if (_persisted) _store.saveMeta(session);
    notifyListeners();
  }

  void deleteRecord(String rid) {
    session.records.removeWhere((r) => r.id == rid);
    if (session.records.isEmpty) {
      // 没有记录就不该留在历史里。
      _store.deleteSession(session.id);
      _persisted = false;
    } else {
      _store.deleteRecord(session.id, rid);
    }
    _touch();
  }

  void newSession() {
    session = _store.createSession();
    _persisted = false;
    notifyListeners();
  }

  void openSession(String sid) {
    final s = _store.loadSession(sid);
    if (s != null) {
      session = s;
      _persisted = true;
      notifyListeners();
    }
  }
}

final currentSessionProvider =
    ChangeNotifierProvider<CurrentSessionController>((ref) {
  return CurrentSessionController(ref.watch(sessionStoreProvider));
});

/// 会话列表（按最近活动倒序）。会在当前会话变更后重新扫描。
final sessionListProvider = FutureProvider<List<SessionSummary>>((ref) async {
  ref.watch(currentSessionProvider);
  return ref.watch(sessionStoreProvider).listSessions();
});

/// 集合（Collection）：把会话按顺序分节组织；单归属。
class CollectionsController extends ChangeNotifier {
  CollectionsController(this._store) {
    reload();
  }

  final SessionStore _store;
  List<Collection> collections = const [];

  int _now() => DateTime.now().millisecondsSinceEpoch;

  void reload() {
    collections = _store.listCollections();
    notifyListeners();
  }

  Collection? byId(String cid) {
    for (final c in collections) {
      if (c.id == cid) return c;
    }
    return null;
  }

  Collection? collectionOf(String sid) {
    for (final c in collections) {
      if (c.sessionIds.contains(sid)) return c;
    }
    return null;
  }

  Collection create(String name, {String? addSessionId}) {
    final c = _store.createCollection(name: name);
    if (addSessionId != null && addSessionId.isNotEmpty) {
      c.sessionIds.add(addSessionId);
      _store.saveCollection(c);
      _store.setSessionCollectionMeta(addSessionId, c.id);
    }
    reload();
    return c;
  }

  void rename(String cid, String name) {
    final c = byId(cid);
    if (c == null) return;
    c.name = name;
    c.updatedAtMs = _now();
    _store.saveCollection(c);
    reload();
  }

  void setNote(String cid, String note) {
    final c = byId(cid);
    if (c == null) return;
    c.note = note;
    c.updatedAtMs = _now();
    _store.saveCollection(c);
    reload();
  }

  /// 把会话移入某集合（先从原集合移除）。
  void addSession(String sid, String cid) {
    for (final c in collections) {
      if (c.sessionIds.remove(sid)) {
        c.updatedAtMs = _now();
        _store.saveCollection(c);
      }
    }
    final c = byId(cid);
    if (c != null) {
      if (!c.sessionIds.contains(sid)) c.sessionIds.add(sid);
      c.updatedAtMs = _now();
      _store.saveCollection(c);
      _store.setSessionCollectionMeta(sid, c.id);
    }
    reload();
  }

  void removeSession(String sid) {
    for (final c in collections) {
      if (c.sessionIds.remove(sid)) {
        c.updatedAtMs = _now();
        _store.saveCollection(c);
      }
    }
    _store.setSessionCollectionMeta(sid, null);
    reload();
  }

  void reorder(String cid, List<String> ids) {
    final c = byId(cid);
    if (c == null) return;
    c.sessionIds
      ..clear()
      ..addAll(ids);
    c.updatedAtMs = _now();
    _store.saveCollection(c);
    reload();
  }

  /// 删除集合：默认只解绑（会话保留为未归类）；[deleteSessions] 为真则连同删除会话。
  void delete(String cid, {bool deleteSessions = false}) {
    final c = byId(cid);
    if (c != null) {
      for (final sid in List<String>.of(c.sessionIds)) {
        if (deleteSessions) {
          _store.deleteSession(sid);
        } else {
          _store.setSessionCollectionMeta(sid, null);
        }
      }
    }
    _store.deleteCollectionFile(cid);
    reload();
  }
}

final collectionsProvider =
    ChangeNotifierProvider<CollectionsController>((ref) {
  return CollectionsController(ref.watch(sessionStoreProvider));
});
