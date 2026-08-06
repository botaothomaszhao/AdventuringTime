import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 地理编码服务。墙内网络下 OSM Nominatim 不可达，默认用 Photon
/// （photon.komoot.io，返回 WGS-84 坐标，无 key）。接口收敛于此，可替换。
class GeoResult {
  final String name;
  final double lat;
  final double lon;

  const GeoResult({required this.name, required this.lat, required this.lon});
}

/// 读取当前搜索服务（photon / nominatim，设置页可切换）。
Future<String> geocodeService() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString('geocodeService') ?? 'photon';
}

Future<void> setGeocodeService(String service) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('geocodeService', service);
}

Future<List<GeoResult>> searchAddress(String q) async {
  final service = await geocodeService();
  if (service == 'nominatim') {
    return _searchNominatim(q);
  }
  return _searchPhoton(q);
}

Future<List<GeoResult>> _searchPhoton(String q) async {
  final url = Uri.parse(
      'https://photon.komoot.io/api/?limit=5&q=${Uri.encodeComponent(q)}');
  final resp = await http.get(url, headers: {'User-Agent': 'AdventuringTime/1.0'});
  if (resp.statusCode != 200) {
    throw Exception('搜索失败：HTTP ${resp.statusCode}');
  }
  final json = jsonDecode(utf8.decode(resp.bodyBytes));
  final features = (json['features'] as List? ?? []);
  final out = <GeoResult>[];
  for (final f in features) {
    final props = f['properties'] as Map<String, dynamic>? ?? {};
    final geo = f['geometry'] as Map<String, dynamic>?;
    if (geo == null) continue;
    final coords = geo['coordinates'] as List?;
    if (coords == null || coords.length < 2) continue;
    final name = <String?>[
      props['name'] as String?,
      props['city'] as String?,
      props['country'] as String?,
    ].where((s) => s != null && s.isNotEmpty).join('，');
    if (name.isEmpty) continue;
    out.add(GeoResult(
      name: name,
      lat: (coords[1] as num).toDouble(),
      lon: (coords[0] as num).toDouble(),
    ));
  }
  return out;
}

Future<List<GeoResult>> _searchNominatim(String q) async {
  final url = Uri.parse(
      'https://nominatim.openstreetmap.org/search?format=json&limit=5&accept-language=zh&q=${Uri.encodeComponent(q)}');
  final resp = await http.get(url, headers: {'User-Agent': 'AdventuringTime/1.0'});
  if (resp.statusCode != 200) {
    throw Exception('搜索失败：HTTP ${resp.statusCode}');
  }
  final list = jsonDecode(utf8.decode(resp.bodyBytes)) as List;
  return [
    for (final item in list)
      GeoResult(
        name: (item['display_name'] as String? ?? ''),
        lat: double.parse(item['lat'] as String),
        lon: double.parse(item['lon'] as String),
      ),
  ];
}

/// 反向地理编码：坐标 → 小范围地址（村/镇/路名，不含国家省份等大范围）。
/// 无结果或失败返回 null。
Future<String?> reverseAddress(double lat, double lon) async {
  try {
    final url = Uri.parse('https://photon.komoot.io/reverse?lon=$lon&lat=$lat');
    final resp = await http.get(url, headers: {'User-Agent': 'AdventuringTime/1.0'}).timeout(const Duration(seconds: 4));
    if (resp.statusCode != 200) return null;
    final json = jsonDecode(utf8.decode(resp.bodyBytes));
    final features = (json['features'] as List? ?? []);
    if (features.isEmpty) return null;
    final props = (features.first['properties'] as Map<String, dynamic>? ?? {});
    final parts = <String?>[
      props['name'] as String?,
      props['street'] as String?,
      props['district'] as String?,
      props['city'] as String?,
    ];
    final out = parts.where((s) => s != null && s.isNotEmpty).map((s) => s!).toList();
    return out.isEmpty ? null : out.join('，');
  } catch (_) {
    return null;
  }
}
