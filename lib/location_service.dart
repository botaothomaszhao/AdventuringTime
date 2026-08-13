import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
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
  static const _posEvents = EventChannel('adventuring_time/location/position');

  static Future<void> start() => _channel.invokeMethod('start');
  static Future<void> pause() => _channel.invokeMethod('pause');
  static Future<void> resume() => _channel.invokeMethod('resume');

  /// 前台/后台模式：前台 1s 定位（蓝点+轨迹），后台降频只采样。服务未运行时 no-op。
  static Future<void> setMode(String mode) =>
      _channel.invokeMethod('setMode', mode);

  /// 停止记录并取回本次会话全部采样点（原生侧已清空会话文件）。
  static Future<List<RawPoint>> stop() async =>
      _decodePoints(await _channel.invokeMethod('stop'));

  /// 会话快照：运行状态、持久化状态（1 记录中/0 暂停）、开始时间、累计时长、当前段起始、采样点。
  static Future<SessionSnapshot> session() async {
    final m = await _channel.invokeMethod('getSession') as Map;
    return SessionSnapshot(
      running: m['running'] as bool? ?? false,
      state: m['state'] as String? ?? '0',
      startAt: _msToTime(m['startAt']),
      segmentStart: _msToTime(m['segmentStart']),
      activeMs: (m['activeMs'] as num?)?.toInt() ?? 0,
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

  /// 实时位置流（仅供蓝点）：会话期间前台服务每次定位都推送（约 1s），含定位时间。
  static Stream<RawPoint> positions() =>
      _posEvents.receiveBroadcastStream().map((e) => _decodePoints([e]).first);

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
  final String state; // '1' 记录中 / '0' 暂停（持久化状态文件值）
  final DateTime? startAt;
  final DateTime? segmentStart; // 当前记录段起始时间
  final int activeMs; // 已累计的记录时长（不含暂停）
  final List<RawPoint> points;

  SessionSnapshot({
    required this.running,
    required this.state,
    required this.startAt,
    required this.segmentStart,
    required this.activeMs,
    required this.points,
  });
}

enum RecordStatus { idle, recording, paused }

/// 一次记录会话的状态：已采样轨迹点 + 累计里程 + 开始时间 + 记录时长。
class RecordState {
  final RecordStatus status;
  final List<TrackPoint> points;
  final double meters;
  final DateTime? startedAt;
  final int recordingSeconds; // 已累计记录时长（不含暂停）
  final DateTime? activeSince; // 当前记录段起始；暂停时为 null

  const RecordState(
    this.status,
    this.points,
    this.meters, [
    this.startedAt,
    this.recordingSeconds = 0,
    this.activeSince,
  ]);

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

  /// 重进应用：会话文件有点即恢复。上次为记录中则直接继续记录（服务未运行则先恢复采样）。
  Future<void> _restore() async {
    final s = await LocationService.session();
    final wasRecording = s.state == '1';
    if (s.points.isEmpty && !wasRecording) return;
    final pts = [for (final p in s.points) TrackPoint(p.latLng, p.time)];
    _lastRawTime = s.points.isEmpty ? null : s.points.last.time;
    final resumed = wasRecording && !s.running;
    if (resumed) {
      await LocationService.resume();
      await _syncMode();
    }
    state = RecordState(
      wasRecording ? RecordStatus.recording : RecordStatus.paused,
      pts,
      pathLengthM([for (final p in pts) p.latLng]),
      s.startAt,
      s.activeMs ~/ 1000,
      wasRecording ? (resumed ? DateTime.now() : (s.segmentStart ?? DateTime.now())) : null,
    );
    _sub ??= LocationService.rawPoints().listen(_onRaw);
  }

  /// 按当前 app 前后台同步服务定位频率（记录开始/恢复后服务刚启动，需纠正模式）。
  Future<void> _syncMode() async {
    final l = WidgetsBinding.instance.lifecycleState;
    await LocationService.setMode(
        l == AppLifecycleState.resumed ? 'foreground' : 'background');
  }

  Future<void> start() async {
    _sub ??= LocationService.rawPoints().listen(_onRaw);
    state = RecordState(RecordStatus.recording, [], 0, DateTime.now(), 0, DateTime.now());
    await LocationService.start();
    await _syncMode();
  }

  Future<void> pause() async {
    await LocationService.pause();
    final last = state.activeSince ?? DateTime.now();
    final secs = state.recordingSeconds + DateTime.now().difference(last).inSeconds;
    state = RecordState(
        RecordStatus.paused, state.points, state.meters, state.startedAt, secs, null);
  }

  Future<void> resume() async {
    await LocationService.resume();
    await _syncMode();
    state = RecordState(RecordStatus.recording, state.points, state.meters, state.startedAt,
        state.recordingSeconds, DateTime.now());
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
      state.recordingSeconds,
      state.activeSince,
    );
  }
}
