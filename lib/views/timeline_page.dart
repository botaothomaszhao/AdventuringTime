import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../lifecycle.dart';
import '../models.dart';
import '../providers.dart';
import 'dialogs.dart';
import 'widgets.dart';

/// 时间线条目：长期地点（含行程内）与行程按时间混合排序。
typedef TimelineItem = ({Object data, DateTime time, DateTime created, String? tripId});

List<TimelineItem> buildTimelineItems(PersonData d) {
  final items = <TimelineItem>[];
  for (final w in d.life.events) {
    items.add((data: w, time: w.sortTime ?? w.createdAt, created: w.createdAt, tripId: null));
  }
  for (final t in d.trips) {
    for (final w in t.gpx.events) {
      items.add((data: w, time: w.sortTime ?? w.createdAt, created: w.createdAt, tripId: t.meta.id));
    }
    items.add((data: t, time: t.meta.startDate ?? t.meta.createdAt, created: t.meta.createdAt, tripId: null));
  }
  items.sort((a, b) {
    final c = a.time.compareTo(b.time);
    return c != 0 ? c : a.created.compareTo(b.created);
  });
  return items;
}

/// 时间线：长期地点与行程按时间混合排序展示。
class TimelinePage extends ConsumerWidget {
  final String personId;

  const TimelinePage({super.key, required this.personId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(personDataProvider(personId));
    return data.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('加载失败：$e')),
      data: (d) {
        final items = buildTimelineItems(d);
        if (items.isEmpty) {
          return const Center(child: Text('还没有记录，去地图上添加长期地点或新建行程吧'));
        }
        return ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, i) {
            final item = items[i];
            if (item.data is Waypoint) {
              return _waypointTile(context, ref, item.data as Waypoint, item.tripId);
            }
            return _tripTile(context, ref, item.data as TripBundle);
          },
        );
      },
    );
  }

  Widget _waypointTile(BuildContext context, WidgetRef ref, Waypoint w, String? tripId) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: const Icon(Icons.star, color: Color(0xFFE65100)),
        title: Text(w.name),
        subtitle: Text(
          [
            if (w.time != null) formatTime(w.time!, w.timePrecision),
            if (tripId != null) '在行程中',
          ].join(' · '),
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (v) async {
            final notifier = ref.read(personDataProvider(personId).notifier);
            switch (v) {
              case 'delete':
                final ok = await confirmDialog(context, '删除长期地点', '确定删除该长期地点？');
                if (!ok) return;
                if (tripId == null) {
                  await notifier.deleteLifeWaypoint(w.id);
                } else {
                  await notifier.deleteTripWaypoint(tripId, w.id);
                }
                final nd = ref.read(personDataProvider(personId)).valueOrNull;
                if (nd != null) {
                  for (final id in w.mediaIds) {
                    await deleteMediaIfUnused(ref, personId, id,
                        waypoints: _allWaypoints(nd), paths: _allPaths(nd));
                  }
                }
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'delete', child: Text('删除')),
          ],
        ),
        onTap: () => Navigator.pushNamed(context, '/person/$personId/event/${w.id}'),
      ),
    );
  }

  Widget _tripTile(BuildContext context, WidgetRef ref, TripBundle t) {
    final stats = tripStats(t);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: const Icon(Icons.luggage_outlined, color: Color(0xFF1565C0)),
        title: Text(t.meta.name.isEmpty ? '（未命名行程）' : t.meta.name),
        subtitle: Text(
          [
            if (t.meta.startDate != null)
              t.meta.endDate != null
                  ? '${fmtDate(t.meta.startDate)} 至 ${fmtDate(t.meta.endDate)}'
                  : fmtDate(t.meta.startDate),
            '${stats.placeCount} 个地点',
            if (stats.pathCount > 0) '${stats.pathCount} 条路径',
          ].join(' · '),
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (v) async {
            final notifier = ref.read(personDataProvider(personId).notifier);
            switch (v) {
              case 'edit':
                final before = List<String>.of(t.meta.mediaIds);
                final form = await showTripDialog(context, personId: personId, existing: t.meta);
                if (form == null) return;
                form.applyTo(t.meta);
                t.meta.updatedAt = DateTime.now();
                await notifier.saveTripMeta(t.meta);
                await cleanupRemovedMedia(ref, personId, before, t.meta.mediaIds);
              case 'delete':
                final ok = await confirmDialog(context, '删除行程', '确定删除该行程（含其中地点与路径）？');
                if (!ok) return;
                await notifier.deleteTrip(t.meta.id);
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('编辑')),
            PopupMenuItem(value: 'delete', child: Text('删除')),
          ],
        ),
        onTap: () => Navigator.pushNamed(context, '/person/$personId/trip/${t.meta.id}'),
      ),
    );
  }
}

List<Waypoint> _allWaypoints(PersonData d) =>
    [...d.life.waypoints, for (final t in d.trips) ...t.gpx.waypoints];

List<PathData> _allPaths(PersonData d) =>
    [for (final t in d.trips) ...t.gpx.paths];
