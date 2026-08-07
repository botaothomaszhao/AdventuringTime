import 'package:adventuring_time/gpx_io.dart';
import 'package:adventuring_time/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

void main() {
  group('GPX round-trip', () {
    test('带扩展字段的事件 wpt 往返一致', () {
      final w = Waypoint(
        id: 'abc123',
        name: '搬家到上海',
        desc: '2008年全家搬到上海',
        latLng: const LatLng(31.23, 121.47),
        time: DateTime.utc(2008, 1, 1),
        timePrecision: TimePrecision.year,
        isEvent: true,
        fromName: '武汉',
        fromLatLng: const LatLng(30.59, 114.30),
        mediaIds: ['media1', 'media2'],
        createdAt: DateTime.utc(2020, 1, 1),
        updatedAt: DateTime.utc(2020, 1, 2),
      );
      final gpx = GpxFile(waypoints: [w]);
      final parsed = parseGpx(toGpx(gpx));
      expect(parsed.waypoints, hasLength(1));
      final p = parsed.waypoints.first;
      expect(p.id, 'abc123');
      expect(p.name, '搬家到上海');
      expect(p.desc, '2008年全家搬到上海');
      expect(p.latLng.latitude, closeTo(31.23, 1e-9));
      expect(p.latLng.longitude, closeTo(121.47, 1e-9));
      expect(p.time, DateTime.utc(2008, 1, 1));
      expect(p.timePrecision, TimePrecision.year);
      expect(p.isEvent, true);
      expect(p.fromName, '武汉');
      expect(p.fromLatLng!.latitude, closeTo(30.59, 1e-9));
      expect(p.mediaId, 'media1');
      expect(p.mediaIds, ['media1', 'media2']);
      expect(p.createdAt, DateTime.utc(2020, 1, 1));
    });

    test('普通地点与 trk/rte 往返一致', () {
      final place = Waypoint(
        id: 'p1',
        name: '大理古城',
        latLng: const LatLng(25.69, 100.16),
        time: DateTime.utc(2023, 5, 1),
        isEvent: false,
        createdAt: DateTime.utc(2023, 5, 2),
        updatedAt: DateTime.utc(2023, 5, 2),
      );
      final gps = PathData(
        id: 'trk1',
        name: '骑行记录',
        desc: 'day1',
        mediaIds: ['m1', 'm2'],
        isGps: true,
        points: [
          TrackPoint(const LatLng(25.0, 100.0), DateTime.utc(2023, 5, 1, 8, 0)),
          TrackPoint(const LatLng(25.1, 100.1), DateTime.utc(2023, 5, 1, 8, 5)),
        ],
        startEventId: 'ev1',
        startLat: 24.9,
        startLon: 99.9,
        createdAt: DateTime.utc(2023, 5, 1),
        updatedAt: DateTime.utc(2023, 5, 1),
      );
      final rte = PathData(
        id: 'rte1',
        name: '手绘路线',
        isGps: false,
        points: [TrackPoint(const LatLng(25.2, 100.2)), TrackPoint(const LatLng(25.3, 100.3))],
        createdAt: DateTime.utc(2023, 5, 1),
        updatedAt: DateTime.utc(2023, 5, 1),
      );
      final gpx = GpxFile(waypoints: [place], paths: [gps, rte]);
      final parsed = parseGpx(toGpx(gpx));
      expect(parsed.waypoints.first.name, '大理古城');
      expect(parsed.tracks, hasLength(1));
      expect(parsed.routes, hasLength(1));
      final t = parsed.tracks.first;
      expect(t.id, 'trk1');
      expect(t.points, hasLength(2));
      expect(t.points.first.time, DateTime.utc(2023, 5, 1, 8, 0));
      expect(t.startEventId, 'ev1');
      expect(t.startLat, closeTo(24.9, 1e-9));
      expect(t.mediaId, 'm1');
      expect(t.mediaIds, ['m1', 'm2']);
      expect(parsed.routes.first.points.last.latLng.longitude, closeTo(100.3, 1e-9));
    });

    test('行程 metadata 往返一致', () {
      final trip = Trip(
        id: 'trip1',
        name: '新疆8日游',
        description: '北疆环线',
        mediaIds: ['c1', 'c2'],
        startDate: DateTime.utc(2024, 7, 1),
        endDate: DateTime.utc(2024, 7, 8),
        startEventId: 'ev1',
        endEventId: 'ev2',
        createdAt: DateTime.utc(2024, 6, 1),
        updatedAt: DateTime.utc(2024, 6, 1),
      );
      final gpx = GpxFile(waypoints: [], paths: []);
      final parsed = parseGpx(toGpx(gpx, trip: trip));
      final m = parsed.metadataTrip!;
      expect(m.id, 'trip1');
      expect(m.name, '新疆8日游');
      expect(m.description, '北疆环线');
      expect(m.mediaIds, ['c1', 'c2']);
      expect(m.startDate, DateTime.utc(2024, 7, 1));
      expect(m.endEventId, 'ev2');
      expect(m.updatedAt, DateTime.utc(2024, 6, 1));
    });

    test('外部 GPX（无扩展字段）可导入且不报错', () {
      const raw = '''<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="someApp" xmlns="http://www.topografix.com/GPX/1/1">
  <wpt lat="30.1" lon="120.2">
    <name>西湖</name>
    <time>2022-01-01T00:00:00Z</time>
  </wpt>
  <trk>
    <name>track</name>
    <trkseg>
      <trkpt lat="30.1" lon="120.2"><time>2022-01-01T00:00:00Z</time></trkpt>
      <trkpt lat="30.2" lon="120.3"><time>2022-01-01T00:01:00Z</time></trkpt>
    </trkseg>
  </trk>
</gpx>''';
      final parsed = parseGpx(raw);
      expect(parsed.waypoints.single.name, '西湖');
      expect(parsed.waypoints.single.isEvent, false);
      expect(parsed.waypoints.single.timePrecision, isNull);
      expect(parsed.tracks.single.points, hasLength(2));
      expect(parsed.tracks.single.mediaId, isNull);
    });
  });
}
