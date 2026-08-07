import 'dart:io';

import 'package:adventuring_time/gpx_io.dart';
import 'package:adventuring_time/models.dart';
import 'package:adventuring_time/storage.dart';
import 'package:adventuring_time/sync.dart';
import 'package:adventuring_time/transfer.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late Directory peopleRoot;
  late PersonRepository local;
  late PersonRepository remote;

  Future<PersonRepository> mkPerson(String id) async {
    final repo = PersonRepository(Directory(p.join(peopleRoot.path, id)));
    await repo.root.create(recursive: true);
    await repo.savePerson(Person(
        id: id, name: 'p$id', createdAt: DateTime.utc(2024, 1, 1), updatedAt: DateTime.utc(2024, 1, 1)));
    return repo;
  }

  /// 直接写 trip.json（saveTrip 会把 updatedAt 改成当前时间，冲突测试需手工控制）。
  Future<void> writeTripRaw(PersonRepository repo, String id, String name, DateTime updatedAt) async {
    final dir = repo.tripDir(id);
    await dir.create(recursive: true);
    final meta = Trip(
        id: id,
        name: name,
        createdAt: DateTime.utc(2024, 1, 1),
        updatedAt: updatedAt);
    await File(p.join(dir.path, 'trip.json')).writeAsString(toJsonString(meta.toJson()));
    await File(p.join(dir.path, 'trip.gpx')).writeAsString(toGpx(GpxFile()));
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sync_test');
    peopleRoot = Directory(p.join(tmp.path, 'people'));
    await peopleRoot.create(recursive: true);
    local = await mkPerson('a');
    remote = await mkPerson('b');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('并集合并：仅远端有的被拉取，仅本地有的被推送', () async {
    await writeTripRaw(remote, 't1', '远端行程', DateTime.utc(2024, 2, 1));
    final life = GpxFile(waypoints: [
      Waypoint(
          id: 'ev1',
          name: '本地事件',
          latLng: const LatLng(30, 120),
          createdAt: DateTime.utc(2024, 1, 1),
          updatedAt: DateTime.utc(2024, 1, 1)),
    ]);
    await local.saveLife(life);

    final s = await mergePerson(local, DirSyncRemote(remote), 'a');

    expect((await local.loadTrip('t1'))!.meta.name, '远端行程');
    expect((await remote.loadLife()).waypoints.length, 1);
    expect(s.pulled, greaterThanOrEqualTo(1));
    expect(s.pushed, greaterThanOrEqualTo(1));
  });

  test('冲突：updatedAt 新者胜，被覆盖旧版进备份', () async {
    await writeTripRaw(local, 't1', '本地版本', DateTime.utc(2024, 1, 1));
    await writeTripRaw(remote, 't1', '远端版本', DateTime.utc(2024, 1, 2));

    await mergePerson(local, DirSyncRemote(remote), 'a');

    final t = await local.loadTrip('t1');
    expect(t!.meta.name, '远端版本');
    expect(await local.listBackups(), isNotEmpty);
  });

  test('墓碑传播：远端删除行程，本地同步删除并记录墓碑', () async {
    await writeTripRaw(local, 't1', 't1', DateTime.utc(2024, 1, 1));
    await writeTripRaw(remote, 't1', 't1', DateTime.utc(2024, 1, 1));
    await remote.deleteTrip('t1');

    await mergePerson(local, DirSyncRemote(remote), 'a');

    expect(await local.loadTrip('t1'), isNull);
    final ts = await local.tombstones();
    expect(ts.any((t) => t.type == 'trip' && t.unitId == 't1'), isTrue);
  });

  test('媒体补齐：life 引用的媒体从远端拉取', () async {
    // 远端有媒体文件与引用它的 life 事件
    final mf = File(p.join(remote.media.dir.path, 'm1.jpg'));
    await mf.parent.create(recursive: true);
    await mf.writeAsBytes([1, 2, 3]);
    final life = GpxFile(waypoints: [
      Waypoint(
          id: 'ev1',
          name: '带图事件',
          mediaId: 'm1',
          latLng: const LatLng(30, 120),
          createdAt: DateTime.utc(2024, 1, 1),
          updatedAt: DateTime.utc(2024, 1, 1)),
    ]);
    await remote.saveLife(life);

    await mergePerson(local, DirSyncRemote(remote), 'a');

    final got = local.media.find('m1');
    expect(got, isNotNull);
    expect(await got!.readAsBytes(), [1, 2, 3]);
  });

  test('整包导出/导入：新人物直接导入，内容完整', () async {
    final mf = File(p.join(local.media.dir.path, 'm1.jpg'));
    await mf.parent.create(recursive: true);
    await mf.writeAsBytes([1, 2, 3]);
    await writeTripRaw(local, 't1', '行程', DateTime.utc(2024, 2, 1));
    await local.saveLife(GpxFile(waypoints: [
      Waypoint(
          id: 'ev1',
          name: '事件',
          mediaId: 'm1',
          latLng: const LatLng(30, 120),
          createdAt: DateTime.utc(2024, 1, 1),
          updatedAt: DateTime.utc(2024, 1, 1)),
    ]));

    final bytes = await exportPersonPack(local);
    expect(await packPersonId(bytes), 'a');

    // 导入到另一个 people 根（该 id 不存在 → 直接新建）
    final app = AppRepository(Directory(p.join(tmp.path, 'people2')));
    final id = await importPersonPack(app, bytes, mode: 'new');
    expect(id, 'a');

    final imported = PersonRepository(app.personDir('a'));
    expect((await imported.loadTrip('t1'))!.meta.name, '行程');
    expect((await imported.loadLife()).waypointById('ev1'), isNotNull);
    expect(imported.media.find('m1'), isNotNull);
  });

  test('导出整包只包含被引用的媒体', () async {
    for (final (id, bytes) in [('m1', [1, 2, 3]), ('m2', [4, 5, 6])]) {
      final mf = File(p.join(local.media.dir.path, '$id.jpg'));
      await mf.parent.create(recursive: true);
      await mf.writeAsBytes(bytes);
    }
    await local.saveLife(GpxFile(waypoints: [
      Waypoint(
          id: 'ev1',
          name: '事件',
          mediaId: 'm1',
          latLng: const LatLng(30, 120),
          createdAt: DateTime.utc(2024, 1, 1),
          updatedAt: DateTime.utc(2024, 1, 1)),
    ]));

    final bytes = await exportPersonPack(local);
    final arch = ZipDecoder().decodeBytes(bytes);
    final names = [for (final f in arch.files) f.name];
    expect(names, contains('media/m1.jpg'));
    expect(names, isNot(contains('media/m2.jpg')));
  });

  test('整包导入合并：已存在人物选合并，两端数据并集', () async {
    // 本地人物 a 有行程 t1；另一设备（同 id a）的包里有行程 t2
    await writeTripRaw(local, 't1', '本地行程', DateTime.utc(2024, 1, 1));
    final src = PersonRepository(Directory(p.join(tmp.path, 'src')));
    await src.root.create(recursive: true);
    await src.savePerson(
        Person(id: 'a', name: 'a', createdAt: DateTime.utc(2024, 1, 1), updatedAt: DateTime.utc(2024, 1, 1)));
    await writeTripRaw(src, 't2', '包内行程', DateTime.utc(2024, 2, 1));
    final bytes = await exportPersonPack(src);

    final app = AppRepository(peopleRoot);
    await importPersonPack(app, bytes, mode: 'merge');

    // 合并进本地 a：t1 保留，t2 加入
    expect((await local.loadTrip('t1'))!.meta.name, '本地行程');
    expect((await local.loadTrip('t2'))!.meta.name, '包内行程');
  });
}
