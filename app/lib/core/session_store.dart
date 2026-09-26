import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_paths.dart';
import '../models/session.dart';

/// 会话/记录的持久化。目录布局（相对 data/history）：
/// ```
/// <sid>.json                 会话 meta（小，列表只读它）
/// records/<sid>/<rid>.json   记录 meta
/// audio/<sid>/<rid>.wav      记录音频（与记录分离）
/// ```
class SessionStore {
  SessionStore(this.paths);

  final AppPaths paths;

  Directory get baseDir => paths.historyDir;
  Directory get _recordsRoot => Directory(p.join(baseDir.path, 'records'));
  Directory get _audioRoot => Directory(p.join(baseDir.path, 'audio'));
  Directory get _collectionsRoot =>
      Directory(p.join(baseDir.path, 'collections'));

  File metaFile(String sid) => File(p.join(baseDir.path, '$sid.json'));
  File collectionFile(String cid) =>
      File(p.join(_collectionsRoot.path, '$cid.json'));
  Directory recordsDir(String sid) => Directory(p.join(_recordsRoot.path, sid));
  Directory audioDir(String sid) => Directory(p.join(_audioRoot.path, sid));

  String audioPath(String sid, String rid) =>
      p.join(audioDir(sid).path, '$rid.wav');

  String relativeAudioPath(String sid, String rid) =>
      p.join('audio', sid, '$rid.wav');

  /// 可排序、唯一的 id：yyyyMMdd-HHmmss-SSS（毫秒冲突时追加序号）。
  static String newId([DateTime? at]) {
    final now = at ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}'
        '-${three(now.millisecond)}';
  }

  /// 创建（仅内存）会话，不落盘；有记录后再由调用方 [saveMeta]。
  Session createSession({DateTime? at}) {
    final now = at ?? DateTime.now();
    var id = newId(now);
    var n = 0;
    while (metaFile(id).existsSync()) {
      n++;
      id = '${newId(now)}-$n';
    }
    return Session(
      id: id,
      createdAtMs: now.millisecondsSinceEpoch,
      updatedAtMs: now.millisecondsSinceEpoch,
    );
  }

  void saveMeta(Session s) => _writeJson(metaFile(s.id), s.metaJson());

  void saveRecord(String sid, GenerationRecord r) {
    final dir = recordsDir(sid);
    dir.createSync(recursive: true);
    _writeJson(File(p.join(dir.path, '${r.id}.json')), r.toJson());
  }

  List<SessionSummary> listSessions() {
    if (!baseDir.existsSync()) return const [];
    final out = <SessionSummary>[];
    for (final e in baseDir.listSync(followLinks: false)) {
      if (e is! File || !e.path.toLowerCase().endsWith('.json')) continue;
      try {
        final j = jsonDecode(e.readAsStringSync()) as Map<String, dynamic>;
        if (j['id'] is! String) continue;
        final recordCount = (j['record_count'] as num?)?.toInt() ?? 0;
        // 空会话不进入历史（至少一条记录）。
        if (recordCount <= 0) continue;
        out.add(SessionSummary(
          id: j['id'] as String,
          name: j['name'] as String? ?? '',
          createdAtMs: (j['created_at_ms'] as num?)?.toInt() ?? 0,
          updatedAtMs: (j['updated_at_ms'] as num?)?.toInt() ?? 0,
          recordCount: recordCount,
        ));
      } catch (_) {}
    }
    out.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    return out;
  }

  Session? loadSession(String sid) {
    final f = metaFile(sid);
    if (!f.existsSync()) return null;
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final s = Session(
        id: sid,
        name: j['name'] as String? ?? '',
        collectionId: j['collection_id'] as String?,
        createdAtMs: (j['created_at_ms'] as num?)?.toInt() ?? 0,
        updatedAtMs: (j['updated_at_ms'] as num?)?.toInt() ?? 0,
      );
      s.records.addAll(loadRecords(sid));
      return s;
    } catch (_) {
      return null;
    }
  }

  /// 更新（或清除）某会话 meta 的 collection_id；会话未落盘则忽略。
  void setSessionCollectionMeta(String sid, String? cid) {
    final f = metaFile(sid);
    if (!f.existsSync()) return;
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      if (cid == null || cid.isEmpty) {
        j.remove('collection_id');
      } else {
        j['collection_id'] = cid;
      }
      _writeJson(f, j);
    } catch (_) {}
  }

  // ---- 集合 ----

  Collection createCollection({String name = ''}) {
    final now = DateTime.now();
    var id = newId(now);
    var n = 0;
    while (collectionFile(id).existsSync()) {
      n++;
      id = '${newId(now)}-$n';
    }
    final c = Collection(
      id: id,
      name: name,
      createdAtMs: now.millisecondsSinceEpoch,
      updatedAtMs: now.millisecondsSinceEpoch,
    );
    saveCollection(c);
    return c;
  }

  void saveCollection(Collection c) =>
      _writeJson(collectionFile(c.id), c.toJson());

  void deleteCollectionFile(String cid) {
    try {
      final f = collectionFile(cid);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  List<Collection> listCollections() {
    if (!_collectionsRoot.existsSync()) return const [];
    final out = <Collection>[];
    for (final e in _collectionsRoot.listSync()) {
      if (e is! File || !e.path.toLowerCase().endsWith('.json')) continue;
      try {
        out.add(Collection.fromJson(
            jsonDecode(e.readAsStringSync()) as Map<String, dynamic>));
      } catch (_) {}
    }
    out.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    return out;
  }

  List<GenerationRecord> loadRecords(String sid) {
    final dir = recordsDir(sid);
    if (!dir.existsSync()) return const [];
    final recs = <GenerationRecord>[];
    for (final e in dir.listSync()) {
      if (e is! File || !e.path.toLowerCase().endsWith('.json')) continue;
      try {
        final r = GenerationRecord.fromJson(
            jsonDecode(e.readAsStringSync()) as Map<String, dynamic>);
        // 意外中断（刚载入就有 generating，只能是上次未完成）：回退为"排队"，
        // 不自动启动；并清掉可能残留的输出（脏数据）。
        if (r.status == 'generating') {
          r.status = 'queued';
          r.outputs.clear();
          _writeJson(File(e.path), r.toJson());
        }
        recs.add(r);
      } catch (_) {}
    }
    recs.sort((a, b) => a.createdAtMs.compareTo(b.createdAtMs));
    return recs;
  }

  void deleteRecord(String sid, String rid) {
    try {
      final rf = File(p.join(recordsDir(sid).path, '$rid.json'));
      if (rf.existsSync()) rf.deleteSync();
    } catch (_) {}
    try {
      final af = File(audioPath(sid, rid));
      if (af.existsSync()) af.deleteSync();
    } catch (_) {}
  }

  /// 删除记录后同步会话统计；为空则删除整个会话（meta/records/audio）。
  void syncSessionAfterRecordDelete(String sid) {
    final count = loadRecords(sid).length;
    if (count == 0) {
      deleteSession(sid);
      return;
    }
    final f = metaFile(sid);
    if (!f.existsSync()) return;
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      j['record_count'] = count;
      _writeJson(f, j);
    } catch (_) {}
  }

  void deleteSession(String sid) {
    try {
      final mf = metaFile(sid);
      if (mf.existsSync()) mf.deleteSync();
    } catch (_) {}
    for (final d in [recordsDir(sid), audioDir(sid)]) {
      try {
        if (d.existsSync()) d.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  void renameSession(String sid, String name) {
    final f = metaFile(sid);
    if (!f.existsSync()) return;
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      j['name'] = name;
      _writeJson(f, j);
    } catch (_) {}
  }

  void clearAll() {
    if (!baseDir.existsSync()) return;
    for (final e in baseDir.listSync()) {
      try {
        if (e is File && e.path.toLowerCase().endsWith('.json')) {
          e.deleteSync();
        } else if (e is Directory) {
          e.deleteSync(recursive: true);
        }
      } catch (_) {}
    }
  }

  void _writeJson(File f, Map<String, dynamic> json) {
    f.parent.createSync(recursive: true);
    final tmp = '${f.path}.tmp';
    File(tmp).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(json)}\n',
      encoding: utf8,
    );
    File(tmp).renameSync(f.path);
  }
}
