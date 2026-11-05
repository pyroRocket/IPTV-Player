import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';

import '../models.dart';
import '../sources/net.dart';
import 'epg.dart';
import 'xmltv.dart';

/// Downloads, caches and parses guide data.
class EpgService {
  /// Guides are re-downloaded when older than this (or on Refresh).
  static const maxAge = Duration(hours: 12);

  /// Loads the guide for [channels] from [urls]. Uses the cached copy when it's
  /// fresh, and falls back to a stale copy if a download fails.
  static Future<Epg> load({
    required List<String> urls,
    required List<MediaItem> channels,
    bool refresh = false,
  }) async {
    if (urls.isEmpty) throw SourceException('No guide address is set for this account.');
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/epg');
    await dir.create(recursive: true);

    final now = DateTime.now();
    final filter = EpgFilter(
      ids: {for (final c in channels) ?c.epgId},
      names: {
        for (final c in channels) ...[
          normalizeChannelName(c.name),
          if (c.epgName != null) normalizeChannelName(c.epgName!),
        ],
      }..remove(''),
      from: now.subtract(const Duration(hours: 3)),
      to: now.add(const Duration(days: 3)),
    );

    final merged = <String, List<Programme>>{};
    final names = <String, String>{};
    Object? lastError;
    for (final url in urls) {
      final file = File('${dir.path}/${_hash(url)}.xmltv');
      try {
        final fresh = file.existsSync() && now.difference(file.lastModifiedSync()) < maxAge;
        if (refresh || !fresh) {
          try {
            await downloadToFile(url, file);
          } catch (e) {
            if (!file.existsSync()) rethrow; // keep using the older copy
            lastError = e;
          }
        }
        final path = file.path;
        final epg = await Isolate.run(() => parseXmltvFile(path, filter));
        epg.byChannel.forEach((k, v) => merged.putIfAbsent(k, () => v));
        epg.idByName.forEach((k, v) => names.putIfAbsent(k, () => v));
      } catch (e) {
        lastError = e;
      }
    }
    if (merged.isEmpty) {
      if (lastError != null) throw lastError;
      throw SourceException('The guide didn\'t have any programmes for your channels.');
    }
    return Epg(merged, names);
  }

  /// Stable file name for a URL (FNV-1a).
  static String _hash(String s) {
    var h = 0xcbf29ce484222325;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return h.toRadixString(16);
  }
}
