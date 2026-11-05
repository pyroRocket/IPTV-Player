import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/epg/epg.dart';
import 'package:iptv_player/epg/xmltv.dart';
import 'package:iptv_player/models.dart';

void main() {
  test('parses XMLTV times with offsets', () {
    expect(parseXmltvTime('20261105183000 +0100'), DateTime.utc(2026, 11, 5, 17, 30).toLocal());
    expect(parseXmltvTime('20261105183000 -0500'), DateTime.utc(2026, 11, 5, 23, 30).toLocal());
    expect(parseXmltvTime('20261105183000'), DateTime.utc(2026, 11, 5, 18, 30).toLocal());
    expect(parseXmltvTime('garbage'), isNull);
  });

  test('normalizes channel names for matching', () {
    expect(normalizeChannelName('UK: BBC One FHD'), 'bbcone');
    expect(normalizeChannelName('BBC One'), 'bbcone');
    expect(normalizeChannelName('Sky Sports Main Event (Backup)'), 'skysportsmainevent');
  });

  group('parseXmltv', () {
    final now = DateTime.now().toUtc();
    String t(DateTime d) => '${d.year}${_pad(d.month)}${_pad(d.day)}${_pad(d.hour)}${_pad(d.minute)}00 +0000';
    final s0 = now.subtract(const Duration(minutes: 30));
    final s1 = now.add(const Duration(minutes: 30));
    final s2 = now.add(const Duration(minutes: 90));
    final xml =
        '''<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="bbc1.uk"><display-name lang="en">BBC One</display-name></channel>
  <channel id="news.int"><display-name>World News 24</display-name></channel>
  <channel id="other"><display-name>Unwatched</display-name></channel>
  <programme start="${t(s0)}" stop="${t(s1)}" channel="bbc1.uk">
    <title lang="en">Morning &amp; More</title><desc>Live <![CDATA[magazine]]> show.</desc>
  </programme>
  <programme start="${t(s1)}" stop="${t(s2)}" channel="bbc1.uk"><title>Film</title></programme>
  <programme start="${t(s0)}" stop="${t(s2)}" channel="news.int"><title>Headlines</title></programme>
  <programme start="${t(s0)}" stop="${t(s2)}" channel="other"><title>Skip me</title></programme>
</tv>''';

    final bbc = MediaItem(kind: ItemKind.live, id: '1', name: 'UK: BBC ONE HD', epgId: 'BBC1.UK');
    final news = MediaItem(kind: ItemKind.live, id: '2', name: 'World News 24 FHD');
    final missing = MediaItem(kind: ItemKind.live, id: '3', name: 'Nope');

    late Epg epg;
    setUpAll(() async {
      epg = await parseXmltv(
        Stream.value(xml),
        EpgFilter(
          ids: {'BBC1.UK'},
          names: {normalizeChannelName(news.name)},
          from: now.subtract(const Duration(hours: 3)),
          to: now.add(const Duration(days: 1)),
        ),
      );
    });

    test('keeps only wanted channels', () {
      expect(epg.byChannel.keys.toSet(), {'bbc1.uk', 'news.int'});
    });

    test('matches by id (case-insensitive) and by name', () {
      expect(epg.nowFor(bbc)!.title, 'Morning & More');
      expect(epg.nowFor(bbc)!.description, 'Live magazine show.');
      expect(epg.nextFor(bbc)!.title, 'Film');
      expect(epg.nowFor(news)!.title, 'Headlines');
      expect(epg.nowFor(missing), isNull);
    });

    test('progress and window queries', () {
      final p = epg.nowFor(bbc)!;
      expect(p.progressAt(DateTime.now()), closeTo(0.5, 0.05));
      expect(epg.between(bbc, DateTime.now(), DateTime.now().add(const Duration(hours: 2))).length, 2);
    });
  });
}

String _pad(int n) => n.toString().padLeft(2, '0');
