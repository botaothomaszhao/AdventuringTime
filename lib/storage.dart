import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'gpx_io.dart';
import 'models.dart';

/// 数据根目录解析。Windows 默认 %USERPROFILE%\AdventuringTime\data（设置中可改），
/// Android 用应用私有目录。两端目录结构一致。
Future<Directory> resolveDataRoot() async {
  final prefs = await SharedPreferences.getInstance();
  final custom = prefs.getString('dataRoot');
  if (custom != null && custom.isNotEmpty) {
    return Directory(custom);
  }
  if (Platform.isWindows) {
    final home = Platform.environment['USERPROFILE'] ?? '.';
    return Directory(p.join(home, 'AdventuringTime', 'data'));
  }
  final dir = await getApplicationSupportDirectory();
  return Directory(p.join(dir.path, 'data'));
}

Future<void> setDataRoot(String? path) async {
  final prefs = await SharedPreferences.getInstance();
  if (path == null || path.isEmpty) {
    await prefs.remove('dataRoot');
  } else {
    await prefs.setString('dataRoot', path);
  }
}

/// 单一媒体文件读写。文件名 `mediaId.<ext>`，引用只存 mediaId（不含扩展名），
/// 读取时按前缀扫描。不做引用计数/去重，删除即物理删除，允许悬空引用。
class MediaStore {
  final Directory dir;

  MediaStore(this.dir);

  File? find(String mediaId) {
    if (!dir.existsSync()) return null;
    final name = mediaId.split('.').first;
    final l = dir.listSync().where((f) => f is File && p.basenameWithoutExtension(f.path) == name).toList();
    return l.isEmpty ? null : l.first as File;
  }

  /// 写入媒体，返回 mediaId（不含扩展名）。
  Future<String> write(String ext, List<int> bytes) async {
    final id = newId();
    final f = File(p.join(dir.path, '$id.$ext'));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes, flush: true);
    return id;
  }

  /// 按现有文件复制进池，返回 mediaId。
  Future<String> import(File src) async {
    final id = newId();
    final ext = p.extension(src.path).replaceFirst('.', '');
    final f = File(p.join(dir.path, '$id.$ext'));
    await f.parent.create(recursive: true);
    await src.copy(f.path);
    return id;
  }

  Future<void> delete(String mediaId) async {
    final f = find(mediaId);
    if (f != null) await f.delete();
  }

  List<File> listAll() {
    if (!dir.existsSync()) return [];
    return dir.listSync().whereType<File>().where((f) => p.extension(f.path).isNotEmpty).toList();
  }
}

class PersonRepository {
  final Directory root; // people/<personId>
  late final MediaStore media = MediaStore(Directory(p.join(root.path, 'media')));

  PersonRepository(this.root);

  static PersonRepository of(Directory peopleRoot, String personId) =>
      PersonRepository(Directory(p.join(peopleRoot.path, personId)));

  // ---------- profile ----------

  Future<Person> loadPerson() async {
    final f = File(p.join(root.path, 'profile.json'));
    if (!await f.exists()) {
      final now = DateTime.now();
      return Person(id: p.basename(root.path), name: '未命名', createdAt: now, updatedAt: now);
    }
    return Person.fromJson(_readJson(f));
  }

  Future<void> savePerson(Person person) async {
    person.updatedAt = DateTime.now();
    await _writeJson(File(p.join(root.path, 'profile.json')), person.toJson());
  }

  // ---------- life.gpx ----------

  Future<GpxFile> loadLife() async {
    final f = File(p.join(root.path, 'life.gpx'));
    if (!await f.exists()) return GpxFile();
    return parseGpx(await f.readAsString());
  }

  Future<void> saveLife(GpxFile gpx) async {
    final f = File(p.join(root.path, 'life.gpx'));
    await f.writeAsString(toGpx(gpx), flush: true);
    await setLifeUpdatedAt(DateTime.now());
  }

  // ---------- trips ----------

  Directory get tripsDir => Directory(p.join(root.path, 'trips'));

  Directory tripDir(String tripId) => Directory(p.join(tripsDir.path, tripId));

  /// 列出全部行程的元数据（只读 trip.json，不存在时回退读 trip.gpx metadata）。
  Future<List<Trip>> listTrips() async {
    final d = tripsDir;
    if (!await d.exists()) return [];
    final out = <Trip>[];
    for (final e in await d.list().toList()) {
      if (e is! Directory) continue;
      final meta = await loadTripMeta(p.basename(e.path));
      if (meta != null) out.add(meta);
    }
    out.sort((a, b) => (a.startDate ?? a.createdAt).compareTo(b.startDate ?? b.createdAt));
    return out;
  }

  Future<Trip?> loadTripMeta(String tripId) async {
    final jf = File(p.join(tripDir(tripId).path, 'trip.json'));
    if (await jf.exists()) return Trip.fromJson(_readJson(jf));
    final gf = File(p.join(tripDir(tripId).path, 'trip.gpx'));
    if (await gf.exists()) return parseGpx(await gf.readAsString()).metadataTrip;
    return null;
  }

  /// 行程完整加载：trip.json 优先，回退 trip.gpx metadata。
  Future<TripBundle?> loadTrip(String tripId) async {
    final meta = await loadTripMeta(tripId);
    if (meta == null) return null;
    final gf = File(p.join(tripDir(tripId).path, 'trip.gpx'));
    final gpx = await gf.exists() ? parseGpx(await gf.readAsString()) : GpxFile();
    return TripBundle(meta: meta, gpx: gpx);
  }

  Future<void> saveTrip(TripBundle bundle) async {
    final dir = tripDir(bundle.meta.id);
    await dir.create(recursive: true);
    final jf = File(p.join(dir.path, 'trip.json'));
    final gf = File(p.join(dir.path, 'trip.gpx'));
    bundle.meta.updatedAt = DateTime.now();
    await _writeJson(jf, bundle.meta.toJson());
    await gf.writeAsString(toGpx(bundle.gpx, trip: bundle.meta), flush: true);
  }

  Future<void> deleteTrip(String tripId) async {
    final dir = tripDir(tripId);
    if (await dir.exists()) await dir.delete(recursive: true);
    await recordTombstone('trip', tripId);
    await pruneOrphanMedia();
  }

  // ---------- 备份 ----------

  static String _timestamp() {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  /// 全量备份：仅复制 profile/life/各行程（媒体不进备份，始终留在共用媒体池），
  /// 存到 `backups/<ts>[-<suffix>]/`（同步前、覆盖导入前与手动触发时调用）。
  Future<void> backupAll({String? suffix}) async {
    final name = suffix == null ? _timestamp() : '${_timestamp()}-$suffix';
    final dest = Directory(p.join(root.path, 'backups', name));
    await dest.create(recursive: true);
    Future<void> put(String name, File src) async {
      if (await src.exists()) await src.copy(p.join(dest.path, name));
    }

    await put('profile.json', File(p.join(root.path, 'profile.json')));
    await put('life.gpx', File(p.join(root.path, 'life.gpx')));
    for (final meta in await listTrips()) {
      await put('trip_${meta.id}.json', File(p.join(tripDir(meta.id).path, 'trip.json')));
      await put('trip_${meta.id}.gpx', File(p.join(tripDir(meta.id).path, 'trip.gpx')));
    }
  }

  /// 列出备份时间戳，用于"从备份恢复"。
  Future<List<String>> listBackups() async {
    final d = Directory(p.join(root.path, 'backups'));
    if (!await d.exists()) return [];
    final l = await d.list().toList();
    return l.whereType<Directory>().map((e) => p.basename(e.path)).toList()
      ..sort((a, b) => b.compareTo(a));
  }

  /// 从指定备份恢复单元（目录名如 `trip_xxx` 或 `life.gpx` 或 `media_xxx.ext`）。
  /// 备份文件本身不被修改。
  Future<void> restoreBackup(String timestamp, String unitName) async {
    final src = FileSystemEntity.typeSync(
        p.join(root.path, 'backups', timestamp, unitName)) ==
            FileSystemEntityType.directory
        ? Directory(p.join(root.path, 'backups', timestamp, unitName)) as FileSystemEntity
        : File(p.join(root.path, 'backups', timestamp, unitName)) as FileSystemEntity;
    if (!await src.exists()) return;
    final target = switch (unitName) {
      'life.gpx' => File(p.join(root.path, 'life.gpx')),
      String s when s.startsWith('trip_') && s.endsWith('.json') =>
        File(p.join(tripDir(s.substring(5, s.length - 5)).path, 'trip.json')),
      String s when s.startsWith('trip_') && s.endsWith('.gpx') =>
        File(p.join(tripDir(s.substring(5, s.length - 4)).path, 'trip.gpx')),
      String s when s.startsWith('trip_') =>
        tripDir(s.substring(5)),
      String s when s.startsWith('media_') =>
        File(p.join(media.dir.path, s.substring(6))),
      _ => File(p.join(root.path, unitName)),
    };
    await _copyTree(src, target);
  }

  /// 把某备份时间戳下的全部单元恢复到当前数据（跳过恢复前自动备份单元，备份文件不动）。
  Future<void> restoreBackupAll(String timestamp) async {
    final d = Directory(p.join(root.path, 'backups', timestamp));
    if (!await d.exists()) return;
    for (final e in await d.list().toList()) {
      final n = p.basename(e.path);
      if (n.startsWith('restore_')) continue;
      await restoreBackup(timestamp, n);
    }
  }

  /// 删除某备份时间戳目录，随后清理孤儿媒体。
  Future<void> deleteBackup(String timestamp) async {
    final d = Directory(p.join(root.path, 'backups', timestamp));
    if (await d.exists()) await d.delete(recursive: true);
    await pruneOrphanMedia();
  }

  /// 扫描当前数据与全部备份的媒体引用，未被引用的媒体物理删除。
  Future<void> pruneOrphanMedia() async {
    final used = await referencedMediaIds();
    for (final ts in await listBackups()) {
      used.addAll(await collectReferencedMediaIds(Directory(p.join(root.path, 'backups', ts))));
    }
    for (final f in media.listAll()) {
      if (!used.contains(p.basenameWithoutExtension(f.path))) {
        await f.delete();
      }
    }
  }

  /// 当前数据（profile/life/行程）引用的 mediaId 集合。
  Future<Set<String>> referencedMediaIds() => collectReferencedMediaIds(root);

  /// 媒体是否在任一备份中被引用（备份只存 gpx/json 引用，不含媒体文件）。
  Future<bool> mediaReferencedInBackups(String mediaId) async {
    for (final ts in await listBackups()) {
      if ((await collectReferencedMediaIds(Directory(p.join(root.path, 'backups', ts)))).contains(mediaId)) {
        return true;
      }
    }
    return false;
  }

  // ---------- 同步状态（manifest.json）----------

  File get manifestFile => File(p.join(root.path, 'manifest.json'));

  Future<Map<String, dynamic>> _readManifest() async {
    final f = manifestFile;
    if (!await f.exists()) return {};
    return _readJson(f);
  }

  Future<void> _writeManifest(Map<String, dynamic> m) async {
    await manifestFile.parent.create(recursive: true);
    await manifestFile.writeAsString(toJsonString(m), flush: true);
  }

  Future<List<SyncTombstone>> tombstones() async {
    final j = await _readManifest();
    return [
      for (final t in (j['tombstones'] as List? ?? []))
        SyncTombstone.fromJson(t as Map<String, dynamic>),
    ];
  }

  Future<void> recordTombstone(String type, String unitId) async {
    final j = await _readManifest();
    final list = [
      for (final t in (j['tombstones'] as List? ?? []))
        if (t is Map && t['type'] != type || (t is Map && t['unitId'] != unitId))
          SyncTombstone.fromJson(t as Map<String, dynamic>),
    ];
    list.add(SyncTombstone(type: type, unitId: unitId, updatedAt: DateTime.now()));
    j['tombstones'] = [for (final t in list) t.toJson()];
    await _writeManifest(j);
  }

  Future<void> clearTombstone(String type, String unitId) async {
    final j = await _readManifest();
    final list = (j['tombstones'] as List? ?? []).cast<Map>();
    final before = list.length;
    list.removeWhere((t) => t['type'] == type && t['unitId'] == unitId);
    if (list.length == before) return;
    j['tombstones'] = list;
    await _writeManifest(j);
  }

  /// life.gpx 的同步时间戳：写文件时更新，同步拉取时设为对方值。
  Future<void> setLifeUpdatedAt(DateTime t) async {
    final j = await _readManifest();
    j['lifeUpdatedAt'] = t.toUtc().toIso8601String();
    await _writeManifest(j);
  }

  Future<DateTime?> lifeUpdatedAt() async {
    final s = (await _readManifest())['lifeUpdatedAt'] as String?;
    return s == null ? null : DateTime.tryParse(s);
  }

  Future<void> setLastSyncAt(DateTime t) async {
    final j = await _readManifest();
    j['lastSyncAt'] = t.toUtc().toIso8601String();
    await _writeManifest(j);
  }

  Future<DateTime?> lastSyncAt() async {
    final s = (await _readManifest())['lastSyncAt'] as String?;
    return s == null ? null : DateTime.tryParse(s);
  }

  /// 复制文件或目录树到目标路径（类型一致）。
  static Future<void> _copyTree(FileSystemEntity src, FileSystemEntity dest) async {
    if (src is File) {
      await Directory(p.dirname(dest.path)).create(recursive: true);
      await src.copy(dest.path);
    } else if (src is Directory) {
      await (dest as Directory).create(recursive: true);
      await for (final e in src.list()) {
        await _copyTree(e, Directory(p.join(dest.path, p.basename(e.path))));
      }
    }
  }

  Map<String, dynamic> _readJson(File f) {
    try {
      final m = jsonDecode(f.readAsStringSync());
      return m as Map<String, dynamic>;
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<void> _writeJson(File f, Map<String, dynamic> m) async {
    await f.writeAsString(toJsonString(m), flush: true);
  }
}

/// 收集目录中所有 gpx/json 引用的 mediaId 集合（用于导出只打被引用媒体、孤儿清理）。
/// 兼容数据目录（profile.json/life.gpx/trips/<id>/…）与备份目录（顶层平铺）两种布局；
/// 跳过 media/ 与 backups/ 目录。媒体引用来自 Waypoint/PathData.mediaIds、Trip.mediaIds、Person.avatar。
Future<Set<String>> collectReferencedMediaIds(Directory root) async {
  final ids = <String>{};
  Future<void> scan(FileSystemEntity e) async {
    if (e is File) {
      final n = p.basename(e.path);
      if (n.endsWith('.gpx')) {
        final g = parseGpx(await e.readAsString());
        for (final w in g.waypoints) {
          ids.addAll(w.mediaIds);
        }
        for (final pt in g.paths) {
          ids.addAll(pt.mediaIds);
        }
      } else if (n.endsWith('.json')) {
        final m = jsonDecode(await e.readAsString()) as Map<String, dynamic>;
        final av = m['avatar'];
        if (av is String && av.isNotEmpty) ids.add(av);
        final ml = m['mediaIds'];
        if (ml is List) {
          for (final v in ml) {
            if (v is String && v.isNotEmpty) ids.add(v);
          }
        }
      }
    } else if (e is Directory) {
      final name = p.basename(e.path);
      if (name == 'media' || name == 'backups') return;
      for (final c in await e.list().toList()) {
        await scan(c);
      }
    }
  }

  await scan(root);
  return ids;
}

/// 全局仓库：人列表的枚举与增删。
class AppRepository {
  final Directory peopleRoot;

  AppRepository(this.peopleRoot);

  Directory personDir(String personId) => Directory(p.join(peopleRoot.path, personId));

  Future<List<Person>> listPeople() async {
    if (!await peopleRoot.exists()) return [];
    final out = <Person>[];
    for (final e in await peopleRoot.list().toList()) {
      if (e is! Directory) continue;
      final name = p.basename(e.path);
      if (name.startsWith('.')) continue;
      out.add(await PersonRepository(e).loadPerson());
    }
    out.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return out;
  }

  Future<Person> createPerson(String name, {String? bio}) async {
    final now = DateTime.now();
    final id = newId();
    final person = Person(id: id, name: name, bio: bio, createdAt: now, updatedAt: now);
    final dir = personDir(id);
    await dir.create(recursive: true);
    await PersonRepository(dir).savePerson(person);
    return person;
  }

  /// 删除人员：连同 backups 一起物理删除整个 person 目录。
  Future<void> deletePerson(String personId) async {
    final dir = personDir(personId);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
