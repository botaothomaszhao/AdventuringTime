import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

import '../providers.dart';

/// 选择一张图片文件，返回 (扩展名, 字节)。Android 用系统相册，桌面用文件选择器。
Future<(String, List<int>)?> pickImageBytes() async {
  XFile? file;
  if (Platform.isAndroid) {
    file = await ImagePicker().pickImage(source: ImageSource.gallery);
  } else {
    const group = XTypeGroup(
      label: 'images',
      extensions: ['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'],
    );
    file = await openFile(acceptedTypeGroups: const [group]);
  }
  if (file == null) return null;
  final ext = p.extension(file.path).replaceFirst('.', '').toLowerCase();
  final norm = ext == 'jpeg' ? 'jpg' : (ext.isEmpty ? 'jpg' : ext);
  return (norm, await file.readAsBytes());
}

/// 按 mediaId 显示媒体文件（按需加载）。
class MediaImage extends ConsumerWidget {
  final String personId;
  final String? mediaId;
  final double? width;
  final double? height;
  final BoxFit fit;

  const MediaImage({
    super.key,
    required this.personId,
    this.mediaId,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = mediaId;
    if (id == null) {
      return Container(
        width: width,
        height: height,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Icon(Icons.image_outlined),
      );
    }
    return SizedBox(
      width: width,
      height: height,
      child: FutureBuilder<File?>(
        future: ref.watch(mediaFileProvider((personId, id)).future),
        builder: (context, snap) {
          final f = snap.data;
          if (f == null || !f.existsSync()) {
            return Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: const Icon(Icons.broken_image_outlined),
            );
          }
          return Image.file(f, fit: fit, width: width, height: height);
        },
      ),
    );
  }
}

/// 按 mediaId 找文件（不含扩展名匹配）。
final mediaFileProvider = FutureProvider.family<File?, (String, String)>((ref, args) async {
  final (personId, mediaId) = args;
  final repo = await ref.watch(personRepoProvider(personId).future);
  return repo.media.find(mediaId);
});

String fmtDate(DateTime? t) =>
    t == null ? '—' : '${t.year}年${t.month}月${t.day}日';
