import 'dart:convert';

import 'package:http/http.dart' as http;

/// OSM Nominatim 地理编码。服务地址收敛于此，可替换。
class GeoResult {
  final String name;
  final double lat;
  final double lon;

  const GeoResult({required this.name, required this.lat, required this.lon});
}

Future<List<GeoResult>> searchAddress(String q) async {
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
