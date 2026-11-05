import 'dart:convert';
import 'dart:isolate';

import '../models.dart';
import 'net.dart';
import 'source.dart';

/// Xtream Codes API client (`player_api.php`).
class XtreamSource extends IptvSource {
  XtreamSource._(this.profile, this.account, this._liveFormats);

  @override
  final Profile profile;
  @override
  final AccountInfo account;
  final List<String> _liveFormats;
  final Map<Section, Catalog> _cache = {};

  String get _base => profile.server!;
  String get _u => Uri.encodeComponent(profile.username!);
  String get _p => Uri.encodeComponent(profile.password!);

  static String normalizeServer(String input) {
    var s = input.trim();
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(s)) s = 'http://$s';
    s = s.replaceFirst(RegExp(r'/(player_api|get|xmltv|panel_api)\.php.*$', caseSensitive: false), '');
    return s.replaceFirst(RegExp(r'/+$'), '');
  }

  /// [originalProfile] keeps the user's M3U profile as the saved identity
  /// when we upgraded a get.php link to the API.
  static Future<XtreamSource> connect(Profile p, {Profile? originalProfile}) async {
    final profile = Profile.xtream(
      server: normalizeServer(p.server!),
      username: p.username!.trim(),
      password: p.password!,
      name: originalProfile?.name ?? p.name,
    );
    final probe = XtreamSource._(profile, const AccountInfo(), const []);
    final dynamic info;
    try {
      info = await probe._api('');
    } on FormatException {
      throw SourceException('This server doesn\'t look like an Xtream Codes provider.');
    }
    if (info is! Map || info['user_info'] is! Map) {
      throw SourceException('This server doesn\'t look like an Xtream Codes provider.');
    }
    final ui = info['user_info'] as Map;
    if ('${ui['auth']}' != '1') {
      throw SourceException('Login failed. Check your username and password.');
    }
    final status = ui['status']?.toString();
    if (status != null && status.isNotEmpty && status.toLowerCase() != 'active') {
      throw SourceException('Your account status is "$status".');
    }
    final exp = int.tryParse('${ui['exp_date']}');
    final formats = (ui['allowed_output_formats'] is List)
        ? (ui['allowed_output_formats'] as List).map((e) => '$e').toList()
        : <String>[];
    // mpv handles raw MPEG-TS best (lower latency); HLS is the fallback.
    var order = ['ts', 'm3u8'].where((f) => formats.isEmpty || formats.contains(f)).toList();
    if (order.isEmpty) order = ['ts', 'm3u8'];
    return XtreamSource._(
      profile,
      AccountInfo(
        expires: exp == null || exp == 0 ? null : DateTime.fromMillisecondsSinceEpoch(exp * 1000),
        maxConnections: int.tryParse('${ui['max_connections']}'),
        status: status,
      ),
      order,
    );
  }

  Future<dynamic> _api(String query) async {
    final url = '$_base/player_api.php?username=$_u&password=$_p${query.isEmpty ? '' : '&$query'}';
    final text = await fetchText(url, timeout: const Duration(seconds: 90));
    // Big catalogs can be tens of MB; parse off the UI thread.
    return Isolate.run(() => jsonDecode(text));
  }

  @override
  List<Section> get sections => Section.values;

  @override
  List<String> get epgUrls => ['$_base/xmltv.php?username=$_u&password=$_p'];

  @override
  Future<Catalog> load(Section section) async {
    final cached = _cache[section];
    if (cached != null) return cached;
    final (catAction, listAction) = switch (section) {
      Section.live => ('get_live_categories', 'get_live_streams'),
      Section.movies => ('get_vod_categories', 'get_vod_streams'),
      Section.series => ('get_series_categories', 'get_series'),
    };
    final results = await Future.wait([_api('action=$catAction'), _api('action=$listAction')]);
    final cats = <Category>[
      for (final c in _asList(results[0]))
        if (c is Map) Category('${c['category_id']}', '${c['category_name'] ?? 'Unnamed'}'),
    ];
    final items = <MediaItem>[];
    for (final s in _asList(results[1])) {
      if (s is Map) {
        final item = _item(section, s);
        if (item != null) items.add(item);
      }
    }
    return _cache[section] = Catalog(cats, items);
  }

  MediaItem? _item(Section section, Map s) {
    final name = '${s['name'] ?? ''}'.trim();
    final cat = '${s['category_id'] ?? ''}';
    switch (section) {
      case Section.live:
        final id = '${s['stream_id'] ?? ''}';
        if (id.isEmpty) return null;
        return MediaItem(
          kind: ItemKind.live,
          id: id,
          name: name,
          logo: _str(s['stream_icon']),
          categoryId: cat,
          number: int.tryParse('${s['num']}'),
          epgId: _str(s['epg_channel_id']),
          sources: [for (final f in _liveFormats) '$_base/live/$_u/$_p/$id.$f'],
        );
      case Section.movies:
        final id = '${s['stream_id'] ?? ''}';
        if (id.isEmpty) return null;
        final ext = _str(s['container_extension']) ?? 'mp4';
        return MediaItem(
          kind: ItemKind.movie,
          id: id,
          name: name,
          logo: _str(s['stream_icon']),
          categoryId: cat,
          sources: ['$_base/movie/$_u/$_p/$id.$ext'],
        );
      case Section.series:
        final id = '${s['series_id'] ?? ''}';
        if (id.isEmpty) return null;
        return MediaItem(kind: ItemKind.series, id: id, name: name, logo: _str(s['cover']), categoryId: cat);
    }
  }

  @override
  Future<List<Season>> seasons(MediaItem series) async {
    final info = await _api('action=get_series_info&series_id=${Uri.encodeComponent(series.id)}');
    if (info is! Map) return const [];
    final raw = info['episodes'];
    final entries = <MapEntry<String, dynamic>>[];
    if (raw is Map) {
      raw.forEach((k, v) => entries.add(MapEntry('$k', v)));
    } else if (raw is List) {
      for (var i = 0; i < raw.length; i++) {
        final eps = raw[i];
        final first = eps is List && eps.isNotEmpty && eps.first is Map ? eps.first as Map : null;
        entries.add(MapEntry('${first?['season'] ?? i + 1}', eps));
      }
    }
    entries.sort((a, b) => (int.tryParse(a.key) ?? 0).compareTo(int.tryParse(b.key) ?? 0));
    return [
      for (final e in entries)
        Season(e.key, [
          for (final ep in _asList(e.value))
            if (ep is Map && ep['id'] != null) _episode(ep, series),
        ]),
    ];
  }

  MediaItem _episode(Map ep, MediaItem series) {
    final id = '${ep['id']}';
    final ext = _str(ep['container_extension']) ?? 'mp4';
    final info = ep['info'] is Map ? ep['info'] as Map : const {};
    final n = ep['episode_num'];
    final title = _str(ep['title']) ?? 'Episode $n';
    return MediaItem(
      kind: ItemKind.episode,
      id: id,
      name: n == null || title.contains('E$n') ? title : 'E$n · $title',
      logo: _str(info['movie_image']) ?? series.logo,
      sources: ['$_base/series/$_u/$_p/$id.$ext'],
    );
  }

  static List _asList(dynamic v) => v is List ? v : (v is Map ? v.values.toList() : const []);
  static String? _str(dynamic v) {
    final s = v?.toString().trim();
    return s == null || s.isEmpty || s == 'null' ? null : s;
  }
}
