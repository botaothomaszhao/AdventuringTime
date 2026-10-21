import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// 经纬度网格步长档位（度），由大到小。
const _steps = <double>[
  30, 20, 10, 5, 2, 1, 0.5, 0.2, 0.1, 0.05, 0.02, 0.01, 0.005, 0.002, 0.001,
];

/// 相邻网格线目标最大屏幕间距（像素）；步长取使间距不超过它的最小档位。
const _maxSpacing = 160.0;

/// 按每度像素数选步长：从大档位取第一个间距 ≤ [_maxSpacing] 的档位。
double gridStepDeg(double pxPerDeg) {
  for (final s in _steps) {
    if (s * pxPerDeg <= _maxSpacing) return s;
  }
  return _steps.last;
}

/// 标注小数位：步长越细保留越多，保证相邻线标注可区分。
int gridLabelDecimals(double step) {
  if (step >= 1) return 0;
  if (step >= 0.1) return 1;
  if (step >= 0.01) return 2;
  return 3;
}

/// 度数标注：如 `36°N`、`120°E`、`0°`、`180°`。
String gridLabel(double value, double step, String positive, String negative) {
  if (value.abs() < 1e-9) return '0°';
  if (value.abs() == 180) return '180°';
  final dir = value > 0 ? positive : negative;
  return '${value.abs().toStringAsFixed(gridLabelDecimals(step))}°$dir';
}

/// 经度归一到 [-180, 180)，用于把跨世界副本的经线标注成同一度数。
double normalizeLng(double lng) {
  var v = (lng + 180) % 360;
  if (v < 0) v += 360;
  return v - 180;
}

/// 视口内的经线经度（可能超出 ±180，表示同一经度在相邻世界副本上的重复）。
List<double> gridMeridians(double centerLng, double halfSpanDeg, double step) {
  final out = <double>[];
  for (var lng = ((centerLng - halfSpanDeg) / step).ceilToDouble() * step;
      lng <= centerLng + halfSpanDeg;
      lng += step) {
    out.add(lng);
  }
  return out;
}

/// 经纬度网格图层：画在当前视口范围内的经纬线及度数标注。
/// 只读覆盖层，不参与地图交互。
class LatLonGridLayer extends StatelessWidget {
  final Color color;

  const LatLonGridLayer({super.key, required this.color});

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    return IgnorePointer(
      child: CustomPaint(
        size: camera.size,
        painter: _GridPainter(camera: camera, color: color),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  final MapCamera camera;
  final Color color;

  _GridPainter({required this.camera, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final worldPx = camera.getWorldWidthAtZoom();
    if (worldPx == 0) return;
    final pxPerDeg = worldPx / 360;
    final step = gridStepDeg(pxPerDeg);
    final b = camera.visibleBounds;
    // 经度范围按视口宽度反推，不取 visibleBounds（其经度被夹在 ±180，跨世界副本会缺线）；
    // 多留一档步长作旋转余量。
    final centerLng = camera.center.longitude;
    final halfSpan = size.width / pxPerDeg / 2 + step;
    final westLng = centerLng - halfSpan;
    final eastLng = centerLng + halfSpan;
    final line = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    final halo = color.computeLuminance() > 0.5 ? Colors.black : Colors.white;
    final style = TextStyle(
      color: color.withValues(alpha: 0.85),
      fontSize: 10,
      shadows: [Shadow(color: halo, blurRadius: 2)],
    );

    void label(String text, double x, double y) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      if (y + tp.height < 0 || y > size.height) return;
      if (x + tp.width < 0 || x > size.width) return;
      canvas.drawRect(
        Rect.fromLTWH(x, y, tp.width, tp.height).inflate(1),
        Paint()..color = halo.withValues(alpha: 0.55),
      );
      tp.paint(canvas, Offset(x, y));
    }

    // 纬线：标注贴在左缘（旋转地图时位置随投影变化）
    for (var lat = (b.south / step).ceilToDouble() * step;
        lat <= b.north;
        lat += step) {
      final a = camera.latLngToScreenOffset(LatLng(lat, westLng));
      final c = camera.latLngToScreenOffset(LatLng(lat, eastLng));
      canvas.drawLine(a, c, line);
      label(gridLabel(lat, step, 'N', 'S'), 2, a.dy + 1);
    }

    // 经线：标注贴顶缘；跨 ±180 与低缩放重复的世界副本各画一份
    for (final lng in gridMeridians(centerLng, halfSpan, step)) {
      final a = camera.latLngToScreenOffset(LatLng(b.north, lng));
      final c = camera.latLngToScreenOffset(LatLng(b.south, lng));
      canvas.drawLine(a, c, line);
      label(gridLabel(normalizeLng(lng), step, 'E', 'W'), a.dx + 2, 2);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => true;
}
