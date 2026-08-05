import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models.dart';
import '../providers.dart';
import 'dialogs.dart';
import 'person_shell.dart';

/// 时间线：该人全部生活事件（life.gpx + 各行程中 eventType=life）按标志时间排序。
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
        final items = <(Waypoint, String?, String)>[];
        for (final w in d.life.events) {
          items.add((w, null, personId));
        }
        for (final t in d.trips) {
          for (final w in t.gpx.events) {
            items.add((w, t.meta.id, personId));
          }
        }
        items.sort((a, b) {
          final c = (a.$1.sortTime ?? a.$1.createdAt).compareTo(b.$1.sortTime ?? b.$1.createdAt);
          return c != 0 ? c : a.$1.createdAt.compareTo(b.$1.createdAt);
        });
        if (items.isEmpty) {
          return const Center(child: Text('还没有生活事件，去地图上添加吧'));
        }
        return ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, i) {
            final (w, tripId, _) = items[i];
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: ListTile(
                leading: Icon(
                  w.fromName != null ? Icons.swap_horiz : Icons.star,
                  color: const Color(0xFFE65100),
                ),
                title: Text(w.name),
                subtitle: Text(
                  [
                    if (w.time != null) formatTime(w.time!, w.timePrecision),
                    if (tripId != null) '在行程中',
                    if (w.fromName != null) '从 ${w.fromName}',
                  ].join(' · '),
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (v) async {
                    final notifier = ref.read(personDataProvider(personId).notifier);
                    switch (v) {
                      case 'edit':
                        final form = await showWaypointDialog(context, personId: personId, existing: w);
                        if (form == null) return;
                        form.applyTo(w);
                        w.updatedAt = DateTime.now();
                        if (tripId == null) {
                          await notifier.saveLifeWaypoint(w);
                        } else {
                          await notifier.saveTripWaypoint(tripId, w);
                        }
                      case 'move_in':
                        if (d.trips.isEmpty) {
                          ScaffoldMessenger.of(context)
                              .showSnackBar(const SnackBar(content: Text('还没有行程，先新建一个')));
                          return;
                        }
                        final choice = await _pickTrip(context, d.trips);
                        if (choice != null) await notifier.moveEventToTrip(w.id, choice.id);
                      case 'move_out':
                        await notifier.moveEventOutOfTrip(w.id);
                      case 'delete':
                        final ok = await confirmDialog(context, '删除事件', '确定删除该事件？');
                        if (!ok) return;
                        if (w.mediaId != null) {
                          await deleteMediaIfUnused(ref, personId, w.mediaId!,
                              waypoints: _allWaypoints(d), paths: _allPaths(d));
                        }
                        if (tripId == null) {
                          await notifier.deleteLifeWaypoint(w.id);
                        } else {
                          await notifier.deleteTripWaypoint(tripId, w.id);
                        }
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'edit', child: Text('编辑')),
                    if (tripId == null)
                      const PopupMenuItem(value: 'move_in', child: Text('移入行程'))
                    else
                      const PopupMenuItem(value: 'move_out', child: Text('移出行程')),
                    const PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
                onTap: () {
                  DefaultTabController.of(context).animateTo(0);
                  ref.read(mapPageActionProvider(personId).notifier).focusOn(w.latLng);
                },
              ),
            );
          },
        );
      },
    );
  }
}

List<Waypoint> _allWaypoints(PersonData d) =>
    [...d.life.waypoints, for (final t in d.trips) ...t.gpx.waypoints];

List<PathData> _allPaths(PersonData d) =>
    [for (final t in d.trips) ...t.gpx.paths];

Future<Trip?> _pickTrip(BuildContext context, List<TripBundle> trips) {
  return showDialog<Trip>(
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
}
