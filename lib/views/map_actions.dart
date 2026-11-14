import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

/// 地图页与外部（壳/时间线/详情页/弹窗）的跨页动作通道。

/// 待定位对象类型。
enum MapLocateKind { waypoint, path, trip }

/// 定位目标：只存 id，收到时再从当前数据解析，避免持有过期对象。
class MapLocateRequest {
  final MapLocateKind kind;
  final String id;

  const MapLocateRequest(this.kind, this.id);
}

class MapPageAction {
  final int requestId;
  final LatLng? focus;
  final bool showLayers;
  final double zoom;
  final MapLocateRequest? locate;

  const MapPageAction(
    this.requestId, {
    this.focus,
    this.showLayers = false,
    this.zoom = 12,
    this.locate,
  });
}

final mapPageActionProvider =
    NotifierProvider.family<MapPageActionNotifier, MapPageAction, String>(
      MapPageActionNotifier.new,
    );

class MapPageActionNotifier extends FamilyNotifier<MapPageAction, String> {
  @override
  MapPageAction build(String personId) => const MapPageAction(0);

  void focusOn(LatLng latlng, {double zoom = 12}) {
    state = MapPageAction(state.requestId + 1, focus: latlng, zoom: zoom);
  }

  void requestShowLayers() {
    state = MapPageAction(state.requestId + 1, showLayers: true);
  }

  void locateWaypoint(String id) => state = MapPageAction(
        state.requestId + 1,
        locate: MapLocateRequest(MapLocateKind.waypoint, id),
      );

  void locatePath(String id) => state = MapPageAction(
        state.requestId + 1,
        locate: MapLocateRequest(MapLocateKind.path, id),
      );

  void locateTrip(String id) => state = MapPageAction(
        state.requestId + 1,
        locate: MapLocateRequest(MapLocateKind.trip, id),
      );
}
