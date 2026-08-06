import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../geo_search.dart';
import '../lifecycle.dart';
import '../models.dart';
import '../providers.dart';
import 'widgets.dart';

/// 编辑对话框集合：地点/事件、路径、行程、人。

/// 地点/事件表单结果。
class WaypointForm {
  final String name;
  final String? desc;
  final DateTime? time;
  final TimePrecision? precision;
  final String? fromName;
  final LatLng? fromLatLng;
  final String? mediaId;
  final bool isEvent;

  const WaypointForm({
    required this.name,
    this.desc,
    this.time,
    this.precision,
    this.fromName,
    this.fromLatLng,
    this.mediaId,
    this.isEvent = false,
  });

  /// 应用到现有 waypoint（写操作前调用，维护 updatedAt）。
  void applyTo(Waypoint w) {
    w.name = name;
    w.desc = desc;
    w.time = time;
    w.timePrecision = precision;
    w.fromName = fromName;
    w.fromLatLng = fromLatLng;
    w.mediaId = mediaId;
    w.isEvent = isEvent;
  }
}

Future<WaypointForm?> showWaypointDialog(
  BuildContext context, {
  required String personId,
  Waypoint? existing,
  LatLng? initialPos,
  String? defaultName,
}) {
  return showDialog<WaypointForm>(
    context: context,
    builder: (_) => _WaypointDialog(
      personId: personId,
      existing: existing,
      initialPos: initialPos,
      defaultName: defaultName,
    ),
  );
}

class _WaypointDialog extends ConsumerStatefulWidget {
  final String personId;
  final Waypoint? existing;
  final LatLng? initialPos;
  final String? defaultName;

  const _WaypointDialog({required this.personId, this.existing, this.initialPos, this.defaultName});

  @override
  ConsumerState<_WaypointDialog> createState() => _WaypointDialogState();
}

class _WaypointDialogState extends ConsumerState<_WaypointDialog> {
  late final TextEditingController _name;
  late final TextEditingController _desc;
  late final TextEditingController _fromName;
  DateTime? _time;
  TimePrecision? _precision;
  LatLng? _fromLatLng;
  String? _mediaId;
  late bool _isEvent;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? widget.defaultName ?? '');
    _desc = TextEditingController(text: e?.desc ?? '');
    _fromName = TextEditingController(text: e?.fromName ?? '');
    _time = e?.time;
    _precision = e?.timePrecision;
    _fromLatLng = e?.fromLatLng;
    _mediaId = e?.mediaId;
    _isEvent = e?.isEvent ?? false;
    if (widget.existing == null && _name.text.isEmpty) {
      _reverseFill();
    }
  }

  /// 新建且无默认名称时，异步反向地理编码填充名称（请求期间不阻塞弹窗）。
  Future<void> _reverseFill() async {
    final pos = widget.initialPos;
    if (pos == null) return;
    final addr = await reverseAddress(pos.latitude, pos.longitude);
    if (addr == null || addr.isEmpty || !mounted) return;
    if (_name.text.isEmpty) {
      _name.text = addr;
      setState(() {});
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    _fromName.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final now = _time ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
    );
    if (date == null) return;
    setState(() {
      _time = date;
      _precision ??= TimePrecision.day;
    });
  }

  Future<void> _pickImage() async {
    final img = await pickImageBytes();
    if (img == null) return;
    final (ext, bytes) = img;
    final id = await ref.read(personDataProvider(widget.personId).notifier).addMedia(ext, bytes);
    ref.invalidate(mediaListProvider(widget.personId));
    setState(() => _mediaId = id);
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('名称不能为空')));
      }
      return;
    }
    Navigator.pop(
      context,
      WaypointForm(
        name: name,
        desc: _desc.text.trim().isEmpty ? null : _desc.text.trim(),
        time: _time,
        precision: _precision,
        fromName: _fromName.text.trim().isEmpty ? null : _fromName.text.trim(),
        fromLatLng: _fromLatLng,
        mediaId: _mediaId,
        isEvent: _isEvent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pos = widget.existing?.latLng ?? widget.initialPos;
    return AlertDialog(
      title: Text(widget.existing == null ? (widget.initialPos != null ? '新增地点' : '新增事件') : '编辑'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('坐标：${pos == null ? '—' : formatLatLng(pos)}'),
            const SizedBox(height: 12),
            if (widget.existing == null)
              CheckboxListTile(
                value: _isEvent,
                onChanged: (v) => setState(() => _isEvent = v ?? false),
                title: const Text('作为生活事件'),
                dense: true,
                contentPadding: EdgeInsets.zero,
              ),
            TextField(
              key: const ValueKey('wp-name'),
              controller: _name,
              decoration: const InputDecoration(labelText: '名称', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('wp-desc'),
              controller: _desc,
              decoration: const InputDecoration(labelText: '说明', border: OutlineInputBorder()),
              maxLines: 2,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickTime,
                    icon: const Icon(Icons.event),
                    label: Text(_time == null ? '设置时间' : _fmtTime()),
                  ),
                ),
                if (_time != null) ...[
                  const SizedBox(width: 8),
                  DropdownButton<TimePrecision>(
                    value: _precision ?? TimePrecision.day,
                    onChanged: (v) => setState(() => _precision = v),
                    items: const [
                      DropdownMenuItem(value: TimePrecision.year, child: Text('年')),
                      DropdownMenuItem(value: TimePrecision.month, child: Text('月')),
                      DropdownMenuItem(value: TimePrecision.day, child: Text('日')),
                    ],
                  ),
                ],
              ],
            ),
            if (_isEvent) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _fromName,
                decoration: const InputDecoration(labelText: '起点名（A→B，可选）', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 4),
              if (_fromLatLng != null)
                Text('起点坐标：${formatLatLng(_fromLatLng!)}'),
              TextButton(
                onPressed: () async {
                  // 简单方式：让用户输入起点坐标；暂不引入二次地图选择
                  final ctrl = TextEditingController();
                  final lat = await showDialog<String>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('起点纬度'),
                      content: TextField(
                        controller: ctrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(hintText: '例如 30.59'),
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
                        FilledButton(onPressed: () => Navigator.pop(c, ctrl.text), child: const Text('确定')),
                      ],
                    ),
                  );
                  if (lat == null || lat.isEmpty) return;
                  final lonCtrl = TextEditingController();
                  if (!context.mounted) return;
                  final lon = await showDialog<String>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('起点经度'),
                      content: TextField(
                        controller: lonCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(hintText: '例如 114.30'),
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
                        FilledButton(onPressed: () => Navigator.pop(c, lonCtrl.text), child: const Text('确定')),
                      ],
                    ),
                  );
                  final la = double.tryParse(lat);
                  final lo = double.tryParse(lon ?? '');
                  if (la != null && lo != null) {
                    setState(() => _fromLatLng = LatLng(la, lo));
                  }
                },
                child: const Text('设置起点坐标'),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _MediaThumb(personId: widget.personId, mediaId: _mediaId)),
                TextButton.icon(
                  onPressed: _pickImage,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  label: const Text('附图'),
                ),
                if (_mediaId != null)
                  IconButton(
                    onPressed: () => setState(() => _mediaId = null),
                    icon: const Icon(Icons.delete_outline),
                    tooltip: '移除图片',
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(key: const ValueKey('dialog-cancel'), onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(key: const ValueKey('dialog-save'), onPressed: _submit, child: const Text('保存')),
      ],
    );
  }

  String _fmtTime() {
    final t = _time!;
    return switch (_precision ?? TimePrecision.day) {
      TimePrecision.year => '${t.year}年',
      TimePrecision.month => '${t.year}年${t.month}月',
      TimePrecision.day => '${t.year}年${t.month}月${t.day}日',
    };
  }
}

/// 媒体缩略预览。
class _MediaThumb extends ConsumerWidget {
  final String personId;
  final String? mediaId;

  const _MediaThumb({required this.personId, this.mediaId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (mediaId == null) {
      return const Text('未附图');
    }
    final async = ref.watch(mediaFileProvider((personId, mediaId!)));
    final file = async.maybeWhen(
      data: (f) => f,
      orElse: () => null,
    );
    if (file == null || !file.existsSync()) return const Text('未附图');
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.file(file, width: 72, height: 72, fit: BoxFit.cover),
    );
  }
}

/// 路径表单结果。
class PathForm {
  final String name;
  final String? desc;
  final String? mediaId;

  const PathForm({required this.name, this.desc, this.mediaId});

  void applyTo(PathData p) {
    p.name = name;
    p.desc = desc;
    p.mediaId = mediaId;
  }
}

Future<PathForm?> showPathDialog(
  BuildContext context, {
  required String personId,
  PathData? existing,
}) {
  return showDialog<PathForm>(
    context: context,
    builder: (_) => _PathDialog(personId: personId, existing: existing),
  );
}

class _PathDialog extends ConsumerStatefulWidget {
  final String personId;
  final PathData? existing;

  const _PathDialog({required this.personId, this.existing});

  @override
  ConsumerState<_PathDialog> createState() => _PathDialogState();
}

class _PathDialogState extends ConsumerState<_PathDialog> {
  late final TextEditingController _name;
  late final TextEditingController _desc;
  String? _mediaId;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    _desc = TextEditingController(text: widget.existing?.desc ?? '');
    _mediaId = widget.existing?.mediaId;
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final img = await pickImageBytes();
    if (img == null) return;
    final (ext, bytes) = img;
    final id = await ref.read(personDataProvider(widget.personId).notifier).addMedia(ext, bytes);
    ref.invalidate(mediaListProvider(widget.personId));
    setState(() => _mediaId = id);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? '路径信息' : '编辑路径'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: '名称', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _desc,
              decoration: const InputDecoration(labelText: '说明', border: OutlineInputBorder()),
              maxLines: 2,
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _MediaThumb(personId: widget.personId, mediaId: _mediaId)),
              TextButton.icon(
                onPressed: _pickImage,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Text('附图'),
              ),
              if (_mediaId != null)
                IconButton(
                  onPressed: () => setState(() => _mediaId = null),
                  icon: const Icon(Icons.delete_outline),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('名称不能为空')));
              return;
            }
            Navigator.pop(
              context,
              PathForm(
                name: name,
                desc: _desc.text.trim().isEmpty ? null : _desc.text.trim(),
                mediaId: _mediaId,
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 行程表单。
class TripForm {
  final String name;
  final String? description;
  final DateTime? startDate;
  final DateTime? endDate;
  final String? startEventId;
  final String? endEventId;
  final String? cover;

  const TripForm({
    required this.name,
    this.description,
    this.startDate,
    this.endDate,
    this.startEventId,
    this.endEventId,
    this.cover,
  });

  void applyTo(Trip t) {
    t.name = name;
    t.description = description;
    t.startDate = startDate;
    t.endDate = endDate;
    t.startEventId = startEventId;
    t.endEventId = endEventId;
    t.cover = cover;
  }
}

Future<TripForm?> showTripDialog(
  BuildContext context, {
  required String personId,
  Trip? existing,
}) {
  return showDialog<TripForm>(
    context: context,
    builder: (_) => _TripDialog(personId: personId, existing: existing),
  );
}

class _TripDialog extends ConsumerStatefulWidget {
  final String personId;
  final Trip? existing;

  const _TripDialog({required this.personId, this.existing});

  @override
  ConsumerState<_TripDialog> createState() => _TripDialogState();
}

class _TripDialogState extends ConsumerState<_TripDialog> {
  late final TextEditingController _name;
  late final TextEditingController _desc;
  DateTime? _startDate;
  DateTime? _endDate;
  String? _startEventId;
  String? _endEventId;
  String? _cover;

  @override
  void initState() {
    super.initState();
    final t = widget.existing;
    _name = TextEditingController(text: t?.name ?? '');
    _desc = TextEditingController(text: t?.description ?? '');
    _startDate = t?.startDate;
    _endDate = t?.endDate;
    _startEventId = t?.startEventId;
    _endEventId = t?.endEventId;
    _cover = t?.cover;
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<DateTime?> _pickDate(DateTime? initial) => showDatePicker(
        context: context,
        initialDate: initial ?? DateTime.now(),
        firstDate: DateTime(1900),
        lastDate: DateTime(2100),
      );

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(personDataProvider(widget.personId));
    final events = data.maybeWhen(
      data: (d) => [for (final w in [...d.life.waypoints, for (final t in d.trips) ...t.gpx.waypoints]) if (w.isEvent) w],
      orElse: () => <Waypoint>[],
    );
    Widget eventPicker(String? value, ValueChanged<String?> onChanged, String label) {
      return DropdownButtonFormField<String?>(
        initialValue: value,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        items: [
          const DropdownMenuItem<String?>(value: null, child: Text('（无）')),
          for (final e in events) DropdownMenuItem<String?>(value: e.id, child: Text(e.name, overflow: TextOverflow.ellipsis)),
        ],
        onChanged: onChanged,
      );
    }

    return AlertDialog(
      title: Text(widget.existing == null ? '新建行程' : '编辑行程'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('trip-name'),
              controller: _name,
              decoration: const InputDecoration(labelText: '名称', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _desc,
              decoration: const InputDecoration(labelText: '说明', border: OutlineInputBorder()),
              maxLines: 2,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      final d = await _pickDate(_startDate);
                      setState(() => _startDate = d);
                    },
                    child: Text(_startDate == null ? '开始日期' : fmtDate(_startDate)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      final d = await _pickDate(_endDate);
                      setState(() => _endDate = d);
                    },
                    child: Text(_endDate == null ? '结束日期' : fmtDate(_endDate)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            eventPicker(_startEventId, (v) => setState(() => _startEventId = v), '起点事件'),
            const SizedBox(height: 8),
            eventPicker(_endEventId, (v) => setState(() => _endEventId = v), '终点事件'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _MediaThumb(personId: widget.personId, mediaId: _cover)),
                TextButton(
                  onPressed: () async {
                    final img = await pickImageBytes();
                    if (img == null) return;
                    final (ext, bytes) = img;
                    final id = await ref
                        .read(personDataProvider(widget.personId).notifier)
                        .addMedia(ext, bytes);
                    ref.invalidate(mediaListProvider(widget.personId));
                    setState(() => _cover = id);
                  },
                  child: const Text('选封面图'),
                ),
                if (_cover != null)
                  IconButton(
                    onPressed: () => setState(() => _cover = null),
                    icon: const Icon(Icons.delete_outline),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('名称不能为空')));
              return;
            }
            Navigator.pop(
              context,
              TripForm(
                name: name,
                description: _desc.text.trim().isEmpty ? null : _desc.text.trim(),
                startDate: _startDate,
                endDate: _endDate,
                startEventId: _startEventId,
                endEventId: _endEventId,
                cover: _cover,
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 人表单。
Future<(String, String?)?> showPersonDialog(BuildContext context, {Person? existing}) {
  return showDialog<(String, String?)>(
    context: context,
    builder: (_) => _PersonDialog(existing: existing),
  );
}

class _PersonDialog extends StatefulWidget {
  final Person? existing;

  const _PersonDialog({this.existing});

  @override
  State<_PersonDialog> createState() => _PersonDialogState();
}

class _PersonDialogState extends State<_PersonDialog> {
  late final TextEditingController _name;
  late final TextEditingController _bio;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    _bio = TextEditingController(text: widget.existing?.bio ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? '新建人' : '编辑资料'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('person-name'),
            controller: _name,
            decoration: const InputDecoration(labelText: '姓名', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _bio,
            decoration: const InputDecoration(labelText: '简介（可选）', border: OutlineInputBorder()),
            maxLines: 2,
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('姓名不能为空')));
              return;
            }
            Navigator.pop(context, (name, _bio.text.trim().isEmpty ? null : _bio.text.trim()));
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 通用确认对话框。
Future<bool> confirmDialog(BuildContext context, String title, String message) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('确定')),
      ],
    ),
  );
  return ok ?? false;
}

/// 已废弃引用清理工具：人/行程里不再引用该媒体时物理删除。
Future<void> deleteMediaIfUnused(
  WidgetRef ref,
  String personId,
  String mediaId, {
  required List<Waypoint> waypoints,
  required List<PathData> paths,
  String? coverId,
}) async {
  final used = {for (final w in waypoints) if (w.mediaId != null) w.mediaId!,
    for (final p in paths) if (p.mediaId != null) p.mediaId!};
  if (coverId != null) used.add(coverId);
  if (!used.contains(mediaId)) {
    await ref.read(personDataProvider(personId).notifier).deleteMedia(mediaId);
    ref.invalidate(mediaListProvider(personId));
  }
}
