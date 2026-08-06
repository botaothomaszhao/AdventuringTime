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
    await backupBefore('life.gpx', f);
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
    await backupBefore('trip_${bundle.meta.id}.json', jf);
    await backupBefore('trip_${bundle.meta.id}.gpx', gf);
    await _writeJson(jf, bundle.meta.toJson());
    await gf.writeAsString(toGpx(bundle.gpx, trip: bundle.meta), flush: true);
  }

  Future<void> deleteTrip(String tripId) async {
    final dir = tripDir(tripId);
    if (await dir.exists()) {
      await backupBefore('trip_$tripId', dir);
      await dir.delete(recursive: true);
    }
    await recordTombstone('trip', tripId);
  }

  // ---------- 备份 ----------

  /// 覆盖/删除前把旧版本整体复制到 `backups/<yyyyMMdd-HHmmss>/`。
  /// src 是文件则备份为单文件，是目录则备份为目录（与 src 类型一致）。
  Future<void> backupBefore(String name, FileSystemEntity src) async {
    if (!await src.exists()) return;
    final ts = _timestamp();
    final dest = FileSystemEntity.typeSync(src.path) == FileSystemEntityType.file
        ? File(p.join(root.path, 'backups', ts, name)) as FileSystemEntity
        : Directory(p.join(root.path, 'backups', ts, name)) as FileSystemEntity;
    await dest.parent.create(recursive: true);
    await _copyTree(src, dest);
  }

  static String _timestamp() {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
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
    if (await target.exists() && target is File) {
      await backupBefore('restore_$unitName', target);
    }
    await _copyTree(src, target);
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

  /// 把整个人目录移到回收目录（data/trash/<时间戳>-<personId>），覆盖导入用。
  Future<void> trashPerson(String personId) async {
    final src = personDir(personId);
    if (!await src.exists()) return;
    final trash = Directory(p.join(peopleRoot.parent.path, 'trash'));
    await trash.create(recursive: true);
    await PersonRepository._copyTree(
        src, Directory(p.join(trash.path, '${DateTime.now().millisecondsSinceEpoch}-$personId')));
    await src.delete(recursive: true);
  }
}
