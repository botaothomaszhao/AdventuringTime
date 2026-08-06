import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cancellable_tile_provider/flutter_map_cancellable_tile_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import '../geo_search.dart';
import '../lifecycle.dart';
import '../models.dart';
import '../providers.dart';
import '../tile_cache.dart';
import 'dialogs.dart';
import 'person_shell.dart';
import 'widgets.dart';

/// 地图页：图层（地点/长期地点/路径/人生轨迹线）、点击弹卡、增删改、
/// 手绘路径与顶点编辑、整体平移、地址搜索、行程标记。
class MapPage extends ConsumerStatefulWidget {
  final String personId;

  const MapPage({super.key, required this.personId});

  @override
  ConsumerState<MapPage> createState() => _MapPageState();
}

enum _EditMode { none, addPlace, drawPath, editPath, translatePath }

class _LayerToggles {
  bool places = true;
  bool events = true;
  bool paths = true;
  bool lifePath = true;
}

class _Selected {
  final String label;
  final String? detail;
  final DateTime? time;
  final List<Widget> Function() actions;
  const _Selected({required this.label, this.detail, this.time, required this.actions});
}

class _MapPageState extends ConsumerState<MapPage> with AutomaticKeepAliveClientMixin {
  final MapController _mapCtrl = MapController();
  final Map<String, _LayerToggles> _toggles = {};
  _EditMode _mode = _EditMode.none;
  final List<LatLng> _draftPoints = [];
  String? _editKey; // 'tripId|pathId'
  _Selected? _selected;
  List<GeoResult> _searchResults = [];
  String _searchQ = '';
  bool _searching = false;
  String? _searchError;  final Map<String, List<LatLng>> _translateOrig = {};
  String? _pendingTripId; // 添加地点模式的目标行程（从行程弹窗进入时预选）
  DiskCachedTileProvider? _tileProvider;
  final _pathHit = ValueNotifier<LayerHitResult<String>?>(null); // 路径层命中
  final _tripHit = ValueNotifier<LayerHitResult<String>?>(null); // 行程连接线层命中
  String? _hoveredPath; // 鼠标悬浮命中的路径（仅记录，点击才打开）
  String? _hoveredTrip; // 鼠标悬浮命中的行程连接线（仅记录，点击才打开）

  static const _palette = [
    Color(0xFF2E7D32), Color(0xFFC62828), Color(0xFF1565C0),
    Color(0xFF6A1B9A), Color(0xFFEF6C00), Color(0xFF00838F),
  ];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _initTileProvider();
    _pathHit.addListener(_onPathHit);
    _tripHit.addListener(_onTripHit);
  }

  @override
  void dispose() {
    _pathHit.dispose();
    _tripHit.dispose();
    super.dispose();
  }

  /// hover 只记录命中的线，不弹卡；点击时由 _onTap 打开。
  void _onPathHit() {
    final r = _pathHit.value;
    if (_mode != _EditMode.none || r == null || r.hitValues.isEmpty) {
      _hoveredPath = null;
    } else {
      _hoveredPath = r.hitValues.first;
    }
  }

  void _onTripHit() {
    final r = _tripHit.value;
    if (_mode != _EditMode.none || r == null || r.hitValues.isEmpty) {
      _hoveredTrip = null;
    } else {
      _hoveredTrip = r.hitValues.first;
    }
  }

  /// 打开悬停命中的实体（行程连接线优先，其次路径）。
  void _openHovered() {
    final d = _personData();
    final tripKey = _hoveredTrip;
    _hoveredTrip = null;
    if (tripKey != null) {
      final parts = tripKey.split('|');
      if (parts.length == 2 && parts[0] == 'trip') {
        final t = d?.tripById(parts[1]);
        if (t != null) {
          _selectTrip(t, widget.personId);
          return;
        }
      }
    }
    final pathKey = _hoveredPath;
    _hoveredPath = null;
    if (pathKey == null) return;
    final parts = pathKey.split('|');
    if (parts.length != 2) return;
    final p = d?.tripById(parts[0])?.gpx.pathById(parts[1]);
    if (p != null) _selectPath(p, parts[0], widget.personId);
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

  _LayerToggles _togglesOf(String personId) => _toggles.putIfAbsent(personId, _LayerToggles.new);

  Future<void> _startAddTrip() async {
    final form = await showTripDialog(context, personId: widget.personId);
    if (form == null) return;
    final now = DateTime.now();
    final trip = Trip(
      id: newId(),
      name: form.name,
      description: form.description,
      cover: form.cover,
      startDate: form.startDate,
      endDate: form.endDate,
      startEventId: form.startEventId,
      endEventId: form.endEventId,
      createdAt: now,
      updatedAt: now,
    );
    form.applyTo(trip);
    await ref.read(personDataProvider(widget.personId).notifier).createTrip(trip);
  }

  // ---------- 数据 ----------

  (List<Person>, List<(String?, GpxFile)>) _peopleData() {
    final all = ref.watch(peopleProvider).maybeWhen(data: (l) => l, orElse: () => <Person>[]);
    final people = all.where((p) => p.id == widget.personId).toList();
    final containers = <(String?, GpxFile)>[];
    final d = ref.watch(personDataProvider(widget.personId)).maybeWhen(data: (d) => d, orElse: () => null);
    if (d != null) {
      for (final t in d.trips) {
        containers.add((t.meta.id, t.gpx));
      }
      containers.add((null, d.life));
    }
    return (people, containers);
  }

  List<(String?, GpxFile)> _allContainers(String personId) {
    final d = ref.read(personDataProvider(personId)).maybeWhen(data: (d) => d, orElse: () => null);
    if (d == null) return [];
    return [(null, d.life), for (final t in d.trips) (t.meta.id, t.gpx)];
  }

  List<Waypoint> _allWaypoints(String personId) =>
      [for (final (_, g) in _allContainers(personId)) ...g.waypoints];

  List<PathData> _allPaths(String personId) =>
      [for (final (_, g) in _allContainers(personId)) ...g.paths];

  PersonData? _personData() =>
      ref.read(personDataProvider(widget.personId)).maybeWhen(data: (d) => d, orElse: () => null);

  // ---------- 选中弹卡 ----------

  void _selectWaypoint(Waypoint w, String? tripId, String personId) {
    final trips = ref
        .read(personDataProvider(personId))
        .maybeWhen(data: (d) => d.trips, orElse: () => <TripBundle>[]);
    setState(() {
      _selected = _Selected(
        label: w.name.isEmpty ? '（未命名）' : w.name,
        detail: w.desc,
        time: w.time,
        actions: () {
          return [
            if (w.isEvent)
              ListTile(
                leading: const Icon(Icons.swap_horiz),
                title: Text(tripId == null ? '移入行程' : '移出行程'),
                onTap: () async {
                  final notifier = ref.read(personDataProvider(personId).notifier);
                  if (tripId == null) {
                    if (trips.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('还没有行程，先新建一个')));
                      return;
                    }
                    final choice = await _pickTrip(trips);
                    if (choice != null) {
                      await notifier.moveEventToTrip(w.id, choice.id);
                      _closeSheet();
                    }
                  } else {
                    await notifier.moveEventOutOfTrip(w.id);
                    _closeSheet();
                  }
                },
              ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑'),
              onTap: () async {
                final form = await showWaypointDialog(context, personId: personId, existing: w, tripId: tripId);
                if (form == null) return;
                form.applyTo(w);
                w.updatedAt = DateTime.now();
                final notifier = ref.read(personDataProvider(personId).notifier);
                if (tripId == null) {
                  await notifier.saveLifeWaypoint(w);
                } else {
                  await notifier.saveTripWaypoint(tripId, w);
                }
                _closeSheet();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除'),
              onTap: () async {
                final ok = await confirmDialog(context, '删除', '确定删除该${w.isEvent ? '长期地点' : '地点'}？');
                if (!ok) return;
                if (w.mediaId != null) {
                  await deleteMediaIfUnused(ref, personId, w.mediaId!,
                      waypoints: _allWaypoints(personId), paths: _allPaths(personId));
                }
                final notifier = ref.read(personDataProvider(personId).notifier);
                if (tripId == null) {
                  await notifier.deleteLifeWaypoint(w.id);
                } else {
                  await notifier.deleteTripWaypoint(tripId, w.id);
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
    final length = formatMeters(pathLengthM([for (final pt in p.points) pt.latLng]));
    setState(() {
      _selected = _Selected(
        label: p.name.isEmpty ? '（未命名路径）' : p.name,
        detail: '${p.isGps ? 'GPS 轨迹' : '手绘路径'} · 长度 $length${p.desc != null ? '\n${p.desc}' : ''}',
        actions: () {
          return [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑路径'),
              onTap: () {
                _closeSheet();
                setState(() {
                  _mode = _EditMode.editPath;
                  _editKey = '$tripId|${p.id}';
                });
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_note_outlined),
              title: const Text('编辑信息'),
              onTap: () async {
                final form = await showPathDialog(
                  context,
                  personId: personId,
                  existing: p,
                  onDelete: () => _deletePathFromDialog(p, tripId, personId),
                );
                if (form == null) return;
                form.applyTo(p);
                p.updatedAt = DateTime.now();
                await ref.read(personDataProvider(personId).notifier).saveTripPath(tripId, p);
                _closeSheet();
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除'),
              onTap: () async {
                final ok = await confirmDialog(context, '删除路径', '确定删除该路径？');
                if (!ok) return;
                if (p.mediaId != null) {
                  await deleteMediaIfUnused(ref, personId, p.mediaId!,
                      waypoints: _allWaypoints(personId), paths: _allPaths(personId));
                }
                await ref.read(personDataProvider(personId).notifier).deleteTripPath(tripId, p.id);
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
        detail: '${fmtDate(t.meta.startDate)} 至 ${fmtDate(t.meta.endDate)} · ${stats.placeCount} 个地点 · ${stats.pathCount} 条路径',
        time: t.meta.startDate,
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
                final form = await showTripDialog(context, personId: personId, existing: t.meta);
                if (form == null) return;
                form.applyTo(t.meta);
                t.meta.updatedAt = DateTime.now();
                await ref.read(personDataProvider(personId).notifier).saveTripMeta(t.meta);
                _closeSheet();
              },
            ),
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('查看详情'),
              onTap: () {
                _closeSheet();
                Navigator.pushNamed(context, '/person/$personId/trip/${t.meta.id}');
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除'),
              onTap: () async {
                final ok = await confirmDialog(context, '删除行程', '确定删除该行程（含其中地点与路径）？');
                if (!ok) return;
                await ref.read(personDataProvider(personId).notifier).deleteTrip(t.meta.id);
                _closeSheet();
              },
            ),
          ];
        },
      );
    });
  }

  Future<Trip?> _pickTrip(List<TripBundle> trips) async {
    final choice = await showDialog<Trip>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('选择行程'),
        children: [
          for (final t in trips)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, t.meta),
              child: Text(t.meta.name),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, null),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    return choice;
  }

  void _closeSheet() {
    if (mounted) setState(() => _selected = null);
  }

  // ---------- 地图事件 ----------

  void _onTap(TapPosition pos, LatLng latlng) {
    switch (_mode) {
      case _EditMode.none:
        if (_hoveredTrip != null || _hoveredPath != null) {
          // 悬浮在连接线/路径上时点击 → 打开对应实体
          _openHovered();
        } else {
          setState(() {
            _selected = null;
            _hoveredTrip = null;
            _hoveredPath = null;
          });
        }
      case _EditMode.addPlace:
        _addWaypointAt(latlng);
      case _EditMode.drawPath:
        break; // 绘制模式下由外层 GestureDetector 处理（点完成结束）
      case _EditMode.editPath:
        break;
      case _EditMode.translatePath:
        break;
    }
  }

  /// 落点新增：搜索得到的用搜索词作默认名称；对话框打开后异步反向地理编码填充。
  Future<void> _addWaypointAt(LatLng latlng, {String? defaultName}) async {
    if (!mounted) return;
    final tripId = _pendingTripId;
    final form = await showWaypointDialog(
      context,
      personId: widget.personId,
      initialPos: latlng,
      defaultName: defaultName,
      tripId: tripId,
      presetTime: tripId == null ? null : _presetTripTime(_personData()?.tripById(tripId)),
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
      mediaId: form.mediaId,
      createdAt: now,
      updatedAt: now,
    );
    form.applyTo(w);
    final notifier = ref.read(personDataProvider(widget.personId).notifier);
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

  void _addDraftFromScreen(Offset localPos) {
    final latlng = _mapCtrl.camera.screenOffsetToLatLng(localPos);
    setState(() => _draftPoints.add(latlng));
  }

  /// 绘制模式：点击被拖动/双击抢走时撤销误加的点。
  void _undoDraftPoint() {
    if (_draftPoints.isNotEmpty) setState(() => _draftPoints.removeLast());
  }

  Future<void> _finishDrawPath() async {
    if (_draftPoints.length < 2) {
      if (mounted) setState(() => _draftPoints.clear());
      return;
    }
    final trips = List<TripBundle>.of(_personData()?.trips ?? const []);
    if (trips.isEmpty) {
      final form = await showTripDialog(context, personId: widget.personId);
      if (form == null) {
        if (mounted) setState(() { _mode = _EditMode.none; _draftPoints.clear(); });
        return;
      }
      final now = DateTime.now();
      final trip = Trip(id: newId(), name: form.name, createdAt: now, updatedAt: now);
      form.applyTo(trip);
      await ref.read(personDataProvider(widget.personId).notifier).createTrip(trip);
      trips.add(TripBundle(meta: trip, gpx: GpxFile()));
    }
    final trip = await _pickTrip(trips);
    if (trip == null) {
      if (mounted) setState(() { _mode = _EditMode.none; _draftPoints.clear(); });
      return;
    }
    final form = await showPathDialog(context, personId: widget.personId);
    if (!mounted) return;
    final now = DateTime.now();
    final path = PathData(
      id: newId(),
      name: form?.name ?? '手绘路径',
      desc: form?.desc,
      mediaId: form?.mediaId,
      isGps: false,
      points: [for (final p in _draftPoints) TrackPoint(p)],
      createdAt: now,
      updatedAt: now,
    );
    await ref.read(personDataProvider(widget.personId).notifier).saveTripPath(trip.id, path);
    if (mounted) setState(() { _mode = _EditMode.none; _draftPoints.clear(); });
  }

  // ---------- 顶点编辑 ----------

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

  PathData? _editingPathCopy() {
    final key = _editPathKey();
    if (key == null) return null;
    final d = _personData();
    final g = d?.tripById(key.$1)?.gpx;
    final p = g?.pathById(key.$2);
    if (p == null) return null;
    final copy = PathData(
      id: p.id,
      name: p.name,
      desc: p.desc,
      mediaId: p.mediaId,
      isGps: p.isGps,
      points: [for (final pt in p.points) TrackPoint(pt.latLng, pt.time)],
      createdAt: p.createdAt,
      updatedAt: p.updatedAt,
    );
    return copy;
  }

  Future<void> _savePath(PathData p) async {
    final key = _editPathKey()!;
    p.updatedAt = DateTime.now();
    await ref.read(personDataProvider(widget.personId).notifier).saveTripPath(key.$1, p);
  }

  // ---------- 平移 ----------

  void _startTranslate() {
    final key = _editPathKey()!;
    final p = _editingPath();
    if (p == null) return;
    _translateOrig[key.$2] = [for (final pt in p.points) pt.latLng];
    setState(() => _mode = _EditMode.translatePath);
  }

  void _finishTranslate() {
    _translateOrig.clear();
    setState(() => _mode = _EditMode.editPath);
  }

  void _applyTranslate(Offset delta) {
    final key = _editPathKey();
    if (key == null) return;
    final orig = _translateOrig[key.$2];
    if (orig == null) return;
    final path = _editingPathCopy();
    if (path == null) return;
    for (var i = 0; i < path.points.length; i++) {
      final src = orig[i];
      final p0 = _mapCtrl.camera.latLngToScreenOffset(src);
      path.points[i] = TrackPoint(_mapCtrl.camera.offsetToCrs(p0 + delta), path.points[i].time);
    }
    _savePath(path);
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
    _mapCtrl.move(latlng, 14);
    _addWaypointAt(latlng, defaultName: r.name);
    setState(() {
      _searchResults = [];
      _searchQ = '';
    });
  }

  // ---------- 渲染 ----------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    ref.listen(mapPageActionProvider(widget.personId), (prev, next) {
      if (prev == null) return;
      if (next.requestId > prev.requestId && next.focus != null) {
        _mapCtrl.move(next.focus!, next.zoom);
      } else if (next.requestId > prev.requestId && next.showLayers) {
        _showLayerPanel();
      }
    });

    final (people, containers) = _peopleData();
    final tileUrl = ref.watch(tileUrlProvider).maybeWhen(data: (u) => u, orElse: () => '');
    // 绘制模式下保留拖动/缩放，但关闭双击缩放（双击用于结束绘制）；整体平移禁用缩放防误触
    var flags = InteractiveFlag.all;
    if (_mode == _EditMode.translatePath) {
      flags = InteractiveFlag.drag;
    } else if (_mode == _EditMode.drawPath) {
      flags = InteractiveFlag.all & ~InteractiveFlag.doubleTapZoom;
    }

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapCtrl,
          options: MapOptions(
            initialCenter: const LatLng(35.0, 105.0),
            initialZoom: 4,
            interactionOptions: InteractionOptions(flags: flags),
            onTap: _onTap,
          ),
          children: [
            TileLayer(
              urlTemplate: tileUrl,
              userAgentPackageName: 'dev.adventuring.time',
              tileProvider: _tileProvider ?? CancellableNetworkTileProvider(),
            ),
            ..._buildLayers(people, containers),
            // 绘制模式预览线（必须在 FlutterMap 内，依赖 MapCamera；空点不渲染）
            if (_mode == _EditMode.drawPath && _draftPoints.isNotEmpty)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: _draftPoints,
                    strokeWidth: 3,
                    color: Colors.orange,
                    pattern: StrokePattern.dashed(segments: const [8, 6]),
                  ),
                ],
              ),
          ],
        ),
        if (_mode == _EditMode.drawPath)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapDown: (d) => _addDraftFromScreen(d.localPosition),
              onTapCancel: _undoDraftPoint,
            ),
          ),
        if (_mode == _EditMode.translatePath)
          Listener(
            behavior: HitTestBehavior.translucent,
            onPointerMove: (e) => _applyTranslate(e.localDelta),
            child: const SizedBox.expand(),
          ),
        if (_mode != _EditMode.none) _buildModeBanner(),
        _buildSearchBar(),
        Positioned(left: 8, bottom: 8, child: _buildToolbar()),
        if (_selected != null)
          Positioned(
            left: 8,
            right: 8,
            bottom: 64,
            child: _SelectedCard(sel: _selected!, onClose: _closeSheet),
          ),
      ],
    );
  }

  List<Widget> _buildLayers(List<Person> people, List<(String?, GpxFile)> containers) {
    final layers = <Widget>[];
    var colorIdx = 0;
    final tripColors = <String, int>{};
    for (final p in people) {
      final toggles = _togglesOf(p.id);
      final d = ref.watch(personDataProvider(p.id)).maybeWhen(data: (d) => d, orElse: () => null);
      if (d == null) continue;
      final personLayers = <Widget>[];

      for (final (tripId, gpx) in [
        for (final t in d.trips) (t.meta.id, t.gpx),
        (null, d.life),
      ]) {
        final color = tripId == null
            ? _palette[0]
            : _palette[tripColors.putIfAbsent(tripId, () => colorIdx++ % _palette.length)];

        if (toggles.places || toggles.events) {
          final markers = <Marker>[];
          for (final w in gpx.waypoints) {
            final isEv = w.isEvent;
            if (isEv && !toggles.events) continue;
            if (!isEv && !toggles.places) continue;
            markers.add(Marker(
              point: w.latLng,
              width: 30,
              height: 30,
              alignment: Alignment.topCenter,
              child: GestureDetector(
                onTap: () => _selectWaypoint(w, tripId, p.id),
                child: Icon(
                  isEv ? Icons.star : Icons.location_on,
                  color: isEv ? const Color(0xFFE65100) : const Color(0xFF2E7D32),
                  size: isEv ? 26 : 24,
                  shadows: const [Shadow(color: Colors.white, blurRadius: 3)],
                ),
              ),
            ));
          }
          personLayers.add(MarkerLayer(markers: markers));
        }

        if (toggles.paths) {
          final polylines = <Polyline>[];
          for (final path in gpx.paths) {
            polylines.add(Polyline<String>(
              points: [for (final pt in path.points) pt.latLng],
              strokeWidth: 3,
              color: color.withValues(alpha: 0.85),
              hitValue: '$tripId|${path.id}',
            ));
          }
          personLayers.add(PolylineLayer(
            polylines: polylines,
            hitNotifier: _pathHit,
            minimumHitbox: 10,
          ));
        }
      }

      if (toggles.lifePath) {
        final life = buildLifePath(d.life.events, d.trips);
        final tripSegs = <Polyline<String>>[];
        final otherSegs = <Polyline>[];
        for (final s in life.segs) {
          final line = Polyline(
            points: [s.from, s.to],
            strokeWidth: s.recorded ? 2.5 : 2,
            color: const Color(0xFFB71C1C),
            pattern: s.recorded
                ? const StrokePattern.solid()
                : StrokePattern.dashed(segments: const [8, 6]),
          );
          if (s.tripId != null) {
            tripSegs.add(Polyline<String>(
              points: [s.from, s.to],
              strokeWidth: s.recorded ? 2.5 : 2,
              color: const Color(0xFFB71C1C),
              pattern: s.recorded
                  ? const StrokePattern.solid()
                  : StrokePattern.dashed(segments: const [8, 6]),
              hitValue: 'trip|${s.tripId}',
            ));
          } else {
            otherSegs.add(line);
          }
        }
        if (otherSegs.isNotEmpty) {
          personLayers.add(PolylineLayer(polylines: otherSegs));
        }
        if (tripSegs.isNotEmpty) {
          // 行程段可点击：点开行程弹窗
          personLayers.add(PolylineLayer(
            polylines: tripSegs,
            hitNotifier: _tripHit,
            minimumHitbox: 10,
          ));
        }
      }

      layers.addAll(personLayers);
    }

    // 顶点编辑层
    final editing = _editingPath();
    if (_mode == _EditMode.editPath && editing != null) {
      final markers = <Marker>[];
      for (var i = 0; i < editing.points.length; i++) {
        final idx = i;
        final pt = editing.points[i];
        markers.add(Marker(
          point: pt.latLng,
          width: 26,
          height: 26,
          child: _DraggableVertex(
            mapCtrl: _mapCtrl,
            point: pt.latLng,
            onMove: (ll) => _moveVertex(editing, idx, ll),
            onTap: () => _deleteVertex(editing, idx),
          ),
        ));
      }
      for (var i = 1; i < editing.points.length; i++) {
        final idx = i;
        final a = editing.points[i - 1].latLng;
        final b = editing.points[i].latLng;
        markers.add(Marker(
          point: LatLng((a.latitude + b.latitude) / 2, (a.longitude + b.longitude) / 2),
          width: 22,
          height: 22,
          child: GestureDetector(
            onTap: () => _insertVertex(editing, idx),
            child: const Icon(Icons.add_circle_outline, color: Color(0xAA1565C0), size: 18),
          ),
        ));
      }
      layers.add(MarkerLayer(markers: markers));
    }

    // 添加地点模式：搜索结果用数字标注在地图上
    if (_mode == _EditMode.addPlace && _searchResults.isNotEmpty) {
      final numMarkers = <Marker>[];
      for (var i = 0; i < _searchResults.length; i++) {
        final idx = i;
        final r = _searchResults[i];
        numMarkers.add(Marker(
          point: LatLng(r.lat, r.lon),
          width: 30,
          height: 30,
          child: GestureDetector(
            onTap: () => _gotoResult(r),
            child: Container(
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: Color(0xFFD84315),
                shape: BoxShape.circle,
              ),
              child: Text(
                '${idx + 1}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
          ),
        ));
      }
      layers.add(MarkerLayer(markers: numMarkers));
    }

    return layers;
  }

  void _moveVertex(PathData p, int index, LatLng latlng) {
    final path = _editingPathCopy();
    if (path == null) return;
    path.points[index] = TrackPoint(latlng, path.points[index].time);
    _savePath(path);
  }

  void _insertVertex(PathData p, int index) {
    final path = _editingPathCopy();
    if (path == null) return;
    final a = path.points[index - 1].latLng;
    final b = path.points[index].latLng;
    path.points.insert(
      index,
      TrackPoint(LatLng((a.latitude + b.latitude) / 2, (a.longitude + b.longitude) / 2)),
    );
    _savePath(path);
  }

  void _deleteVertex(PathData p, int index) {
    final path = _editingPathCopy();
    if (path == null) return;
    if (path.points.length <= 2) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('至少保留 2 个顶点')));
      return;
    }
    path.points.removeAt(index);
    _savePath(path);
  }

  Widget _buildModeBanner() {
    final msg = switch (_mode) {
      _EditMode.addPlace => '输入搜索或点击地图选点',
      _EditMode.drawPath => '点击落点，点完成结束（${_draftPoints.length} 点）',
      _EditMode.editPath => '拖动顶点、点顶点删除、点空心圆插入',
      _EditMode.translatePath => '拖动整条路径',
      _EditMode.none => '',
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
                  _draftPoints.clear();
                  _editKey = null;
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
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.search),
                  ),
                  IconButton(
                    onPressed: () => setState(() {
                      _mode = _EditMode.none;
                      _searchResults = [];
                      _searchQ = '';
                    }),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            if (_searchError != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Row(children: [
                  Expanded(child: Text(_searchError!, style: const TextStyle(color: Colors.red, fontSize: 12))),
                ]),
              ),
            if (_searchResults.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Text('结果已用数字标注在地图上，点击数字或下方列表选点',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              ),
            for (final r in _searchResults)
              ListTile(
                dense: true,
                leading: CircleAvatar(
                  radius: 11,
                  backgroundColor: const Color(0xFFD84315),
                  child: Text(
                    '${_searchResults.indexOf(r) + 1}',
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
                title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
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
        onPressed: () => setState(() => _mode = _EditMode.addPlace),
      ),
      IconButton(
        icon: const Icon(Icons.timeline),
        tooltip: '绘制路径',
        onPressed: () => setState(() {
          _mode = _EditMode.drawPath;
          _draftPoints.clear();
        }),
      ),
      IconButton(
        icon: const Icon(Icons.luggage_outlined),
        tooltip: '新建行程',
        onPressed: _startAddTrip,
      ),
    ];
  }

  List<Widget> _modeTools() {
    final editing = _editingPath();
    switch (_mode) {
      case _EditMode.editPath:
        return [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: '编辑信息',
            onPressed: editing == null ? null : () => _editPathInfo(editing),
          ),
          IconButton(
            icon: const Icon(Icons.open_with),
            tooltip: '整体平移',
            onPressed: editing == null ? null : _startTranslate,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '删除路径',
            onPressed: editing == null ? null : () => _deletePathFromEdit(editing),
          ),
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: '完成',
            onPressed: () => setState(() {
              _mode = _EditMode.none;
              _editKey = null;
            }),
          ),
        ];
      case _EditMode.translatePath:
        return [
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: '完成平移',
            onPressed: _finishTranslate,
          ),
        ];
      case _EditMode.drawPath:
        return [
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: '完成',
            onPressed: _finishDrawPath,
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: '退出',
            onPressed: () => setState(() {
              _mode = _EditMode.none;
              _draftPoints.clear();
            }),
          ),
        ];
      default:
        return [
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: '退出',
            onPressed: () => setState(() {
              _mode = _EditMode.none;
              _draftPoints.clear();
            }),
          ),
        ];
    }
  }

  Future<void> _editPathInfo(PathData p) async {
    final key = _editPathKey()!;
    final form = await showPathDialog(
      context,
      personId: widget.personId,
      existing: p,
      onDelete: () => _deletePathFromDialog(p, key.$1, widget.personId),
    );
    if (form == null) return;
    form.applyTo(p);
    p.updatedAt = DateTime.now();
    await ref.read(personDataProvider(widget.personId).notifier).saveTripPath(key.$1, p);
  }

  /// 路径编辑对话框内的删除：确认后删除并关闭对话框与编辑模式。
  Future<void> _deletePathFromDialog(PathData p, String tripId, String personId) async {
    final ok = await confirmDialog(context, '删除路径', '确定删除该路径？');
    if (!ok) return;
    if (p.mediaId != null) {
      await deleteMediaIfUnused(ref, personId, p.mediaId!,
          waypoints: _allWaypoints(personId), paths: _allPaths(personId));
    }
    await ref.read(personDataProvider(personId).notifier).deleteTripPath(tripId, p.id);
    if (context.mounted) Navigator.pop(context);
    if (mounted) {
      setState(() {
        _mode = _EditMode.none;
        _editKey = null;
        _selected = null;
      });
    }
  }

  Future<void> _deletePathFromEdit(PathData p) async {
    final key = _editPathKey()!;
    final ok = await confirmDialog(context, '删除路径', '确定删除该路径？');
    if (!ok) return;
    if (p.mediaId != null) {
      await deleteMediaIfUnused(ref, widget.personId, p.mediaId!,
          waypoints: _allWaypoints(widget.personId), paths: _allPaths(widget.personId));
    }
    await ref.read(personDataProvider(widget.personId).notifier).deleteTripPath(key.$1, p.id);
    if (mounted) {
      setState(() {
        _mode = _EditMode.none;
        _editKey = null;
      });
    }
  }

  void _showLayerPanel() {
    final current = _togglesOf(widget.personId);
    showModalBottomSheet(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setSheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('图层', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              SwitchListTile(
                title: const Text('地点'),
                value: current.places,
                onChanged: (v) {
                  current.places = v;
                  setSheet(() {});
                  setState(() {});
                },
              ),
              SwitchListTile(
                title: const Text('长期地点'),
                value: current.events,
                onChanged: (v) {
                  current.events = v;
                  setSheet(() {});
                  setState(() {});
                },
              ),
              SwitchListTile(
                title: const Text('路径'),
                value: current.paths,
                onChanged: (v) {
                  current.paths = v;
                  setSheet(() {});
                  setState(() {});
                },
              ),
              SwitchListTile(
                title: const Text('人生轨迹线'),
                value: current.lifePath,
                onChanged: (v) {
                  current.lifePath = v;
                  setSheet(() {});
                  setState(() {});
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// 可拖动顶点：pan 时按像素偏移换算经纬度实时更新。
class _DraggableVertex extends StatefulWidget {
  final MapController mapCtrl;
  final LatLng point;
  final void Function(LatLng) onMove;
  final VoidCallback onTap;

  const _DraggableVertex({
    required this.mapCtrl,
    required this.point,
    required this.onMove,
    required this.onTap,
  });

  @override
  State<_DraggableVertex> createState() => _DraggableVertexState();
}

class _DraggableVertexState extends State<_DraggableVertex> {
  Offset? _startLocal;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onPanStart: (d) => _startLocal = d.localPosition,
      onPanUpdate: (d) {
        final start = _startLocal;
        if (start == null) return;
        final delta = d.localPosition - start;
        final camera = widget.mapCtrl.camera;
        final p0 = camera.latLngToScreenOffset(widget.point);
        widget.onMove(camera.offsetToCrs(p0 + delta));
      },
      onPanEnd: (_) => _startLocal = null,
      child: const Icon(Icons.circle, color: Colors.blue, size: 22),
    );
  }
}

class _SelectedCard extends StatelessWidget {
  final _Selected sel;
  final VoidCallback onClose;
  const _SelectedCard({required this.sel, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Material(
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
                  child: Text(sel.label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                IconButton(icon: const Icon(Icons.close), onPressed: onClose, visualDensity: VisualDensity.compact),
              ],
            ),
            if (sel.detail != null) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(sel.detail!)),
            if (sel.time != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(fmtDate(sel.time), style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
              ),
            ...sel.actions(),
          ],
        ),
      ),
    );
  }
}
