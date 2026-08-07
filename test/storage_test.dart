import 'dart:io';

import 'package:adventuring_time/models.dart';
import 'package:adventuring_time/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late PersonRepository repo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('atrip_test');
    repo = PersonRepository(Directory(p.join(tmp.path, 'people', 'p1')));
    await repo.root.create(recursive: true);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('事件移入/移出行程：跨文件移动且数据不变', () async {
    final w = Waypoint(
      id: 'ev1',
      name: '搬家到上海',
      desc: '2008年',
      latLng: const LatLng(31.23, 121.47),
      time: DateTime.utc(2008, 1, 1),
      timePrecision: TimePrecision.year,
      isEvent: true,
      fromName: '武汉',
      mediaId: 'm1',
      createdAt: DateTime.utc(2020, 1, 1),
      updatedAt: DateTime.utc(2020, 1, 1),
    );
    final life = GpxFile(waypoints: [w]);
    await repo.saveLife(life);
    expect((await repo.loadLife()).waypointById('ev1'), isNotNull);

    // 移入行程
    await repo.saveTrip(TripBundle(
      meta: Trip(
        id: 't1',
        name: 't1',
        createdAt: DateTime.utc(2024, 1, 1),
        updatedAt: DateTime.utc(2024, 1, 1),
      ),
      gpx: GpxFile(waypoints: [w]),
    ));
    await repo.saveLife(GpxFile()); // life.gpx 不再含 ev1
    final lifeAfter = await repo.loadLife();
    expect(lifeAfter.waypointById('ev1'), isNull);
    final trip = await repo.loadTrip('t1');
    final moved = trip!.gpx.waypointById('ev1')!;
    expect(moved.name, '搬家到上海');
    expect(moved.timePrecision, TimePrecision.year);
    expect(moved.fromName, '武汉');
    expect(moved.mediaId, 'm1');

    // 移回 life
    await repo.saveLife(GpxFile(waypoints: [moved]));
    await repo.saveTrip(TripBundle(meta: trip.meta, gpx: GpxFile()));
    expect((await repo.loadLife()).waypointById('ev1')!.latLng.latitude, closeTo(31.23, 1e-9));
    expect((await repo.loadTrip('t1'))!.gpx.waypoints, isEmpty);
  });

  test('手动备份后恢复到该版本', () async {
    final life = GpxFile(waypoints: [
      Waypoint(
        id: 'w1',
        name: '版本1',
        latLng: const LatLng(1, 1),
        createdAt: DateTime.utc(2020, 1, 1),
        updatedAt: DateTime.utc(2020, 1, 1),
      )
    ]);
    await repo.saveLife(life);
    life.waypoints.first.name = '版本2';
    await repo.saveLife(life);
    await repo.backupAll(); // 此刻备份的是版本2
    life.waypoints.first.name = '版本3';
    await repo.saveLife(life);

    final backups = await repo.listBackups();
    expect(backups, isNotEmpty);
    await repo.restoreBackup(backups.first, 'life.gpx');
    final f = File(p.join(tmp.path, 'people', 'p1', 'life.gpx'));
    expect(f.readAsStringSync(), contains('版本2'));
  });

  test('整包备份后可恢复被删行程', () async {
    final meta = Trip(
      id: 't1',
      name: '新疆8日游',
      createdAt: DateTime.utc(2024, 1, 1),
      updatedAt: DateTime.utc(2024, 1, 1),
    );
    await repo.saveTrip(TripBundle(meta: meta, gpx: GpxFile()));
    await repo.backupAll();
    await repo.deleteTrip('t1');
    expect(await repo.loadTrip('t1'), isNull);

    final backups = await repo.listBackups();
    await repo.restoreBackupAll(backups.first);
    final restored = await repo.loadTrip('t1');
    expect(restored, isNotNull);
    expect(restored!.meta.name, '新疆8日游');
  });

  test('删除行程后清理无引用的媒体，备份中仍有引用则保留', () async {
    for (final id in ['m1', 'm2']) {
      final f = File(p.join(repo.media.dir.path, '$id.jpg'));
      await f.parent.create(recursive: true);
      await f.writeAsBytes([1, 2, 3]);
    }
    final w = Waypoint(
      id: 'w1',
      name: '带图',
      mediaId: 'm1',
      latLng: const LatLng(1, 1),
      createdAt: DateTime.utc(2024, 1, 1),
      updatedAt: DateTime.utc(2024, 1, 1),
    );
    await repo.saveTrip(TripBundle(
      meta: Trip(
        id: 't1',
        name: 't1',
        createdAt: DateTime.utc(2024, 1, 1),
        updatedAt: DateTime.utc(2024, 1, 1),
      ),
      gpx: GpxFile(waypoints: [w]),
    ));
    await repo.backupAll(); // 备份里 t1.gpx 引用 m1

    await repo.deleteTrip('t1');
    expect(repo.media.find('m1'), isNotNull);
    expect(repo.media.find('m2'), isNull);
  });

  test('备份引用检查：媒体被备份引用时保留', () async {
    final w = Waypoint(
      id: 'w1',
      name: '带图',
      mediaId: 'm1',
      latLng: const LatLng(1, 1),
      createdAt: DateTime.utc(2024, 1, 1),
      updatedAt: DateTime.utc(2024, 1, 1),
    );
    await repo.saveTrip(TripBundle(
      meta: Trip(
        id: 't1',
        name: 't1',
        createdAt: DateTime.utc(2024, 1, 1),
        updatedAt: DateTime.utc(2024, 1, 1),
      ),
      gpx: GpxFile(waypoints: [w]),
    ));
    await repo.backupAll();
    expect(await repo.mediaReferencedInBackups('m1'), isTrue);
    expect(await repo.mediaReferencedInBackups('nope'), isFalse);
  });

  test('媒体池写入/查找/删除', () async {
    final id = await repo.media.write('jpg', [1, 2, 3]);
    expect(id, isNotEmpty);
    final f = repo.media.find(id);
    expect(f, isNotNull);
    expect(await f!.readAsBytes(), [1, 2, 3]);
    await repo.media.delete(id);
    expect(repo.media.find(id), isNull);
  });

  test('mediaIds 列表（地点/行程/路径）被引用收集', () async {
    for (final id in ['m1', 'm2', 'm3', 'm4']) {
      final f = File(p.join(repo.media.dir.path, '$id.jpg'));
      await f.parent.create(recursive: true);
      await f.writeAsBytes([1]);
    }
    await repo.saveTrip(TripBundle(
      meta: Trip(
        id: 't1',
        name: 't1',
        mediaIds: ['m1', 'm2'],
        createdAt: DateTime.utc(2024, 1, 1),
        updatedAt: DateTime.utc(2024, 1, 1),
      ),
      gpx: GpxFile(
        waypoints: [
          Waypoint(
            id: 'w1',
            name: 'w1',
            mediaIds: ['m3'],
            latLng: const LatLng(0, 0),
            createdAt: DateTime.utc(2024, 1, 1),
            updatedAt: DateTime.utc(2024, 1, 1),
          ),
        ],
        paths: [
          PathData(
            id: 'p1',
            name: 'p1',
            mediaIds: ['m4'],
            isGps: true,
            points: [TrackPoint(const LatLng(0, 0), DateTime.utc(2024, 1, 1))],
            createdAt: DateTime.utc(2024, 1, 1),
            updatedAt: DateTime.utc(2024, 1, 1),
          ),
        ],
      ),
    ));
    final ids = await repo.referencedMediaIds();
    expect(ids, containsAll(['m1', 'm2', 'm3', 'm4']));
  });

  test('listTrips 排序按 startDate', () async {
    for (final (tid, start) in [('a', DateTime.utc(2024, 7, 1)), ('b', DateTime.utc(2024, 5, 1))]) {
      await repo.saveTrip(TripBundle(
        meta: Trip(
          id: tid,
          name: tid,
          startDate: start,
          createdAt: DateTime.utc(2024, 1, 1),
          updatedAt: DateTime.utc(2024, 1, 1),
        ),
        gpx: GpxFile(),
      ));
    }
    final trips = await repo.listTrips();
    expect(trips.map((t) => t.id).toList(), ['b', 'a']);
  });
}
