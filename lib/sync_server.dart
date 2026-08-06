import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'storage.dart';
import 'sync.dart';
import 'version.dart';

/// Windows 端内置同步服务器（§7.3）：只做文件读写，不做合并决策。
/// 默认端口 8024，绑定任意网卡。
class SyncServer {
  final int port;
  HttpServer? _server;

  SyncServer(this.port);

  bool get running => _server != null;

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server!.listen(_handle);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<AppRepository> _repo() async {
    final root = await resolveDataRoot();
    return AppRepository(Directory('${root.path}${Platform.pathSeparator}people'));
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final segs = req.uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segs.isEmpty || segs.first != 'api') {
        return _json(res, 404, {'error': 'not found'});
      }
      if (segs.length == 2 && segs[1] == 'ping' && req.method == 'GET') {
        return _json(res, 200, {
          'name': 'AdventuringTime',
          'version': appVersion,
          'port': port,
        });
      }
      if (segs.length == 2 && segs[1] == 'people' && req.method == 'GET') {
        final app = await _repo();
        final people = await app.listPeople();
        return _json(res, 200, [
          for (final p in people)
            {'id': p.id, 'name': p.name, 'updatedAt': p.updatedAt.toUtc().toIso8601String()},
        ]);
      }
      if (segs.length == 4 && segs[1] == 'person' && segs[3] == 'manifest' && req.method == 'GET') {
        final repo = PersonRepository((await _repo()).personDir(segs[2]));
        if (!await repo.root.exists()) return _json(res, 200, {'units': []});
        final units = await buildManifest(repo);
        return _json(res, 200, {'units': [for (final u in units) u.toJson()]});
      }
      if (segs.length == 4 && segs[1] == 'person' && segs[3] == 'unit') {
        final params = req.uri.queryParameters;
        final type = params['type'];
        final unitId = params['unitId'];
        if (type == null || unitId == null) return _json(res, 400, {'error': 'missing type/unitId'});
        final repo = PersonRepository((await _repo()).personDir(segs[2]));
        if (req.method == 'GET') {
          final units = await buildManifest(repo);
          final u = units
              .where((x) => x.type == type && x.unitId == unitId && !x.deleted)
              .firstOrNull;
          if (u == null) return _json(res, 404, {'error': 'unit not found'});
          final bytes = await packUnit(repo, u);
          res.headers.set('content-type', 'application/octet-stream');
          res.headers.set('x-sha256', u.sha256.isNotEmpty ? u.sha256 : sha256.convert(bytes).toString());
          res.add(bytes);
          return await res.close();
        }
        if (req.method == 'POST') {
          await repo.root.create(recursive: true);
          final bytes = await _readBody(req);
          final deleted = params['deleted'] == '1';
          final unit = SyncUnit(
            type: type,
            unitId: unitId,
            updatedAt: params['updatedAt'] == null
                ? DateTime.now()
                : DateTime.fromMillisecondsSinceEpoch(int.tryParse(params['updatedAt']!) ?? 0),
            sha256: sha256.convert(bytes).toString(),
            size: bytes.length,
            deleted: deleted,
          );
          final expected = params['sha256'];
          if (!deleted && bytes.isEmpty) {
            return _json(res, 400, {'error': 'empty body'});
          }
          if (!deleted && expected != null && expected != unit.sha256) {
            return _json(res, 400, {'error': 'sha256 mismatch'});
          }
          if (deleted) {
            await deleteUnit(repo, unit);
            await repo.recordTombstone(type, unitId);
          } else {
            await writeUnit(repo, unit, bytes);
          }
          return _json(res, 200, {'ok': true});
        }
        return _json(res, 405, {'error': 'method not allowed'});
      }
      return _json(res, 404, {'error': 'not found'});
    } catch (e) {
      return _json(res, 500, {'error': '$e'});
    } finally {
      await res.close();
    }
  }
}

void _json(HttpResponse res, int status, Object obj) {
  res.statusCode = status;
  res.headers.set('content-type', 'application/json; charset=utf-8');
  res.write(jsonEncode(obj));
}

Future<List<int>> _readBody(HttpRequest req) async {
  final b = BytesBuilder();
  await for (final chunk in req) {
    b.add(chunk);
  }
  return b.takeBytes();
}
