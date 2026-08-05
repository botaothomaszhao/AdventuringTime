import 'package:adventuring_time/lifecycle.dart';
import 'package:adventuring_time/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

Waypoint ev(String id, DateTime t, LatLng ll) => Waypoint(
      id: id,
      name: id,
      latLng: ll,
      time: t,
      isEvent: true,
      createdAt: t,
      updatedAt: t,
    );

TripBundle trip(String id, DateTime start, List<PathData> paths) => TripBundle(
      meta: Trip(
        id: id,
        name: id,
        startDate: start,
        createdAt: start,
        updatedAt: start,
      ),
      gpx: GpxFile(paths: paths),
    );

void main() {
  group('人生轨迹线', () {
    test('事件-行程-事件按时间排序并正确连接', () {
      final e1 = ev('e1', DateTime.utc(2000, 1, 1), const LatLng(0, 0));
      final t2 = trip('t2', DateTime.utc(2005, 1, 1), [
        PathData(
          id: 'p1',
          name: 'p1',
          isGps: true,
          points: [
            TrackPoint(const LatLng(1, 1), DateTime.utc(2005, 1, 1)),
            TrackPoint(const LatLng(1, 2), DateTime.utc(2005, 1, 2)),
          ],
          createdAt: DateTime.utc(2005, 1, 1),
          updatedAt: DateTime.utc(2005, 1, 1),
        ),
      ]);
      final e3 = ev('e3', DateTime.utc(2010, 1, 1), const LatLng(3, 3));
      final r = buildLifePath([e3, e1], [t2]);
      // 事件1 → 行程起点 直线(虚线)；行程内部 实线；行程尾 → 事件3 直线(虚线)
      final dashed = r.segs.where((s) => !s.recorded).toList();
      final solid = r.segs.where((s) => s.recorded).toList();
      expect(dashed, hasLength(2));
      expect(solid, hasLength(1));
      expect(dashed.first.from, const LatLng(0, 0));
      expect(dashed.first.to, const LatLng(1, 1));
      expect(solid.first.from, const LatLng(1, 1));
      expect(solid.first.to, const LatLng(1, 2));
      expect(dashed.last.from, const LatLng(1, 2));
      expect(dashed.last.to, const LatLng(3, 3));
      // 里程：实线 = 1°纬距，虚线 = 2 段各 1° 经距 + 1° 纬距
      expect(r.recordedMeters, closeTo(haversineM(const LatLng(1, 1), const LatLng(1, 2)), 1e-6));
      expect(r.estimatedMeters,
          closeTo(haversineM(const LatLng(0, 0), const LatLng(1, 1)) + haversineM(const LatLng(1, 2), const LatLng(3, 3)), 1e-6));
    });

    test('同刻按 createdAt 排序，环状序列首尾相接', () {
      // time 相同，但 a 的 createdAt 更早 → a 在前
      final a = Waypoint(
        id: 'a',
        name: 'a',
        latLng: const LatLng(0, 0),
        time: DateTime.utc(2000, 1, 1),
        isEvent: true,
        createdAt: DateTime.utc(1999, 12, 1),
        updatedAt: DateTime.utc(1999, 12, 1),
      );
      final c = ev('c', DateTime.utc(2000, 1, 1), const LatLng(1, 0));
      final r = buildLifePath([c, a], []);
      expect(r.segs, hasLength(1));
      expect(r.segs.first.from, const LatLng(0, 0));
      expect(r.segs.first.to, const LatLng(1, 0));
    });

    test('行程内部多 track 间隔为虚线段', () {
      final t = trip('t', DateTime.utc(2005, 1, 1), [
        PathData(
          id: 's1',
          name: 's1',
          isGps: true,
          points: [
            TrackPoint(const LatLng(0, 0), DateTime.utc(2005, 1, 1)),
            TrackPoint(const LatLng(0, 1), DateTime.utc(2005, 1, 1, 1)),
          ],
          createdAt: DateTime.utc(2005, 1, 1),
          updatedAt: DateTime.utc(2005, 1, 1),
        ),
        PathData(
          id: 's2',
          name: 's2',
          isGps: true,
          points: [
            TrackPoint(const LatLng(0, 2), DateTime.utc(2005, 1, 2)),
            TrackPoint(const LatLng(0, 3), DateTime.utc(2005, 1, 2, 1)),
          ],
          createdAt: DateTime.utc(2005, 1, 1),
          updatedAt: DateTime.utc(2005, 1, 1),
        ),
      ]);
      final r = buildLifePath([], [t]);
      // 实线2段 + 虚线1段（s1尾→s2首）
      expect(r.segs.where((s) => s.recorded), hasLength(2));
      expect(r.segs.where((s) => !s.recorded), hasLength(1));
      expect(r.segs.firstWhere((s) => !s.recorded).from, const LatLng(0, 1));
      expect(r.segs.firstWhere((s) => !s.recorded).to, const LatLng(0, 2));
    });
  });

  group('统计', () {
    test('tripStats 里程/天数/数量正确', () {
      final t = trip('t', DateTime.utc(2024, 7, 1), [
        PathData(
          id: 's1',
          name: 's1',
          isGps: true,
          points: [
            TrackPoint(const LatLng(0, 0), DateTime.utc(2024, 7, 1)),
            TrackPoint(const LatLng(0, 1), DateTime.utc(2024, 7, 1)),
            TrackPoint(const LatLng(0, 2), DateTime.utc(2024, 7, 2)),
          ],
          createdAt: DateTime.utc(2024, 7, 1),
          updatedAt: DateTime.utc(2024, 7, 1),
        ),
      ]);
      t.gpx.waypoints.add(ev('w1', DateTime.utc(2024, 7, 1), const LatLng(0, 0))..mediaId = 'm1');
      t.meta.cover = 'm2';
      final s = tripStats(t);
      expect(s.recordedMeters, closeTo(2 * haversineM(const LatLng(0, 0), const LatLng(0, 1)), 1e-6));
      expect(s.days, 2);
      expect(s.placeCount, 1);
      expect(s.pathCount, 1);
      expect(s.mediaCount, 2);
    });
  });

  group('haversine', () {
    test('零距离与已知距离', () {
      expect(haversineM(const LatLng(0, 0), const LatLng(0, 0)), 0);
      // 1° 纬度 ≈ 111.19 km
      expect(haversineM(const LatLng(0, 0), const LatLng(1, 0)), closeTo(111194.9, 500));
    });
  });
}
