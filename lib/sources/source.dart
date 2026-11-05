import '../models.dart';
import 'm3u.dart';
import 'net.dart';
import 'xtream.dart';

/// A connected provider that can list content.
abstract class IptvSource {
  Profile get profile;
  AccountInfo? get account => null;

  /// Sections that have content (an M3U may only have live channels).
  List<Section> get sections;
  Future<Catalog> load(Section section);

  /// The provider's own TV guide (XMLTV) addresses, if any.
  List<String> get epgUrls => const [];

  /// Episodes for a series (Xtream only).
  Future<List<Season>> seasons(MediaItem series) async => const [];
}

/// Connects using a profile. A pasted `get.php?username=..&password=..`
/// playlist link is upgraded to an Xtream login when the provider supports
/// it, because that gives proper Movies/Series sections and loads faster.
Future<IptvSource> connect(Profile p) async {
  if (p.isXtream) return XtreamSource.connect(p);

  final asXtream = xtreamFromPlaylistUrl(p.url!);
  if (asXtream != null) {
    try {
      return await XtreamSource.connect(asXtream, originalProfile: p);
    } on SourceException {
      // Fall through: plain M3U still works on providers with the API disabled.
    }
  }
  return M3uSource.connect(p);
}

Profile? xtreamFromPlaylistUrl(String url) {
  final Uri u;
  try {
    u = Uri.parse(url.trim());
  } catch (_) {
    return null;
  }
  final user = u.queryParameters['username'];
  final pass = u.queryParameters['password'];
  final file = u.pathSegments.isEmpty ? '' : u.pathSegments.last.toLowerCase();
  if (user == null || pass == null || (file != 'get.php' && file != 'player_api.php')) {
    return null;
  }
  final dir = u.path.substring(0, u.path.lastIndexOf('/'));
  return Profile.xtream(server: '${u.origin}$dir', username: user, password: pass);
}
