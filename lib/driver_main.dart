import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import 'main.dart' as app;
import 'geo_search.dart';
import 'models.dart';
import 'providers.dart';
import 'storage.dart';

/// MCP 测试入口：
/// 1. 启用 flutter driver 扩展（支持 tap/输入等标准命令）
/// 2. 注册自定义 handler：直接操作数据层（addWaypoint/createTrip 等），
///    配合 widget inspector 验证 UI 渲染。
late final ProviderContainer appContainer;
final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

void main() {
  appContainer = ProviderContainer();
  enableFlutterDriverExtension(handler: _handleCommand);
  runApp(UncontrolledProviderScope(
    container: appContainer,
    child: MaterialApp(
      navigatorKey: navKey,
      onGenerateRoute: app.generateRoute,
    ),
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

  Future<PersonRepository> _repoFor(String pid) =>
      appContainer.read(personRepoProvider(pid).future);
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
    case 'media':
      // 从指定路径导入媒体到池，返回 mediaId
      final f = File(params['path']!);
      final id = await notifier.addMediaFromPath(f);
      return 'ok:$id';
    case 'setWaypointMedia':
      final w = notifier.d.life.waypoints.firstWhere((x) => x.id == params['waypointId']!);
      w.mediaId = params['mediaId'];
      await notifier.saveLifeWaypoint(w);
      return 'ok:${w.mediaId}';
    case 'setTripCover':
      final t = notifier.d.tripById(params['tripId']!);
      if (t == null) return 'no-trip';
      final meta = Trip(
        id: t.meta.id,
        name: t.meta.name,
        description: t.meta.description,
        cover: params['mediaId'],
        startDate: t.meta.startDate,
        endDate: t.meta.endDate,
        startEventId: t.meta.startEventId,
        endEventId: t.meta.endEventId,
        createdAt: t.meta.createdAt,
        updatedAt: t.meta.updatedAt,
      );
      await notifier.saveTripMeta(meta);
      return 'ok';
    case 'typeText':
      // 向当前聚焦的 EditableText 注入文本（driver enterText 在桌面端不可靠）
      final text = params['text'] ?? '';
      final focus = FocusManager.instance.primaryFocus;
      final state = focus?.context?.findAncestorStateOfType<EditableTextState>();
      if (state == null) return 'no-focus';
      state.updateEditingValue(TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ));
      return 'ok';
    case 'readLife':
      final repo = await _repoFor(personId);
      final g = await repo.loadLife();
      return jsonEncode([
        for (final w in g.waypoints) {'id': w.id, 'name': w.name, 'mediaId': w.mediaId},
      ]);
    case 'moveEvent':
      // 事件移入/移出行程：dir=in/out
      if (params['dir'] == 'in') {
        await notifier.moveEventToTrip(params['eventId']!, params['tripId']!);
      } else {
        await notifier.moveEventOutOfTrip(params['eventId']!);
      }
      return 'ok';
    case 'getLife':
      final d = notifier.d;
      return jsonEncode({
        'life': [for (final w in d.life.waypoints) {'id': w.id, 'name': w.name, 'isEvent': w.isEvent}],
        'tripEvents': [
          for (final t in d.trips)
            {
              'trip': t.meta.id,
              'events': [for (final w in t.gpx.waypoints) if (w.isEvent) w.id],
            }
        ],
      });
    case 'reverse':
      final addr = await reverseAddress(
        double.parse(params['lat']!),
        double.parse(params['lon']!),
      );
      return 'addr:$addr';
    case 'nav':
      // 直接导航（绕开 driver tap 的 Windows idle 问题）
      navKey.currentState?.pushNamed(params['route'] ?? '/');
      return 'ok';
    case 'uiState':
      // 返回 UI 关键状态（当前焦点）
      return jsonEncode({
        'focus': FocusManager.instance.primaryFocus?.context?.widget.runtimeType.toString(),
      });
    default:
      return 'unknown:$command';
  }
}
