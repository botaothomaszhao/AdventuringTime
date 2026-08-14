import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../lifecycle.dart';
import '../models.dart';
import '../providers.dart';
import 'dialogs.dart';
import 'widgets.dart';

/// 长期地点详情：内联编辑名称/说明/时间，删除，底部常驻照片墙。
class EventDetailPage extends ConsumerWidget {
  final String personId;
  final String waypointId;

  const EventDetailPage({super.key, required this.personId, required this.waypointId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(personDataProvider(personId));
    return data.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(body: Center(child: Text('加载失败：$e'))),
      data: (d) {
        Waypoint? found;
        for (final w in [...d.life.waypoints, for (final t in d.trips) ...t.gpx.waypoints]) {
          if (w.id == waypointId) {
            found = w;
            break;
          }
        }
        if (found == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('长期地点不存在')),
            body: const Center(child: Text('长期地点不存在或已被删除')),
          );
        }
        final w = found;
        final tripId = d.containerOf(w).$1;
        final notifier = ref.read(personDataProvider(personId).notifier);

        Future<void> saveWaypoint() async {
          w.updatedAt = DateTime.now();
          if (tripId == null) {
            await notifier.saveLifeWaypoint(w);
          } else {
            await notifier.saveTripWaypoint(tripId, w);
          }
        }

        Future<void> setPhotos(List<String> next) async {
          final removed = [for (final id in w.mediaIds) if (!next.contains(id)) id];
          w.mediaIds = next;
          await saveWaypoint();
          for (final id in removed) {
            await deleteMediaIfUnused(ref, personId, id,
                waypoints: _allWaypoints(d), paths: _allPaths(d));
          }
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(w.name.isEmpty ? '（未命名）' : w.name),
            actions: [
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: '删除长期地点',
                onPressed: () async {
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
                  if (context.mounted) Navigator.pop(context);
                },
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              InlineTextEdit(
                value: w.name,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                onSave: (v) async {
                  if (v.isEmpty) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('名称不能为空')));
                    return;
                  }
                  w.name = v;
                  await saveWaypoint();
                },
              ),
              InlineTextEdit(
                value: w.desc,
                hint: '添加说明…',
                maxLines: 3,
                onSave: (v) async {
                  w.desc = v.isEmpty ? null : v;
                  await saveWaypoint();
                },
              ),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        leading: const Icon(Icons.star, color: Color(0xFFE65100)),
                        title: const Text('长期地点'),
                        subtitle: Text('坐标：${formatLatLng(w.latLng)}'),
                      ),
                      const Divider(),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                final precision = w.timePrecision ?? TimePrecision.day;
                                final t = await pickTimeWithPrecision(
                                  context,
                                  precision: precision,
                                  current: w.time,
                                );
                                if (t == null) return;
                                w.time = t;
                                w.timePrecision = precision;
                                await saveWaypoint();
                              },
                              icon: const Icon(Icons.event),
                              label: Text(
                                w.time == null
                                    ? '到达时间（必填）'
                                    : formatTime(w.time!, w.timePrecision),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          DropdownButton<TimePrecision>(
                            value: w.timePrecision ?? TimePrecision.day,
                            onChanged: (v) async {
                              w.timePrecision = v;
                              await saveWaypoint();
                            },
                            items: const [
                              DropdownMenuItem(value: TimePrecision.year, child: Text('年')),
                              DropdownMenuItem(value: TimePrecision.month, child: Text('月')),
                              DropdownMenuItem(value: TimePrecision.day, child: Text('日')),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              PhotoWall(personId: personId, mediaIds: w.mediaIds, onChanged: setPhotos),
            ],
          ),
        );
      },
    );
  }
}

List<Waypoint> _allWaypoints(PersonData d) =>
    [...d.life.waypoints, for (final t in d.trips) ...t.gpx.waypoints];

List<PathData> _allPaths(PersonData d) => [for (final t in d.trips) ...t.gpx.paths];
