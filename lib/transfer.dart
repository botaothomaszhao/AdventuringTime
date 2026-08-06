import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'storage.dart';
import 'sync.dart';

/// 人物整包导入导出（§8.2）：.atrip zip {profile.json, life.gpx, trips/<id>/…, media/…}。
/// 导入时 personId 已存在 → 覆盖（旧目录进回收站 trash/）/合并（复用同步合并逻辑）。

/// 导出当前人物整包为 .atrip 字节。
Future<List<int>> exportPersonPack(PersonRepository repo) async {
  final arch = Archive();
  Future<void> addFile(String disk, String name) async {
    final f = File(p.join(repo.root.path, disk));
    if (await f.exists()) {
      arch.addFile(ArchiveFile(name, 0, await f.readAsBytes())..lastModTime = 0);
    }
  }

  Future<void> addDir(Directory dir, String prefix) async {
    if (!await dir.exists()) return;
    await for (final e in dir.list()) {
      if (e is File) {
        arch.addFile(
            ArchiveFile('$prefix${p.basename(e.path)}', 0, await e.readAsBytes())..lastModTime = 0);
      } else if (e is Directory) {
        await addDir(e, '$prefix${p.basename(e.path)}/');
      }
    }
  }

  await addFile('profile.json', 'profile.json');
  await addFile('life.gpx', 'life.gpx');
  await addDir(repo.tripsDir, 'trips/');
  await addDir(repo.media.dir, 'media/');
  return Uint8List.fromList(ZipEncoder().encode(arch));
}

/// 读取 .atrip 包内人物 id（用于判断导入时是否已存在）。
Future<String?> packPersonId(List<int> bytes) async {
  final arch = ZipDecoder().decodeBytes(bytes);
  final f = arch.files.where((f) => f.name == 'profile.json').firstOrNull;
  if (f == null) return null;
  final j = jsonDecode(utf8.decode(f.content as List<int>)) as Map<String, dynamic>;
  return j['id'] as String?;
}

/// 导入 .atrip 到 people 根，返回 personId。
/// mode：'overwrite' 覆盖（旧目录进回收站）/ 'merge' 合并（同步合并逻辑）/ 其余=直接新建。
Future<String> importPersonPack(AppRepository appRepo, List<int> bytes, {String? mode}) async {
  await appRepo.peopleRoot.create(recursive: true);
  final tmp = await Directory.systemTemp.createTemp('atrip_import');
  try {
    await _extractZip(bytes, tmp);
    final profile = File(p.join(tmp.path, 'profile.json'));
    if (!await profile.exists()) throw const FormatException('无效的 .atrip 包：缺少 profile.json');
    final personId = jsonDecode(await profile.readAsString())['id'] as String;
    final target = appRepo.personDir(personId);
    if (await target.exists()) {
      if (mode == 'overwrite') {
        await appRepo.trashPerson(personId);
        await tmp.rename(target.path);
      } else if (mode == 'merge') {
        await mergePerson(PersonRepository(target), DirSyncRemote(PersonRepository(tmp)), personId);
      } else {
        throw StateError('人物已存在，需选择覆盖或合并');
      }
    } else {
      await tmp.rename(target.path);
    }
    return personId;
  } finally {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  }
}

Future<void> _extractZip(List<int> bytes, Directory dest) async {
  final arch = ZipDecoder().decodeBytes(bytes);
  for (final f in arch.files) {
    if (!f.isFile) continue;
    final out = File(p.join(dest.path, f.name));
    await out.parent.create(recursive: true);
    await out.writeAsBytes(f.content as List<int>, flush: true);
  }
}

/// 安卓：经 MediaStore 写入公共下载目录，返回可显示的相对路径。
Future<String> saveToDownloads(String filename, List<int> bytes) async {
  final ch = const MethodChannel('adventuring_time/files');
  final res = await ch.invokeMethod('saveToDownloads', {
    'filename': filename,
    'data': bytes,
  });
  return (res as String?) ?? filename;
}
