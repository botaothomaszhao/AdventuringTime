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
import 'views/dialogs.dart';
import 'views/person_shell.dart';

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
    case 'addTripPhoto':
      // 给行程照片列表首位插入一张媒体
      final t = notifier.d.tripById(params['tripId']!);
      if (t == null) return 'no-trip';
      final c = params['mediaId'];
      final meta = Trip(
        id: t.meta.id,
        name: t.meta.name,
        description: t.meta.description,
        mediaIds: c == null
            ? t.meta.mediaIds
            : [c, ...t.meta.mediaIds.where((m) => m != c)],
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
    case 'addWaypointDialog':
      // 与地图页 _addWaypointAt 相同的完整流程：对话框 → 按类型分发保存
      final form = await showWaypointDialog(
        navKey.currentContext!,
        personId: personId,
        initialPos: LatLng(double.parse(params['lat']!), double.parse(params['lon']!)),
        tripId: params['tripId'],
        presetTime: params['presetTime'] == null
            ? null
            : DateTime.parse(params['presetTime']!),
      );
      if (form == null) return 'cancelled';
      final now = DateTime.now();
      final w = Waypoint(
        id: newId(),
        name: form.name,
        desc: form.desc,
        latLng: LatLng(double.parse(params['lat']!), double.parse(params['lon']!)),
        time: form.time,
        timePrecision: form.precision,
        isEvent: form.isEvent,
        mediaIds: form.mediaIds,
        createdAt: now,
        updatedAt: now,
      );
      form.applyTo(w);
      if (form.isEvent) {
        await notifier.saveLifeWaypoint(w);
      } else {
        await notifier.saveTripWaypoint(form.tripId!, w);
      }
      return 'saved:${w.id}|isEvent=${form.isEvent}|trip=${form.tripId ?? ''}';
    case 'saveTripWaypoint':
      // 直接给指定行程添加地点（flag 标记验证用）
      final now = DateTime.now();
      final w = Waypoint(
        id: newId(),
        name: params['name'] ?? '',
        latLng: LatLng(double.parse(params['lat']!), double.parse(params['lon']!)),
        time: DateTime.parse(params['time'] ?? DateTime.now().toIso8601String()),
        createdAt: now,
        updatedAt: now,
      );
      await notifier.saveTripWaypoint(params['tripId']!, w);
      return 'ok:${w.id}';
    case 'nav':
      // 直接导航（绕开 driver tap 的 Windows idle 问题）
      navKey.currentState?.pushNamed(params['route'] ?? '/');
      return 'ok';
    case 'debugAnchor':
      // 检查行程 flag 锚点状态（验证渲染用）
      final d = notifier.d;
      final allLife = [
        for (final w in d.life.events) w,
        for (final x in d.trips) ...x.gpx.events,
      ];
      return [for (final t in d.trips) {
            'name': t.meta.name,
            'paths': t.gpx.paths.length,
            'wps': t.gpx.waypoints.length,
            'startRef': t.meta.startEventId,
            'startRefInLife': t.meta.startEventId != null &&
                allLife.any((w) => w.id == t.meta.startEventId),
          }]
          .map((m) => jsonEncode(m))
          .join(' | ');
    case 'focusMap':
      // 地图定位（验证 marker 渲染用），zoom 可选
      appContainer.read(mapPageActionProvider(personId).notifier).focusOn(
            LatLng(double.parse(params['lat']!), double.parse(params['lon']!)),
            zoom: double.parse(params['zoom'] ?? '12'),
          );
      return 'ok';
    case 'uiState':
      // 返回 UI 关键状态（焦点、对话框标题、SnackBar 文本）
      String? snackText;
      String? dialogTitle;
      void walk(Element e) {
        if (snackText != null && dialogTitle != null) return;
        if (e.widget is SnackBar) {
          final c = (e.widget as SnackBar).content;
          if (c is Text && snackText == null) snackText = c.data;
        } else if (e.widget is AlertDialog) {
          final t = (e.widget as AlertDialog).title;
          if (t is Text && dialogTitle == null) dialogTitle = t.data;
        }
        e.visitChildren(walk);
      }

      final root = WidgetsBinding.instance.rootElement;
      if (root != null) walk(root);
      // 中文文本输出码点（ASCII 安全，避免终端编码干扰调试）
      String cp(String? s) =>
          s == null ? '' : [for (final c in s.codeUnits) c.toRadixString(16)].join('-');
      return jsonEncode({
        'focus': FocusManager.instance.primaryFocus?.context?.widget.runtimeType.toString(),
        'snack': cp(snackText),
        'dialog': cp(dialogTitle),
      });
    default:
      return 'unknown:$command';
  }
}
