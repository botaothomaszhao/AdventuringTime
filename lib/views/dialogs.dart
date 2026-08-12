import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../geo_search.dart';
import '../lifecycle.dart';
import '../models.dart';
import '../providers.dart';
import 'widgets.dart';

/// 编辑对话框集合：地点/长期地点、路径、行程、人。

/// 简单数值列表选择（年份/月份），定位到当前值附近。
Future<int?> pickValueDialog(
  BuildContext context, {
  required int from,
  required int to,
  required String unit,
  int? current,
}) {
  final cur = current ?? (unit == '年' ? DateTime.now().year : 1);
  return showDialog<int>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('选择$unit'),
      content: SizedBox(
        width: 220,
        height: 300,
        child: ListView.builder(
          controller: ScrollController(
            initialScrollOffset: (cur - from) * 40.0,
          ),
          itemCount: to - from + 1,
          itemBuilder: (c, i) => ListTile(
            dense: true,
            title: Text('${from + i} $unit'),
            onTap: () => Navigator.pop(c, from + i),
          ),
        ),
      ),
    ),
  );
}

/// 按精度选择时间：年=年份列表，月=年+月，日=日历。供地点对话框/详情页复用。
Future<DateTime?> pickTimeWithPrecision(
  BuildContext context, {
  required TimePrecision precision,
  DateTime? current,
}) async {
  DateTime? t;
  switch (precision) {
    case TimePrecision.year:
      final y = await pickValueDialog(context, from: 1900, to: 2100, unit: '年');
      if (y != null) t = DateTime(y, 1, 1);
    case TimePrecision.month:
      final y = await pickValueDialog(context, from: 1900, to: 2100, unit: '年');
      if (y == null) return null;
      final m = await pickValueDialog(context, from: 1, to: 12, unit: '月');
      if (m != null) t = DateTime(y, m, 1);
    case TimePrecision.day:
      final now = current ?? DateTime.now();
      t = await showDatePicker(
        context: context,
        initialDate: now,
        firstDate: DateTime(1900),
        lastDate: DateTime(2100),
      );
  }
  return t;
}

/// 地点/长期地点表单结果。
class WaypointForm {
  final String name;
  final String? desc;
  final DateTime? time;
  final TimePrecision? precision;
  final List<String> mediaIds;
  final bool isEvent;
  final String? tripId; // 普通地点的所属行程（长期地点为 null）

  const WaypointForm({
    required this.name,
    this.desc,
    this.time,
    this.precision,
    this.mediaIds = const [],
    this.isEvent = false,
    this.tripId,
  });

  /// 应用到现有 waypoint（写操作前调用，维护 updatedAt）。
  void applyTo(Waypoint w) {
    w.name = name;
    w.desc = desc;
    w.time = time;
    w.timePrecision = precision;
    w.mediaIds = mediaIds;
    w.isEvent = isEvent;
  }
}

Future<WaypointForm?> showWaypointDialog(
  BuildContext context, {
  required String personId,
  Waypoint? existing,
  LatLng? initialPos,
  String? defaultName,
  String? tripId,
  DateTime? presetTime,
  VoidCallback? onDelete,
}) {
  return showDialog<WaypointForm>(
    context: context,
    builder: (_) => _WaypointDialog(
      personId: personId,
      existing: existing,
      initialPos: initialPos,
      defaultName: defaultName,
      tripId: tripId,
      presetTime: presetTime,
      onDelete: onDelete,
    ),
  );
}

class _WaypointDialog extends ConsumerStatefulWidget {
  final String personId;
  final Waypoint? existing;
  final LatLng? initialPos;
  final String? defaultName;
  final String? tripId; // 新建时预选的所属行程；编辑时当前所属行程
  final DateTime? presetTime; // 新建时预填的到达时间
  final VoidCallback? onDelete; // 删除当前地点（编辑时提供）

  const _WaypointDialog({
    required this.personId,
    this.existing,
    this.initialPos,
    this.defaultName,
    this.tripId,
    this.presetTime,
    this.onDelete,
  });

  @override
  ConsumerState<_WaypointDialog> createState() => _WaypointDialogState();
}

class _WaypointDialogState extends ConsumerState<_WaypointDialog> {
  late final TextEditingController _name;
  late final TextEditingController _desc;
  DateTime? _time;
  TimePrecision? _precision;
  List<String> _mediaIds = [];
  late bool _isEvent;
  String? _tripId;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? widget.defaultName ?? '');
    _desc = TextEditingController(text: e?.desc ?? '');
    _time = e?.time ?? widget.presetTime;
    _precision = e?.timePrecision;
    _mediaIds = e == null ? [] : [...e.mediaIds];
    _isEvent = e?.isEvent ?? false;
    _tripId = widget.tripId;
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
    super.dispose();
  }

  /// 按当前精度选择时间：年=年份列表，月=年+月，日=日历。
  Future<void> _pickTime() async {
    final precision = _precision ?? TimePrecision.day;
    final t = await pickTimeWithPrecision(context, precision: precision, current: _time);
    if (t == null) return;
    setState(() {
      _time = t;
      _precision = precision;
    });
  }

  /// 普通地点必选的所属行程下拉（新建长期地点不显示）。
  Widget _tripPicker() {
    final trips = ref
        .watch(personDataProvider(widget.personId))
        .maybeWhen(data: (d) => d.trips, orElse: () => <TripBundle>[]);
    if (trips.isEmpty) {
      return const Align(
        alignment: Alignment.centerLeft,
        child: Text('还没有行程，请先在地图上新建行程', style: TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }
    return DropdownButtonFormField<String>(
      key: const ValueKey('wp-trip'),
      initialValue: _tripId,
      decoration: const InputDecoration(labelText: '所属行程（必选）', border: OutlineInputBorder()),
      items: [
        for (final t in trips)
          DropdownMenuItem(value: t.meta.id, child: Text(t.meta.name, overflow: TextOverflow.ellipsis)),
      ],
      onChanged: (v) => setState(() => _tripId = v),
    );
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('名称不能为空')));
      }
      return;
    }
    if (_time == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请设置到达时间')));
      }
      return;
    }
    if (!_isEvent && _tripId == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请选择所属行程')));
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
        mediaIds: _mediaIds,
        isEvent: _isEvent,
        tripId: _isEvent ? null : _tripId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pos = widget.existing?.latLng ?? widget.initialPos;
    return AlertDialog(
      title: Text(widget.existing == null ? '新增地点' : '编辑'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('坐标：${pos == null ? '—' : formatLatLng(pos)}'),
            const SizedBox(height: 12),
            if (widget.existing == null)
              CheckboxListTile(
                value: _isEvent,
                onChanged: (v) => setState(() => _isEvent = v ?? false),
                title: const Text('作为长期地点'),
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
                    label: Text(_time == null ? '到达时间（必填）' : _fmtTime()),
                  ),
                ),
                const SizedBox(width: 8),
                DropdownButton<TimePrecision>(
                  key: const ValueKey('wp-precision'),
                  value: _precision ?? TimePrecision.day,
                  onChanged: (v) => setState(() => _precision = v),
                  items: const [
                    DropdownMenuItem(value: TimePrecision.year, child: Text('年')),
                    DropdownMenuItem(value: TimePrecision.month, child: Text('月')),
                    DropdownMenuItem(value: TimePrecision.day, child: Text('日')),
                  ],
                ),
              ],
            ),
            if (widget.existing == null && !_isEvent) ...[
              const SizedBox(height: 8),
              _tripPicker(),
            ],
            const SizedBox(height: 8),
            Text(
              '照片',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 8),
            _PhotoList(
              personId: widget.personId,
              mediaIds: _mediaIds,
              initial: widget.existing?.mediaIds ?? const [],
              onChanged: (v) => setState(() => _mediaIds = v),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.onDelete != null)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            onPressed: widget.onDelete,
            child: const Text('删除'),
          ),
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

/// 对话框内照片列表：缩略图左对齐，点击预览大图，右上角删除，末尾添加。
class _PhotoList extends ConsumerStatefulWidget {
  final String personId;
  final List<String> mediaIds;
  final List<String> initial; // 对话框打开时的照片（编辑前），用于区分本次新上传
  final ValueChanged<List<String>> onChanged;

  const _PhotoList({
    required this.personId,
    required this.mediaIds,
    this.initial = const [],
    required this.onChanged,
  });

  @override
  ConsumerState<_PhotoList> createState() => _PhotoListState();
}

class _PhotoListState extends ConsumerState<_PhotoList> {
  Future<void> _add() async {
    final img = await pickImageBytes();
    if (img == null) return;
    final (ext, bytes) = img;
    final id = await ref
        .read(personDataProvider(widget.personId).notifier)
        .addMedia(ext, bytes);
    ref.invalidate(mediaListProvider(widget.personId));
    widget.onChanged([...widget.mediaIds, id]);
  }

  Future<void> _remove(String id) async {
    widget.onChanged([for (final m in widget.mediaIds) if (m != id) m]);
    // 本次会话新上传的照片尚未被任何数据引用，点叉时立即按引用检查删除文件。
    if (!widget.initial.contains(id)) {
      await _deleteMediaChecked(ref, widget.personId, id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final id in widget.mediaIds)
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: GestureDetector(
                  onTap: () => showMediaPreview(context, widget.personId, id),
                  child: _MediaThumb(personId: widget.personId, mediaId: id),
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
                    child: const Icon(Icons.close, size: 14, color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        InkWell(
          onTap: _add,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Icon(Icons.add_a_photo_outlined),
          ),
        ),
      ],
    );
  }
}

/// 路径表单结果。
class PathForm {
  final String name;
  final String? desc;
  final List<String> mediaIds;
  final DateTime? time; // 手绘路径的时间（写入首点，供轨迹线排序）

  const PathForm({required this.name, this.desc, this.mediaIds = const [], this.time});

  void applyTo(PathData p) {
    p.name = name;
    p.desc = desc;
    p.mediaIds = mediaIds;
    // GPS 轨迹时间取自记录开始时间，不可改；仅手绘路径写首点时间
    if (time != null && !p.isGps && p.points.isNotEmpty) {
      p.points[0] = TrackPoint(p.points[0].latLng, time);
    }
  }
}

Future<PathForm?> showPathDialog(
  BuildContext context, {
  required String personId,
  PathData? existing,
  VoidCallback? onDelete,
}) {
  return showDialog<PathForm>(
    context: context,
    builder: (_) => _PathDialog(personId: personId, existing: existing, onDelete: onDelete),
  );
}

class _PathDialog extends ConsumerStatefulWidget {
  final String personId;
  final PathData? existing;
  final VoidCallback? onDelete;

  const _PathDialog({required this.personId, this.existing, this.onDelete});

  @override
  ConsumerState<_PathDialog> createState() => _PathDialogState();
}

class _PathDialogState extends ConsumerState<_PathDialog> {
  late final TextEditingController _name;
  late final TextEditingController _desc;
  List<String> _mediaIds = [];
  DateTime? _time;
  TimePrecision? _precision;
  late final bool _isGps;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    _desc = TextEditingController(text: widget.existing?.desc ?? '');
    _mediaIds = widget.existing == null ? [] : [...widget.existing!.mediaIds];
    _time = widget.existing?.points.firstOrNull?.time;
    _precision = null;
    _isGps = widget.existing?.isGps ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  /// 按当前精度选择时间（与地点对话框一致）。
  Future<void> _pickTime() async {
    final precision = _precision ?? TimePrecision.day;
    final t = await pickTimeWithPrecision(context, precision: precision, current: _time);
    if (t == null) return;
    setState(() => _time = t);
  }

  String _fmtTime() {
    final t = _time!;
    return switch (_precision ?? TimePrecision.day) {
      TimePrecision.year => '${t.year}年',
      TimePrecision.month => '${t.year}年${t.month}月',
      TimePrecision.day => '${t.year}年${t.month}月${t.day}日',
    };
  }

  /// GPS 轨迹速度统计摘要（编辑既有路径时展示）。
  String _speedSummary() {
    final s = pathSpeedStats(widget.existing!.points);
    return '平均 ${formatSpeedKmh(s.avgMps)} · 最高 ${formatSpeedKmh(s.maxMps)}';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? '路径信息' : '编辑路径'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
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
          if (!_isGps) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickTime,
                    icon: const Icon(Icons.event),
                    label: Text(_time == null ? '设置时间（可选）' : _fmtTime()),
                  ),
                ),
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
            ),
          ] else ...[
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              child: Text(
                _time == null ? 'GPS 轨迹' : 'GPS 轨迹 · ${_fmtTime()}',
                style: const TextStyle(fontSize: 14, color: Colors.grey),
              ),
            ),
            Text(
              _speedSummary(),
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 12),
          ],
          const SizedBox(height: 8),
          Text(
            '照片',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
            const SizedBox(height: 8),
            _PhotoList(
              personId: widget.personId,
              mediaIds: _mediaIds,
              initial: widget.existing?.mediaIds ?? const [],
              onChanged: (v) => setState(() => _mediaIds = v),
            ),
        ],
      ),
      actions: [
        if (widget.onDelete != null)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            onPressed: widget.onDelete,
            child: const Text('删除'),
          ),
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
                mediaIds: _mediaIds,
                time: _time,
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
  final List<String> mediaIds;

  const TripForm({
    required this.name,
    this.description,
    this.startDate,
    this.endDate,
    this.startEventId,
    this.endEventId,
    this.mediaIds = const [],
  });

  void applyTo(Trip t) {
    t.name = name;
    t.description = description;
    t.startDate = startDate;
    t.endDate = endDate;
    t.startEventId = startEventId;
    t.endEventId = endEventId;
    t.mediaIds = mediaIds;
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
  List<String> _mediaIds = [];

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
    _mediaIds = t == null ? [] : [...t.mediaIds];
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
          crossAxisAlignment: CrossAxisAlignment.start,
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
            eventPicker(_startEventId, (v) => setState(() => _startEventId = v), '起点长期地点'),
            const SizedBox(height: 8),
            eventPicker(_endEventId, (v) => setState(() => _endEventId = v), '终点长期地点'),
            const SizedBox(height: 8),
            Text(
              '照片',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 8),
            _PhotoList(
              personId: widget.personId,
              mediaIds: _mediaIds,
              initial: widget.existing?.mediaIds ?? const [],
              onChanged: (v) => setState(() => _mediaIds = v),
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
                mediaIds: _mediaIds,
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

/// 废弃引用清理工具：当前数据与全部备份都不再引用该媒体时物理删除。
Future<void> deleteMediaIfUnused(
  WidgetRef ref,
  String personId,
  String mediaId, {
  required List<Waypoint> waypoints,
  required List<PathData> paths,
}) async {
  final used = {
    for (final w in waypoints) ...w.mediaIds,
    for (final p in paths) ...p.mediaIds,
  };
  final d = ref.read(personDataProvider(personId)).valueOrNull;
  if (d != null) {
    for (final t in d.trips) {
      used.addAll(t.meta.mediaIds);
    }
  }
  if (!used.contains(mediaId)) {
    final repo = await ref.read(personRepoProvider(personId).future);
    if (await repo.mediaReferencedInBackups(mediaId)) return;
    await ref.read(personDataProvider(personId).notifier).deleteMedia(mediaId);
    ref.invalidate(mediaListProvider(personId));
  }
}

/// 按当前数据引用集检查后删除单个媒体文件。
Future<void> _deleteMediaChecked(WidgetRef ref, String personId, String mediaId) async {
  final d = ref.read(personDataProvider(personId)).valueOrNull;
  final waypoints = d == null
      ? const <Waypoint>[]
      : [...d.life.waypoints, for (final t in d.trips) ...t.gpx.waypoints];
  final paths =
      d == null ? const <PathData>[] : [for (final t in d.trips) ...t.gpx.paths];
  await deleteMediaIfUnused(ref, personId, mediaId,
      waypoints: waypoints, paths: paths);
}

/// 编辑保存后清理被移出表单的媒体：before 为编辑前的媒体列表，引用检查后物理删除。
Future<void> cleanupRemovedMedia(
  WidgetRef ref,
  String personId,
  List<String> before,
  List<String> after,
) async {
  final removed = [for (final id in before) if (!after.contains(id)) id];
  for (final id in removed) {
    await _deleteMediaChecked(ref, personId, id);
  }
}

/// 轨迹记录停止后的保存对话框：选/新建行程、轨迹名、说明、附图，存为该行程一条 trk。
/// 返回是否保存成功。
Future<bool> showRecordSaveDialog(
  BuildContext context, {
  required String personId,
  required List<TrackPoint> points,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => _RecordSaveDialog(personId: personId, points: points),
  );
  return ok ?? false;
}

class _RecordSaveDialog extends ConsumerStatefulWidget {
  final String personId;
  final List<TrackPoint> points;

  const _RecordSaveDialog({required this.personId, required this.points});

  @override
  ConsumerState<_RecordSaveDialog> createState() => _RecordSaveDialogState();
}

class _RecordSaveDialogState extends ConsumerState<_RecordSaveDialog> {
  String? _tripId;
  late final TextEditingController _name;
  late final TextEditingController _desc;
  (String, List<int>)? _img;

  @override
  void initState() {
    super.initState();
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    _name = TextEditingController(
        text: '轨迹 ${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}');
    _desc = TextEditingController();
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _pickTrip() async {
    final trips = ref.read(personDataProvider(widget.personId)).valueOrNull?.trips ?? [];
    final choice = await showDialog<Object>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('选择行程'),
        children: [
          for (final t in trips)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, t.meta.id),
              child: Text(t.meta.name),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, '__new__'),
            child: const Text('新建行程'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, null),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (choice == '__new__') {
      final form = await showTripDialog(context, personId: widget.personId);
      if (form == null) return;
      final now = DateTime.now();
      final trip = Trip(
        id: newId(),
        name: form.name,
        description: form.description,
        mediaIds: form.mediaIds,
        startDate: form.startDate,
        endDate: form.endDate,
        startEventId: form.startEventId,
        endEventId: form.endEventId,
        createdAt: now,
        updatedAt: now,
      );
      form.applyTo(trip);
      await ref.read(personDataProvider(widget.personId).notifier).createTrip(trip);
      setState(() => _tripId = trip.id);
    } else if (choice is String) {
      setState(() => _tripId = choice);
    }
  }

  Future<void> _save() async {
    if (_tripId == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请选择行程')));
      return;
    }
    final notifier = ref.read(personDataProvider(widget.personId).notifier);
    String? mediaId;
    if (_img != null) {
      mediaId = await notifier.addMedia(_img!.$1, _img!.$2);
    }
    final now = DateTime.now();
    final path = PathData(
      id: newId(),
      name: _name.text.trim().isEmpty ? '轨迹' : _name.text.trim(),
      desc: _desc.text.trim().isEmpty ? null : _desc.text.trim(),
      mediaId: mediaId,
      isGps: true,
      points: widget.points,
      createdAt: now,
      updatedAt: now,
    );
    await notifier.saveTripPath(_tripId!, path);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final tripName = _tripId == null
        ? '选择行程'
        : (ref.read(personDataProvider(widget.personId)).valueOrNull
                ?.tripById(_tripId!)?.meta.name ??
            '选择行程');
    return AlertDialog(
      title: const Text('保存轨迹'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tripName, style: const TextStyle(fontSize: 16)),
              trailing: const Icon(Icons.arrow_drop_down),
              onTap: _pickTrip,
            ),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: '轨迹名称'),
            ),
            TextField(
              controller: _desc,
              decoration: const InputDecoration(labelText: '说明（可选）'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () async {
                    final img = await pickImageBytes();
                    if (img != null) setState(() => _img = img);
                  },
                  icon: const Icon(Icons.photo_outlined, size: 18),
                  label: Text(_img == null ? '附图' : '已选图片'),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}
