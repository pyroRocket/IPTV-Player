import '../epg/epg.dart';
import '../models.dart';
import 'espn.dart';

/// A channel in the user's playlist that is (probably) showing an event.
class ChannelMatch {
  const ChannelMatch(this.channel, {this.programme, this.viaBroadcaster});
  final MediaItem channel;

  /// The guide programme that matched, if found through the guide.
  final Programme? programme;

  /// The ESPN broadcaster name that matched, if found that way.
  final String? viaBroadcaster;
}

final _junk = RegExp(r'\b(fc|afc|cf|sc|the)\b');
final _space = RegExp(r'\s+');

String _norm(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
    .replaceAll(_junk, ' ')
    .replaceAll(_space, ' ')
    .trim();

/// Names a guide might use for a competitor: "Newcastle United", "Newcastle".
List<String> _aliases(Competitor c) =>
    {_norm(c.name), if (c.shortName != null) _norm(c.shortName!)}.where((n) => n.length >= 3).toList();

bool _mentions(String title, Competitor c) => _aliases(c).any((a) => (' $title ').contains(' $a '));

/// Indexes the guide once so matching many events stays fast.
class SportsMatcher {
  SportsMatcher(this.channels, this.epg) {
    for (final ch in channels) {
      final key = normalizeChannelName(ch.name);
      if (key.isNotEmpty) _byName.putIfAbsent(key, () => []).add(ch);
      final progs = epg?.programmesFor(ch) ?? const <Programme>[];
      if (progs.isNotEmpty) _withGuide.add((ch, progs));
    }
  }

  final List<MediaItem> channels;
  final Epg? epg;
  final Map<String, List<MediaItem>> _byName = {};
  final List<(MediaItem, List<Programme>)> _withGuide = [];
  final Map<String, List<ChannelMatch>> _cache = {};

  /// Programmes overlapping [from, to), using binary search on sorted lists.
  static Iterable<Programme> _overlapping(List<Programme> progs, DateTime from, DateTime to) sync* {
    var lo = 0, hi = progs.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (progs[mid].stop.isAfter(from)) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    for (var i = lo; i < progs.length && progs[i].start.isBefore(to); i++) {
      yield progs[i];
    }
  }

  /// Guide matches first (most reliable for the user's own channels),
  /// then channels whose name matches an ESPN broadcaster.
  List<ChannelMatch> channelsFor(SportEvent e, {int limit = 12}) =>
      _cache.putIfAbsent('${e.league.path}/${e.id}', () => _find(e, limit));

  List<ChannelMatch> _find(SportEvent e, int limit) {
    final out = <ChannelMatch>[];
    final seen = <String>{};
    if (_withGuide.isNotEmpty) {
      final from = e.start.subtract(const Duration(minutes: 20));
      final to = e.start.add(const Duration(minutes: 30));
      final name = _norm(e.name);
      for (final (ch, progs) in _withGuide) {
        if (out.length >= limit) break;
        for (final p in _overlapping(progs, from, to)) {
          final title = _norm('${p.title} ${p.description ?? ''}');
          final hit = e.isTeamEvent
              ? e.competitors.every((c) => _mentions(title, c))
              : (name.length >= 6 && title.contains(name)) || _sameRace(e, title);
          if (hit && seen.add(ch.key)) {
            out.add(ChannelMatch(ch, programme: p));
            break;
          }
        }
      }
    }
    for (final b in e.broadcasts) {
      final key = normalizeChannelName(b);
      if (key.length < 3) continue;
      for (final ch in _byName[key] ?? const <MediaItem>[]) {
        if (out.length >= limit) break;
        if (seen.add(ch.key)) out.add(ChannelMatch(ch, viaBroadcaster: b));
      }
    }
    return out;
  }

  /// "Las Vegas Grand Prix" in a "Formula 1: Las Vegas Grand Prix - Race" listing.
  bool _sameRace(SportEvent e, String title) {
    if (e.league.sportKey != 'racing') return false;
    final words = _norm(e.name).split(' ').where((w) => w.length > 3 && w != 'grand' && w != 'prix');
    return title.contains('grand prix') && words.isNotEmpty && words.every(title.contains);
  }
}
