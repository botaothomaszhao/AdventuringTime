import 'package:adventuring_time/main.dart';
import 'package:adventuring_time/models.dart';
import 'package:adventuring_time/providers.dart';
import 'package:adventuring_time/views/timeline_page.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

void main() {
  testWidgets('应用可构建：直接进入主界面', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: AdventuringTimeApp()));
    await tester.pump();
    // 无人物时显示空状态与"新增人物"
    expect(find.text('新增人物'), findsWidgets);
    expect(find.text('地图'), findsOneWidget);
  });

  test('时间线：长期地点与行程按时间混合排序', () {
    final person = Person(
      id: 'p1',
      name: '测试',
      createdAt: DateTime.utc(2000, 1, 1),
      updatedAt: DateTime.utc(2000, 1, 1),
    );
    Waypoint wp(String id, String name, DateTime t, {String? tripId}) => Waypoint(
          id: id,
          name: name,
          latLng: const LatLng(0, 0),
          time: t,
          isEvent: true,
          createdAt: t,
          updatedAt: t,
        );
    final d = PersonData(
      person: person,
      life: GpxFile(waypoints: [
        wp('wp1', '出生地', DateTime.utc(1990, 1, 1)),
        wp('wp2', '上海', DateTime.utc(2000, 1, 1)),
      ]),
      trips: [
        TripBundle(
          meta: Trip(
            id: 't1',
            name: '环游世界',
            startDate: DateTime.utc(2010, 1, 1),
            createdAt: DateTime.utc(2010, 1, 1),
            updatedAt: DateTime.utc(2010, 1, 1),
          ),
          gpx: GpxFile(waypoints: [
            wp('wp3', '行程内长期地点', DateTime.utc(2010, 6, 1), tripId: 't1'),
          ]),
        ),
      ],
    );
    final items = buildTimelineItems(d);
    expect(items, hasLength(4));
    // 顺序：出生地(1990) → 上海(2000) → 环游世界(2010) → 行程内长期地点(2010-6)
    expect((items[0].data as Waypoint).name, '出生地');
    expect((items[1].data as Waypoint).name, '上海');
    expect((items[2].data as TripBundle).meta.name, '环游世界');
    expect((items[3].data as Waypoint).name, '行程内长期地点');
    expect(items[3].tripId, 't1');
  });
}
