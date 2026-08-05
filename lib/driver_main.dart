import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import 'main.dart' as app;
import 'models.dart';
import 'providers.dart';

/// MCP 测试入口：
/// 1. 启用 flutter driver 扩展（支持 tap/输入等标准命令）
/// 2. 注册自定义 handler：直接操作数据层（addWaypoint/createTrip 等），
///    配合 widget inspector 验证 UI 渲染。
late final ProviderContainer appContainer;

void main() {
  appContainer = ProviderContainer();
  enableFlutterDriverExtension(handler: _handleCommand);
  runApp(UncontrolledProviderScope(
    container: appContainer,
    child: const app.AdventuringTimeApp(),
  ));
}

/// 自定义命令格式：`command|key=value|key=value`（FlutterDriver.requestData 发送）。
Future<String> _handleCommand(String? message) async {
  final parts = (message ?? '').split('|');
  final command = parts.first;
  final params = <String, String>{};
  for (final p in parts.skip(1)) {
    final i = p.indexOf('=');
    if (i > 0) params[p.substring(0, i)] = p.substring(i + 1);
  }
  final personId = params['personId'] ?? '';
  final notifier = appContainer.read(personDataProvider(personId).notifier);
  await notifier.future; // 确保数据加载完成
  switch (command) {
    case 'addWaypoint':
      final now = DateTime.now();
      final w = Waypoint(
        id: newId(),
        name: params['name'] ?? '',
        desc: params['desc'],
        latLng: LatLng(double.parse(params['lat']!), double.parse(params['lon']!)),
        time: params['time'] == null ? null : DateTime.parse(params['time']!),
        timePrecision: params['precision'] == null ? null : TimePrecisionX.parse(params['precision']),
        isEvent: params['event'] == 'true',
        fromName: params['fromName'],
        fromLatLng: params['fromLat'] == null
            ? null
            : LatLng(double.parse(params['fromLat']!), double.parse(params['fromLon']!)),
        mediaId: params['mediaId'],
        createdAt: now,
        updatedAt: now,
      );
      await notifier.saveLifeWaypoint(w);
      return 'ok:${w.id}';
    case 'createTrip':
      final now = DateTime.now();
      final t = Trip(
        id: newId(),
        name: params['name'] ?? '',
        description: params['desc'],
        startDate: params['startDate'] == null ? null : DateTime.parse(params['startDate']!),
        endDate: params['endDate'] == null ? null : DateTime.parse(params['endDate']!),
        createdAt: now,
        updatedAt: now,
      );
      await notifier.createTrip(t);
      return 'ok:${t.id}';
    case 'addPath':
      final points = (jsonDecode(params['points']!) as List)
          .map((p) => TrackPoint(LatLng((p['lat'] as num).toDouble(), (p['lon'] as num).toDouble()),
              p['time'] == null ? null : DateTime.parse(p['time'] as String)))
          .toList();
      final now = DateTime.now();
      final path = PathData(
        id: newId(),
        name: params['name'] ?? '测试路径',
        isGps: params['gps'] == 'true',
        points: points,
        createdAt: now,
        updatedAt: now,
      );
      await notifier.saveTripPath(params['tripId']!, path);
      return 'ok:${path.id}';
    case 'getData':
      final d = notifier.d;
      final trips = [for (final t in d.trips) {'id': t.meta.id, 'name': t.meta.name}];
      return jsonEncode({
        'person': d.person.name,
        'lifeWaypoints': d.life.waypoints.length,
        'lifeEvents': d.life.events.length,
        'trips': trips,
      });
    case 'setTripCover':
      await notifier.saveTripMeta(Trip(
        id: params['tripId']!,
        name: 'x',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));
      return 'noop';
    default:
      return 'unknown:$command';
  }
}
