import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// 瓦片磁盘缓存 TileProvider：命中磁盘直接读，未命中下载后写入缓存。
/// 离线时命中缓存可正常显示。
class DiskCachedTileProvider extends TileProvider {
  final Directory cacheDir;

  DiskCachedTileProvider({required this.cacheDir});

  @override
  bool get supportsCancelLoading => false;

  File _fileFor(TileCoordinates c) => File(p.join(cacheDir.path, '${c.z}', '${c.x}', '${c.y}.png'));

  String _urlFor(TileCoordinates c, TileLayer options) {
    var url = options.urlTemplate ?? '';
    url = url
        .replaceAll('{z}', c.z.toString())
        .replaceAll('{x}', c.x.toString())
        .replaceAll('{y}', c.y.toString());
    final subdomains = options.subdomains;
    if (subdomains.isNotEmpty && url.contains('{s}')) {
      final s = subdomains[(c.x + c.y + c.z) % subdomains.length];
      url = url.replaceAll('{s}', s);
    }
    if (url.contains('{r}')) url = url.replaceAll('{r}', '@2x');
    return url;
  }

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return _CachedTileImage(
      url: _urlFor(coordinates, options),
      cacheFile: _fileFor(coordinates),
      headers: headers,
    );
  }
}

class _CachedTileImage extends ImageProvider<_CachedTileImage> {
  final String url;
  final File cacheFile;
  final Map<String, String> headers;

  _CachedTileImage({required this.url, required this.cacheFile, this.headers = const {}});

  @override
  Future<_CachedTileImage> obtainKey(ImageConfiguration configuration) async => this;

  @override
  ImageStreamCompleter loadImage(_CachedTileImage key, ImageDecoderCallback decode) {
    return OneFrameImageStreamCompleter(_load(decode));
  }

  Future<ImageInfo> _load(ImageDecoderCallback decode) async {
    List<int> bytes;
    if (await cacheFile.exists()) {
      bytes = await cacheFile.readAsBytes();
    } else {
      final resp = await http.get(Uri.parse(url), headers: headers);
      if (resp.statusCode != 200) {
        throw Exception('tile http ${resp.statusCode}: $url');
      }
      bytes = resp.bodyBytes;
      await cacheFile.parent.create(recursive: true);
      await cacheFile.writeAsBytes(bytes, flush: true);
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(Uint8List.fromList(bytes));
    final codec = await decode(buffer);
    final frame = await codec.getNextFrame();
    return ImageInfo(image: frame.image);
  }

  @override
  bool operator ==(Object other) => other is _CachedTileImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
