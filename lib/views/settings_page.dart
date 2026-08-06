import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../geo_search.dart';
import '../providers.dart';
import '../storage.dart';
import '../sync.dart';
import '../sync_server.dart';
import '../version.dart';

/// 设置：瓦片源、搜索服务、局域网同步、数据目录、关于。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final TextEditingController _tileUrl;
  late final TextEditingController _portCtrl;
  late final TextEditingController _addrCtrl;
  bool _saved = false;
  String? _service;
  SyncServer? _server;
  bool _serverBusy = false;
  bool _syncing = false;
  String _syncStatus = '';
  List<String> _ips = const [];

  static const _presets = {
    'Carto Voyager（墙内可用，推荐）':
        'https://basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png',
    'Esri（墙内可用）':
        'https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/{z}/{y}/{x}',
    'OpenStreetMap（需墙外）':
        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  };

  @override
  void initState() {
    super.initState();
    _tileUrl = TextEditingController();
    _portCtrl = TextEditingController();
    _addrCtrl = TextEditingController();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final port = prefs.getInt('syncPort') ?? 8024;
    _portCtrl.text = '$port';
    _addrCtrl.text = prefs.getString('syncAddress') ?? '';
    if (Platform.isWindows) {
      _ips = await _lanIps();
      if (prefs.getBool('syncServerOn') ?? false) {
        await _startServer(port);
      }
    }
    if (mounted) setState(() {});
  }

  Future<List<String>> _lanIps() async {
    final out = <String>[];
    for (final i in await NetworkInterface.list(
        type: InternetAddressType.IPv4, includeLoopback: false)) {
      for (final a in i.addresses) {
        if (!a.isLoopback) out.add(a.address);
      }
    }
    return out;
  }

  Future<void> _startServer(int port) async {
    setState(() => _serverBusy = true);
    try {
      final s = SyncServer(port);
      await s.start();
      _server = s;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('syncServerOn', true);
      setState(() {});
    } finally {
      setState(() => _serverBusy = false);
    }
  }

  Future<void> _stopServer() async {
    setState(() => _serverBusy = true);
    try {
      await _server?.stop();
      _server = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('syncServerOn', false);
      setState(() {});
    } finally {
      setState(() => _serverBusy = false);
    }
  }

  Future<void> _doSync() async {
    final addr = _addrCtrl.text.trim();
    if (addr.isEmpty) {
      setState(() => _syncStatus = '请输入服务器地址（IP:端口）');
      return;
    }
    setState(() {
      _syncing = true;
      _syncStatus = '同步中…';
    });
    try {
      final base = addr.startsWith('http://') ? addr : 'http://$addr';
      final remote = HttpSyncRemote(base);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('syncAddress', addr);
      final root = await resolveDataRoot();
      final app = AppRepository(Directory(p.join(root.path, 'people')));
      final result = await syncAll(app, remote);
      var pulled = 0, pushed = 0, deleted = 0;
      for (final s in result.values) {
        pulled += s.pulled;
        pushed += s.pushed;
        deleted += s.deleted;
      }
      ref.invalidate(peopleProvider);
      final currentId = ref.read(currentPersonIdProvider);
      if (currentId != null) ref.invalidate(personDataProvider(currentId));
      if (!mounted) return;
      setState(() => _syncStatus = '同步完成：拉取 $pulled / 推送 $pushed / 删除 $deleted');
    } catch (e) {
      if (!mounted) return;
      setState(() => _syncStatus = '同步失败：$e');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  void dispose() {
    _tileUrl.dispose();
    _portCtrl.dispose();
    _addrCtrl.dispose();
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
          const Text('如遇部分地区放大后不可用，可尝试更换瓦片源。自定义模板须为 WGS-84 Web Mercator。',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final e in _presets.entries)
                ActionChip(
                  avatar: _tileUrl.text == e.value
                      ? const Icon(Icons.check, size: 16)
                      : null,
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
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () async {
                    await setTileUrl(_tileUrl.text.trim());
                    ref.invalidate(tileUrlProvider);
                    setState(() => _saved = true);
                    if (!mounted) return;
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('已保存并生效')));
                  },
                  child: const Text('保存瓦片源'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () async {
                  final dir = await getApplicationSupportDirectory();
                  final cache = Directory(p.join(dir.path, 'tiles'));
                  if (await cache.exists()) {
                    await cache.delete(recursive: true);
                  }
                  if (!mounted) return;
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('瓦片缓存已清除')));
                },
                child: const Text('清除瓦片缓存'),
              ),
            ],
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
          const Text('局域网同步', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text('Windows 端作为服务器（默认端口 8024），其他设备输入 IP:端口 后点同步。'
              '双向并集合并，冲突以较新版本为准，被覆盖版本自动进备份。',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 8),
          if (Platform.isWindows) ...[
            Row(
              children: [
                Text(_server != null ? '服务器运行中（端口 ${_portCtrl.text}）' : '服务器未运行',
                    style: const TextStyle(fontWeight: FontWeight.w500)),
                const Spacer(),
                FilledButton(
                  onPressed: _serverBusy
                      ? null
                      : () async {
                          if (_server != null) {
                            await _stopServer();
                          } else {
                            await _startServer(int.tryParse(_portCtrl.text.trim()) ?? 8024);
                          }
                        },
                  child: Text(_server != null ? '停止服务器' : '启动服务器'),
                ),
              ],
            ),
            TextField(
              controller: _portCtrl,
              enabled: _server == null,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: '端口',
              ),
            ),
            if (_ips.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('本机 IP：${_ips.join('  /  ')}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
            ],
            const SizedBox(height: 8),
          ],
          TextField(
            controller: _addrCtrl,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: '服务器地址（IP:端口）',
              hintText: '192.168.1.5:8024',
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _syncing ? null : _doSync,
                  icon: const Icon(Icons.sync),
                  label: Text(_syncing ? '同步中…' : '立即同步'),
                ),
              ),
            ],
          ),
          if (_syncStatus.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(_syncStatus, style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
          ],
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
          Text('探索的时光 Adventuring Time v$appVersion\n'
              '纯本地足迹地图：轨迹、长期地点、行程合集。\n'
              '数据格式：GPX + atrip 扩展。'),
          const SizedBox(height: 8),
          InkWell(
            onTap: () => launchUrl(Uri.parse('https://github.com/botaothomaszhao/AdventuringTime')),
            child: const Text('项目主页：https://github.com/botaothomaszhao/AdventuringTime',
                style: TextStyle(color: Colors.blue, decoration: TextDecoration.underline)),
          ),
        ],
      ),
    );
  }
}
