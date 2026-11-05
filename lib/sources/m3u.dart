import 'dart:isolate';

import '../models.dart';
import 'net.dart';
import 'source.dart';

/// A plain M3U / M3U Plus playlist.
class M3uSource extends IptvSource {
  M3uSource._(this.profile, this._catalogs);

  @override
  final Profile profile;
  final Map<Section, Catalog> _catalogs;

  static Future<M3uSource> connect(Profile p) async {
    final text = await fetchText(p.url!.trim(), timeout: const Duration(seconds: 120));
    final catalogs = await Isolate.run(() => parseM3u(text));
    if (catalogs.values.every((c) => c.items.isEmpty)) {
      throw SourceException('No channels found in that playlist.');
    }
    return M3uSource._(p, catalogs);
  }

  @override
  List<Section> get sections => Section.values.where((s) => _catalogs[s]!.items.isNotEmpty).toList();

  @override
  Future<Catalog> load(Section section) async => _catalogs[section]!;
}

final _attr = RegExp(r'([\w-]+)="([^"]*)"');
final _vodExt = RegExp(r'\.(mp4|mkv|avi|mov|m4v|wmv|webm|flv)(\?|$)', caseSensitive: false);

/// Parses M3U text into Live / Movies / Series catalogs using `group-title`
/// for categories. Xtream-style URLs (/movie/, /series/) are sorted into
/// the matching section; series entries are individual playable episodes.
Map<Section, Catalog> parseM3u(String text) {
  final groups = {for (final s in Section.values) s: <String, Category>{}};
  final items = {for (final s in Section.values) s: <MediaItem>[]};
  String? name, logo, group;
  var n = 0;

  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (line.startsWith('#EXTINF')) {
      final attrs = {for (final m in _attr.allMatches(line)) m.group(1)!.toLowerCase(): m.group(2)!};
      name = _titleOf(line) ?? attrs['tvg-name'];
      logo = attrs['tvg-logo'];
      group = attrs['group-title'];
    } else if (line.startsWith('#EXTGRP:')) {
      group ??= line.substring(8).trim();
    } else if (!line.startsWith('#')) {
      final url = line;
      final lower = url.toLowerCase();
      final section = lower.contains('/series/')
          ? Section.series
          : (lower.contains('/movie/') || _vodExt.hasMatch(lower))
          ? Section.movies
          : Section.live;
      final g = (group == null || group.isEmpty) ? 'Uncategorized' : group;
      groups[section]!.putIfAbsent(g, () => Category(g, g));
      n++;
      items[section]!.add(
        MediaItem(
          kind: switch (section) {
            Section.live => ItemKind.live,
            Section.movies => ItemKind.movie,
            Section.series => ItemKind.episode,
          },
          id: url,
          name: (name == null || name.isEmpty) ? 'Channel $n' : name,
          logo: (logo == null || logo.isEmpty) ? null : logo,
          categoryId: g,
          sources: [url],
        ),
      );
      name = logo = group = null;
    }
  }
  return {for (final s in Section.values) s: Catalog(groups[s]!.values.toList(), items[s]!)};
}

/// The title is everything after the first comma that isn't inside quotes.
String? _titleOf(String line) {
  var inQuotes = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == '"') inQuotes = !inQuotes;
    if (c == ',' && !inQuotes) return line.substring(i + 1).trim();
  }
  return null;
}
