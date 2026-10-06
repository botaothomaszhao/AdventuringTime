import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import '../geo_search.dart';
import '../lifecycle.dart';
import '../location_service.dart';
import '../models.dart';
import '../providers.dart';
import '../tile_cache.dart';
import 'dialogs.dart';
import 'person_shell.dart';
import 'widgets.dart';

/// 弹卡下方"倒凸"行程跳转按钮的高度；用于让弹卡保持原位、按钮向下突出。
const double _tripTabHeight = 44.0;

/// 地图页：图层（地点/长期地点/路径/人生轨迹线）、点击弹卡、增删改、
/// 轨迹切分、地址搜索、行程标记。
class MapPage extends ConsumerStatefulWidget {
  /// 可为空：无人物时地图照常显示（不含任何人的数据），操作走提示。
  final String? personId;

  const MapPage({super.key, this.personId});

  @override
  ConsumerState<MapPage> createState() => _MapPageState();
}

enum _EditMode { none, addPlace, splitPath }

/// 图层筛选：长期地点开关 + 勾选行程；touched 前默认"全部"全开。
class _LayerToggles {
  bool events = true;
  bool touched = false;
  final Set<String> tripIds = {};
}

class _Selected {
  final String label;
  final Widget? detail;
  final DateTime? time;
  final TimePrecision? precision;
  final List<Widget> Function() actions;
  final String? tripLabel; // 所属行程跳转标签（卡片下方居中的凸出按钮）
  final VoidCallback? onOpenTrip; // 点击后切到该行程的弹卡
  final String? pathKey; // 'tripId|pathId'，非空时地图上高亮该轨迹
  const _Selected({
    required this.label,
    this.detail,
    this.time,
    this.precision,
    required this.actions,
    this.tripLabel,
    this.onOpenTrip,
    this.pathKey,
  });
}

class _MapPageState extends ConsumerState<MapPage>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  final MapController _mapCtrl = MapController();
  final Map<String, _LayerToggles> _toggles = {};
  _EditMode _mode = _EditMode.none;
  String? _editKey; // 'tripId|pathId'
  int? _splitIndex; // 切分模式：已选采样点下标
  _Selected? _selected;
  List<GeoResult> _searchResults = [];
  String _searchQ = '';
  bool _searching = false;
  String? _searchError;
  GeoResult? _searchFocus; // 已跳转到地图位置的搜索结果（点同一项再保存）
  String? _pendingTripId; // 添加地点模式的目标行程（从行程弹窗进入时预选）
  DiskCachedTileProvider? _tileProvider;
  LatLng? _myPos; // 实时定位点（geolocator 流，仅前台订阅）
  DateTime? _myPosTime; // geolocator 定位时间
  LatLng? _livePos; // 记录中前台服务实时位置
  DateTime? _livePosTime; // 实时位置定位时间
  double? _liveSpeedMps; // 实时速度（每秒位置差计算，仅记录中）
  StreamSubscription<Position>? _posSub;
  StreamSubscription<RawPoint>? _liveSub;
  bool _locPermissionOk = false;
  Timer? _bgCancelTimer; // 未记录进后台延迟取消 geolocator 的定时器
  int _activePointers = 0; // 地图上当前按下的触点数量

  static const _palette = [
    Color(0xFF2E7D32),
    Color(0xFFC62828),
    Color(0xFF1565C0),
    Color(0xFF6A1B9A),
    Color(0xFFEF6C00),
    Color(0xFF00838F),
  ];

  static const _minZoom = 1.0;
  static const _maxZoom = 19.0;
  static const _highlightColor = Color(0xFFFF6D00); // 轨迹选中/切分高亮

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initTileProvider();
    if (Platform.isAndroid) _initMyLocation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _bgCancelTimer?.cancel();
    _posSub?.cancel();
    _liveSub?.cancel();
    super.dispose();
  }

  /// 前后台切换：前台恢复定位（服务 1s、geolocator 蓝点）；后台记录中 geolocator
  /// 保持（GPS 热，回前台蓝点不冷启动），未记录时延迟一段时间再取消（快速切回仍可用）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!Platform.isAndroid) return;
    if (state == AppLifecycleState.resumed) {
      _bgCancelTimer?.cancel();
      _bgCancelTimer = null;
      LocationService.setMode('foreground');
      // 前台期间 geolocator 持续订阅保持 GPS 热（仅未记录进后台超时后取消）；
      // 回前台若被取消则重订阅并先用系统最后位置兜底
      if (_locPermissionOk && _posSub == null) {
        _subscribeGeo();
        _seedLastKnownPosition();
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      LocationService.setMode('background');
      _bgCancelTimer?.cancel();
      _bgCancelTimer = null;
      final recording = ref.read(recordingProvider).status == RecordStatus.recording;
      if (recording) return; // 记录中保持 geolocator，回前台不冷启动
      // 未记录：延迟 60s 再取消订阅，短时间内切回仍可直接使用
      _bgCancelTimer = Timer(const Duration(seconds: 60), () {
        if (!mounted) return;
        _posSub?.cancel();
        _posSub = null;
      });
    }
  }

  /// 蓝点：请求定位权限并订阅实时位置。空闲用 geolocator 流；
  /// 记录中（前台）用前台服务推送的实时位置。
  Future<void> _initMyLocation() async {
    if (!await LocationService.ensureLocationPermission()) return;
    if (!mounted) return;
    _locPermissionOk = true;
    _subscribeGeo();
    _liveSub = LocationService.positions().listen(_onLivePos);
    final l = WidgetsBinding.instance.lifecycleState;
    await LocationService.setMode(
        l == AppLifecycleState.resumed ? 'foreground' : 'background');
  }

  /// 前台服务实时位置：更新蓝点并据此算实时速度（每秒数据，非采样点）。
  void _onLivePos(RawPoint p) {
    if (!mounted) return;
    setState(() {
      final prev = _livePos;
      final prevT = _livePosTime;
      _livePos = p.latLng;
      _livePosTime = p.time;
      if (prev != null && prevT != null) {
        final dt = p.time.difference(prevT).inMilliseconds / 1000.0;
        // 间隔过短（抖动）或过大（后台恢复/无信号）时不更新速度
        _liveSpeedMps = (dt >= 0.3 && dt <= 10) ? haversineM(prev, p.latLng) / dt : null;
      }
    });
  }

  /// 订阅 geolocator 蓝点流（仅前台调用）；先取消旧订阅防泄漏。
  void _subscribeGeo() {
    _posSub?.cancel();
    _posSub =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 5,
          ),
        ).listen((p) {
          if (mounted) {
            setState(() {
              _myPos = LatLng(p.latitude, p.longitude);
              _myPosTime = p.timestamp;
            });
          }
        });
  }

  /// 订阅后立即用系统最后已知位置兜底，避免回前台等 GPS 冷启动期间蓝点卡在旧位。
  Future<void> _seedLastKnownPosition() async {
    if (!_locPermissionOk || !mounted) return;
    final p = await Geolocator.getLastKnownPosition();
    if (p != null && mounted) {
      setState(() {
        _myPos = LatLng(p.latitude, p.longitude);
        _myPosTime = p.timestamp;
      });
    }
  }

  /// 蓝点实时位置：取候选源（红线末端/geolocator/服务实时位置）中定位时间最新者——
  /// 前台位置流每秒更新占优；后台/回前台瞬间位置流冻结，红线末端（服务持续采样）
  /// 兜底，回前台时蓝点已随记录的线画好，避免停在记录的线中间的旧位置。
  LatLng? _currentBluePos(RecordState? rec) {
    LatLng? best;
    DateTime? bestT;
    void consider(DateTime? t, LatLng? p) {
      if (p == null) return;
      if (best == null || (t != null && (bestT == null || t.isAfter(bestT!)))) {
        best = p;
        bestT = t;
      }
    }

    if (rec != null && rec.points.isNotEmpty) {
      consider(rec.points.last.time, rec.points.last.latLng);
    }
    consider(_myPosTime, _myPos);
    consider(_livePosTime, _livePos);
    return best;
  }

  /// 添加地点模式下点击蓝点：在当前位置添加地点。
  void _onMyPosTap() {
    if (_mode != _EditMode.addPlace) return;
    final p = _currentBluePos(
      Platform.isAndroid ? ref.read(recordingProvider) : null,
    );
    if (p == null) return;
    _addWaypointAt(p);
  }

  /// 相机回到我的位置并把地图方向复位到正北。
  void _centerOnMyPos() {
    final p = _currentBluePos(
      Platform.isAndroid ? ref.read(recordingProvider) : null,
    );
    if (p == null) {
      // 定位不可用时也复位方向到正北，仅提示不移动相机
      _mapCtrl.rotate(0);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('定位不可用，请检查定位权限与开关')));
      return;
    }
    _mapCtrl.move(p, _mapCtrl.camera.zoom);
    _mapCtrl.rotate(0);
  }

  /// 放大：已达最大级则不动（避免 move 回最大值表现为缩小）。
  void _zoomIn() {
    final z = _mapCtrl.camera.zoom;
    if (z >= _maxZoom - 0.001) return;
    _mapCtrl.move(_mapCtrl.camera.center, (z + 1).clamp(_minZoom, _maxZoom));
  }

  /// 缩小：已达最小级则不动。
  void _zoomOut() {
    final z = _mapCtrl.camera.zoom;
    if (z <= _minZoom + 0.001) return;
    _mapCtrl.move(_mapCtrl.camera.center, (z - 1).clamp(_minZoom, _maxZoom));
  }

  /// 无人物时地图操作不可用，提示先新建人物；有则执行。
  void _guardPerson(VoidCallback action) {
    if (widget.personId == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('需要先新建人物')));
      return;
    }
    action();
  }

  /// 左上角记录按钮：空闲时开始记录，记录中时停止并保存。
  Future<void> _onRecordButton(RecordState rec) async {
    final pid = widget.personId;
    if (pid == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('需要先新建人物')));
      return;
    }
    if (rec.status == RecordStatus.idle) {
      if (!await LocationService.ensureLocationPermission()) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('未获得定位权限，无法记录')));
        }
        return;
      }
      // 清除上个会话残留的实时位置，避免新会话蓝点先显示旧位置
      setState(() {
        _livePos = null;
        _livePosTime = null;
        _liveSpeedMps = null;
      });
      await ref.read(recordingProvider.notifier).start();
    } else {
      final pts = await ref.read(recordingProvider.notifier).stop();
      if (!mounted) return;
      if (pts.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('没有记录到有效定位点')));
        return;
      }
      final ok = await showRecordSaveDialog(
        context,
        personId: pid,
        points: pts,
      );
      if (ok && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('轨迹已保存')));
      }
    }
  }

  /// 点击位置与线段 a→b 的屏幕像素距离。
  /// 与 PolylineLayer 一致：projectList 对相邻点做 world 调整（跨 180° 时
  /// 翻转 ±360° 显示最短路径）；同时 workAcrossWorlds 会把跨世界线段重复
  /// 绘制到相邻 world，故遍历相邻副本取最近距离。
  double _distToSegmentPx(LatLng p, LatLng a, LatLng b) {
    final cam = _mapCtrl.camera;
    final wPx = cam.crs.scale(cam.zoom);
    final sp = cam.latLngToScreenOffset(p);
    final sa = cam.latLngToScreenOffset(a);
    var sb = cam.latLngToScreenOffset(b);
    if (sb.dx - sa.dx > wPx / 2) {
      sb -= Offset(wPx, 0);
    } else if (sb.dx - sa.dx < -wPx / 2) {
      sb += Offset(wPx, 0);
    }
    double dist(Offset a2, Offset b2) {
      final ab = b2 - a2;
      final ap = sp - a2;
      final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
      final t = len2 == 0
          ? 0.0
          : ((ap.dx * ab.dx + ap.dy * ab.dy) / len2).clamp(0.0, 1.0);
      return (sp - (a2 + ab * t)).distance;
    }

    var best = dist(sa, sb);
    for (final s in [-wPx, wPx]) {
      final d = dist(sa + Offset(s, 0), sb + Offset(s, 0));
      if (d < best) best = d;
    }
    return best;
  }

  /// 点击点到地点图标的屏幕像素距离（以图标中心为圆心：30px 标记框 topCenter 布局、
  /// 图标居中，中心位于实际位置上方 15px）。
  double _distToMarkerPx(LatLng p, LatLng a) {
    final cam = _mapCtrl.camera;
    final wPx = cam.crs.scale(cam.zoom);
    final sp = cam.latLngToScreenOffset(p);
    final sa = cam.latLngToScreenOffset(a) + const Offset(0, -15);
    var dx = sa.dx - sp.dx;
    if (dx > wPx / 2) {
      dx -= wPx;
    } else if (dx < -wPx / 2) {
      dx += wPx;
    }
    return Offset(dx, sa.dy - sp.dy).distance;
  }

  /// 点击位置命中检测：地点/长期地点优先，其次路径（有编辑操作），再次行程连接线；未命中则关闭卡片。
  /// 与图层筛选联动：仅命中可见的地点/路径/连接线。
  void _openAt(LatLng tap) {
    final pid = widget.personId;
    final d = _personData();
    if (d == null || pid == null) return;
    const thresh = 10.0;
    const wpThresh = 20.0;
    final toggles = _togglesOf(pid);
    final showAll = _allOn(toggles, d.trips);
    final visibleTrips = showAll
        ? d.trips
        : [
            for (final id in toggles.tripIds)
              if (d.tripById(id) != null) d.tripById(id)!,
          ];
    final showEvents = showAll || toggles.events;
    // 地点/长期地点优先（与渲染可见性一致，以图标中心为圆心测距）
    final waypointHits = <String, ({Waypoint w, String? tripId})>{};
    if (showEvents) {
      for (final w in d.life.waypoints) {
        waypointHits[w.id] = (w: w, tripId: null);
      }
    }
    for (final t in visibleTrips) {
      for (final w in t.gpx.waypoints) {
        waypointHits[w.id] = (w: w, tripId: t.meta.id);
      }
      for (final eid in [t.meta.startEventId, t.meta.endEventId]) {
        final e = _findWaypoint(d, eid);
        if (e != null && !waypointHits.containsKey(e.id)) {
          waypointHits[e.id] = (w: e, tripId: d.containerOf(e).$1);
        }
      }
    }
    String? bestWp;
    var bestWpDist = double.infinity;
    for (final MapEntry(key: id, value: hit) in waypointHits.entries) {
      final dist = _distToMarkerPx(tap, hit.w.latLng);
      if (dist < bestWpDist) {
        bestWpDist = dist;
        bestWp = id;
      }
    }
    if (bestWp != null && bestWpDist <= wpThresh) {
      final hit = waypointHits[bestWp]!;
      _selectWaypoint(hit.w, hit.tripId, pid);
      return;
    }
    // 路径优先
    for (final t in visibleTrips) {
      for (final p in t.gpx.paths) {
        for (var i = 1; i < p.points.length; i++) {
          if (_distToSegmentPx(
                tap,
                p.points[i - 1].latLng,
                p.points[i].latLng,
              ) <=
              thresh) {
            _selectPath(p, t.meta.id, pid);
            return;
          }
        }
      }
    }
    // 行程连接线（行程相关连接线属于行程，仅对勾选行程命中）
    final visibleConnTrips = showAll
        ? {for (final t in d.trips) t.meta.id}
        : toggles.tripIds;
    final life = buildLifePath(d.life.events, d.trips);
    String? bestTrip;
    var bestTripDist = double.infinity;
    for (final s in life.segs) {
      final tripId = s.tripId;
      if (tripId == null) continue;
      if (!visibleConnTrips.contains(tripId)) continue;
      final dist = _distToSegmentPx(tap, s.from, s.to);
      if (dist < bestTripDist) {
        bestTripDist = dist;
        bestTrip = tripId;
      }
    }
    if (bestTrip != null && bestTripDist <= thresh) {
      final t = d.tripById(bestTrip);
      if (t != null) {
        _selectTrip(t, pid);
        return;
      }
    }
    setState(() => _selected = null);
  }

  Future<void> _initTileProvider() async {
    final dir = await getApplicationSupportDirectory();
    if (!mounted) return;
    setState(() {
      _tileProvider = DiskCachedTileProvider(
        cacheDir: Directory('${dir.path}${Platform.pathSeparator}tiles'),
      );
    });
  }

  _LayerToggles _togglesOf(String personId) =>
      _toggles.putIfAbsent(personId, _LayerToggles.new);

  /// "全部"态：未手动筛选过默认全开；操作后为长期地点开着且行程全覆盖。
  bool _allOn(_LayerToggles toggles, List<TripBundle> trips) {
    if (!toggles.touched) return true;
    if (!toggles.events) return false;
    final allTripIds = [for (final t in trips) t.meta.id];
    if (allTripIds.isEmpty) return true;
    return allTripIds.every(toggles.tripIds.contains);
  }

  Future<void> _startAddTrip() async {
    final pid = widget.personId!;
    final form = await showTripDialog(context, personId: pid);
    if (form == null) return;
    final now = DateTime.now();
    final trip = Trip(
      id: newId(),
      name: form.name,
      description: form.description,
      mediaIds: form.mediaIds,
      startDate: form.startDate,
      endDate: form.endDate,
      startEventId: form.startEventId,
      endEventId: form.endEventId,
      createdAt: now,
      updatedAt: now,
    );
    form.applyTo(trip);
    await ref
        .read(personDataProvider(pid).notifier)
        .createTrip(trip);
  }

  // ---------- 数据 ----------

  (List<Person>, List<(String?, GpxFile)>) _peopleData() {
    final pid = widget.personId;
    final all = ref
        .watch(peopleProvider)
        .maybeWhen(data: (l) => l, orElse: () => <Person>[]);
    final people = pid == null ? <Person>[] : all.where((p) => p.id == pid).toList();
    final containers = <(String?, GpxFile)>[];
    final d = pid == null
        ? null
        : ref
            .watch(personDataProvider(pid))
            .maybeWhen(data: (d) => d, orElse: () => null);
    if (d != null) {
      for (final t in d.trips) {
        containers.add((t.meta.id, t.gpx));
      }
      containers.add((null, d.life));
    }
    return (people, containers);
  }

  List<(String?, GpxFile)> _allContainers(String personId) {
    final d = ref
        .read(personDataProvider(personId))
        .maybeWhen(data: (d) => d, orElse: () => null);
    if (d == null) return [];
    return [(null, d.life), for (final t in d.trips) (t.meta.id, t.gpx)];
  }

  List<Waypoint> _allWaypoints(String personId) => [
    for (final (_, g) in _allContainers(personId)) ...g.waypoints,
  ];

  List<PathData> _allPaths(String personId) => [
    for (final (_, g) in _allContainers(personId)) ...g.paths,
  ];

  PersonData? _personData() {
    final pid = widget.personId;
    if (pid == null) return null;
    return ref
        .read(personDataProvider(pid))
        .maybeWhen(data: (d) => d, orElse: () => null);
  }

  /// 按 id 找长期地点（life.gpx + 各行程内），供行程首尾引用。
  Waypoint? _findWaypoint(PersonData d, String? id) {
    if (id == null) return null;
    final w = d.life.waypointById(id);
    if (w != null) return w;
    for (final t in d.trips) {
      final w2 = t.gpx.waypointById(id);
      if (w2 != null) return w2;
    }
    return null;
  }

  // ---------- 选中弹卡 ----------

  void _selectWaypoint(Waypoint w, String? tripId, String personId) {
    final tripMeta = tripId == null ? null : _personData()?.tripById(tripId)?.meta;
    final tripName = (tripMeta == null || tripMeta.name.isEmpty)
        ? '所属行程'
        : tripMeta.name;
    setState(() {
      _selected = _Selected(
        label: w.name.isEmpty ? '（未命名）' : w.name,
        detail: w.desc == null ? null : Text(w.desc!),
        time: w.time,
        precision: w.timePrecision,
        tripLabel: tripId == null ? null : tripName,
        onOpenTrip: tripId == null
            ? null
            : () {
                final t = _personData()?.tripById(tripId);
                if (t != null) _selectTrip(t, personId);
              },
        actions: () {
          return [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑'),
              onTap: () async {
                final before = List<String>.of(w.mediaIds);
                final form = await showWaypointDialog(
                  context,
                  personId: personId,
                  existing: w,
                  tripId: tripId,
                );
                if (form == null) return;
                form.applyTo(w);
                w.updatedAt = DateTime.now();
                final notifier = ref.read(
                  personDataProvider(personId).notifier,
                );
                if (tripId == null) {
                  await notifier.saveLifeWaypoint(w);
                } else {
                  await notifier.saveTripWaypoint(tripId, w);
                }
                _closeSheet();
                await cleanupRemovedMedia(ref, personId, before, w.mediaIds);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除'),
              onTap: () async {
                final ok = await confirmDialog(
                  context,
                  '删除',
                  '确定删除该${w.isEvent ? '长期地点' : '地点'}？',
                );
                if (!ok) return;
                final notifier = ref.read(
                  personDataProvider(personId).notifier,
                );
                if (tripId == null) {
                  await notifier.deleteLifeWaypoint(w.id);
                } else {
                  await notifier.deleteTripWaypoint(tripId, w.id);
                }
                for (final id in w.mediaIds) {
                  await deleteMediaIfUnused(
                    ref,
                    personId,
                    id,
                    waypoints: _allWaypoints(personId),
                    paths: _allPaths(personId),
                  );
                }
                _closeSheet();
              },
            ),
          ];
        },
      );
    });
  }

  void _selectPath(PathData p, String tripId, String personId) {
    final tripMeta = _personData()?.tripById(tripId)?.meta;
    final tripName = (tripMeta == null || tripMeta.name.isEmpty)
        ? '所属行程'
        : tripMeta.name;
    final length = formatMeters(
      pathLengthM([for (final pt in p.points) pt.latLng]),
    );
    final s = pathSpeedStats(p.points);
    final speed =
        ' · 平均 ${formatSpeedKmh(s.avgMps)} · 最高 ${formatSpeedKmh(s.maxMps)}';
    setState(() {
      _selected = _Selected(
        label: p.name.isEmpty ? '（未命名路径）' : p.name,
        detail: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              runSpacing: 4,
              children: [
                const Text('GPS 轨迹'),
                const Text(' · '),
                Text('长度 $length$speed'),
              ],
            ),
            if (p.desc != null) Text(p.desc!),
          ],
        ),
        tripLabel: tripName,
        pathKey: '$tripId|${p.id}',
        onOpenTrip: () {
          final t = _personData()?.tripById(tripId);
          if (t != null) _selectTrip(t, personId);
        },
        actions: () {
          return [
            ListTile(
              leading: const Icon(Icons.edit_note_outlined),
              title: const Text('编辑信息'),
              onTap: () async {
                final before = List<String>.of(p.mediaIds);
                final form = await showPathDialog(
                  context,
                  personId: personId,
                  existing: p,
                  onDelete: () => _deletePathFromDialog(p, tripId, personId),
                );
                if (form == null) return;
                form.applyTo(p);
                p.updatedAt = DateTime.now();
                await ref
                    .read(personDataProvider(personId).notifier)
                    .saveTripPath(tripId, p);
                _closeSheet();
                await cleanupRemovedMedia(ref, personId, before, p.mediaIds);
              },
            ),
            if (p.points.length >= 4)
              ListTile(
                leading: const Icon(Icons.content_cut),
                title: const Text('切分轨迹'),
                onTap: () {
                  _closeSheet();
                  setState(() {
                    _mode = _EditMode.splitPath;
                    _editKey = '$tripId|${p.id}';
                    _splitIndex = null;
                  });
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除'),
              onTap: () async {
                final ok = await confirmDialog(context, '删除路径', '确定删除该路径？');
                if (!ok) return;
                await ref
                    .read(personDataProvider(personId).notifier)
                    .deleteTripPath(tripId, p.id);
                for (final id in p.mediaIds) {
                  await deleteMediaIfUnused(
                    ref,
                    personId,
                    id,
                    waypoints: _allWaypoints(personId),
                    paths: _allPaths(personId),
                  );
                }
                _closeSheet();
              },
            ),
          ];
        },
      );
    });
  }

  void _selectTrip(TripBundle t, String personId) {
    final stats = tripStats(t);
    setState(() {
      _selected = _Selected(
        label: t.meta.name.isEmpty ? '（未命名行程）' : t.meta.name,
        detail: Text(
          '${fmtDate(t.meta.startDate)} 至 ${fmtDate(t.meta.endDate)} · ${stats.placeCount} 个地点 · ${stats.pathCount} 条路径',
        ),
        actions: () {
          return [
            ListTile(
              leading: const Icon(Icons.add_location_alt_outlined),
              title: const Text('添加地点'),
              onTap: () {
                _closeSheet();
                setState(() {
                  _pendingTripId = t.meta.id;
                  _mode = _EditMode.addPlace;
                });
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑行程'),
              onTap: () async {
                final before = List<String>.of(t.meta.mediaIds);
                final form = await showTripDialog(
                  context,
                  personId: personId,
                  existing: t.meta,
                );
                if (form == null) return;
                form.applyTo(t.meta);
                t.meta.updatedAt = DateTime.now();
                await ref
                    .read(personDataProvider(personId).notifier)
                    .saveTripMeta(t.meta);
                _closeSheet();
                await cleanupRemovedMedia(ref, personId, before, t.meta.mediaIds);
              },
            ),
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('查看详情'),
              onTap: () {
                _closeSheet();
                Navigator.pushNamed(
                  context,
                  '/person/$personId/trip/${t.meta.id}',
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除'),
              onTap: () async {
                final ok = await confirmDialog(
                  context,
                  '删除行程',
                  '确定删除该行程（含其中地点与路径）？',
                );
                if (!ok) return;
                await ref
                    .read(personDataProvider(personId).notifier)
                    .deleteTrip(t.meta.id);
                _closeSheet();
              },
            ),
          ];
        },
      );
    });
  }

  void _closeSheet() {
    if (mounted) setState(() => _selected = null);
  }

  // ---------- 地图事件 ----------

  void _onTap(TapPosition pos, LatLng latlng) {
    // 多点触控下忽略"残留点击"：触点抬起时其余手指仍在按下（>=3 指滑动场景），
    // 此时不应把它当单指点击处理，否则连续弹窗会引发布局/键盘抖动导致卡死。
    if (_activePointers > 0) return;
    switch (_mode) {
      case _EditMode.none:
        _openAt(latlng);
      case _EditMode.addPlace:
        _addWaypointAt(latlng);
      case _EditMode.splitPath:
        _pickSplitPoint(latlng);
    }
  }

  /// 落点新增：搜索得到的用搜索词作默认名称；对话框打开后异步反向地理编码填充。
  Future<void> _addWaypointAt(LatLng latlng, {String? defaultName}) async {
    if (!mounted) return;
    final pid = widget.personId;
    if (pid == null) return;
    final tripId = _pendingTripId;
    final form = await showWaypointDialog(
      context,
      personId: pid,
      initialPos: latlng,
      defaultName: defaultName,
      tripId: tripId,
      presetTime: tripId == null
          ? DateTime.now()
          : (_presetTripTime(_personData()?.tripById(tripId)) ?? DateTime.now()),
    );
    if (form == null) {
      if (mounted) {
        setState(() {
          _mode = _EditMode.none;
          _pendingTripId = null;
        });
      }
      return;
    }
    final now = DateTime.now();
    final w = Waypoint(
      id: newId(),
      name: form.name,
      desc: form.desc,
      latLng: latlng,
      time: form.time,
      timePrecision: form.precision,
      isEvent: form.isEvent,
      mediaIds: form.mediaIds,
      createdAt: now,
      updatedAt: now,
    );
    form.applyTo(w);
    final notifier = ref.read(personDataProvider(pid).notifier);
    if (form.isEvent) {
      await notifier.saveLifeWaypoint(w);
    } else {
      await notifier.saveTripWaypoint(form.tripId!, w);
    }
    if (mounted) {
      setState(() {
        _mode = _EditMode.none;
        _searchResults = [];
        _searchQ = '';
        _searchFocus = null;
        _pendingTripId = null;
      });
    }
  }

  /// 行程添加地点时的预填时间：行程开始日期，其次最后一个地点/路径的时间。
  DateTime? _presetTripTime(TripBundle? t) {
    if (t == null) return null;
    if (t.meta.startDate != null) return t.meta.startDate;
    DateTime? last;
    for (final w in t.gpx.waypoints) {
      final tt = w.sortTime;
      if (tt != null && (last == null || tt.isAfter(last))) last = tt;
    }
    for (final p in t.gpx.paths) {
      final tt = p.points.firstOrNull?.time;
      if (tt != null && (last == null || tt.isAfter(last))) last = tt;
    }
    return last;
  }

  // ---------- 路径定位 ----------

  (String, String)? _editPathKey() {
    if (_editKey == null) return null;
    final parts = _editKey!.split('|');
    if (parts.length != 2) return null;
    return (parts[0], parts[1]);
  }

  PathData? _editingPath() {
    final key = _editPathKey();
    if (key == null) return null;
    final d = _personData();
    return d?.tripById(key.$1)?.gpx.pathById(key.$2);
  }

  // ---------- 轨迹切分 ----------

  /// 切分模式：点击轨迹附近，吸附到最近的采样点作为切分点（两侧各需至少 2 点）。
  void _pickSplitPoint(LatLng tap) {
    final editing = _editingPath();
    if (editing == null || editing.points.isEmpty) return;
    final cam = _mapCtrl.camera;
    final sp = cam.latLngToScreenOffset(tap);
    var best = 0;
    var bestD = double.infinity;
    for (var i = 0; i < editing.points.length; i++) {
      final d = (cam.latLngToScreenOffset(editing.points[i].latLng) - sp).distance;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    if (bestD > 40) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请点击轨迹附近选择切分点')));
      return;
    }
    if (best < 2 || best > editing.points.length - 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('切分点太靠近端点，两侧各需至少 2 个采样点')),
      );
      return;
    }
    setState(() => _splitIndex = best);
  }

  Future<void> _performSplit() async {
    final key = _editPathKey();
    final i = _splitIndex;
    final pid = widget.personId;
    final p = _editingPath();
    if (key == null || i == null || pid == null || p == null) return;
    final preview = splitGpsPath(p, i);
    final ok = await showSplitConfirmDialog(
      context,
      head: preview.head,
      tail: preview.tail,
    );
    if (!ok) return;
    await ref
        .read(personDataProvider(pid).notifier)
        .splitTripPath(key.$1, key.$2, i);
    if (!mounted) return;
    setState(() {
      _mode = _EditMode.none;
      _editKey = null;
      _splitIndex = null;
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已切分为两条轨迹')));
  }

  // ---------- 搜索 ----------

  Future<void> _doSearch() async {
    if (_searchQ.trim().isEmpty) return;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final results = await searchAddress(_searchQ.trim());
      if (!mounted) return;
      setState(() {
        _searchResults = results;
        _searching = false;
        _searchFocus = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _searchError = '搜索失败：$e';
      });
    }
  }

  void _gotoResult(GeoResult r) {
    final latlng = LatLng(r.lat, r.lon);
    if (_searchFocus != r) {
      // 第一次点：跳转到地图该位置，标记为选中；再点同一项才弹保存
      _mapCtrl.move(latlng, 14);
      setState(() => _searchFocus = r);
      return;
    }
    _addWaypointAt(latlng, defaultName: r.name);
    setState(() {
      _searchResults = [];
      _searchQ = '';
      _searchFocus = null;
    });
  }

  // ---------- 渲染 ----------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final pid = widget.personId;
    if (pid != null) {
      ref.listen(mapPageActionProvider(pid), (prev, next) {
        if (prev == null) return;
        if (next.requestId > prev.requestId && next.focus != null) {
          _mapCtrl.move(next.focus!, next.zoom);
        } else if (next.requestId > prev.requestId && next.showLayers) {
          _showLayerPanel();
        }
      });
    }

    final (people, containers) = _peopleData();
    final tileUrl = ref
        .watch(tileUrlProvider)
        .maybeWhen(data: (u) => u, orElse: () => '');
    // 瓦片层：深色模式下应用内置反色滤镜（容器级，性能好）
    final dark = Theme.of(context).brightness == Brightness.dark;
    final tileLayer = TileLayer(
      urlTemplate: tileUrl,
      userAgentPackageName: 'dev.adventuring.time',
      tileProvider: _tileProvider ?? CancellableNetworkTileProvider(),
      reset: tileReset.stream,
    );
    // 记录会话状态（仅 Android，Windows 不 watch 避免调用原生通道）
    final rec = Platform.isAndroid ? ref.watch(recordingProvider) : null;

    return Stack(
      children: [
        Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => _activePointers++,
          onPointerUp: (_) => _activePointers--,
          onPointerCancel: (_) => _activePointers--,
          child: FlutterMap(
            mapController: _mapCtrl,
              options: MapOptions(
                initialCenter: const LatLng(35.0, 105.0),
                initialZoom: 4,
                interactionOptions: const InteractionOptions(flags: InteractiveFlag.all),
                onTap: _onTap,
              ),
              children: [
                if (dark)
                  darkModeTilesContainerBuilder(context, tileLayer)
                else
                  tileLayer,
                ..._buildLayers(people, containers, rec),
                // 比例尺：安卓右下角有缩放按钮，上移避让；深色模式瓦片反色，用白字
              Scalebar(
                alignment: Alignment.bottomRight,
                padding: EdgeInsets.only(
                  right: 8,
                  bottom: Platform.isAndroid ? 160 : 8,
                ),
                textStyle: TextStyle(
                  color: dark ? Colors.white : Colors.black,
                  fontSize: 12,
                ),
                lineColor: dark ? Colors.white : Colors.black,
              ),
            ],
          ),
        ),
        if (Platform.isAndroid)
          Positioned(
            right: 8,
            bottom: 8,
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: '放大',
                    onPressed: _zoomIn,
                  ),
                  IconButton(
                    icon: const Icon(Icons.remove),
                    tooltip: '缩小',
                    onPressed: _zoomOut,
                  ),
                  IconButton(
                    icon: const Icon(Icons.my_location),
                    tooltip: '回到我的位置，方向复位正北',
                    onPressed: _centerOnMyPos,
                  ),
                ],
              ),
            ),
          ),
        if (_mode == _EditMode.splitPath) _buildModeBanner(),
        _buildSearchBar(),
        Positioned(left: 8, bottom: 8, child: _buildToolbar()),
        if (Platform.isAndroid && _mode == _EditMode.none)
          Positioned(
            left: 8,
            top: 8,
            child: FloatingActionButton.small(
              heroTag: 'record',
              tooltip: rec!.status == RecordStatus.idle ? '开始记录轨迹' : '停止记录并保存',
              onPressed: () => _onRecordButton(rec),
              child: Icon(
                rec.status == RecordStatus.idle
                    ? Icons.fiber_manual_record
                    : Icons.stop,
                color: rec.status == RecordStatus.idle ? Colors.red : null,
              ),
            ),
          ),
        if (Platform.isAndroid &&
            _mode == _EditMode.none &&
            rec != null &&
            rec.status != RecordStatus.idle)
          Positioned(
            top: 8,
            right: 8,
            child: _RecordHud(
              rec: rec,
              speedMps: _liveSpeedMps,
            ),
          ),
        if (_selected != null)
          // 弹卡底缘始终位于 bottom:64；有行程跳转按钮时，按钮向下突入该空隙，
          // 因此把整段(卡片+按钮)的底锚下移按钮高度，让卡片本身不抬升。
          Positioned(
            left: 8,
            right: 8,
            bottom: _selected!.onOpenTrip != null ? 64 - _tripTabHeight : 64,
            child: _SelectedCard(sel: _selected!, onClose: _closeSheet),
          ),
      ],
    );
  }

  List<Widget> _buildLayers(
    List<Person> people,
    List<(String?, GpxFile)> containers,
    RecordState? rec,
  ) {
    final layers = <Widget>[];
    var colorIdx = 0;
    final tripColors = <String, int>{};
    for (final p in people) {
      final toggles = _togglesOf(p.id);
      final d = ref
          .watch(personDataProvider(p.id))
          .maybeWhen(data: (d) => d, orElse: () => null);
      if (d == null) continue;
      final personLayers = <Widget>[];

      Color tripColor(String tripId) => _palette[tripColors.putIfAbsent(
            tripId,
            () => colorIdx++ % _palette.length,
          )];
      // 按 trips 固定顺序预分配全部行程颜色，避免不同筛选下分配顺序变化导致颜色漂移
      for (final t in d.trips) {
        tripColor(t.meta.id);
      }

      final showAll = _allOn(toggles, d.trips);
      // 可见行程：全部模式显示全部，否则仅勾选行程
      final visibleTrips = showAll
          ? d.trips
          : [
              for (final id in toggles.tripIds)
                if (d.tripById(id) != null) d.tripById(id)!,
            ];
      // 连接线可见行程集合（行程相关连接线属于行程，未勾选不显示）
      final visibleConnTrips = showAll
          ? {for (final t in d.trips) t.meta.id}
          : toggles.tripIds;
      final showEvents = showAll || toggles.events;

      // 长期地点标记：长期地点开关全显 + 勾选行程的首尾/行程内长期地点（按 id 去重）
      final eventMarkers = <String, Marker>{};
      final placeMarkers = <Marker>[];
      Marker eventMarker(Waypoint w) => Marker(
            point: w.latLng,
            width: 30,
            height: 30,
            alignment: Alignment.topCenter,
            child: const Icon(
              Icons.star,
              color: Color(0xFFE65100),
              size: 26,
              shadows: [Shadow(color: Colors.white, blurRadius: 3)],
            ),
          );
      if (showEvents) {
        for (final w in d.life.waypoints) {
          eventMarkers[w.id] = eventMarker(w);
        }
      }
      for (final t in visibleTrips) {
        for (final w in t.gpx.waypoints) {
          if (w.isEvent) {
            eventMarkers[w.id] = eventMarker(w);
          } else {
            placeMarkers.add(
              Marker(
                point: w.latLng,
                width: 30,
                height: 30,
                alignment: Alignment.topCenter,
                child: const Icon(
                  Icons.location_on,
                  color: Color(0xFF2E7D32),
                  size: 24,
                  shadows: [Shadow(color: Colors.white, blurRadius: 3)],
                ),
              ),
            );
          }
        }
        // 首尾长期地点始终显示（即使未勾选长期地点）
        for (final eid in [t.meta.startEventId, t.meta.endEventId]) {
          final e = _findWaypoint(d, eid);
          if (e != null && !eventMarkers.containsKey(e.id)) {
            eventMarkers[e.id] = eventMarker(e);
          }
        }
      }
      if (eventMarkers.isNotEmpty) {
        personLayers.add(MarkerLayer(markers: eventMarkers.values.toList()));
      }
      if (placeMarkers.isNotEmpty) {
        personLayers.add(MarkerLayer(markers: placeMarkers));
      }

      // 路径（勾选行程）；被点击选中的轨迹叠加橙色高亮（与切分一致）
      final hlKey = _selected?.pathKey;
      final polylines = <Polyline>[];
      final hlPolylines = <Polyline>[];
      for (final t in visibleTrips) {
        final color = tripColor(t.meta.id);
        for (final path in t.gpx.paths) {
          final key = '${t.meta.id}|${path.id}';
          final pts = [for (final pt in path.points) pt.latLng];
          polylines.add(
            Polyline<String>(
              points: pts,
              strokeWidth: 3,
              color: color.withValues(alpha: 0.85),
              hitValue: key,
            ),
          );
          if (key == hlKey) {
            hlPolylines.add(
              Polyline<String>(
                points: pts,
                strokeWidth: 6,
                color: _highlightColor.withValues(alpha: 0.6),
                hitValue: key,
              ),
            );
          }
        }
      }
      if (polylines.isNotEmpty) {
        personLayers.add(PolylineLayer(polylines: polylines));
      }
      if (hlPolylines.isNotEmpty) {
        personLayers.add(PolylineLayer(polylines: hlPolylines));
      }

      // 连接线：长期地点/全部模式画完整轨迹线（行程段用行程色、长期地点间灰色）；
      // 仅行程模式画勾选行程的内部连接线（行程色）
      final segs = <Polyline>[];
      Polyline connSeg(LifeSeg s, Color color) => Polyline(
            points: [s.from, s.to],
            strokeWidth: 2,
            color: color,
            pattern: StrokePattern.dashed(segments: const [8, 6]),
          );
      if (showEvents) {
        for (final s in buildLifePath(d.life.events, d.trips).segs) {
          final tripId = s.tripId;
          if (tripId == null) {
            segs.add(connSeg(s, const Color(0xFF9E9E9E)));
          } else if (visibleConnTrips.contains(tripId)) {
            segs.add(connSeg(s, tripColor(tripId)));
          }
        }
      } else {
        for (final t in visibleTrips) {
          final color = tripColor(t.meta.id);
          for (final s in tripInnerSegs(t, d.life.events)) {
            segs.add(connSeg(s, color));
          }
        }
      }
      if (segs.isNotEmpty) {
        personLayers.add(PolylineLayer(polylines: segs));
      }

      layers.addAll(personLayers);
    }

    // 切分模式：高亮被切分轨迹并标记已选切分点
    if (_mode == _EditMode.splitPath) {
      final split = _editingPath();
      if (split != null && split.points.isNotEmpty) {
        layers.add(
          PolylineLayer(
            polylines: [
              Polyline(
                points: [for (final pt in split.points) pt.latLng],
                strokeWidth: 6,
                color: _highlightColor.withValues(alpha: 0.6),
              ),
            ],
          ),
        );
        final i = _splitIndex;
        if (i != null && i < split.points.length) {
          layers.add(
            MarkerLayer(
              markers: [
                Marker(
                  point: split.points[i].latLng,
                  width: 30,
                  height: 30,
                  child: const Icon(
                    Icons.circle,
                    color: _highlightColor,
                    size: 20,
                    shadows: [Shadow(color: Colors.white, blurRadius: 3)],
                  ),
                ),
              ],
            ),
          );
        }
      }
    }

    // 添加地点模式：搜索结果用数字标注在地图上
    if (_mode == _EditMode.addPlace && _searchResults.isNotEmpty) {
      final numMarkers = <Marker>[];
      for (var i = 0; i < _searchResults.length; i++) {
        final idx = i;
        final r = _searchResults[i];
        numMarkers.add(
          Marker(
            point: LatLng(r.lat, r.lon),
            width: 30,
            height: 30,
            child: GestureDetector(
              onTap: () => _addWaypointAt(LatLng(r.lat, r.lon), defaultName: r.name),
              child: Container(
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: Color(0xFFD84315),
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '${idx + 1}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ),
        );
      }
      layers.add(MarkerLayer(markers: numMarkers));
    }

    // 记录中：本次会话轨迹实时预览
    if (rec != null && rec.points.length >= 2) {
      layers.add(
        PolylineLayer(
          polylines: [
            Polyline(
              points: [for (final t in rec.points) t.latLng],
              strokeWidth: 4,
              color: const Color(0xFFFF5722),
            ),
          ],
        ),
      );
    }

    // 蓝点：我的实时位置（仅 Android）
    final bluePos = _currentBluePos(rec);
    if (Platform.isAndroid && bluePos != null) {
      layers.add(
        MarkerLayer(
          markers: [
            Marker(
              point: bluePos,
              width: 40,
              height: 40,
              child: GestureDetector(
                onTap: _onMyPosTap,
                child: const Icon(
                  Icons.my_location,
                  color: Color(0xFF1565C0),
                  size: 30,
                  shadows: [Shadow(color: Colors.white, blurRadius: 4)],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return layers;
  }

  /// 切分模式提示：未选点提示选点，已选点显示切分点时间。
  String _splitBannerText() {
    final i = _splitIndex;
    final editing = _editingPath();
    if (i == null || editing == null || i >= editing.points.length) {
      return '点击轨迹附近选择切分点';
    }
    final t = editing.points[i].time;
    if (t == null) return '已选切分点，点完成切分';
    String two(int v) => v.toString().padLeft(2, '0');
    return '切分点：${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}，点完成切分';
  }

  Widget _buildModeBanner() {
    final msg = switch (_mode) {
      _EditMode.splitPath => _splitBannerText(),
      _EditMode.none || _EditMode.addPlace => '',
    };
    return Positioned(
      top: 8,
      left: 8,
      right: 8,
      child: Material(
        elevation: 3,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(child: Text(msg, style: const TextStyle(fontSize: 13))),
              TextButton(
                onPressed: () => setState(() {
                  _mode = _EditMode.none;
                  _editKey = null;
                  _splitIndex = null;
                }),
                child: const Text('退出'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    if (_mode != _EditMode.addPlace) return const SizedBox.shrink();
    return Positioned(
      top: 8,
      left: 8,
      right: 8,
      child: Material(
        elevation: 3,
        borderRadius: BorderRadius.circular(8),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      autofocus: true,
                      onChanged: (v) => setState(() => _searchQ = v),
                      onSubmitted: (_) => _doSearch(),
                      decoration: const InputDecoration(
                        hintText: '输入搜索，或直接点击地图选点',
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('search-btn'),
                    onPressed: _doSearch,
                    icon: _searching
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search),
                  ),
                  IconButton(
                    onPressed: () => setState(() {
                      _mode = _EditMode.none;
                      _searchResults = [];
                      _searchQ = '';
                      _searchFocus = null;
                    }),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            if (_searchError != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _searchError!,
                        style: const TextStyle(color: Colors.red, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            if (_searchResults.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text(
                  '结果已用数字标注在地图上，点击数字或下方列表选点',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            for (final r in _searchResults)
              ListTile(
                dense: true,
                selected: _searchFocus == r,
                leading: CircleAvatar(
                  radius: 11,
                  backgroundColor: _searchFocus == r
                      ? const Color(0xFF1565C0)
                      : const Color(0xFFD84315),
                  child: Text(
                    '${_searchResults.indexOf(r) + 1}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                title: Text(
                  r.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => _gotoResult(r),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(28),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: _mode == _EditMode.none ? _normalTools() : _modeTools(),
      ),
    );
  }

  List<Widget> _normalTools() {
    return [
      IconButton(
        icon: const Icon(Icons.location_on_outlined),
        tooltip: '添加地点',
        onPressed: () =>
            _guardPerson(() => setState(() => _mode = _EditMode.addPlace)),
      ),
      IconButton(
        icon: const Icon(Icons.luggage_outlined),
        tooltip: '新建行程',
        onPressed: () => _guardPerson(_startAddTrip),
      ),
    ];
  }

  List<Widget> _modeTools() {
    switch (_mode) {
      case _EditMode.splitPath:
        return [
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: '完成切分',
            onPressed: _splitIndex == null ? null : _performSplit,
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: '退出',
            onPressed: () => setState(() {
              _mode = _EditMode.none;
              _editKey = null;
              _splitIndex = null;
            }),
          ),
        ];
      case _EditMode.none || _EditMode.addPlace:
        return [
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: '退出',
            onPressed: () => setState(() => _mode = _EditMode.none),
          ),
        ];
    }
  }

  /// 路径编辑对话框内的删除：确认后删除并关闭对话框与编辑模式。
  Future<void> _deletePathFromDialog(
    PathData p,
    String tripId,
    String personId,
  ) async {
    final ok = await confirmDialog(context, '删除路径', '确定删除该路径？');
    if (!ok) return;
    await ref
        .read(personDataProvider(personId).notifier)
        .deleteTripPath(tripId, p.id);
    for (final id in p.mediaIds) {
      await deleteMediaIfUnused(
        ref,
        personId,
        id,
        waypoints: _allWaypoints(personId),
        paths: _allPaths(personId),
      );
    }
    if (context.mounted) Navigator.pop(context);
    if (mounted) {
      setState(() {
        _mode = _EditMode.none;
        _editKey = null;
        _selected = null;
      });
    }
  }

  void _showLayerPanel() {
    final pid = widget.personId!;
    final toggles = _togglesOf(pid);
    final d = ref
        .read(personDataProvider(pid))
        .maybeWhen(data: (d) => d, orElse: () => null);
    final allTripIds = [
      for (final t in d?.trips ?? const <TripBundle>[]) t.meta.id,
    ];

    showModalBottomSheet(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setSheet) {
          void refresh() {
            setSheet(() {});
            setState(() {});
          }

          // 首次操作时把"全部"态的隐含全选物化为显式 tripIds，后续增删基于真实选中集
          void enter() {
            if (!toggles.touched) {
              toggles.tripIds.addAll(allTripIds);
            }
            toggles.touched = true;
          }

          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    '图层',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                SwitchListTile(
                  title: const Text('全部'),
                  value: _allOn(toggles, d?.trips ?? const <TripBundle>[]),
                  onChanged: (v) {
                    toggles.touched = true;
                    toggles.events = v;
                    toggles.tripIds
                      ..clear()
                      ..addAll(v ? allTripIds : const <String>[]);
                    refresh();
                  },
                ),
                SwitchListTile(
                  title: const Text('长期地点'),
                  value: toggles.events,
                  onChanged: (v) {
                    enter();
                    toggles.events = v;
                    refresh();
                  },
                ),
                if (allTripIds.isNotEmpty) ...[
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '行程',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(c).colorScheme.outline,
                        ),
                      ),
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final t in d!.trips)
                          SwitchListTile(
                            dense: true,
                            title: Text(t.meta.name),
                            value:
                                !toggles.touched || toggles.tripIds.contains(t.meta.id),
                            onChanged: (v) {
                              enter();
                              if (v) {
                                toggles.tripIds.add(t.meta.id);
                              } else {
                                toggles.tripIds.remove(t.meta.id);
                              }
                              refresh();
                            },
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SelectedCard extends StatelessWidget {
  final _Selected sel;
  final VoidCallback onClose;
  const _SelectedCard({required this.sel, required this.onClose});

  @override
  Widget build(BuildContext context) {
    // 下方居中的凸出按钮：与卡片同底、窄于卡片，形成"倒凸字"向下突出，
    // 高度固定为 _tripTabHeight，弹卡因此保持原位；按钮在水平中点，不遮挡左右下角常驻按钮。
    final tab = sel.onOpenTrip == null
        ? null
        : Material(
            color: Theme.of(context).cardColor,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(10),
              bottom: Radius.circular(16),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: sel.onOpenTrip,
              child: SizedBox(
                height: _tripTabHeight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.luggage_outlined, size: 22),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          sel.tripLabel ?? '所属行程',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15),
                        ),
                      ),
                      const SizedBox(width: 2),
                      const Icon(Icons.arrow_drop_down, size: 26),
                    ],
                  ),
                ),
              ),
            ),
          );
    final card = Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    sel.label,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: onClose,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            if (sel.detail != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: sel.detail!,
              ),
            if (sel.time != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  formatTime(sel.time!, sel.precision),
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ...sel.actions(),
          ],
        ),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [card, if (tab != null) tab],
    );
  }
}

/// 记录中的右上角信息条：状态、时长、里程、实时速度。
class _RecordHud extends StatefulWidget {
  final RecordState rec;
  final double? speedMps; // 实时速度（每秒位置差计算）

  const _RecordHud({
    required this.rec,
    required this.speedMps,
  });

  @override
  State<_RecordHud> createState() => _RecordHudState();
}

class _RecordHudState extends State<_RecordHud> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 显示时长：计时=当前-会话开始（无暂停，路径一定是一整段，大退期间也算时间）。
  String _fmtDuration(RecordState rec) {
    final d = DateTime.now().difference(rec.startedAt ?? DateTime.now());
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  }

  @override
  Widget build(BuildContext context) {
    final rec = widget.rec;
    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        height: 40, // 与左侧开始记录按钮（FloatingActionButton.small）等高对齐
        child: Padding(
          padding: const EdgeInsets.only(left: 12, right: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.circle, size: 12, color: Colors.red),
              const SizedBox(width: 6),
              Text(_fmtDuration(rec), style: const TextStyle(fontSize: 15)),
              const SizedBox(width: 10),
              Text(
                formatMeters(rec.meters),
                style: const TextStyle(fontSize: 15),
              ),
              const SizedBox(width: 8),
              Text(
                formatSpeedKmh(widget.speedMps),
                style: const TextStyle(fontSize: 15),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
