import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'geo_search.dart';
import 'models.dart';
import 'storage.dart';

/// 状态管理：数据根 / 人列表 / 单人的全量数据（person + life.gpx + 全部行程）。
/// 写操作统一在此层：先落盘（带备份）再更新内存 state。

final dataRootProvider = FutureProvider<Directory>((ref) => resolveDataRoot());

final peopleProvider = AsyncNotifierProvider<PeopleNotifier, List<Person>>(PeopleNotifier.new);

/// 当前操作人物：无人生成时自动取第一个；删除/无匹配时自动切换到第一个。
final currentPersonIdProvider =
    NotifierProvider<CurrentPersonIdNotifier, String?>(CurrentPersonIdNotifier.new);

class CurrentPersonIdNotifier extends Notifier<String?> {
  @override
  String? build() {
    ref.listen(peopleProvider, (prev, next) {
      final list = next.valueOrNull ?? const <Person>[];
      final cur = state;
      if (cur == null || !list.any((p) => p.id == cur)) {
        state = list.isEmpty ? null : list.first.id;
      }
    });
    return null;
  }

  void select(String? id) => state = id;
}

class PeopleNotifier extends AsyncNotifier<List<Person>> {
  Future<AppRepository> _repo() async {
    final root = await ref.read(dataRootProvider.future);
    return AppRepository(Directory('${root.path}${Platform.pathSeparator}people'));
  }

  @override
  Future<List<Person>> build() async {
    final repo = await _repo();
    return repo.listPeople();
  }

  Future<Person> addPerson(String name, {String? bio}) async {
    final repo = await _repo();
    final person = await repo.createPerson(name, bio: bio);
    state = AsyncData([...state.value ?? [], person]);
    return person;
  }

  Future<void> removePerson(String personId) async {
    final repo = await _repo();
    await repo.deletePerson(personId);
    state = AsyncData([...(state.value ?? []).where((p) => p.id != personId)]);
  }

  Future<void> reload() async {
    final repo = await _repo();
    state = AsyncData(await repo.listPeople());
  }

  Future<void> updatePerson(Person person) async {
    final repo = await _repo();
    await repo.personDir(person.id).exists().then((_) async {
      await PersonRepository(repo.personDir(person.id)).savePerson(person);
    });
    final idx = (state.value ?? []).indexWhere((p) => p.id == person.id);
    if (idx >= 0) {
      final list = [...state.value!];
      list[idx] = person;
      state = AsyncData(list);
    }
  }
}

final personRepoProvider = FutureProvider.family<PersonRepository, String>((ref, personId) async {
  final root = await ref.read(dataRootProvider.future);
  return PersonRepository.of(Directory('${root.path}${Platform.pathSeparator}people'), personId);
});

/// 单人全量数据。
class PersonData {
  final Person person;
  final GpxFile life;
  final List<TripBundle> trips;

  PersonData({required this.person, required this.life, required this.trips});

  TripBundle? tripById(String id) {
    for (final t in trips) {
      if (t.meta.id == id) return t;
    }
    return null;
  }

  /// 事件/地点所在容器。
  (String?, GpxFile) containerOf(Waypoint w) {
    if (life.waypointById(w.id) != null) return (null, life);
    for (final t in trips) {
      if (t.gpx.waypointById(w.id) != null) return (t.meta.id, t.gpx);
    }
    return (null, life);
  }

  PersonData copy() => PersonData(
        person: person,
        life: GpxFile(waypoints: [...life.waypoints], paths: [...life.paths]),
        trips: [
          for (final t in trips)
            TripBundle(
              meta: t.meta,
              gpx: GpxFile(
                waypoints: [...t.gpx.waypoints],
                paths: [...t.gpx.paths],
                orderIds: [...t.gpx.orderIds],
              ),
            ),
        ],
      );
}

final personDataProvider =
    AsyncNotifierProvider.family<PersonDataNotifier, PersonData, String>(PersonDataNotifier.new);

class PersonDataNotifier extends FamilyAsyncNotifier<PersonData, String> {
  @override
  Future<PersonData> build(String personId) async {
    final repo = await ref.watch(personRepoProvider(personId).future);
    final person = await repo.loadPerson();
    final life = await repo.loadLife();
    final bundles = <TripBundle>[];
    for (final meta in await repo.listTrips()) {
      final b = await repo.loadTrip(meta.id);
      if (b != null) bundles.add(b);
    }
    return PersonData(person: person, life: life, trips: bundles);
  }

  Future<PersonRepository> _repo() => ref.read(personRepoProvider(arg).future);

  /// 全量落盘（含备份）并更新 state。修改须先在 next 上完成。
  Future<void> _commit(PersonData next) async {
    final repo = await _repo();
    await repo.savePerson(next.person);
    await repo.saveLife(next.life);
    for (final t in next.trips) {
      await repo.saveTrip(t);
    }
    state = AsyncData(next);
  }

  PersonData get d => state.value!;

  // ---------- 媒体 ----------

  Future<String> addMedia(String ext, List<int> bytes) async {
    final repo = await _repo();
    return repo.media.write(ext, bytes);
  }

  /// 从现有文件导入媒体（测试/导入用）。
  Future<String> addMediaFromPath(File src) async {
    final repo = await _repo();
    return repo.media.import(src);
  }

  Future<void> deleteMedia(String mediaId) async {
    final repo = await _repo();
    await repo.media.delete(mediaId);
  }

  // ---------- 生活（life.gpx）----------

  Future<void> saveLifeWaypoint(Waypoint w) async {
    final next = d.copy();
    final idx = next.life.waypoints.indexWhere((x) => x.id == w.id);
    if (idx >= 0) {
      next.life.waypoints[idx] = w;
    } else {
      next.life.waypoints.add(w);
    }
    await _commit(next);
  }

  Future<void> deleteLifeWaypoint(String id) async {
    final next = d.copy();
    next.life.waypoints.removeWhere((x) => x.id == id);
    await _commit(next);
  }

  // ---------- 行程 ----------

  Future<void> createTrip(Trip meta) async {
    final next = d.copy();
    next.trips.add(TripBundle(meta: meta, gpx: GpxFile()));
    await _commit(next);
  }

  Future<void> saveTripMeta(Trip meta) async {
    final next = d.copy();
    final idx = next.trips.indexWhere((t) => t.meta.id == meta.id);
    if (idx < 0) return;
    next.trips[idx] = TripBundle(meta: meta, gpx: next.trips[idx].gpx);
    await _commit(next);
  }

  Future<void> deleteTrip(String tripId) async {
    final repo = await _repo();
    await repo.deleteTrip(tripId);
    final next = d.copy();
    next.trips.removeWhere((t) => t.meta.id == tripId);
    state = AsyncData(next);
  }

  GpxFile _tripGpx(PersonData next, String tripId) =>
      next.tripById(tripId)!.gpx;

  Future<void> saveTripWaypoint(String tripId, Waypoint w) async {
    final next = d.copy();
    final g = _tripGpx(next, tripId);
    final idx = g.waypoints.indexWhere((x) => x.id == w.id);
    if (idx >= 0) {
      g.waypoints[idx] = w;
    } else {
      g.waypoints.add(w);
    }
    await _commit(next);
  }

  Future<void> deleteTripWaypoint(String tripId, String wptId) async {
    final next = d.copy();
    final g = _tripGpx(next, tripId);
    g.waypoints.removeWhere((x) => x.id == wptId);
    g.orderIds.remove(wptId);
    await _commit(next);
  }

  Future<void> saveTripPath(String tripId, PathData path) async {
    final next = d.copy();
    final g = _tripGpx(next, tripId);
    final idx = g.paths.indexWhere((x) => x.id == path.id);
    if (idx >= 0) {
      g.paths[idx] = path;
    } else {
      g.paths.add(path);
    }
    await _commit(next);
  }

  Future<void> deleteTripPath(String tripId, String pathId) async {
    final next = d.copy();
    final g = _tripGpx(next, tripId);
    g.paths.removeWhere((x) => x.id == pathId);
    g.orderIds.remove(pathId);
    await _commit(next);
  }

  /// 行程内路径/地点按天手动调序：itemId 上移/下移一位（同一天内）。
  /// orderIds 为空或未覆盖全部项时先按时间生成基准顺序，再交换相邻同天项。
  Future<void> reorderTripItem(String tripId, String itemId, bool up) async {
    final next = d.copy();
    final g = _tripGpx(next, tripId);
    final all = <Object>[...g.paths, ...g.waypoints];
    String idOf(Object o) => o is PathData ? o.id : (o as Waypoint).id;
    DateTime sortTime(Object o) =>
        (o is PathData ? o.points.firstOrNull?.time : (o as Waypoint).time) ??
        (o is PathData ? o.createdAt : (o as Waypoint).createdAt);
    String dayKey(Object o) {
      final t = o is PathData ? o.points.firstOrNull?.time : (o as Waypoint).time;
      if (t == null) return '未标日期';
      return '${t.year}-${t.month}-${t.day}';
    }

    var ids = g.orderIds;
    final covered = ids.isNotEmpty &&
        ids.length == all.length &&
        all.every((o) => ids.contains(idOf(o)));
    if (!covered) {
      final sorted = [...all]..sort((a, b) => sortTime(a).compareTo(sortTime(b)));
      ids = [for (final o in sorted) idOf(o)];
    }
    final i = ids.indexOf(itemId);
    if (i < 0) return;
    final keyOf = {for (final o in all) idOf(o): dayKey(o)};
    final k = keyOf[itemId]!;
    void swap(int j) {
      final tmp = ids[i];
      ids[i] = ids[j];
      ids[j] = tmp;
    }

    if (up) {
      for (var j = i - 1; j >= 0; j--) {
        if (keyOf[ids[j]] == k) {
          swap(j);
          break;
        }
      }
    } else {
      for (var j = i + 1; j < ids.length; j++) {
        if (keyOf[ids[j]] == k) {
          swap(j);
          break;
        }
      }
    }
    g.orderIds = ids;
    await _commit(next);
  }

  // ---------- 事件移动 ----------

  /// 事件移入行程：从 life.gpx 移除，加入目标行程 gpx（数据自身不变）。
  Future<void> moveEventToTrip(String eventId, String tripId) async {
    final next = d.copy();
    final w = next.life.waypoints.firstWhere((x) => x.id == eventId);
    next.life.waypoints.remove(w);
    _tripGpx(next, tripId).waypoints.add(w);
    await _commit(next);
  }

  /// 事件移出行程：回到 life.gpx。
  Future<void> moveEventOutOfTrip(String eventId) async {
    final next = d.copy();
    for (final t in next.trips) {
      final idx = t.gpx.waypoints.indexWhere((x) => x.id == eventId);
      if (idx >= 0) {
        final w = t.gpx.waypoints.removeAt(idx);
        t.gpx.orderIds.remove(eventId);
        next.life.waypoints.add(w);
        break;
      }
    }
    await _commit(next);
  }
}

/// 媒体列表（照片墙用），修改媒体后 invalidate。
final mediaListProvider = FutureProvider.family<List<File>, String>((ref, personId) async {
  final repo = await ref.watch(personRepoProvider(personId).future);
  return repo.media.listAll();
});

/// 当前数据实际引用的 mediaId 集合（不含备份引用）。
final referencedMediaIdsProvider = FutureProvider.family<Set<String>, String>((ref, personId) async {
  final repo = await ref.watch(personRepoProvider(personId).future);
  return repo.referencedMediaIds();
});

/// 设置：瓦片源 URL。墙内默认 Carto Voyager，可在设置中切换。
final tileUrlProvider = FutureProvider<String>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString('tileUrl') ??
      'https://basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png';
});

Future<void> setTileUrl(String url) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('tileUrl', url);
}

/// 设置：地址搜索服务（photon / nominatim）。
final geocodeServiceProvider = FutureProvider<String>((ref) => geocodeService());
