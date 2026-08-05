import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../providers.dart';
import 'map_page.dart';
import 'stats_page.dart';
import 'timeline_page.dart';

/// 单人的底部导航壳：地图 / 时间线 / 统计。
class PersonShell extends ConsumerWidget {
  final String personId;
  final int initialTab;

  const PersonShell({super.key, required this.personId, required this.initialTab});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(personDataProvider(personId));
    final personName = data.maybeWhen(data: (d) => d.person.name, orElse: () => '');
    return DefaultTabController(
      length: 3,
      initialIndex: initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: Text(personName.isEmpty ? '…' : personName),
          actions: [
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: '新建行程',
              onPressed: () => ref.read(mapPageActionProvider(personId).notifier).requestAddTrip(),
            ),
          ],
        ),
        body: TabBarView(
          children: [
            MapPage(personId: personId),
            TimelinePage(personId: personId),
            StatsPage(personId: personId),
          ],
        ),
        bottomNavigationBar: const TabBar(
          tabs: [
            Tab(icon: Icon(Icons.map_outlined), text: '地图'),
            Tab(icon: Icon(Icons.timeline), text: '时间线'),
            Tab(icon: Icon(Icons.insights), text: '统计'),
          ],
        ),
      ),
    );
  }
}

/// 地图页与外部（壳/时间线）的跨页动作通道：新建行程、地图定位。
class MapPageAction {
  final int requestId;
  final LatLng? focus;

  MapPageAction(this.requestId, [this.focus]);
}

final mapPageActionProvider =
    NotifierProvider.family<MapPageActionNotifier, MapPageAction, String>(MapPageActionNotifier.new);

class MapPageActionNotifier extends FamilyNotifier<MapPageAction, String> {
  @override
  MapPageAction build(String personId) => MapPageAction(0);

  void requestAddTrip() {
    state = MapPageAction(state.requestId + 1);
  }

  void focusOn(LatLng latlng) {
    state = MapPageAction(state.requestId + 1, latlng);
  }
}
