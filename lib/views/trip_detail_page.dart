import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../lifecycle.dart';
import '../models.dart';
import '../providers.dart';
import 'dialogs.dart';
import 'widgets.dart';

/// 行程详情：内联编辑基本信息与起终点、统计摘要、按日期分组的路径与地点、底部照片墙。
class TripDetailPage extends ConsumerWidget {
  final String personId;
  final String tripId;

  const TripDetailPage({super.key, required this.personId, required this.tripId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(personDataProvider(personId));
    return data.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(body: Center(child: Text('加载失败：$e'))),
      data: (d) {
        final trip = d.tripById(tripId);
        if (trip == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('行程不存在')),
            body: const Center(child: Text('行程不存在或已被删除')),
          );
        }
        final stats = tripStats(trip);
        final events = _eventsOf(d);
        final grouped = _groupByDate(trip);
        final notifier = ref.read(personDataProvider(personId).notifier);

        Future<void> saveMeta() async {
          trip.meta.updatedAt = DateTime.now();
          await notifier.saveTripMeta(trip.meta);
        }

        Future<void> setPhotos(List<String> next) async {
          final removed = [
            for (final id in trip.meta.mediaIds) if (!next.contains(id)) id,
          ];
          trip.meta.mediaIds = next;
          await saveMeta();
          for (final id in removed) {
            await deleteMediaIfUnused(
              ref,
              personId,
              id,
              waypoints: _allWaypoints(d),
              paths: _allPaths(d),
            );
          }
        }

        Widget eventPicker(String label, String? value, ValueChanged<String?> onChanged) {
          return DropdownButtonFormField<String?>(
            initialValue: value,
            decoration: InputDecoration(
              labelText: label,
              border: const OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('（无）')),
              for (final e in events)
                DropdownMenuItem<String?>(
                  value: e.id,
                  child: Text(e.name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: onChanged,
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(trip.meta.name.isEmpty ? '（未命名行程）' : trip.meta.name),
            actions: [
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: '删除行程',
                onPressed: () async {
                  final ok = await confirmDialog(
                    context,
                    '删除行程',
                    '确定删除该行程（含其中地点与路径）？',
                  );
                  if (!ok) return;
                  await notifier.deleteTrip(tripId);
                  if (context.mounted) Navigator.pop(context);
                },
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              InlineTextEdit(
                value: trip.meta.name,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                onSave: (v) async {
                  if (v.isEmpty) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('名称不能为空')));
                    return;
                  }
                  trip.meta.name = v;
                  await saveMeta();
                },
              ),
              InlineTextEdit(
                value: trip.meta.description,
                hint: '添加说明…',
                maxLines: 3,
                onSave: (v) async {
                  trip.meta.description = v.isEmpty ? null : v;
                  await saveMeta();
                },
              ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () async {
                                final t = await showDatePicker(
                                  context: context,
                                  initialDate: trip.meta.startDate ?? DateTime.now(),
                                  firstDate: DateTime(1900),
                                  lastDate: DateTime(2100),
                                );
                                if (t == null) return;
                                trip.meta.startDate = t;
                                await saveMeta();
                              },
                              child: Text(
                                trip.meta.startDate == null
                                    ? '开始日期'
                                    : fmtDate(trip.meta.startDate),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () async {
                                final t = await showDatePicker(
                                  context: context,
                                  initialDate: trip.meta.endDate ?? DateTime.now(),
                                  firstDate: DateTime(1900),
                                  lastDate: DateTime(2100),
                                );
                                if (t == null) return;
                                trip.meta.endDate = t;
                                await saveMeta();
                              },
                              child: Text(
                                trip.meta.endDate == null
                                    ? '结束日期'
                                    : fmtDate(trip.meta.endDate),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      eventPicker('起点长期地点', trip.meta.startEventId, (v) async {
                        trip.meta.startEventId = v;
                        await saveMeta();
                      }),
                      const SizedBox(height: 8),
                      eventPicker('终点长期地点', trip.meta.endEventId, (v) async {
                        trip.meta.endEventId = v;
                        await saveMeta();
                      }),
                      const Divider(),
                      _row('记录里程', formatMeters(stats.recordedMeters)),
                      _row('天数', '${stats.days} 天'),
                      _row('地点', '${stats.placeCount} 个'),
                      _row('路径', '${stats.pathCount} 条'),
                      _row('照片', '${stats.mediaCount} 张'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              for (final g in grouped) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    g.date,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                for (final item in g.items)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      item.data is PathData ? Icons.timeline : Icons.location_on,
                      size: 20,
                    ),
                    title: Text(
                      item.data is PathData
                          ? (item.data as PathData).name
                          : (item.data as Waypoint).name,
                    ),
                    subtitle: Text(item.data is PathData
                        ? ((item.data as PathData).isGps ? 'GPS 轨迹' : '手绘路径')
                        : ((item.data as Waypoint).desc ?? '')),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_upward, size: 18),
                          tooltip: '上移',
                          visualDensity: VisualDensity.compact,
                          onPressed: item.canUp
                              ? () => _moveItem(ref, item.data, true)
                              : null,
                        ),
                        IconButton(
                          icon: const Icon(Icons.arrow_downward, size: 18),
                          tooltip: '下移',
                          visualDensity: VisualDensity.compact,
                          onPressed: item.canDown
                              ? () => _moveItem(ref, item.data, false)
                              : null,
                        ),
                      ],
                    ),
                    onTap: () async {
                      if (item.data is PathData) {
                        final p = item.data as PathData;
                        final before = List<String>.of(p.mediaIds);
                        final form = await showPathDialog(
                          context,
                          personId: personId,
                          existing: p,
                          onDelete: () => _deletePathFromPage(context, ref, p, tripId),
                        );
                        if (form == null) return;
                        form.applyTo(p);
                        p.updatedAt = DateTime.now();
                        await notifier.saveTripPath(tripId, p);
                        await cleanupRemovedMedia(ref, personId, before, p.mediaIds);
                      } else {
                        final w = item.data as Waypoint;
                        final before = List<String>.of(w.mediaIds);
                        final form = await showWaypointDialog(
                          context,
                          personId: personId,
                          existing: w,
                          tripId: tripId,
                          onDelete: () => _deleteWaypointFromPage(context, ref, w, tripId),
                        );
                        if (form == null) return;
                        form.applyTo(w);
                        w.updatedAt = DateTime.now();
                        await notifier.saveTripWaypoint(tripId, w);
                        await cleanupRemovedMedia(ref, personId, before, w.mediaIds);
                      }
                    },
                  ),
              ],
              const SizedBox(height: 16),
              PhotoWall(personId: personId, mediaIds: trip.meta.mediaIds, onChanged: setPhotos),
            ],
          ),
        );
      },
    );
  }

  List<Waypoint> _eventsOf(PersonData d) {
    return [
      for (final w in [...d.life.waypoints, for (final t in d.trips) ...t.gpx.waypoints])
        if (w.isEvent) w,
    ];
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Text(value),
        ],
      ),
    );
  }

  /// 按日期分组的路径与地点。组内默认按时间排序；orderIds 覆盖该组全部项时按自定义顺序。
  List<({String date, List<({Object data, bool canUp, bool canDown})> items})> _groupByDate(
      TripBundle trip) {
    final map = <String, List<Object>>{};
    String keyFor(DateTime? t) {
      if (t == null) return '未标日期';
      return '${t.year}年${t.month}月${t.day}日';
    }

    String idOf(Object o) => o is PathData ? o.id : (o as Waypoint).id;
    DateTime? timeOf(Object o) =>
        o is PathData ? o.points.firstOrNull?.time : (o as Waypoint).time;
    DateTime sortTime(Object o) =>
        timeOf(o) ?? (o is PathData ? o.createdAt : (o as Waypoint).createdAt);

    final g = trip.gpx;
    for (final p in g.paths) {
      map.putIfAbsent(keyFor(timeOf(p)), () => []).add(p);
    }
    for (final w in g.waypoints) {
      map.putIfAbsent(keyFor(timeOf(w)), () => []).add(w);
    }
    final ids = g.orderIds;
    final out = <({String date, List<({Object data, bool canUp, bool canDown})> items})>[];
    for (final e in map.entries) {
      final items = e.value;
      final covered = ids.isNotEmpty && items.every((o) => ids.contains(idOf(o)));
      if (covered) {
        items.sort((a, b) => ids.indexOf(idOf(a)).compareTo(ids.indexOf(idOf(b))));
      } else {
        items.sort((a, b) => sortTime(a).compareTo(sortTime(b)));
      }
      out.add((
        date: e.key,
        items: [
          for (var i = 0; i < items.length; i++)
            (data: items[i], canUp: i > 0, canDown: i < items.length - 1),
        ],
      ));
    }
    out.sort((a, b) {
      bool isDate(String s) => s.contains('年');
      if (isDate(a.date) && isDate(b.date)) {
        return a.date.compareTo(b.date);
      }
      return a.date == '未标日期' ? 1 : (b.date == '未标日期' ? -1 : a.date.compareTo(b.date));
    });
    return out;
  }

  /// 当天内上移/下移一个路径或地点（跨类型混排，参照自定义顺序）。
  Future<void> _moveItem(WidgetRef ref, Object item, bool up) async {
    final id = item is PathData ? item.id : (item as Waypoint).id;
    await ref.read(personDataProvider(personId).notifier).reorderTripItem(tripId, id, up);
  }

  /// 地点编辑对话框内的删除：确认后删除并关闭对话框。
  Future<void> _deleteWaypointFromPage(
    BuildContext context,
    WidgetRef ref,
    Waypoint w,
    String tripId,
  ) async {
    final ok = await confirmDialog(context, '删除地点', '确定删除该地点？');
    if (!ok) return;
    await ref.read(personDataProvider(personId).notifier).deleteTripWaypoint(tripId, w.id);
    final nd = ref.read(personDataProvider(personId)).valueOrNull;
    if (nd != null) {
      for (final id in w.mediaIds) {
        await deleteMediaIfUnused(
          ref,
          personId,
          id,
          waypoints: _allWaypoints(nd),
          paths: _allPaths(nd),
        );
      }
    }
    if (context.mounted) Navigator.pop(context);
  }

  /// 路径编辑对话框内的删除：确认后删除并关闭对话框。
  Future<void> _deletePathFromPage(
    BuildContext context,
    WidgetRef ref,
    PathData p,
    String tripId,
  ) async {
    final ok = await confirmDialog(context, '删除路径', '确定删除该路径？');
    if (!ok) return;
    await ref.read(personDataProvider(personId).notifier).deleteTripPath(tripId, p.id);
    final nd = ref.read(personDataProvider(personId)).valueOrNull;
    if (nd != null) {
      for (final id in p.mediaIds) {
        await deleteMediaIfUnused(
          ref,
          personId,
          id,
          waypoints: _allWaypoints(nd),
          paths: _allPaths(nd),
        );
      }
    }
    if (context.mounted) Navigator.pop(context);
  }
}

List<Waypoint> _allWaypoints(PersonData d) =>
    [...d.life.waypoints, for (final t in d.trips) ...t.gpx.waypoints];

List<PathData> _allPaths(PersonData d) => [for (final t in d.trips) ...t.gpx.paths];
