import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../lifecycle.dart';
import '../providers.dart';
import 'widgets.dart';

/// 统计：每人总览 + 各行程统计。
class StatsPage extends ConsumerWidget {
  final String personId;

  const StatsPage({super.key, required this.personId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(personDataProvider(personId));
    final used = ref.watch(referencedMediaIdsProvider(personId));
    return data.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('加载失败：$e')),
      data: (d) {
        final mediaCount = used.maybeWhen(data: (s) => s.length, orElse: () => 0);
        final stats = personStats(d.life.events, d.trips, mediaCount);
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${d.person.name} 总览',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    _row('记录里程', formatMeters(stats.recordedMeters)),
                    _row('推算里程', formatMeters(stats.estimatedMeters)),
                    _row('总里程', formatMeters(stats.recordedMeters + stats.estimatedMeters)),
                    _row('长期地点', '${stats.eventCount} 个'),
                    _row('行程', '${stats.tripCount} 个'),
                    _row('照片', '${stats.mediaCount} 张'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text('行程统计', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            for (final t in d.trips)
              Card(
                child: ListTile(
                  leading: MediaImage(
                    personId: personId,
                    mediaId: t.meta.mediaIds.isEmpty ? null : t.meta.mediaIds.first,
                    width: 44,
                    height: 44,
                  ),
                  title: Text(t.meta.name),
                  subtitle: Text(_tripStatsLine(tripStats(t), estimatedTripMeters(t, d.life.events))),
                  onTap: () => Navigator.pushNamed(context, '/person/$personId/trip/${t.meta.id}'),
                ),
              ),
            if (d.trips.isEmpty) const Padding(
              padding: EdgeInsets.all(16),
              child: Text('还没有行程'),
            ),
          ],
        );
      },
    );
  }

  String _tripStatsLine(TripStats s, double estimatedMeters) {
    final parts = <String>[
      '记录 ${formatMeters(s.recordedMeters)} + 推算 ${formatMeters(estimatedMeters)}',
      '${s.days} 天',
      '${s.placeCount} 地点',
      '${s.pathCount} 路径',
      '${s.mediaCount} 照片',
    ];
    return parts.join(' · ');
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [Text(label), Text(value, style: const TextStyle(fontWeight: FontWeight.w600))],
      ),
    );
  }
}
