import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../models.dart';
import '../providers.dart';
import 'dialogs.dart';
import 'map_page.dart';
import 'stats_page.dart';
import 'timeline_page.dart';

/// 主界面：顶部操作栏（人物选择/新增/删除/图层/设置）+ 底部导航（地图/时间线/统计）。
class PersonHome extends ConsumerStatefulWidget {
  final int initialTab;

  const PersonHome({super.key, this.initialTab = 0});

  @override
  ConsumerState<PersonHome> createState() => _PersonHomeState();
}

class _PersonHomeState extends ConsumerState<PersonHome> with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this, initialIndex: widget.initialTab);
    _tab.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _onMenu(String v, List<Person> people, String? currentId) async {
    final notifier = ref.read(peopleProvider.notifier);
    switch (v) {
      case 'add':
        final r = await showPersonDialog(context);
        if (r == null) return;
        final (name, bio) = r;
        final person = await notifier.addPerson(name, bio: bio);
        ref.read(currentPersonIdProvider.notifier).select(person.id);
      case 'edit':
        final me = people.firstWhere((p) => p.id == currentId);
        final r = await showPersonDialog(context, existing: me);
        if (r == null) return;
        final (name, bio) = r;
        me.name = name;
        me.bio = bio;
        await notifier.updatePerson(me);
      case 'delete':
        final ok = await confirmDialog(context, '删除人物', '将连同备份一起物理删除该人物的全部数据，确定？');
        if (ok && currentId != null) {
          await notifier.removePerson(currentId);
        }
      default:
        ref.read(currentPersonIdProvider.notifier).select(v);
    }
  }

  @override
  Widget build(BuildContext context) {
    final people = ref.watch(peopleProvider).maybeWhen(data: (l) => l, orElse: () => <Person>[]);
    final currentId = ref.watch(currentPersonIdProvider);
    final current = people.where((p) => p.id == currentId).firstOrNull;
    return Scaffold(
      appBar: AppBar(
        title: PopupMenuButton<String>(
          onSelected: (v) => _onMenu(v, people, currentId),
          itemBuilder: (_) => [
            for (final p in people)
              PopupMenuItem(
                value: p.id,
                child: Row(children: [
                  Icon(Icons.person_outline, size: 18, color: p.id == currentId ? Colors.orange : null),
                  const SizedBox(width: 8),
                  Text(p.name),
                ]),
              ),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'add', child: Text('新增人物')),
            if (current != null) ...[
              const PopupMenuItem(value: 'edit', child: Text('编辑资料')),
              const PopupMenuItem(value: 'delete', child: Text('删除当前人物')),
            ],
          ],
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(current?.name ?? '选择人物', style: const TextStyle(fontSize: 18)),
              const Icon(Icons.arrow_drop_down),
            ],
          ),
        ),
        actions: [
          if (_tab.index == 0)
            IconButton(
              icon: const Icon(Icons.layers_outlined),
              tooltip: '图层开关',
              onPressed: () => ref.read(mapPageActionProvider(currentId!).notifier).requestShowLayers(),
            ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
            onPressed: () => Navigator.pushNamed(context, '/settings'),
          ),
        ],
      ),
      body: current == null
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('还没有人物，点左上角"选择人物"→新增人物'),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () async {
                      final r = await showPersonDialog(context);
                      if (r == null) return;
                      final (name, bio) = r;
                      final person = await ref.read(peopleProvider.notifier).addPerson(name, bio: bio);
                      ref.read(currentPersonIdProvider.notifier).select(person.id);
                    },
                    child: const Text('新增人物'),
                  ),
                ],
              ),
            )
          : TabBarView(
              controller: _tab,
              children: [
                MapPage(personId: current.id),
                TimelinePage(personId: current.id),
                StatsPage(personId: current.id),
              ],
            ),
      bottomNavigationBar: TabBar(
        controller: _tab,
        tabs: const [
          Tab(icon: Icon(Icons.map_outlined), text: '地图'),
          Tab(icon: Icon(Icons.timeline), text: '时间线'),
          Tab(icon: Icon(Icons.insights), text: '统计'),
        ],
      ),
    );
  }
}

/// 地图页与外部（壳/时间线/行程详情）的跨页动作通道：地图定位、打开图层面板。
class MapPageAction {
  final int requestId;
  final LatLng? focus;
  final bool showLayers;

  MapPageAction(this.requestId, [this.focus, this.showLayers = false]);
}

final mapPageActionProvider =
    NotifierProvider.family<MapPageActionNotifier, MapPageAction, String>(MapPageActionNotifier.new);

class MapPageActionNotifier extends FamilyNotifier<MapPageAction, String> {
  @override
  MapPageAction build(String personId) => MapPageAction(0);

  void focusOn(LatLng latlng) {
    state = MapPageAction(state.requestId + 1, latlng);
  }

  void requestShowLayers() {
    state = MapPageAction(state.requestId + 1, null, true);
  }
}
