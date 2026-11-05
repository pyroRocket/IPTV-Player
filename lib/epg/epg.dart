import '../models.dart';

/// One TV programme from the guide.
class Programme {
  const Programme({
    required this.channel,
    required this.start,
    required this.stop,
    required this.title,
    this.description,
  });

  /// XMLTV channel id.
  final String channel;
  final DateTime start;
  final DateTime stop;
  final String title;
  final String? description;

  bool isOnAt(DateTime t) => !t.isBefore(start) && t.isBefore(stop);

  /// 0..1 through the programme at [t].
  double progressAt(DateTime t) {
    final total = stop.difference(start).inSeconds;
    if (total <= 0) return 0;
    return (t.difference(start).inSeconds / total).clamp(0.0, 1.0);
  }
}

/// Parsed guide data plus the logic for matching playlist channels to it.
class Epg {
  Epg(this.byChannel, this.idByName);

  /// Programmes per XMLTV channel id, sorted by start time.
  final Map<String, List<Programme>> byChannel;

  /// Normalized display name -> XMLTV channel id, for channels with no id match.
  final Map<String, String> idByName;

  final Map<String, String?> _matchCache = {};

  bool get isEmpty => byChannel.isEmpty;

  /// The guide channel for a playlist item: by id first, then by name.
  String? channelFor(MediaItem item) {
    return _matchCache.putIfAbsent(item.key, () {
      final id = item.epgId;
      if (id != null && byChannel.containsKey(id)) return id;
      if (id != null) {
        final lower = id.toLowerCase();
        for (final k in byChannel.keys) {
          if (k.toLowerCase() == lower) return k;
        }
      }
      for (final n in [item.epgName, item.name]) {
        if (n == null) continue;
        final hit = idByName[normalizeChannelName(n)];
        if (hit != null) return hit;
      }
      return null;
    });
  }

  List<Programme> programmesFor(MediaItem item) {
    final c = channelFor(item);
    return c == null ? const [] : (byChannel[c] ?? const []);
  }

  Programme? nowFor(MediaItem item, [DateTime? at]) {
    final t = at ?? DateTime.now();
    for (final p in programmesFor(item)) {
      if (p.isOnAt(t)) return p;
      if (p.start.isAfter(t)) break;
    }
    return null;
  }

  Programme? nextFor(MediaItem item, [DateTime? at]) {
    final t = at ?? DateTime.now();
    for (final p in programmesFor(item)) {
      if (p.start.isAfter(t)) return p;
    }
    return null;
  }

  /// Programmes in [from, to) for a channel.
  List<Programme> between(MediaItem item, DateTime from, DateTime to) => [
    for (final p in programmesFor(item))
      if (p.stop.isAfter(from) && p.start.isBefore(to)) p,
  ];
}

final _prefix = RegExp(r'^[a-z]{2,4}\s*[:|]\s*');
final _quality = RegExp(r'\b(uhd|fhd|hd|sd|hevc|h265|4k|8k|1080p?|720p?|50fps|60fps|backup|raw)\b');
final _nonAlnum = RegExp(r'[^a-z0-9]');

/// "UK: BBC One FHD" and "BBC One" both become "bbcone".
String normalizeChannelName(String name) {
  var s = name.toLowerCase().trim();
  s = s.replaceFirst(_prefix, '');
  s = s.replaceAll(RegExp(r'\[[^\]]*\]|\([^)]*\)'), ' ');
  s = s.replaceAll(_quality, ' ');
  return s.replaceAll(_nonAlnum, '');
}
