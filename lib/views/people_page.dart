import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import 'dialogs.dart';
import 'widgets.dart';

/// 人列表：增删、编辑资料、进入各人视图。
class PeoplePage extends ConsumerWidget {
  const PeoplePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final people = ref.watch(peopleProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('探索的时光'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
            onPressed: () => Navigator.pushNamed(context, '/settings'),
          ),
        ],
      ),
      body: people.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败：$e')),
        data: (list) => list.isEmpty
            ? const Center(child: Text('还没有人，点右下角添加'))
            : ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final p = list[i];
                  return Card(
                    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: ListTile(
                      leading: MediaImage(personId: p.id, mediaId: p.avatar, width: 44, height: 44),
                      title: Text(p.name),
                      subtitle: Text(p.bio ?? ''),
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) async {
                          if (v == 'edit') {
                            final r = await showPersonDialog(context, existing: p);
                            if (r == null) return;
                            final (name, bio) = r;
                            p.name = name;
                            p.bio = bio;
                            await ref.read(peopleProvider.notifier).updatePerson(p);
                          } else if (v == 'delete') {
                            final ok = await confirmDialog(context, '删除人员', '将连同备份一起物理删除 ${p.name} 的全部数据，确定？');
                            if (ok) {
                              await ref.read(peopleProvider.notifier).removePerson(p.id);
                            }
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('编辑资料')),
                          PopupMenuItem(value: 'delete', child: Text('删除')),
                        ],
                      ),
                      onTap: () => Navigator.pushNamed(context, '/person/${p.id}/map'),
                    ),
                  );
                },
              ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final r = await showPersonDialog(context);
          if (r == null) return;
          final (name, bio) = r;
          await ref.read(peopleProvider.notifier).addPerson(name, bio: bio);
        },
        child: const Icon(Icons.person_add),
      ),
    );
  }
}
