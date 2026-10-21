import 'package:adventuring_time/views/latlon_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

void main() {
  group('网格步长', () {
    test('按每度像素取不超过目标间距的最小档位', () {
      expect(gridStepDeg(1.42), 30); // zoom 1
      expect(gridStepDeg(11.38), 10); // zoom 4
      expect(gridStepDeg(182), 0.5); // zoom 8
      expect(gridStepDeg(2913), 0.05); // zoom 12
      expect(gridStepDeg(46603), 0.002); // zoom 16
    });

    test('极高层级取最细档位 0.001 度', () {
      expect(gridStepDeg(372826), 0.001);
    });
  });

  group('度数标注', () {
    test('整数步长不带小数', () {
      expect(gridLabel(36, 1, 'N', 'S'), '36°N');
      expect(gridLabel(-120, 1, 'E', 'W'), '120°W');
      expect(gridLabel(0, 1, 'N', 'S'), '0°');
    });

    test('细分步长按档位保留小数', () {
      expect(gridLabel(36.5, 0.5, 'N', 'S'), '36.5°N');
      expect(gridLabel(120.05, 0.05, 'E', 'W'), '120.05°E');
      expect(gridLabel(120.04, 0.02, 'E', 'W'), '120.04°E');
      expect(gridLabel(30.123, 0.001, 'N', 'S'), '30.123°N');
    });
  });

  testWidgets('网格图层能在地图中正常布局与绘制', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: FlutterMap(
            options: MapOptions(
              initialCenter: LatLng(35, 105),
              initialZoom: 4,
            ),
            children: [LatLonGridLayer(color: Colors.black)],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(LatLonGridLayer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
