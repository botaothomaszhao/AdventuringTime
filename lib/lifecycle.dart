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
/// 虚线=推算直线段。行程内部：地点与路径按行程内顺序（orderIds 优先，否则按时间）
/// 依次相连，路径只连接其首尾（不重复绘制路径本身），最后连回终点长期地点。
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
    final inner = _tripInner(t, findWp);
    items.add(_LifeItem(
      time: t.meta.startDate ?? t.meta.createdAt,
      created: t.meta.createdAt,
      first: inner.first,
      last: inner.last,
      segs: inner.segs,
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

  // 收集所有段并统计；记录里程独立统计全部 GPS 轨迹（轨迹线不再重复画路径）
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
  if (recorded == 0) {
    for (final t in trips) {
      for (final trk in t.gpx.tracks) {
        recorded += pathLengthM(_pathPoints(trk));
      }
    }
  }
  return LifePathResult(segs, recorded, estimated);
}

/// 行程内部节点：路径（首/尾点）与地点；顺序与行程详情页一致——按日期分组、
/// 组间日期升序，组内 orderIds 覆盖该组全部项时按自定义顺序，否则按时间。
/// 起点长期地点置于最前，相邻节点间连虚线；路径仅连首尾，不重复画路径；最后连回终点。
/// 返回连接段序列与行程首末点（供轨迹线相邻连接）。
({List<LifeSeg> segs, LatLng? first, LatLng? last}) _tripInner(
    TripBundle t, Waypoint? Function(String?) findWp) {
  final startWp = findWp(t.meta.startEventId);
  final endWp = findWp(t.meta.endEventId);
  var nodes = <_TripNode>[];
  for (final p in t.gpx.paths) {
    if (p.points.isEmpty) continue;
    nodes.add(_TripNode(path: p));
  }
  for (final w in t.gpx.waypoints) {
    nodes.add(_TripNode(wp: w));
  }
  // 排序与行程详情页一致：按日期分组、组间日期升序（未标日期最后）、
  // 组内 orderIds 覆盖该组全部项时按自定义顺序，否则按时间。
  final orderIds = t.gpx.orderIds;
  int? dayOf(_TripNode n) {
    final tm = n.path != null ? n.path!.points.first.time : n.wp!.time;
    if (tm == null) return null;
    return tm.year * 10000 + tm.month * 100 + tm.day;
  }
  final byDay = <int?, List<_TripNode>>{};
  for (final n in nodes) {
    byDay.putIfAbsent(dayOf(n), () => []).add(n);
  }
  final dayKeys = byDay.keys.toList()..sort((a, b) {
        if (a == null) return b == null ? 0 : 1;
        if (b == null) return -1;
        return a.compareTo(b);
      });
  final ordered = <_TripNode>[];
  for (final k in dayKeys) {
    final group = byDay[k]!;
    if (orderIds.isNotEmpty && group.every((n) => orderIds.contains(n.id))) {
      group.sort((a, b) => orderIds.indexOf(a.id).compareTo(orderIds.indexOf(b.id)));
    } else {
      group.sort((a, b) => a.time.compareTo(b.time));
    }
    ordered.addAll(group);
  }
  nodes = ordered;
  final segs = <LifeSeg>[];
  LatLng? prev = startWp?.latLng;
  for (final n in nodes) {
    final p = n.path;
    if (p != null) {
      if (prev != null) segs.add(LifeSeg(prev, p.points.first.latLng, false, t.meta.id));
      prev = p.points.last.latLng;
    } else {
      if (prev != null) segs.add(LifeSeg(prev, n.wp!.latLng, false, t.meta.id));
      prev = n.wp!.latLng;
    }
  }
  if (endWp != null && prev != null) {
    segs.add(LifeSeg(prev, endWp.latLng, false, t.meta.id));
  }
  final first = startWp?.latLng ??
      (nodes.isEmpty ? null : (nodes.first.path?.points.first.latLng ?? nodes.first.wp!.latLng));
  final last = endWp?.latLng ??
      (nodes.isEmpty ? null : (nodes.last.path?.points.last.latLng ?? nodes.last.wp!.latLng));
  return (segs: segs, first: first, last: last);
}

class _TripNode {
  final DateTime time;
  final String id;
  final PathData? path;
  final Waypoint? wp;

  _TripNode({this.path, this.wp})
      : assert(path != null || wp != null),
        time = path != null
            ? path.points.first.time ?? path.createdAt
            : (wp!.time ?? wp!.createdAt),
        id = path != null ? path.id : wp!.id;
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

/// 单行程推算里程（米）：行程内部直线段总长——起点长期地点→各路径首尾/地点→
/// 终点长期地点，与轨迹线行程部分一致；不含实际 GPS 轨迹自身长度。
double estimatedTripMeters(TripBundle t, List<Waypoint> events) {
  var total = 0.0;
  for (final s in tripInnerSegs(t, events)) {
    total += haversineM(s.from, s.to);
  }
  return total;
}

/// 单行程内部连接段（起点长期地点→各路径首尾/地点→终点长期地点，全部虚线），
/// 供地图按行程勾选显示连接线；与轨迹线行程部分一致。
List<LifeSeg> tripInnerSegs(TripBundle t, List<Waypoint> events) {
  Waypoint? findWp(String? id) {
    if (id == null) return null;
    for (final e in events) {
      if (e.id == id) return e;
    }
    for (final w in t.gpx.waypoints) {
      if (w.id == id) return w;
    }
    return null;
  }

  return _tripInner(t, findWp).segs;
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
  final media = <String>{
    ...t.meta.mediaIds,
    for (final w in t.gpx.waypoints) ...w.mediaIds,
    for (final pth in t.gpx.paths) ...pth.mediaIds,
  };
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

/// 坐标 SWNE 格式化：25.69000°N 100.16000°E。
String formatLatLng(LatLng ll) {
  final ns = ll.latitude >= 0 ? 'N' : 'S';
  final ew = ll.longitude >= 0 ? 'E' : 'W';
  return '${ll.latitude.abs().toStringAsFixed(5)}°$ns ${ll.longitude.abs().toStringAsFixed(5)}°$ew';
}

/// 相邻采样点速度统计的间隔上限（秒）。原生采样阈值 20s，正常点对间隔必 ≤20s，
/// 超过即为暂停/无信号造成的无效段，速度不可靠，不参与统计。
const int maxSpeedGapSec = 21;

/// 有效相邻段（间隔 ≤21s 且时间正序），返回每段距离（m）与时长（s）。
/// 排除暂停/无信号造成的超长间隔段；avg 与 max 共用同一批段，口径一致。
List<({double dist, int secs})> _validSegments(List<TrackPoint> pts) {
  final out = <({double dist, int secs})>[];
  for (var i = 1; i < pts.length; i++) {
    final t0 = pts[i - 1].time;
    final t1 = pts[i].time;
    if (t0 == null || t1 == null) continue;
    final dt = t1.difference(t0).inSeconds;
    if (dt <= 0 || dt > maxSpeedGapSec) continue;
    out.add((dist: haversineM(pts[i - 1].latLng, pts[i].latLng), secs: dt));
  }
  return out;
}

/// GPS 路径速度统计。
class PathSpeedStats {
  /// 平均速度（m/s）：总路程 / 首末点时间差；暂停时间计入。
  final double? avgMps;

  /// 最高瞬时速度（m/s）：相邻有效段中距离/时长最大者；无有效段为 null。
  final double? maxMps;

  const PathSpeedStats(this.avgMps, this.maxMps);
}

PathSpeedStats pathSpeedStats(List<TrackPoint> pts) {
  final meters = pathLengthM([for (final p in pts) p.latLng]);
  final start = pts.firstOrNull?.time;
  final end = pts.lastOrNull?.time;
  double? avg;
  if (start != null && end != null) {
    final dt = end.difference(start).inSeconds;
    if (dt > 0) avg = meters / dt;
  }
  double? max;
  for (final seg in _validSegments(pts)) {
    final v = seg.dist / seg.secs;
    if (max == null || v > max) max = v;
  }
  return PathSpeedStats(avg, max);
}

/// 最近两点瞬时速度（m/s）。点数不足 2 或最近点对间隔超长（暂停刚恢复）时
/// 返回 null，表示当前速度未知。
double? currentSpeedMps(List<TrackPoint> pts) {
  if (pts.length < 2) return null;
  final a = pts[pts.length - 2];
  final b = pts.last;
  final t0 = a.time;
  final t1 = b.time;
  if (t0 == null || t1 == null) return null;
  final dt = t1.difference(t0).inSeconds;
  if (dt <= 0 || dt > maxSpeedGapSec) return null;
  return haversineM(a.latLng, b.latLng) / dt;
}

/// 速度格式化："--" / "12.3 km/h"。
String formatSpeedKmh(double? mps) =>
    mps == null ? '--' : '${(mps * 3.6).toStringAsFixed(1)} km/h';
