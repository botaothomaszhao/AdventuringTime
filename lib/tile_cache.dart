import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// 通知地图重载瓦片（清除缓存后调用）。
final StreamController<void> tileReset = StreamController<void>.broadcast();

/// 删除瓦片磁盘缓存，并清空 Flutter 内存图像缓存、通知地图重载。
/// 只删磁盘不清内存缓存的话，已解码的旧瓦片仍会按 URL 命中，看起来像没清。
Future<void> clearTileCache(Directory cacheDir) async {
  if (await cacheDir.exists()) {
    await cacheDir.delete(recursive: true);
  }
  PaintingBinding.instance.imageCache
    ..clear()
    ..clearLiveImages();
  tileReset.add(null);
}

/// 瓦片磁盘缓存 TileProvider：命中磁盘直接读，未命中下载后写入缓存。
/// 离线时命中缓存可正常显示。
class DiskCachedTileProvider extends TileProvider {
  final Directory cacheDir;

  /// 开启后，缓存瓦片若来自其他瓦片源（[TileCoordinates] 旁的 `.src` 标记不符），
  /// 浏览到时重新下载并覆盖；关闭时缓存瓦片始终优先。
  bool overwriteMismatched = false;

  DiskCachedTileProvider({required this.cacheDir});

  @override
  bool get supportsCancelLoading => false;

  File _fileFor(TileCoordinates c) => File(p.join(cacheDir.path, '${c.z}', '${c.x}', '${c.y}.png'));

  /// 记录瓦片下载时所用瓦片源（URL 模板）的标记文件。
  File _sourceFileFor(TileCoordinates c) => File(p.join(cacheDir.path, '${c.z}', '${c.x}', '${c.y}.src'));

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
      source: options.urlTemplate ?? '',
      cacheFile: _fileFor(coordinates),
      sourceFile: _sourceFileFor(coordinates),
      overwriteMismatched: overwriteMismatched,
      headers: headers,
    );
  }
}

class _CachedTileImage extends ImageProvider<_CachedTileImage> {
  final String url;
  final String source;
  final File cacheFile;
  final File sourceFile;
  final bool overwriteMismatched;
  final Map<String, String> headers;

  _CachedTileImage({
    required this.url,
    required this.source,
    required this.cacheFile,
    required this.sourceFile,
    required this.overwriteMismatched,
    this.headers = const {},
  });

  @override
  Future<_CachedTileImage> obtainKey(ImageConfiguration configuration) async => this;

  @override
  ImageStreamCompleter loadImage(_CachedTileImage key, ImageDecoderCallback decode) {
    return OneFrameImageStreamCompleter(_load(decode));
  }

  /// 缓存瓦片是否来自其他源（无 `.src` 标记的旧缓存视为未知来源）。
  Future<bool> _isOtherSource() async {
    if (!await sourceFile.exists()) return true;
    return (await sourceFile.readAsString()).trim() != source.trim();
  }

  Future<ImageInfo> _load(ImageDecoderCallback decode) async {
    final cached = await cacheFile.exists();
    final stale = cached && overwriteMismatched && await _isOtherSource();
    List<int> bytes;
    if (cached && !stale) {
      bytes = await cacheFile.readAsBytes();
    } else {
      try {
        final resp = await http.get(Uri.parse(url), headers: headers);
        if (resp.statusCode != 200) {
          throw Exception('tile http ${resp.statusCode}: $url');
        }
        bytes = resp.bodyBytes;
        await cacheFile.parent.create(recursive: true);
        await cacheFile.writeAsBytes(bytes, flush: true);
        await sourceFile.writeAsString(source, flush: true);
      } catch (_) {
        // 覆盖失败（如离线）时仍用旧缓存，保证已缓存区域可看。
        if (!cached) rethrow;
        bytes = await cacheFile.readAsBytes();
      }
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
