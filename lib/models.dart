import 'package:latlong2/latlong.dart';

/// 数据模型：人 / 行程 / 地点(事件) / 路径。
/// 所有对象对应磁盘上的 JSON 或 GPX 文件（见 gpx_io.dart / storage.dart）。

String newId() {
  final r = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
  final s = DateTime.now().millisecondsSinceEpoch.toRadixString(16);
  return '$r$s${(r.hashCode & 0xffff).toRadixString(16)}';
}
/// 时间模糊精度。year 时 time 存当年 1月1日，month 存当月 1日，day 存精确日期。
enum TimePrecision { year, month, day }

extension TimePrecisionX on TimePrecision {
  String get wire => name; // year / month / day

  static TimePrecision? parse(String? s) => switch (s) {
        'year' => TimePrecision.year,
        'month' => TimePrecision.month,
        'day' => TimePrecision.day,
        _ => null,
      };
}

/// 时间按精度格式化："2008年" / "2008年3月" / "2008年3月5日"
String formatTime(DateTime t, TimePrecision? p) {
  switch (p) {
    case TimePrecision.year:
      return '${t.year}年';
    case TimePrecision.month:
      return '${t.year}年${t.month}月';
    default:
      return '${t.year}年${t.month}月${t.day}日';
  }
}

/// 个人信息，对应 profile.json。
class Person {
  final String id;
  String name;
  String? avatar; // mediaId
  String? bio;
  final DateTime createdAt;
  DateTime updatedAt;

  Person({
    required this.id,
    required this.name,
    this.avatar,
    this.bio,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'avatar': avatar,
        'bio': bio,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory Person.fromJson(Map<String, dynamic> j) => Person(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        avatar: j['avatar'] as String?,
        bio: j['bio'] as String?,
        createdAt: DateTime.parse(j['createdAt'] as String),
        updatedAt: DateTime.parse(j['updatedAt'] as String),
      );
}

/// 行程元数据，对应 trip.json（同时写入 trip.gpx 的 metadata 扩展）。
class Trip {
  final String id;
  String name;
  String? description;
  String? cover; // mediaId
  DateTime? startDate; // 标志时间点
  DateTime? endDate;
  String? startEventId; // 起终点事件引用（同人）
  String? endEventId;
  final DateTime createdAt;
  DateTime updatedAt;

  Trip({
    required this.id,
    required this.name,
    this.description,
    this.cover,
    this.startDate,
    this.endDate,
    this.startEventId,
    this.endEventId,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'cover': cover,
        'startDate': startDate?.toIso8601String(),
        'endDate': endDate?.toIso8601String(),
        'startEventId': startEventId,
        'endEventId': endEventId,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory Trip.fromJson(Map<String, dynamic> j) => Trip(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        description: j['description'] as String?,
        cover: j['cover'] as String?,
        startDate: _parseTime(j['startDate']),
        endDate: _parseTime(j['endDate']),
        startEventId: j['startEventId'] as String?,
        endEventId: j['endEventId'] as String?,
        createdAt: _parseTime(j['createdAt']) ?? DateTime.now(),
        updatedAt: _parseTime(j['updatedAt']) ?? DateTime.now(),
      );

  static DateTime? _parseTime(dynamic v) =>
      v is String && v.isNotEmpty ? DateTime.tryParse(v) : null;
}

/// 地点 waypoint。isEvent=true 时为长期地点（人生轨迹节点，星标）。
/// 归属容器：life.gpx（未归入行程）或某 trip.gpx（已归入行程），单一存储。
class Waypoint {
  final String id;
  String name;
  String? desc;
  LatLng latLng;
  DateTime? time; // 到达时间（必填：所有地点都有）
  TimePrecision? timePrecision;
  bool isEvent; // atrip:eventType=life
  String? fromName;
  LatLng? fromLatLng; // A→B 起点（可选）
  String? mediaId;
  final DateTime createdAt;
  DateTime updatedAt;

  Waypoint({
    required this.id,
    required this.name,
    this.desc,
    required this.latLng,
    this.time,
    this.timePrecision,
    this.isEvent = false,
    this.fromName,
    this.fromLatLng,
    this.mediaId,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 显示时间（无则 null），供时间线排序/展示。
  DateTime? get sortTime => time;
}

/// 路径：GPS 轨迹（trk，点带 time）或手绘路径（rte，点无 time）。
class PathData {
  final String id;
  String name;
  String? desc;
  String? mediaId;
  final bool isGps; // true=trk, false=rte
  List<TrackPoint> points;
  String? startEventId;
  double? startLat, startLon;
  String? endEventId;
  double? endLat, endLon;
  final DateTime createdAt;
  DateTime updatedAt;

  PathData({
    required this.id,
    required this.name,
    this.desc,
    this.mediaId,
    required this.isGps,
    required this.points,
    this.startEventId,
    this.startLat,
    this.startLon,
    this.endEventId,
    this.endLat,
    this.endLon,
    required this.createdAt,
    required this.updatedAt,
  });

  LatLng get start => points.first.latLng;
  LatLng get end => points.last.latLng;
}

class TrackPoint {
  final LatLng latLng;
  final DateTime? time; // GPS 轨迹有；手绘无

  TrackPoint(this.latLng, [this.time]);

  LatLng get latLngValue => latLng;
}

/// 一份 GPX 文件的解析结果。
class GpxFile {
  final List<Waypoint> waypoints;
  final List<PathData> paths; // trk + rte 统一存放（isGps 区分）
  Trip? metadataTrip; // 从 metadata 扩展读出的行程元数据

  GpxFile({
    List<Waypoint>? waypoints,
    List<PathData>? paths,
    this.metadataTrip,
  })  : waypoints = waypoints ?? [],
        paths = paths ?? [];

  List<Waypoint> get events => waypoints.where((w) => w.isEvent).toList();
  List<Waypoint> get places => waypoints.where((w) => !w.isEvent).toList();
  List<PathData> get tracks => paths.where((p) => p.isGps).toList();
  List<PathData> get routes => paths.where((p) => !p.isGps).toList();

  Waypoint? waypointById(String id) {
    for (final w in waypoints) {
      if (w.id == id) return w;
    }
    return null;
  }

  PathData? pathById(String id) {
    for (final p in paths) {
      if (p.id == id) return p;
    }
    return null;
  }
}

/// 行程完整数据：元数据 + GPX 内容。
class TripBundle {
  Trip meta;
  GpxFile gpx;

  TripBundle({required this.meta, required this.gpx});
}

/// 同步删除墓碑，存于 manifest.json，随清单传播给其他端。
class SyncTombstone {
  final String type; // trip | life | media
  final String unitId;
  final DateTime updatedAt; // 删除时间

  SyncTombstone({required this.type, required this.unitId, required this.updatedAt});

  Map<String, dynamic> toJson() => {
        'type': type,
        'unitId': unitId,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  factory SyncTombstone.fromJson(Map<String, dynamic> j) => SyncTombstone(
        type: j['type'] as String,
        unitId: j['unitId'] as String,
        updatedAt: DateTime.parse(j['updatedAt'] as String),
      );
}
