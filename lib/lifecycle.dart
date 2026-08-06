import 'dart:math';

import 'package:latlong2/latlong.dart';

import 'models.dart';

/// 几何与统计纯函数：haversine、人生轨迹线、统计口径。

const double _earthR = 6371000.0;

double _rad(double deg) => deg * pi / 180;

/// 两点球面距离（米）。
double haversineM(LatLng a, LatLng b) {
  final dLat = _rad(b.latitude - a.latitude);
  final dLon = _rad(b.longitude - a.longitude);
  final h = sin(dLat / 2) * sin(dLat / 2) +
      cos(_rad(a.latitude)) * cos(_rad(b.latitude)) * sin(dLon / 2) * sin(dLon / 2);
  return 2 * _earthR * asin(min(1, sqrt(h)));
}

/// 折线总长（米）。
double pathLengthM(List<LatLng> pts) {
  var total = 0.0;
  for (var i = 1; i < pts.length; i++) {
    total += haversineM(pts[i - 1], pts[i]);
  }
  return total;
}

/// 一个轨迹线段：recorded=true 为实际记录段（实线），false 为推算直线段（虚线）。
/// tripId 非空时该段属于行程（可点击打开行程弹窗）。
class LifeSeg {
  final LatLng from;
  final LatLng to;
  final bool recorded;
  final String? tripId;

  const LifeSeg(this.from, this.to, this.recorded, [this.tripId]);
}

/// 人生轨迹线计算结果。
class LifePathResult {
  final List<LifeSeg> segs;
  final double recordedMeters;
  final double estimatedMeters;

  const LifePathResult(this.segs, this.recordedMeters, this.estimatedMeters);
}

/// 单条路径（trk/rte）的取点序列，用于行程内部连接。
List<LatLng> _pathPoints(PathData p) => [for (final pt in p.points) pt.latLng];

/// 构建人生轨迹线：全部长期地点 + 全部行程按时间排序，相邻项连接，
/// 实线=实际记录段，虚线=推算直线段。统计实/虚里程。
/// 行程内部：路径、地点、起点长期地点按时间顺序相连，最后连回终点长期地点。
/// 相邻项连接段归属行程时（任一端为行程）标行程 id，供地图点击打开行程。
LifePathResult buildLifePath(List<Waypoint> events, List<TripBundle> trips) {
  final segs = <LifeSeg>[];

  void add(LatLng a, LatLng b, bool rec, [String? tripId]) {
    if (a == b) return;
    segs.add(LifeSeg(a, b, rec, tripId));
  }

  // 按 id 查找长期地点（事件列表 + 各行程内），用于起终点引用
  Waypoint? findWp(String? id) {
    if (id == null) return null;
    for (final e in events) {
      if (e.id == id) return e;
    }
    for (final t in trips) {
      for (final w in t.gpx.waypoints) {
        if (w.id == id) return w;
      }
    }
    return null;
  }

  // 排序项：长期地点或行程
  final items = <_LifeItem>[];
  for (final e in events) {
    items.add(_LifeItem(
      time: e.sortTime ?? e.createdAt,
      created: e.createdAt,
      first: e.latLng,
      last: e.latLng,
    ));
  }
  for (final t in trips) {
    final itemSegs = <LifeSeg>[];
    final startWp = findWp(t.meta.startEventId);
    final endWp = findWp(t.meta.endEventId);
    // 行程内节点：路径（首点时间或创建时间）、地点（到达时间）、起点长期地点（最早时间）
    final nodes = <({DateTime time, PathData? path, LatLng point})>[];
    for (final p in t.gpx.paths) {
      if (p.points.isEmpty) continue;
      nodes.add((time: p.points.first.time ?? p.createdAt, path: p, point: p.points.first.latLng));
    }
    for (final w in t.gpx.waypoints) {
      nodes.add((time: w.sortTime ?? w.createdAt, path: null, point: w.latLng));
    }
    if (startWp != null) {
      var earliest = nodes.isEmpty ? t.meta.startDate ?? t.meta.createdAt : nodes.first.time;
      for (final n in nodes) {
        if (n.time.isBefore(earliest)) earliest = n.time;
      }
      nodes.add((
        time: earliest.subtract(const Duration(seconds: 1)),
        path: null,
        point: startWp.latLng,
      ));
    }
    nodes.sort((a, b) => a.time.compareTo(b.time));
    // 按时间顺序连接：路径内部实线，节点之间虚线
    LatLng? prev;
    for (final n in nodes) {
      final p = n.path;
      if (p != null) {
        if (prev != null) itemSegs.add(LifeSeg(prev, p.points.first.latLng, false, t.meta.id));
        for (var i = 1; i < p.points.length; i++) {
          itemSegs.add(LifeSeg(p.points[i - 1].latLng, p.points[i].latLng, true, t.meta.id));
        }
        prev = p.points.last.latLng;
      } else {
        if (prev != null) itemSegs.add(LifeSeg(prev, n.point, false, t.meta.id));
        prev = n.point;
      }
    }
    // 最后连回终点长期地点
    if (endWp != null && prev != null) {
      itemSegs.add(LifeSeg(prev, endWp.latLng, false, t.meta.id));
    }
    final first = itemSegs.isEmpty ? startWp?.latLng : itemSegs.first.from;
    final last = endWp?.latLng ?? (itemSegs.isEmpty ? startWp?.latLng : itemSegs.last.to);
    items.add(_LifeItem(
      time: t.meta.startDate ?? t.meta.createdAt,
      created: t.meta.createdAt,
      first: first,
      last: last,
      segs: itemSegs,
      tripId: t.meta.id,
    ));
  }

  items.sort((a, b) {
    final c = a.time.compareTo(b.time);
    return c != 0 ? c : a.created.compareTo(b.created);
  });

  // 相邻项连接（推算直线段）：任一端是行程时该段归属行程（可点击打开行程）
  for (var i = 0; i + 1 < items.length; i++) {
    final a = items[i];
    final b = items[i + 1];
    if (a.last == null || b.first == null) continue;
    add(a.last!, b.first!, false, b.tripId ?? a.tripId);
  }

  // 收集所有段并统计
  for (final item in items) {
    segs.addAll(item.segs);
  }
  var recorded = 0.0;
  var estimated = 0.0;
  for (final s in segs) {
    final d = haversineM(s.from, s.to);
    if (s.recorded) {
      recorded += d;
    } else {
      estimated += d;
    }
  }
  return LifePathResult(segs, recorded, estimated);
}

class _LifeItem {
  final DateTime time;
  final DateTime created;
  final LatLng? first;
  final LatLng? last;
  final List<LifeSeg> segs;
  final String? tripId; // 行程 item 的 id（长期地点为 null）

  _LifeItem({
    required this.time,
    required this.created,
    required this.first,
    required this.last,
    this.segs = const [],
    this.tripId,
  });
}

/// 行程统计。
class TripStats {
  final double recordedMeters;
  final int days;
  final int placeCount;
  final int pathCount;
  final int mediaCount;

  const TripStats({
    required this.recordedMeters,
    required this.days,
    required this.placeCount,
    required this.pathCount,
    required this.mediaCount,
  });
}

TripStats tripStats(TripBundle t) {
  var meters = 0.0;
  final dates = <int>{};
  for (final trk in t.gpx.tracks) {
    meters += pathLengthM(_pathPoints(trk));
    for (final pt in trk.points) {
      final tm = pt.time;
      if (tm != null) dates.add(tm.year * 10000 + tm.month * 100 + tm.day);
    }
  }
  int days;
  if (dates.isNotEmpty) {
    days = dates.length;
  } else if (t.meta.startDate != null && t.meta.endDate != null) {
    days = t.meta.endDate!.difference(t.meta.startDate!).inDays + 1;
  } else {
    days = t.gpx.tracks.isNotEmpty || t.gpx.paths.isNotEmpty ? 1 : 0;
  }
  final media = <String>{};
  if (t.meta.cover != null) media.add(t.meta.cover!);
  for (final w in t.gpx.waypoints) {
    if (w.mediaId != null) media.add(w.mediaId!);
  }
  for (final pth in t.gpx.paths) {
    if (pth.mediaId != null) media.add(pth.mediaId!);
  }
  return TripStats(
    recordedMeters: meters,
    days: days,
    placeCount: t.gpx.waypoints.length,
    pathCount: t.gpx.paths.length,
    mediaCount: media.length,
  );
}

/// 每人统计。
class PersonStats {
  final double recordedMeters;
  final double estimatedMeters;
  final int eventCount;
  final int tripCount;
  final int mediaCount;

  const PersonStats({
    required this.recordedMeters,
    required this.estimatedMeters,
    required this.eventCount,
    required this.tripCount,
    required this.mediaCount,
  });
}

PersonStats personStats(List<Waypoint> events, List<TripBundle> trips, int mediaCount) {
  final path = buildLifePath(events, trips);
  return PersonStats(
    recordedMeters: path.recordedMeters,
    estimatedMeters: path.estimatedMeters,
    eventCount: events.length,
    tripCount: trips.length,
    mediaCount: mediaCount,
  );
}

/// 里程格式化："1.2 km" / "850 m"。
String formatMeters(double m) {
  if (m >= 1000) return '${(m / 1000).toStringAsFixed(m >= 100000 ? 0 : 1)} km';
  return '${m.round()} m';
}

/// 坐标 SWNE 格式化：N25.69000° E100.16000°。
String formatLatLng(LatLng ll) {
  final ns = ll.latitude >= 0 ? 'N' : 'S';
  final ew = ll.longitude >= 0 ? 'E' : 'W';
  return '$ns${ll.latitude.abs().toStringAsFixed(5)}° $ew${ll.longitude.abs().toStringAsFixed(5)}°';
}
