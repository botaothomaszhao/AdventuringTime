import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'storage.dart';

/// 局域网同步（§7）：单元模型、清单构建、打包/落盘、合并逻辑。
/// Windows 服务器只做文件读写，合并决策全部在客户端执行（两端同一套逻辑）。

/// 同步单元描述（§7.2）。
class SyncUnit {
  final String type; // profile | trip | life | media
  final String unitId;
  final DateTime updatedAt;
  final String sha256;
  final int size;
  final bool deleted;

  const SyncUnit({
    required this.type,
    required this.unitId,
    required this.updatedAt,
    this.sha256 = '',
    this.size = 0,
    this.deleted = false,
  });

  String get key => '$type:$unitId';

  Map<String, dynamic> toJson() => {
        'type': type,
        'unitId': unitId,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'sha256': sha256,
        'size': size,
        'deleted': deleted,
      };

  factory SyncUnit.fromJson(Map<String, dynamic> j) => SyncUnit(
        type: j['type'] as String,
        unitId: j['unitId'] as String,
        updatedAt: DateTime.parse(j['updatedAt'] as String),
        sha256: j['sha256'] as String? ?? '',
        size: (j['size'] as num?)?.toInt() ?? 0,
        deleted: j['deleted'] as bool? ?? false,
      );
}

class PersonBrief {
  final String id;
  final String name;
  final DateTime updatedAt;

  PersonBrief({required this.id, required this.name, required this.updatedAt});
}

/// 远端抽象：HTTP 服务器（HttpSyncRemote）或本地目录（DirSyncRemote，导入合并用）。
abstract class SyncRemote {
  Future<List<PersonBrief>> people();
  Future<List<SyncUnit>> manifest(String personId);
  Future<List<int>> fetchUnit(String personId, SyncUnit unit);
  Future<void> pushUnit(String personId, SyncUnit unit, List<int> bytes);

  /// 同步前让远端（服务器）备份其全部数据，双端都在合并前留快照。
  Future<void> backupAll() async {}
}

String _sha(List<int> b) => sha256.convert(b).toString();

// ---------- 清单构建 ----------

/// 构建本地同步清单：profile/life/各行程/媒体池 + 墓碑（已回到磁盘的墓碑忽略）。
Future<List<SyncUnit>> buildManifest(PersonRepository repo) async {
  final units = <SyncUnit>[];
  final profile = File(p.join(repo.root.path, 'profile.json'));
  if (await profile.exists()) {
    final b = await profile.readAsBytes();
    final person = await repo.loadPerson();
    units.add(SyncUnit(
        type: 'profile', unitId: 'profile', updatedAt: person.updatedAt, sha256: _sha(b), size: b.length));
  }
  final life = File(p.join(repo.root.path, 'life.gpx'));
  if (await life.exists()) {
    final b = await life.readAsBytes();
    units.add(SyncUnit(
        type: 'life',
        unitId: 'life',
        updatedAt: await repo.lifeUpdatedAt() ?? DateTime.fromMillisecondsSinceEpoch(0),
        sha256: _sha(b),
        size: b.length));
  }
  for (final meta in await repo.listTrips()) {
    final jf = File(p.join(repo.tripDir(meta.id).path, 'trip.json'));
    if (!await jf.exists()) continue;
    final b = await jf.readAsBytes();
    units.add(SyncUnit(type: 'trip', unitId: meta.id, updatedAt: meta.updatedAt, size: b.length));
  }
  for (final f in repo.media.listAll()) {
    final b = await f.readAsBytes();
    units.add(SyncUnit(
        type: 'media',
        unitId: p.basename(f.path),
        updatedAt: f.lastModifiedSync(),
        sha256: _sha(b),
        size: b.length));
  }
  for (final t in await repo.tombstones()) {
    if (units.any((u) => u.type == t.type && u.unitId == t.unitId)) continue;
    units.add(SyncUnit(type: t.type, unitId: t.unitId, updatedAt: t.updatedAt, deleted: true));
  }
  return units;
}

// ---------- 单元打包 / 落盘 ----------

Future<List<int>> packUnit(PersonRepository repo, SyncUnit u) async {
  switch (u.type) {
    case 'profile':
      return File(p.join(repo.root.path, 'profile.json')).readAsBytes();
    case 'life':
      return File(p.join(repo.root.path, 'life.gpx')).readAsBytes();
    case 'media':
      return File(p.join(repo.media.dir.path, u.unitId)).readAsBytes();
    case 'trip':
      return _packTrip(repo, u.unitId);
  }
  throw StateError('未知单元类型 ${u.type}');
}

/// 行程打包为 zip：trip.json + trip.gpx + 该行程引用的媒体。
Future<List<int>> _packTrip(PersonRepository repo, String tripId) async {
  final dir = repo.tripDir(tripId);
  final arch = Archive();
  Future<void> add(String name) async {
    final f = File(p.join(dir.path, name));
    if (await f.exists()) {
      arch.addFile(ArchiveFile(name, 0, await f.readAsBytes())..lastModTime = DateTime.now().millisecondsSinceEpoch ~/ 1000);
    }
  }

  await add('trip.json');
  await add('trip.gpx');
  final bundle = await repo.loadTrip(tripId);
  if (bundle != null) {
    final ids = <String>{
      ...bundle.meta.mediaIds,
      for (final w in bundle.gpx.waypoints) ...w.mediaIds,
      for (final pt in bundle.gpx.paths) ...pt.mediaIds,
    };
    for (final id in ids) {
      final f = repo.media.find(id);
      if (f != null) {
        arch.addFile(ArchiveFile('media/${p.basename(f.path)}', 0, await f.readAsBytes())..lastModTime = DateTime.now().millisecondsSinceEpoch ~/ 1000);
      }
    }
  }
  return Uint8List.fromList(ZipEncoder().encode(arch));
}

/// 落盘单元：覆盖前备份，媒体按 sha 去重，行程清墓碑。
Future<void> writeUnit(PersonRepository repo, SyncUnit u, List<int> bytes) async {
  switch (u.type) {
    case 'profile':
      final f = File(p.join(repo.root.path, 'profile.json'));
      await f.writeAsBytes(bytes, flush: true);
      break;
    case 'life':
      final f = File(p.join(repo.root.path, 'life.gpx'));
      await f.writeAsBytes(bytes, flush: true);
      await repo.setLifeUpdatedAt(u.updatedAt);
      break;
    case 'media':
      final f = File(p.join(repo.media.dir.path, u.unitId));
      if (await f.exists() && u.sha256.isNotEmpty && _sha(await f.readAsBytes()) == u.sha256) return;
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes, flush: true);
      break;
    case 'trip':
      await _writeTrip(repo, u.unitId, bytes);
      break;
  }
}

Future<void> _writeTrip(PersonRepository repo, String tripId, List<int> bytes) async {
  final tmp = await Directory.systemTemp.createTemp('atrip_trip');
  try {
    final arch = ZipDecoder().decodeBytes(bytes);
    for (final f in arch.files) {
      if (!f.isFile) continue;
      final out = File(p.join(tmp.path, f.name));
      await out.parent.create(recursive: true);
      await out.writeAsBytes(f.content as List<int>, flush: true);
    }
    final dir = repo.tripDir(tripId);
    await dir.create(recursive: true);
    Future<void> put(String name) async {
      final src = File(p.join(tmp.path, name));
      if (await src.exists()) await src.copy(p.join(dir.path, name));
    }

    await put('trip.json');
    await put('trip.gpx');
    final mediaDir = Directory(p.join(tmp.path, 'media'));
    if (await mediaDir.exists()) {
      await for (final e in mediaDir.list()) {
        if (e is! File) continue;
        final dst = File(p.join(repo.media.dir.path, p.basename(e.path)));
        if (!await dst.exists()) await e.copy(dst.path);
      }
    }
    await repo.clearTombstone('trip', tripId);
  } finally {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  }
}

/// 物理删除单元：备份 + 删除 + 记录墓碑（供墓碑传播与服务器接收删除用）。
Future<void> deleteUnit(PersonRepository repo, SyncUnit u) async {
  switch (u.type) {
    case 'trip':
      await repo.deleteTrip(u.unitId); // deleteTrip 内部已备份并记录墓碑
      break;
    case 'life':
      final f = File(p.join(repo.root.path, 'life.gpx'));
      if (await f.exists()) await f.delete();
      await repo.setLifeUpdatedAt(DateTime.fromMillisecondsSinceEpoch(0));
      break;
    case 'media':
      final f = File(p.join(repo.media.dir.path, u.unitId));
      if (await f.exists()) await f.delete();
      await repo.recordTombstone('media', u.unitId);
      break;
    case 'profile':
      break; // 人物整包不随单元删除
  }
}

// ---------- 合并逻辑（§7.4，两端共用）----------

class SyncSummary {
  int pulled = 0;
  int pushed = 0;
  int deleted = 0;
  int skipped = 0;
}

/// 与远端合并一个人的数据。local 不存在时自动创建目录。
Future<SyncSummary> mergePerson(PersonRepository local, SyncRemote remote, String personId) async {
  await local.root.create(recursive: true);
  await local.backupAll();
  final summary = SyncSummary();
  final localUnits = await buildManifest(local);
  final remoteUnits = await remote.manifest(personId);
  final localMap = {for (final u in localUnits) u.key: u};
  final remoteMap = {for (final u in remoteUnits) u.key: u};
  final keys = {...localMap.keys, ...remoteMap.keys};

  for (final key in keys) {
    final l = localMap[key];
    final r = remoteMap[key];
    if (l == null) {
      if (r!.deleted) {
        summary.skipped++;
      } else {
        await writeUnit(local, r, await remote.fetchUnit(personId, r));
        summary.pulled++;
      }
    } else if (r == null) {
      final bytes = l.deleted ? const <int>[] : await packUnit(local, l);
      await remote.pushUnit(personId, l, bytes);
      summary.pushed++;
    } else if (r.deleted && !l.deleted) {
      await deleteUnit(local, l);
      summary.deleted++;
    } else if (l.deleted && !r.deleted) {
      await remote.pushUnit(personId, l, const <int>[]);
      summary.pushed++;
    } else if (l.deleted && r.deleted) {
      summary.skipped++;
    } else {
      // 双方均存活：sha 相同跳过，否则 updatedAt 新者胜（被覆盖方旧版入备份）
      if (l.sha256.isNotEmpty && l.sha256 == r.sha256) {
        summary.skipped++;
      } else if (r.updatedAt.isAfter(l.updatedAt)) {
        await writeUnit(local, r, await remote.fetchUnit(personId, r));
        summary.pulled++;
      } else if (l.updatedAt.isAfter(r.updatedAt)) {
        await remote.pushUnit(personId, l, await packUnit(local, l));
        summary.pushed++;
      } else {
        summary.skipped++;
      }
    }
  }

  // 媒体按引用补齐（§7.4 步骤 3）：life/行程引用的媒体本地缺失则从远端拉。
  for (final id in await _missingReferencedMedia(local)) {
    final u = remoteUnits
        .where((x) => x.type == 'media' && p.basenameWithoutExtension(x.unitId) == id)
        .firstOrNull;
    if (u != null) {
      await writeUnit(local, u, await remote.fetchUnit(personId, u));
      summary.pulled++;
    }
  }

  await local.setLastSyncAt(DateTime.now());
  return summary;
}

/// 本地数据引用但媒体池缺失的 mediaId 集合。
Future<Set<String>> _missingReferencedMedia(PersonRepository repo) async {
  final ids = await repo.referencedMediaIds();
  return {for (final id in ids) if (repo.media.find(id) == null) id};
}

/// 本地与远端全部人物并集，逐个合并。
Future<Map<String, SyncSummary>> syncAll(AppRepository local, SyncRemote remote) async {
  await remote.backupAll();
  final localPeople = await local.listPeople();
  final remotePeople = await remote.people();
  final ids = {
    for (final p in localPeople) p.id,
    for (final p in remotePeople) p.id,
  };
  final result = <String, SyncSummary>{};
  for (final id in ids) {
    result[id] = await mergePerson(PersonRepository(local.personDir(id)), remote, id);
  }
  return result;
}

// ---------- 远端实现 ----------

/// HTTP 远端（Android 客户端 / Windows 对另一台 Windows 同步）。
class HttpSyncRemote implements SyncRemote {
  final String baseUrl; // http://192.168.1.5:8024
  final http.Client _client;

  HttpSyncRemote(this.baseUrl, {http.Client? client}) : _client = client ?? http.Client();

  void _check(http.Response r) {
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw HttpException('HTTP ${r.statusCode}${r.body.isNotEmpty ? ': ${r.body}' : ''}');
    }
  }

  @override
  Future<List<PersonBrief>> people() async {
    final r = await _client.get(Uri.parse('$baseUrl/api/people'));
    _check(r);
    final list = jsonDecode(r.body) as List;
    return [
      for (final j in list)
        PersonBrief(
          id: j['id'] as String,
          name: j['name'] as String? ?? '',
          updatedAt: DateTime.parse(j['updatedAt'] as String),
        ),
    ];
  }

  @override
  Future<List<SyncUnit>> manifest(String personId) async {
    final r = await _client.get(Uri.parse('$baseUrl/api/person/$personId/manifest'));
    _check(r);
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return [for (final u in (j['units'] as List? ?? [])) SyncUnit.fromJson(u as Map<String, dynamic>)];
  }

  @override
  Future<List<int>> fetchUnit(String personId, SyncUnit unit) async {
    final r = await _client.get(Uri.parse(
        '$baseUrl/api/person/$personId/unit?type=${unit.type}&unitId=${Uri.encodeQueryComponent(unit.unitId)}'));
    _check(r);
    return r.bodyBytes;
  }

  @override
  Future<void> pushUnit(String personId, SyncUnit unit, List<int> bytes) async {
    final q = <String, String>{
      'type': unit.type,
      'unitId': unit.unitId,
      'updatedAt': unit.updatedAt.toUtc().millisecondsSinceEpoch.toString(),
      if (unit.deleted) 'deleted': '1',
      if (bytes.isNotEmpty) 'sha256': _sha(bytes),
    };
    final qs = q.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&');
    final r = await _client.post(
      Uri.parse('$baseUrl/api/person/$personId/unit?$qs'),
      headers: {'content-type': 'application/octet-stream'},
      body: bytes,
    );
    _check(r);
  }

  @override
  Future<void> backupAll() async {
    final r = await _client.post(Uri.parse('$baseUrl/api/backup'));
    _check(r);
  }

  /// 探测服务器信息（/api/ping）。
  Future<Map<String, dynamic>> ping() async {
    final r = await _client.get(Uri.parse('$baseUrl/api/ping'));
    _check(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }
}

/// 本地目录远端（导入整包合并复用，personId 恒为该目录人物）。
class DirSyncRemote implements SyncRemote {
  final PersonRepository repo;

  DirSyncRemote(this.repo);

  @override
  Future<List<PersonBrief>> people() async {
    final person = await repo.loadPerson();
    return [PersonBrief(id: person.id, name: person.name, updatedAt: person.updatedAt)];
  }

  @override
  Future<List<SyncUnit>> manifest(String personId) => buildManifest(repo);

  @override
  Future<List<int>> fetchUnit(String personId, SyncUnit unit) => packUnit(repo, unit);

  @override
  Future<void> pushUnit(String personId, SyncUnit unit, List<int> bytes) async {
    if (unit.deleted) return;
    await writeUnit(repo, unit, bytes);
  }

  @override
  Future<void> backupAll() async {}
}
