import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/models.dart';
import 'package:iptv_player/sources/m3u.dart';
import 'package:iptv_player/sources/source.dart';
import 'package:iptv_player/sources/xtream.dart';

void main() {
  group('parseM3u', () {
    const sample = '''#EXTM3U x-tvg-url="http://epg.example/xmltv.php"
#EXTINF:-1 tvg-id="bbc1" tvg-name="BBC One" tvg-logo="http://logo/bbc1.png" group-title="UK | News, Ent",BBC One HD
http://host:8080/user/pass/101
#EXTINF:-1 tvg-logo="" group-title="Sports",Sky Sports, Main Event
http://host:8080/live/user/pass/102.ts
#EXTINF:-1,No Group Channel
#EXTVLCOPT:http-user-agent=Foo
https://cdn.example/stream.m3u8
#EXTINF:-1 group-title="Movies 2024",Some Movie (2024)
http://host:8080/movie/user/pass/555.mkv
#EXTINF:-1 group-title="Drama",Show S01 E01
http://host:8080/series/user/pass/777.mp4
''';

    test('sorts into sections with categories and titles', () {
      final c = parseM3u(sample);
      final live = c[Section.live]!;
      expect(live.items.map((i) => i.name), ['BBC One HD', 'Sky Sports, Main Event', 'No Group Channel']);
      expect(live.categories.map((x) => x.name), ['UK | News, Ent', 'Sports', 'Uncategorized']);
      expect(live.items.first.logo, 'http://logo/bbc1.png');
      expect(live.items[1].logo, isNull);
      expect(live.items[2].sources, ['https://cdn.example/stream.m3u8']);
      expect(live.counts['Sports'], 1);

      expect(c[Section.movies]!.items.single.name, 'Some Movie (2024)');
      expect(c[Section.series]!.items.single.kind, ItemKind.episode);
    });

    test('handles CRLF and missing header', () {
      final c = parseM3u('#EXTINF:-1,A\r\nhttp://a/1\r\n#EXTINF:-1,B\r\nhttp://a/2\r\n');
      expect(c[Section.live]!.items.map((i) => i.name), ['A', 'B']);
      expect(c[Section.live]!.items.first.sources.single, 'http://a/1');
    });
  });

  group('xtream urls', () {
    test('get.php playlist link becomes an Xtream login', () {
      final p = xtreamFromPlaylistUrl(
        'http://prov.tv:8080/get.php?username=bob&password=s3c%26t&type=m3u_plus&output=ts',
      )!;
      expect(p.isXtream, isTrue);
      expect(p.server, 'http://prov.tv:8080');
      expect(p.username, 'bob');
      expect(p.password, 's3c&t');
    });

    test('plain playlist link stays M3U', () {
      expect(xtreamFromPlaylistUrl('https://example.com/list.m3u'), isNull);
    });

    test('normalizes server input', () {
      expect(XtreamSource.normalizeServer('prov.tv:8080/'), 'http://prov.tv:8080');
      expect(XtreamSource.normalizeServer(' https://prov.tv/player_api.php?username=a '), 'https://prov.tv');
    });
  });
}
