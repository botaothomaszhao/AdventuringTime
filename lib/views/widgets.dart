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

/// 大图预览对话框。
void showMediaPreview(BuildContext context, String personId, String mediaId) {
  showDialog(
    context: context,
    builder: (_) => Dialog(
      child: MediaImage(personId: personId, mediaId: mediaId, height: 400, fit: BoxFit.contain),
    ),
  );
}

/// 点击编辑、勾选保存的内联文本编辑（详情页名称/说明复用）。
class InlineTextEdit extends StatefulWidget {
  final String? value;
  final String? hint;
  final int maxLines;
  final TextStyle? style;
  final ValueChanged<String> onSave; // 传入 trim 后的文本

  const InlineTextEdit({
    super.key,
    this.value,
    this.hint,
    this.maxLines = 1,
    this.style,
    required this.onSave,
  });

  @override
  State<InlineTextEdit> createState() => _InlineTextEditState();
}

class _InlineTextEditState extends State<InlineTextEdit> {
  late final TextEditingController _c;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _c = TextEditingController(text: widget.value ?? '');
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _c.text.trim();
    widget.onSave(text);
    setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_editing) {
      return InkWell(
        onTap: () {
          _c.text = widget.value ?? '';
          setState(() => _editing = true);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            _c.text.isEmpty ? (widget.hint ?? '点击编辑') : _c.text,
            style: widget.style ??
                (_c.text.isEmpty
                    ? TextStyle(color: Colors.grey.shade500, fontStyle: FontStyle.italic)
                    : null),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: _c,
              autofocus: true,
              maxLines: widget.maxLines,
              decoration: InputDecoration(
                isDense: true,
                hintText: widget.hint,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: '保存',
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}

/// 照片墙：常驻网格，支持添加/删除/预览。媒体文件的物理清理由页面负责。
class PhotoWall extends ConsumerStatefulWidget {
  final String personId;
  final List<String> mediaIds;
  final Future<void> Function(List<String> next) onChanged;

  const PhotoWall({
    super.key,
    required this.personId,
    required this.mediaIds,
    required this.onChanged,
  });

  @override
  ConsumerState<PhotoWall> createState() => _PhotoWallState();
}

class _PhotoWallState extends ConsumerState<PhotoWall> {
  List<String> get mediaIds => widget.mediaIds;

  Future<void> _add() async {
    final img = await pickImageBytes();
    if (img == null) return;
    final (ext, bytes) = img;
    final id = await ref.read(personDataProvider(widget.personId).notifier).addMedia(ext, bytes);
    await widget.onChanged([...mediaIds, id]);
  }

  Future<void> _remove(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除照片'),
        content: const Text('确定删除该照片？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('确定')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.onChanged([for (final m in mediaIds) if (m != id) m]);
  }

  void _preview(String id) {
    showMediaPreview(context, widget.personId, id);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('照片墙', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          children: [
            for (final id in mediaIds)
              Stack(
                children: [
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: GestureDetector(
                        onTap: () => _preview(id),
                        child: MediaImage(personId: widget.personId, mediaId: id),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 2,
                    right: 2,
                    child: GestureDetector(
                      onTap: () => _remove(id),
                      child: Container(
                        decoration: const BoxDecoration(
                          color: Colors.black54,
                          shape: BoxShape.circle,
                        ),
                        padding: const EdgeInsets.all(2),
                        child: const Icon(Icons.close, size: 16, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            InkWell(
              onTap: _add,
              borderRadius: BorderRadius.circular(6),
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(Icons.add_a_photo_outlined),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
