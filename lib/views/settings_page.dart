import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../geo_search.dart';
import '../providers.dart';
import '../storage.dart';

/// 设置：瓦片源、搜索服务、数据目录、关于。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final TextEditingController _tileUrl;
  bool _saved = false;
  String? _service;

  static const _presets = {
    'Esri（墙内可用，推荐）':
        'https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/{z}/{y}/{x}',
    'OpenStreetMap':
        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    'Carto Voyager':
        'https://basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png',
  };

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
    final currentService = _service ?? ref.watch(geocodeServiceProvider).maybeWhen(data: (s) => s, orElse: () => 'photon');
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('地图瓦片源', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text('墙内网络建议使用 Esri（坐标与 OSM 一致）。自定义模板须为 WGS-84 Web Mercator。',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final e in _presets.entries)
                ActionChip(
                  label: Text(e.key),
                  onPressed: () {
                    setState(() {
                      _tileUrl.text = e.value;
                      _saved = false;
                    });
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _tileUrl,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '瓦片模板 URL',
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
          const Text('地址搜索服务', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text('Photon（默认，墙内可用）；Nominatim 为 OSM 官方服务，墙内可能超时。',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'photon', label: Text('Photon')),
              ButtonSegment(value: 'nominatim', label: Text('Nominatim')),
            ],
            selected: {currentService ?? 'photon'},
            onSelectionChanged: (s) async {
              await setGeocodeService(s.first);
              setState(() => _service = s.first);
              if (!mounted) return;
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('搜索服务已切换')));
            },
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
