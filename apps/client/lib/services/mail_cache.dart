import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Request paths whose latest data came from the cache because the server was
/// unreachable, with the cache time. A live response for a path removes it, so
/// each screen derives its offline state from the resources it shows.
final cachedPathsProvider =
    StateProvider<Map<String, DateTime>>((ref) => const {});

/// Records one cacheable read in [cachedPathsProvider].
void recordCacheState(
  StateController<Map<String, DateTime>> controller,
  String path,
  DateTime? cachedAt,
) {
  final next = {...controller.state};
  if (cachedAt == null) {
    next.remove(path);
  } else {
    next[path] = cachedAt;
  }
  controller.state = next;
}

/// Oldest cache time among [paths], or null when all of them are live.
DateTime? offlineSinceFor(Map<String, DateTime> cached, Iterable<String> paths) {
  DateTime? oldest;
  for (final path in paths) {
    final savedAt = cached[path];
    if (savedAt != null && (oldest == null || savedAt.isBefore(oldest))) {
      oldest = savedAt;
    }
  }
  return oldest;
}

class CachedPayload {
  const CachedPayload({required this.data, required this.savedAt});

  final Object? data;
  final DateTime savedAt;
}

/// JSON-file cache of server responses keyed by request path.
/// Account-scoped paths (`/accounts/{id}/...`) live in one folder per account
/// so deleting an account removes its mail from the device. The provider list
/// holds no account data and lives apart so it survives account deletion.
class MailCache {
  MailCache(this._root);

  final Future<Directory> Function() _root;

  static const _sharedFolder = 'shared';
  static const _providersFolder = 'providers';
  static final _accountPath = RegExp(r'^/accounts/([^/]+)/');
  // Distinct temp names keep concurrent writes of one path from mixing.
  static var _tempSeq = 0;

  // Bumped by clearAccount; a read started before a clear must not write back.
  var _epoch = 0;
  final _clearedAt = <String, int>{};

  /// Pass to [write] as `startedAt` for a response requested at this moment.
  int get epoch => _epoch;

  bool _clearedSince(String folder, int? startedAt) =>
      startedAt != null && (_clearedAt[folder] ?? -1) >= startedAt;

  static String _folderFor(String path) {
    if (path == '/providers') return _providersFolder;
    final match = _accountPath.firstMatch(path);
    return match == null ? _sharedFolder : 'a_${match.group(1)}';
  }

  // FNV-1a 64-bit; the stored path is re-checked on read, so a collision is a miss.
  static String _fileName(String path) {
    var hash = 0xcbf29ce484222325;
    for (final unit in utf8.encode(path)) {
      hash = (hash ^ unit) * 0x100000001b3;
    }
    return '${hash.toUnsigned(64).toRadixString(16)}.json';
  }

  Future<File> _file(String path) async {
    final root = await _root();
    return File('${root.path}/${_folderFor(path)}/${_fileName(path)}');
  }

  Future<void> write(String path, Object? data, {int? startedAt}) async {
    final folder = _folderFor(path);
    if (_clearedSince(folder, startedAt)) return;
    try {
      final file = await _file(path);
      await file.parent.create(recursive: true);
      // Write beside the target, then rename over it, so a failed or
      // interrupted write leaves the last complete copy in place.
      final temp = File('${file.path}.${_tempSeq++}.tmp');
      try {
        await temp.writeAsString(
          jsonEncode({
            'path': path,
            'savedAt': DateTime.now().toUtc().toIso8601String(),
            'data': data,
          }),
          flush: true,
        );
        if (_clearedSince(folder, startedAt)) {
          await temp.delete();
          return;
        }
        await temp.rename(file.path);
      } catch (_) {
        if (await temp.exists()) await temp.delete();
        rethrow;
      }
    } catch (_) {
      // A cache write failure must never break a live response.
    }
  }

  Future<CachedPayload?> read(String path) async {
    try {
      final file = await _file(path);
      if (!await file.exists()) return null;
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (json['path'] != path) return null;
      final savedAt = DateTime.tryParse(json['savedAt'] as String? ?? '');
      if (savedAt == null) return null;
      return CachedPayload(data: json['data'], savedAt: savedAt.toLocal());
    } catch (_) {
      return null;
    }
  }

  /// Removes everything cached for [accountId]. The shared folder also goes
  /// because the merged inbox and account list may contain that account.
  Future<void> clearAccount(String accountId) async {
    final epoch = _epoch++;
    for (final folder in ['a_$accountId', _sharedFolder]) {
      _clearedAt[folder] = epoch;
    }
    try {
      final root = await _root();
      for (final folder in ['a_$accountId', _sharedFolder]) {
        final dir = Directory('${root.path}/$folder');
        if (await dir.exists()) await dir.delete(recursive: true);
      }
    } catch (_) {}
  }
}
