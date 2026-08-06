import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'lifecycle.dart';
import 'models.dart';

/// 原生定位通道封装。采样（位移 > 20m 或间隔 > 30s）与落盘都在 Kotlin 前台服务，
/// Dart 侧维护 UI 会话状态；重进应用时从原生拉回会话恢复，被杀不丢数据。
class LocationService {
  LocationService._();

  static const _channel = MethodChannel('adventuring_time/location');
  static const _events = EventChannel('adventuring_time/location/events');

  static Future<void> start() => _channel.invokeMethod('start');
  static Future<void> pause() => _channel.invokeMethod('pause');
  static Future<void> resume() => _channel.invokeMethod('resume');

  /// 停止记录并取回本次会话全部采样点（原生侧已清空会话文件）。
  static Future<List<RawPoint>> stop() async =>
      _decodePoints(await _channel.invokeMethod('stop'));

  /// 会话快照：{running, paused, startAt, points}。重进应用时恢复。
  static Future<SessionSnapshot> session() async {
    final m = await _channel.invokeMethod('getSession') as Map;
    return SessionSnapshot(
      running: m['running'] as bool? ?? false,
      paused: m['paused'] as bool? ?? false,
      startAt: _msToTime(m['startAt']),
      points: _decodePoints(m['points']),
    );
  }

  static DateTime? _msToTime(Object? ms) {
    final v = (ms as num?)?.toInt() ?? 0;
    return v <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(v);
  }

  /// 请求定位权限（记录与蓝点共用），返回是否可用。
  static Future<bool> ensureLocationPermission() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      return false;
    }
    return true;
  }

  /// 实时采样点流（仅供 UI 更新）。
  static Stream<RawPoint> rawPoints() =>
      _events.receiveBroadcastStream().map((e) => _decodePoints([e]).first);

  static List<RawPoint> _decodePoints(Object? l) {
    if (l is! List) return [];
    return [
      for (final e in l)
        RawPoint(
          LatLng(((e as Map)['lat'] as num).toDouble(), (e['lon'] as num).toDouble()),
          DateTime.fromMillisecondsSinceEpoch((e['time'] as num).toInt()),
        ),
    ];
  }
}

/// 原生采样点。
class RawPoint {
  final LatLng latLng;
  final DateTime time;

  RawPoint(this.latLng, this.time);
}

class SessionSnapshot {
  final bool running;
  final bool paused;
  final DateTime? startAt;
  final List<RawPoint> points;

  SessionSnapshot({
    required this.running,
    required this.paused,
    required this.startAt,
    required this.points,
  });
}

enum RecordStatus { idle, recording, paused }

/// 一次记录会话的状态：已采样轨迹点 + 累计里程 + 开始时间。
class RecordState {
  final RecordStatus status;
  final List<TrackPoint> points;
  final double meters;
  final DateTime? startedAt;

  const RecordState(this.status, this.points, this.meters, [this.startedAt]);

  static const idle = RecordState(RecordStatus.idle, [], 0);
}

/// 记录会话：重进应用时从原生恢复（点已落盘，服务被杀了也不丢）。
final recordingProvider =
    NotifierProvider<RecordingNotifier, RecordState>(RecordingNotifier.new);

class RecordingNotifier extends Notifier<RecordState> {
  StreamSubscription<RawPoint>? _sub;
  DateTime? _lastRawTime;

  @override
  RecordState build() {
    scheduleMicrotask(_restore);
    return RecordState.idle;
  }

  /// 重进应用：会话文件有点即恢复（服务未运行视为暂停，可点"继续"接着记）。
  Future<void> _restore() async {
    final s = await LocationService.session();
    if (s.points.isEmpty) return;
    final pts = [for (final p in s.points) TrackPoint(p.latLng, p.time)];
    _lastRawTime = s.points.last.time;
    state = RecordState(
      s.running && !s.paused ? RecordStatus.recording : RecordStatus.paused,
      pts,
      pathLengthM([for (final p in pts) p.latLng]),
      s.startAt,
    );
    _sub ??= LocationService.rawPoints().listen(_onRaw);
  }

  Future<void> start() async {
    _sub ??= LocationService.rawPoints().listen(_onRaw);
    state = RecordState(RecordStatus.recording, [], 0, DateTime.now());
    await LocationService.start();
  }

  Future<void> pause() async {
    await LocationService.pause();
    state = RecordState(RecordStatus.paused, state.points, state.meters, state.startedAt);
  }

  Future<void> resume() async {
    await LocationService.resume();
    state = RecordState(RecordStatus.recording, state.points, state.meters, state.startedAt);
  }

  /// 停止记录，返回全部采样点（会话清零）。
  Future<List<TrackPoint>> stop() async {
    await _sub?.cancel();
    _sub = null;
    final pts = [for (final p in await LocationService.stop()) TrackPoint(p.latLng, p.time)];
    _lastRawTime = null;
    state = RecordState.idle;
    return pts;
  }

  void _onRaw(RawPoint p) {
    // 时间戳去重：恢复拉取与实时推送可能重复
    if (_lastRawTime != null && !p.time.isAfter(_lastRawTime!)) return;
    _lastRawTime = p.time;
    final pts = [...state.points, TrackPoint(p.latLng, p.time)];
    state = RecordState(
      state.status,
      pts,
      pts.length < 2 ? 0 : state.meters + haversineM(pts[pts.length - 2].latLng, p.latLng),
      state.startedAt,
    );
  }
}
