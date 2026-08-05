import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../storage.dart';

/// 设置：瓦片源 URL、数据目录、关于。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final TextEditingController _tileUrl;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _tileUrl = TextEditingController();
  }

  @override
  void dispose() {
    _tileUrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tile = ref.watch(tileUrlProvider).maybeWhen(data: (u) => u, orElse: () => '');
    if (!_saved && _tileUrl.text.isEmpty) {
      _tileUrl.text = tile;
    }
    final root = ref.watch(dataRootProvider).maybeWhen(data: (d) => d.path, orElse: () => '');
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('瓦片源', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextField(
            controller: _tileUrl,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            ),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () async {
              await setTileUrl(_tileUrl.text.trim());
              setState(() => _saved = true);
              if (!mounted) return;
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('已保存（重启后生效）')));
            },
            child: const Text('保存瓦片源'),
          ),
          const Divider(height: 32),
          const Text('数据目录', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('当前：$root'),
          const SizedBox(height: 8),
          TextField(
            onSubmitted: (v) async {
              await setDataRoot(v.trim().isEmpty ? null : v.trim());
              ref.invalidate(dataRootProvider);
            },
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: '修改数据目录（留空恢复默认）',
            ),
          ),
          const Divider(height: 32),
          const Text('关于', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('探索的时光 Adventuring Time v0.1\n'
              '纯本地足迹地图：轨迹、生活事件、行程合集。\n'
              '数据格式：GPX + atrip 扩展。'),
          const SizedBox(height: 8),
          Text('默认数据位置：%USERPROFILE%\\AdventuringTime\\data',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        ],
      ),
    );
  }
}
