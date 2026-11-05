/// Core data types shared by the Xtream and M3U sources.
library;

enum Section { live, movies, series }

extension SectionLabel on Section {
  String get label => switch (this) {
    Section.live => 'Live TV',
    Section.movies => 'Movies',
    Section.series => 'Series',
  };
}

enum ItemKind { live, movie, series, episode }

/// A saved login. Either an Xtream Codes account or an M3U playlist URL.
class Profile {
  Profile.xtream({
    required String this.server,
    required String this.username,
    required String this.password,
    String? name,
    this.epgUrl,
  }) : type = 'xtream',
       url = null,
       name = name ?? _host(server);

  Profile.m3u({required String this.url, String? name, this.epgUrl})
    : type = 'm3u',
      server = null,
      username = null,
      password = null,
      name = name ?? _host(url);

  final String type; // 'xtream' | 'm3u'
  final String name;
  final String? server;
  final String? username;
  final String? password;
  final String? url;

  /// Custom guide (XMLTV) address. When empty, the provider's own guide is used.
  final String? epgUrl;

  bool get isXtream => type == 'xtream';

  /// Stable identity used for saving favorites per account.
  String get id => isXtream ? 'x|$server|$username' : 'm|$url';

  Map<String, dynamic> toJson() => {
    'type': type,
    'name': name,
    if (server != null) 'server': server,
    if (username != null) 'username': username,
    if (password != null) 'password': password,
    if (url != null) 'url': url,
    if (epgUrl != null && epgUrl!.isNotEmpty) 'epgUrl': epgUrl,
  };

  Profile withEpgUrl(String? epg) {
    final e = (epg == null || epg.trim().isEmpty) ? null : epg.trim();
    return isXtream
        ? Profile.xtream(server: server!, username: username!, password: password!, name: name, epgUrl: e)
        : Profile.m3u(url: url!, name: name, epgUrl: e);
  }

  static Profile fromJson(Map<String, dynamic> j) => j['type'] == 'xtream'
      ? Profile.xtream(
          server: j['server'],
          username: j['username'],
          password: j['password'],
          name: j['name'],
          epgUrl: j['epgUrl'],
        )
      : Profile.m3u(url: j['url'], name: j['name'], epgUrl: j['epgUrl']);

  static String _host(String u) {
    try {
      final h = Uri.parse(u).host;
      return h.isEmpty ? u : h;
    } catch (_) {
      return u;
    }
  }
}

class Category {
  const Category(this.id, this.name);
  final String id;
  final String name;
}

/// Anything the user can pick: a channel, movie, series, or episode.
class MediaItem {
  MediaItem({
    required this.kind,
    required this.id,
    required this.name,
    this.logo,
    this.categoryId = '',
    this.sources = const [],
    this.number,
    this.epgId,
    this.epgName,
  }) : searchName = name.toLowerCase();

  final ItemKind kind;
  final String id;
  final String name;
  final String? logo;
  final String categoryId;

  /// Playback URLs to try in order (e.g. .ts first, then .m3u8).
  final List<String> sources;
  final int? number;
  final String searchName;

  /// Guide channel id (XMLTV `tvg-id` / Xtream `epg_channel_id`), if known.
  final String? epgId;

  /// Alternative name for guide matching (`tvg-name`).
  final String? epgName;

  String get key => '${kind.name}:$id';
  bool get playable => kind != ItemKind.series;
}

/// One loaded section (Live TV, Movies, or Series).
class Catalog {
  Catalog(this.categories, this.items) {
    for (final i in items) {
      counts[i.categoryId] = (counts[i.categoryId] ?? 0) + 1;
    }
  }
  final List<Category> categories;
  final List<MediaItem> items;
  final Map<String, int> counts = {};

  static final empty = Catalog(const [], const []);
}

class Season {
  const Season(this.number, this.episodes);
  final String number;
  final List<MediaItem> episodes;
}

/// Shown under the account name, e.g. expiry date and connection limit.
class AccountInfo {
  const AccountInfo({this.expires, this.maxConnections, this.status});
  final DateTime? expires;
  final int? maxConnections;
  final String? status;
}
