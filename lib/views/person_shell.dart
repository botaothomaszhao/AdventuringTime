import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../models.dart';
import '../providers.dart';
import '../storage.dart';
import '../transfer.dart';
import 'dialogs.dart';
import 'map_page.dart';
import 'stats_page.dart';
import 'timeline_page.dart';

/// 跨平台保存 .atrip：安卓写下载目录，其余弹保存对话框。
Future<void> _saveAtrip(BuildContext context, String filename, List<int> bytes) async {
  if (Platform.isAndroid) {
    final path = await saveToDownloads(filename, bytes);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已导出到下载目录：$path')));
  } else {
    final loc = await getSaveLocation(suggestedName: filename);
    final path = loc?.path;
    if (path == null) return;
    await File(path).writeAsBytes(bytes, flush: true);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已导出')));
  }
}

/// 主界面：顶部操作栏（人物选择/新增/删除/图层/设置）+ 底部导航（地图/时间线/统计）。
class PersonHome extends ConsumerStatefulWidget {
  final int initialTab;

  const PersonHome({super.key, this.initialTab = 0});

  @override
  ConsumerState<PersonHome> createState() => _PersonHomeState();
}

class _PersonHomeState extends ConsumerState<PersonHome>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(
      length: 3,
      vsync: this,
      initialIndex: widget.initialTab,
    );
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
        final ok = await confirmDialog(
          context,
          '删除人物',
          '将连同备份一起物理删除该人物的全部数据，确定？',
        );
        if (ok && currentId != null) {
          await notifier.removePerson(currentId);
        }
      case 'export':
        if (currentId != null) await _exportPerson(context, currentId);
      case 'import':
        await _importPerson(context);
      default:
        ref.read(currentPersonIdProvider.notifier).select(v);
    }
  }

  Future<void> _exportPerson(BuildContext context, String personId) async {
    try {
      final repo = await ref.read(personRepoProvider(personId).future);
      final person = await repo.loadPerson();
      final bytes = await exportPersonPack(repo);
      final filename =
          '${person.name.isEmpty ? 'person' : person.name}-${DateTime.now().millisecondsSinceEpoch}.atrip';
      await _saveAtrip(context, filename, bytes);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出失败：$e')));
    }
  }

  /// 备份管理对话框：手动备份 / 查看已有备份（恢复、导出、删除）。
  Future<void> _openBackupDialog(BuildContext context, Person person) async {
    final repo = await ref.read(personRepoProvider(person.id).future);
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _BackupDialog(
        repo: repo,
        personId: person.id,
        personName: person.name,
      ),
    );
  }

  Future<void> _importPerson(BuildContext context) async {
    const group = XTypeGroup(label: 'atrip', extensions: ['atrip']);
    final file = await openFile(acceptedTypeGroups: const [group]);
    if (file == null) return;
    try {
      final bytes = await file.readAsBytes();
      final personId = await packPersonId(bytes);
      if (personId == null) {
        throw const FormatException('无效的 .atrip 包');
      }
      final root = await ref.read(dataRootProvider.future);
      final app = AppRepository(
        Directory('${root.path}${Platform.pathSeparator}people'),
      );
      var mode = 'new';
      if (await app.personDir(personId).exists()) {
        final m = await showDialog<String>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('人物已存在'),
            content: const Text('选择合并可保留两端数据，冲突以较新版本为准；覆盖会替换当前数据。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(c, 'overwrite'),
                child: const Text('覆盖'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(c, 'merge'),
                child: const Text('合并'),
              ),
            ],
          ),
        );
        if (m == null) return;
        mode = m;
      }
      final id = await importPersonPack(app, bytes, mode: mode);
      await ref.read(peopleProvider.notifier).reload();
      ref.read(currentPersonIdProvider.notifier).select(id);
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('人物已导入')));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导入失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final people = ref
        .watch(peopleProvider)
        .maybeWhen(data: (l) => l, orElse: () => <Person>[]);
    final currentId = ref.watch(currentPersonIdProvider);
    final current = people.where((p) => p.id == currentId).firstOrNull;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PopupMenuButton<String>(
              onSelected: (v) => _onMenu(v, people, currentId),
              itemBuilder: (_) => [
                for (final p in people)
                  PopupMenuItem(
                    value: p.id,
                    child: Row(
                      children: [
                        Icon(
                          Icons.person_outline,
                          size: 18,
                          color: p.id == currentId ? Colors.orange : null,
                        ),
                        const SizedBox(width: 8),
                        Text(p.name),
                      ],
                    ),
                  ),
                const PopupMenuDivider(),
                const PopupMenuItem(value: 'add', child: Text('新增人物')),
                if (current != null) ...[
                  const PopupMenuItem(value: 'edit', child: Text('编辑资料')),
                  const PopupMenuItem(value: 'delete', child: Text('删除当前人物')),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'export',
                    child: Text('导出人物整包 (.atrip)'),
                  ),
                  const PopupMenuItem(
                    value: 'import',
                    child: Text('导入人物整包 (.atrip)'),
                  ),
                ],
              ],
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    current?.name ?? '选择人物',
                    style: const TextStyle(fontSize: 18),
                  ),
                  const Icon(Icons.arrow_drop_down),
                ],
              ),
            ),
            if (current != null)
              IconButton(
                icon: const Icon(Icons.archive_outlined),
                tooltip: '备份',
                onPressed: () => _openBackupDialog(context, current),
              ),
          ],
        ),
        actions: [
          if (_tab.index == 0)
            IconButton(
              icon: const Icon(Icons.layers_outlined),
              tooltip: '图层开关',
              onPressed: () => ref
                  .read(mapPageActionProvider(currentId!).notifier)
                  .requestShowLayers(),
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
                      final person = await ref
                          .read(peopleProvider.notifier)
                          .addPerson(name, bio: bio);
                      ref
                          .read(currentPersonIdProvider.notifier)
                          .select(person.id);
                    },
                    child: const Text('新增人物'),
                  ),
                ],
              ),
            )
          : IndexedStack(
              index: _tab.index,
              children: [
                MapPage(personId: current.id),
                TimelinePage(personId: current.id),
                StatsPage(personId: current.id),
              ],
            ),
      bottomNavigationBar: TabBar(
        controller: _tab,
        tabs: const [
          Tab(
            key: ValueKey('tab-map'),
            icon: Icon(Icons.map_outlined),
            text: '地图',
          ),
          Tab(
            key: ValueKey('tab-timeline'),
            icon: Icon(Icons.timeline),
            text: '时间线',
          ),
          Tab(
            key: ValueKey('tab-stats'),
            icon: Icon(Icons.insights),
            text: '统计',
          ),
        ],
      ),
    );
  }
}

/// 备份管理对话框：手动备份 / 已有备份的恢复、导出、删除。
class _BackupDialog extends ConsumerStatefulWidget {
  final PersonRepository repo;
  final String personId;
  final String personName;

  const _BackupDialog({
    required this.repo,
    required this.personId,
    required this.personName,
  });

  @override
  ConsumerState<_BackupDialog> createState() => _BackupDialogState();
}

class _BackupDialogState extends ConsumerState<_BackupDialog> {
  List<String>? _backups;
  String? _err;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final l = await widget.repo.listBackups();
      if (mounted) setState(() {
        _backups = l;
        _err = null;
      });
    } catch (e) {
      if (mounted) setState(() => _err = '$e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _manualBackup() async {
    try {
      await widget.repo.backupAll();
      await _reload();
      _snack('已手动备份');
    } catch (e) {
      _snack('备份失败：$e');
    }
  }

  Future<void> _restore(String ts) async {
    final ok = await confirmDialog(
      context,
      '恢复备份',
      '恢复 $ts 后当前数据将被该版本替换（备份文件保留），确定？',
    );
    if (!ok) return;
    try {
      await widget.repo.restoreBackupAll(ts);
      ref.invalidate(peopleProvider);
      ref.invalidate(personDataProvider(widget.personId));
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _snack('恢复失败：$e');
    }
  }

  Future<void> _export(String ts) async {
    try {
      final bytes = await exportBackupPack(widget.repo, ts);
      final name = widget.personName.isEmpty ? 'person' : widget.personName;
      if (!mounted) return;
      await _saveAtrip(context, '$name-$ts.atrip', bytes);
    } catch (e) {
      _snack('导出失败：$e');
    }
  }

  Future<void> _delete(String ts) async {
    final ok = await confirmDialog(
      context,
      '删除备份',
      '删除备份 $ts？该时间点的版本将不可恢复。',
    );
    if (!ok) return;
    try {
      await widget.repo.deleteBackup(ts);
      await _reload();
    } catch (e) {
      _snack('删除失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final backups = _backups;
    final theme = Theme.of(context);
    return Dialog(
      child: SizedBox(
        width: 420,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('备份', style: theme.textTheme.titleLarge),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton.icon(
                onPressed: _manualBackup,
                icon: const Icon(Icons.archive),
                label: const Text('手动备份'),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('已有备份'),
            ),
            Expanded(
              child: backups == null
                  ? Center(child: Text(_err ?? '加载中…'))
                  : backups.isEmpty
                      ? const Center(child: Text('暂无备份'))
                      : ListView(
                          children: [
                            for (final ts in backups)
                              ListTile(
                                dense: true,
                                title: Text(ts),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      tooltip: '恢复该版本',
                                      icon: const Icon(Icons.restore),
                                      onPressed: () => _restore(ts),
                                    ),
                                    IconButton(
                                      tooltip: '导出备份',
                                      icon: const Icon(Icons.download_outlined),
                                      onPressed: () => _export(ts),
                                    ),
                                    IconButton(
                                      tooltip: '删除备份',
                                      icon: const Icon(Icons.delete_outline),
                                      onPressed: () => _delete(ts),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 地图页与外部（壳/时间线/行程详情）的跨页动作通道：地图定位、打开图层面板。
class MapPageAction {
  final int requestId;
  final LatLng? focus;
  final bool showLayers;
  final double zoom;

  MapPageAction(
    this.requestId, [
    this.focus,
    this.showLayers = false,
    this.zoom = 12,
  ]);
}

final mapPageActionProvider =
    NotifierProvider.family<MapPageActionNotifier, MapPageAction, String>(
      MapPageActionNotifier.new,
    );

class MapPageActionNotifier extends FamilyNotifier<MapPageAction, String> {
  @override
  MapPageAction build(String personId) => MapPageAction(0);

  void focusOn(LatLng latlng, {double zoom = 12}) {
    state = MapPageAction(state.requestId + 1, latlng, false, zoom);
  }

  void requestShowLayers() {
    state = MapPageAction(state.requestId + 1, null, true);
  }
}
