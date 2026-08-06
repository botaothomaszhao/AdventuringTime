import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../lifecycle.dart';
import '../models.dart';
import '../providers.dart';
import 'dialogs.dart';
import 'person_shell.dart';
import 'widgets.dart';

/// 行程详情：基本信息、封面、起终点、统计摘要、按日期分组的路径与地点、照片墙。
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
        String? eventName(String? id) {
          if (id == null) return null;
          for (final e in events) {
            if (e.id == id) return e.name;
          }
          return null;
        }

        final mediaIds = <String>{};
        if (trip.meta.cover != null) mediaIds.add(trip.meta.cover!);
        for (final w in trip.gpx.waypoints) {
          if (w.mediaId != null) mediaIds.add(w.mediaId!);
        }
        for (final p in trip.gpx.paths) {
          if (p.mediaId != null) mediaIds.add(p.mediaId!);
        }

        final grouped = _groupByDate(trip);

        return Scaffold(
          appBar: AppBar(
            title: Text(trip.meta.name),
            actions: [
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: '编辑行程',
                onPressed: () async {
                  final form = await showTripDialog(context, personId: personId, existing: trip.meta);
                  if (form == null) return;
                  form.applyTo(trip.meta);
                  trip.meta.updatedAt = DateTime.now();
                  await ref.read(personDataProvider(personId).notifier).saveTripMeta(trip.meta);
                },
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: '删除行程',
                onPressed: () async {
                  final ok = await confirmDialog(context, '删除行程', '确定删除该行程（含其中地点与路径）？');
                  if (!ok) return;
                  await ref.read(personDataProvider(personId).notifier).deleteTrip(tripId);
                  if (context.mounted) Navigator.pop(context);
                },
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (trip.meta.cover != null)
                Center(
                  child: MediaImage(personId: personId, mediaId: trip.meta.cover, width: 200, height: 140),
                ),
              _EditableDesc(personId: personId, tripId: tripId, desc: trip.meta.description),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _row('时间', '${fmtDate(trip.meta.startDate)} 至 ${fmtDate(trip.meta.endDate)}'),
                      _row('起点', eventName(trip.meta.startEventId) ?? '—'),
                      _row('终点', eventName(trip.meta.endEventId) ?? '—'),
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
                  child: Text(g.date, style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
                for (final item in g.items)
                  ListTile(
                    dense: true,
                    leading: Icon(item is PathData ? Icons.timeline : Icons.location_on, size: 20),
                    title: Text(item is PathData ? item.name : (item as Waypoint).name),
                    subtitle: Text(item is PathData
                        ? (item.isGps ? 'GPS 轨迹' : '手绘路径')
                        : ((item as Waypoint).desc ?? '')),
                    onTap: () {
                      final target = item is PathData
                          ? (item.points.isEmpty ? null : item.points.first.latLng)
                          : (item as Waypoint).latLng;
                      if (target == null) return;
                      Navigator.pop(context);
                      ref.read(mapPageActionProvider(personId).notifier).focusOn(target);
                    },
                  ),
              ],
              if (mediaIds.isNotEmpty) ...[
                const SizedBox(height: 8),
                const Text('照片墙', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                GridView.count(
                  crossAxisCount: 3,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                  children: [
                    for (final id in mediaIds)
                      GestureDetector(
                        onTap: () => showDialog(
                          context: context,
                          builder: (_) => Dialog(
                            child: MediaImage(personId: personId, mediaId: id, height: 400, fit: BoxFit.contain),
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: MediaImage(personId: personId, mediaId: id),
                        ),
                      ),
                  ],
                ),
              ],
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
        children: [Text(label, style: const TextStyle(color: Colors.grey)), Text(value)],
      ),
    );
  }

  List<({String date, List<Object> items})> _groupByDate(TripBundle trip) {
    final map = <String, List<Object>>{};
    String keyFor(DateTime? t) {
      if (t == null) return '未标日期';
      return '${t.year}年${t.month}月${t.day}日';
    }

    for (final p in trip.gpx.paths) {
      map.putIfAbsent(keyFor(p.points.firstOrNull?.time ?? p.createdAt), () => []).add(p);
    }
    for (final w in trip.gpx.waypoints) {
      map.putIfAbsent(keyFor(w.time ?? w.createdAt), () => []).add(w);
    }
    final out = map.entries.map((e) => (date: e.key, items: e.value)).toList();
    out.sort((a, b) {
      bool isDate(String s) => s.contains('年');
      if (isDate(a.date) && isDate(b.date)) {
        return a.date.compareTo(b.date);
      }
      return a.date == '未标日期' ? 1 : (b.date == '未标日期' ? -1 : a.date.compareTo(b.date));
    });
    return out;
  }
}

/// 说明内联编辑：点击显示区直接进入编辑，保存后落盘。
class _EditableDesc extends ConsumerStatefulWidget {
  final String personId;
  final String tripId;
  final String? desc;

  const _EditableDesc({required this.personId, required this.tripId, this.desc});

  @override
  ConsumerState<_EditableDesc> createState() => _EditableDescState();
}

class _EditableDescState extends ConsumerState<_EditableDesc> {
  late final TextEditingController _c;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _c = TextEditingController(text: widget.desc ?? '');
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final d = ref.read(personDataProvider(widget.personId)).valueOrNull;
    final t = d?.tripById(widget.tripId);
    if (t == null) return;
    final meta = t.meta;
    meta.description = _c.text.trim().isEmpty ? null : _c.text.trim();
    meta.updatedAt = DateTime.now();
    await ref.read(personDataProvider(widget.personId).notifier).saveTripMeta(meta);
    setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_editing) {
      return InkWell(
        onTap: () => setState(() => _editing = true),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            _c.text.isEmpty ? '添加说明…' : _c.text,
            style: _c.text.isEmpty
                ? TextStyle(color: Colors.grey.shade500, fontStyle: FontStyle.italic)
                : null,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: _c,
              autofocus: true,
              maxLines: 3,
              decoration: const InputDecoration(
                isDense: true,
                hintText: '说明',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: '保存说明',
            onPressed: _save,
          ),
        ],
      ),
    );
  }
}
