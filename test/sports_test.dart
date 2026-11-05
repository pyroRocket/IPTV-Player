import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/epg/epg.dart';
import 'package:iptv_player/models.dart';
import 'package:iptv_player/sports/espn.dart';
import 'package:iptv_player/sports/leagues.dart';
import 'package:iptv_player/sports/matching.dart';

void main() {
  final league = leagueByPath('soccer/eng.fa')!;
  final events = parseScoreboard(league, File('test/fixtures/espn_scoreboard.json').readAsStringSync());

  test('parses ESPN scoreboard', () {
    expect(events, hasLength(3));
    final live = events[0];
    expect(live.state, EventState.live);
    expect(live.status, "67'");
    expect(live.venue, 'Villa Park');
    expect(live.start, DateTime.utc(2026, 2, 14, 17, 45).toLocal());
    expect(live.competitors.first.name, 'Aston Villa'); // home first
    expect(live.competitors.map((c) => c.score), ['2', '1']);
    expect(live.broadcasts, containsAll(['ESPN+', 'BBC One']));
    expect(live.isTeamEvent, isTrue);

    final upcoming = events[1];
    expect(upcoming.state, EventState.upcoming);
    expect(upcoming.competitors.first.name, 'Arsenal'); // sorted home first

    final done = events[2];
    expect(done.state, EventState.finished);
    expect(done.competitors.first.score, '3'); // score object form
    expect(done.competitors.first.winner, isTrue);
  });

  test('follows teams across competitions by sport and id', () {
    expect(events[1].involves({'soccer:359'}), isTrue);
    expect(events[1].involves({'football:359'}), isFalse);
  });

  test('finds matches on the user\'s channels via guide and broadcaster', () {
    final live = events[0];
    final sky = MediaItem(kind: ItemKind.live, id: '1', name: 'UK: Sky Sports Football HD', epgId: 'ssf');
    final other = MediaItem(kind: ItemKind.live, id: '2', name: 'Some Channel', epgId: 'other');
    final bbc = MediaItem(kind: ItemKind.live, id: '3', name: 'BBC ONE FHD');
    final epg = Epg({
      'ssf': [
        Programme(
          channel: 'ssf',
          start: live.start.subtract(const Duration(minutes: 15)),
          stop: live.start.add(const Duration(hours: 2)),
          title: 'Live FA Cup: Aston Villa v Newcastle',
        ),
      ],
      'other': [
        Programme(
          channel: 'other',
          start: live.start.subtract(const Duration(minutes: 15)),
          stop: live.start.add(const Duration(hours: 2)),
          title: 'Aston Villa: A History',
        ),
      ],
    }, {});
    final m = SportsMatcher([sky, other, bbc], epg).channelsFor(live);
    expect(m.map((x) => x.channel.name), ['UK: Sky Sports Football HD', 'BBC ONE FHD']);
    expect(m.first.programme, isNotNull);
    expect(m.last.viaBroadcaster, 'BBC One');
  });
}
