import 'dart:convert';

import 'package:latlong2/latlong.dart';
import 'package:xml/xml.dart';

import 'models.dart';

/// GPX 解析/生成，含 atrip 扩展（urn:adventuring-time）。
/// 解析时对未知扩展字段跳过不报错；生成时只写本软件认识的字段。

const String _atripNs = 'urn:adventuring-time';

/// 文本转义（写 XML 时用）。
String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

String _lat(LatLng p) => p.latitude.toString();
String _lon(LatLng p) => p.longitude.toString();
String _iso(DateTime t) => t.toUtc().toIso8601String();

/// 取子元素（忽略命名空间前缀，仅按 local name 匹配）。
List<XmlElement> _children(XmlElement e, String local) =>
    e.childElements.where((c) => c.name.local == local).toList();

XmlElement? _child(XmlElement e, String local) {
  final l = _children(e, local);
  return l.isEmpty ? null : l.first;
}

String? _text(XmlElement e, String local) => _child(e, local)?.innerText;

double? _num(String? s) => s == null ? null : double.tryParse(s);

String? _ext(XmlElement e, String local) {
  final ext = _child(e, 'extensions');
  if (ext == null) return null;
  for (final c in ext.childElements) {
    if (c.name.local == local) return c.innerText;
  }
  return null;
}

/// 从 wpt/trk/rte 元素解析通用 atrip 字段。
Waypoint _parseWaypoint(XmlElement e) {
  final lat = double.parse(e.getAttribute('lat')!);
  final lon = double.parse(e.getAttribute('lon')!);
  final time = _text(e, 'time');
  final precision = TimePrecisionX.parse(_ext(e, 'timePrecision'));
  final isEvent = _ext(e, 'eventType') == 'life';
  final fromLat = _num(_ext(e, 'fromLat'));
  final fromLon = _num(_ext(e, 'fromLon'));
  final createdAt = _ext(e, 'createdAt');
  final updatedAt = _ext(e, 'updatedAt');
  return Waypoint(
    id: _ext(e, 'id') ?? newId(),
    name: _text(e, 'name') ?? '',
    desc: _text(e, 'desc'),
    latLng: LatLng(lat, lon),
    time: time == null ? null : DateTime.tryParse(time),
    timePrecision: precision,
    isEvent: isEvent,
    fromName: _ext(e, 'fromName'),
    fromLatLng: fromLat != null && fromLon != null ? LatLng(fromLat, fromLon) : null,
    mediaId: _ext(e, 'mediaId'),
    createdAt: createdAt == null ? DateTime.now() : DateTime.tryParse(createdAt) ?? DateTime.now(),
    updatedAt: updatedAt == null ? DateTime.now() : DateTime.tryParse(updatedAt) ?? DateTime.now(),
  );
}

PathData _parsePath(XmlElement e, {required bool isGps}) {
  final segs = <XmlElement>[];
  if (isGps) {
    for (final seg in _children(e, 'trkseg')) {
      segs.addAll(_children(seg, 'trkpt'));
    }
  } else {
    segs.addAll(_children(e, 'rtept'));
  }
  final points = <TrackPoint>[];
  for (final pt in segs) {
    final lat = double.tryParse(pt.getAttribute('lat') ?? '');
    final lon = double.tryParse(pt.getAttribute('lon') ?? '');
    if (lat == null || lon == null) continue;
    final t = _text(pt, 'time');
    points.add(TrackPoint(LatLng(lat, lon), t == null ? null : DateTime.tryParse(t)));
  }
  final createdAt = _ext(e, 'createdAt');
  final updatedAt = _ext(e, 'updatedAt');
  return PathData(
    id: _ext(e, 'id') ?? newId(),
    name: _text(e, 'name') ?? '',
    desc: _text(e, 'desc'),
    mediaId: _ext(e, 'mediaId'),
    isGps: isGps,
    points: points,
    startEventId: _ext(e, 'startEventId'),
    startLat: _num(_ext(e, 'startLat')),
    startLon: _num(_ext(e, 'startLon')),
    endEventId: _ext(e, 'endEventId'),
    endLat: _num(_ext(e, 'endLat')),
    endLon: _num(_ext(e, 'endLon')),
    createdAt: createdAt == null ? DateTime.now() : DateTime.tryParse(createdAt) ?? DateTime.now(),
    updatedAt: updatedAt == null ? DateTime.now() : DateTime.tryParse(updatedAt) ?? DateTime.now(),
  );
}

/// 从 metadata 解析行程元数据（外部 GPX 回退用）。
Trip? _parseMetadataTrip(XmlElement metadata) {
  final trip = _child(metadata, 'extensions')?.childElements
      .where((c) => c.name.local == 'trip')
      .firstOrNull;
  if (trip == null) return null;
  DateTime? p(String n) {
    final v = _text(trip, n);
    return v == null || v.isEmpty ? null : DateTime.tryParse(v);
  }

  String? s(String n) => _text(trip, n);
  return Trip(
    id: s('id') ?? newId(),
    name: s('name') ?? '',
    description: s('description'),
    cover: s('cover'),
    startDate: p('startDate'),
    endDate: p('endDate'),
    startEventId: s('startEventId'),
    endEventId: s('endEventId'),
    createdAt: p('createdAt') ?? DateTime.now(),
    updatedAt: p('updatedAt') ?? DateTime.now(),
  );
}

/// 解析 GPX 文本。
GpxFile parseGpx(String content) {
  final doc = XmlDocument.parse(content);
  final root = doc.rootElement;
  final waypoints = <Waypoint>[];
  final paths = <PathData>[];
  Trip? meta;
  for (final e in root.childElements) {
    switch (e.name.local) {
      case 'wpt':
        waypoints.add(_parseWaypoint(e));
      case 'trk':
        paths.add(_parsePath(e, isGps: true));
      case 'rte':
        paths.add(_parsePath(e, isGps: false));
      case 'metadata':
        meta = _parseMetadataTrip(e);
    }
  }
  return GpxFile(waypoints: waypoints, paths: paths, metadataTrip: meta);
}

String _wptXml(Waypoint w) {
  final b = StringBuffer('  <wpt lat="${_lat(w.latLng)}" lon="${_lon(w.latLng)}">\n');
  if (w.name.isNotEmpty) b.write('    <name>${_esc(w.name)}</name>\n');
  if (w.desc != null) b.write('    <desc>${_esc(w.desc!)}</desc>\n');
  if (w.time != null) b.write('    <time>${_iso(w.time!)}</time>\n');
  b.write('    <extensions>\n');
  b.write('      <atrip:id>${w.id}</atrip:id>\n');
  if (w.isEvent) b.write('      <atrip:eventType>life</atrip:eventType>\n');
  if (w.timePrecision != null) {
    b.write('      <atrip:timePrecision>${w.timePrecision!.wire}</atrip:timePrecision>\n');
  }
  if (w.fromName != null) b.write('      <atrip:fromName>${_esc(w.fromName!)}</atrip:fromName>\n');
  if (w.fromLatLng != null) {
    b.write('      <atrip:fromLat>${_lat(w.fromLatLng!)}</atrip:fromLat>\n');
    b.write('      <atrip:fromLon>${_lon(w.fromLatLng!)}</atrip:fromLon>\n');
  }
  if (w.mediaId != null) b.write('      <atrip:mediaId>${w.mediaId}</atrip:mediaId>\n');
  b.write('      <atrip:createdAt>${_iso(w.createdAt)}</atrip:createdAt>\n');
  b.write('      <atrip:updatedAt>${_iso(w.updatedAt)}</atrip:updatedAt>\n');
  b.write('    </extensions>\n');
  b.write('  </wpt>\n');
  return b.toString();
}

String _pathXml(PathData p) {
  final tag = p.isGps ? 'trk' : 'rte';
  final b = StringBuffer('  <$tag>\n');
  if (p.name.isNotEmpty) b.write('    <name>${_esc(p.name)}</name>\n');
  if (p.desc != null) b.write('    <desc>${_esc(p.desc!)}</desc>\n');
  b.write('    <extensions>\n');
  b.write('      <atrip:id>${p.id}</atrip:id>\n');
  if (p.mediaId != null) b.write('      <atrip:mediaId>${p.mediaId}</atrip:mediaId>\n');
  if (p.startEventId != null) b.write('      <atrip:startEventId>${p.startEventId}</atrip:startEventId>\n');
  if (p.startLat != null) b.write('      <atrip:startLat>${p.startLat}</atrip:startLat>\n');
  if (p.startLon != null) b.write('      <atrip:startLon>${p.startLon}</atrip:startLon>\n');
  if (p.endEventId != null) b.write('      <atrip:endEventId>${p.endEventId}</atrip:endEventId>\n');
  if (p.endLat != null) b.write('      <atrip:endLat>${p.endLat}</atrip:endLat>\n');
  if (p.endLon != null) b.write('      <atrip:endLon>${p.endLon}</atrip:endLon>\n');
  b.write('      <atrip:createdAt>${_iso(p.createdAt)}</atrip:createdAt>\n');
  b.write('      <atrip:updatedAt>${_iso(p.updatedAt)}</atrip:updatedAt>\n');
  b.write('    </extensions>\n');
  if (p.isGps) {
    b.write('    <trkseg>\n');
    for (final pt in p.points) {
      b.write('      <trkpt lat="${_lat(pt.latLng)}" lon="${_lon(pt.latLng)}"');
      if (pt.time != null) {
        b.write('>\n        <time>${_iso(pt.time!)}</time>\n      </trkpt>\n');
      } else {
        b.write('/>\n');
      }
    }
    b.write('    </trkseg>\n');
  } else {
    for (final pt in p.points) {
      b.write('      <rtept lat="${_lat(pt.latLng)}" lon="${_lon(pt.latLng)}"/>\n');
    }
  }
  b.write('  </$tag>\n');
  return b.toString();
}

String _metadataXml(Trip t) {
  final b = StringBuffer('  <metadata>\n');
  b.write('    <extensions>\n');
  b.write('      <atrip:trip>\n');
  b.write('        <atrip:id>${t.id}</atrip:id>\n');
  b.write('        <atrip:name>${_esc(t.name)}</atrip:name>\n');
  if (t.description != null) b.write('        <atrip:description>${_esc(t.description!)}</atrip:description>\n');
  if (t.cover != null) b.write('        <atrip:cover>${t.cover}</atrip:cover>\n');
  if (t.startDate != null) b.write('        <atrip:startDate>${_iso(t.startDate!)}</atrip:startDate>\n');
  if (t.endDate != null) b.write('        <atrip:endDate>${_iso(t.endDate!)}</atrip:endDate>\n');
  if (t.startEventId != null) b.write('        <atrip:startEventId>${t.startEventId}</atrip:startEventId>\n');
  if (t.endEventId != null) b.write('        <atrip:endEventId>${t.endEventId}</atrip:endEventId>\n');
  b.write('        <atrip:createdAt>${_iso(t.createdAt)}</atrip:createdAt>\n');
  b.write('        <atrip:updatedAt>${_iso(t.updatedAt)}</atrip:updatedAt>\n');
  b.write('      </atrip:trip>\n');
  b.write('    </extensions>\n');
  b.write('  </metadata>\n');
  return b.toString();
}

/// 生成 GPX 文本。metadata 非空时写入行程元数据。
String toGpx(GpxFile gpx, {Trip? trip}) {
  final b = StringBuffer();
  b.write('<?xml version="1.0" encoding="UTF-8"?>\n');
  b.write(
      '<gpx version="1.1" creator="AdventuringTime" xmlns="http://www.topografix.com/GPX/1/1" xmlns:atrip="$_atripNs">\n');
  if (trip != null) b.write(_metadataXml(trip));
  for (final w in gpx.waypoints) {
    b.write(_wptXml(w));
  }
  for (final p in gpx.paths) {
    b.write(_pathXml(p));
  }
  b.write('</gpx>\n');
  return b.toString();
}

/// 生成 JSON（trip.json / profile.json）。
String toJsonString(Map<String, dynamic> m) => const JsonEncoder.withIndent('  ').convert(m);
