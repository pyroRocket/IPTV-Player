import 'dart:convert';
import 'dart:isolate';

import '../sources/net.dart';

/// ESPN's public site API (no key). Overridable for testing with
/// `--dart-define=ESPN_BASE=http://localhost:9099`.
const espnBase = String.fromEnvironment('ESPN_BASE', defaultValue: 'https://site.api.espn.com');

class League {
  const League(this.sport, this.path, this.name);

  /// Sport group shown in the picker, e.g. "Soccer".
  final String sport;

  /// ESPN path, e.g. "soccer/eng.1".
  final String path;
  final String name;

  /// Team ids are shared across a sport's competitions on ESPN
  /// (Arsenal is the same id in the Premier League and the FA Cup).
  String get sportKey => path.split('/').first;
}

class Team {
  const Team({required this.id, required this.sportKey, required this.name, this.shortName, this.logo});
  final String id;
  final String sportKey;
  final String name;
  final String? shortName;
  final String? logo;

  String get key => '$sportKey:$id';

  Map<String, dynamic> toJson() => {
    'id': id,
    'sport': sportKey,
    'name': name,
    if (shortName != null) 'short': shortName,
    if (logo != null) 'logo': logo,
  };

  static Team fromJson(Map<String, dynamic> j) =>
      Team(id: j['id'], sportKey: j['sport'], name: j['name'], shortName: j['short'], logo: j['logo']);
}

class Competitor {
  const Competitor({
    required this.name,
    this.shortName,
    this.abbreviation,
    this.logo,
    this.score,
    this.teamId,
    this.home = false,
    this.winner = false,
  });
  final String name;
  final String? shortName;
  final String? abbreviation;
  final String? logo;
  final String? score;
  final String? teamId;
  final bool home;
  final bool winner;
}

enum EventState { upcoming, live, finished }

class SportEvent {
  const SportEvent({
    required this.id,
    required this.league,
    required this.name,
    required this.start,
    required this.state,
    required this.status,
    required this.competitors,
    this.venue,
    this.broadcasts = const [],
  });

  final String id;
  final League league;
  final String name;
  final DateTime start;
  final EventState state;

  /// ESPN's short status, e.g. "67'", "Q3 5:21", "FT", "Final".
  final String status;

  /// Home first when there are two teams.
  final List<Competitor> competitors;
  final String? venue;

  /// TV / streaming broadcasters ESPN lists for the event.
  final List<String> broadcasts;

  bool get isTeamEvent => competitors.length == 2 && competitors.every((c) => c.teamId != null);
  bool involves(Set<String> teamKeys) =>
      competitors.any((c) => c.teamId != null && teamKeys.contains('${league.sportKey}:${c.teamId}'));
}

String _ym(DateTime d) => '${d.year}${d.month.toString().padLeft(2, '0')}';

/// Months (YYYYMM) touched by [from]..[to].
List<String> monthsBetween(DateTime from, DateTime to) {
  final out = <String>[];
  for (var m = DateTime(from.year, from.month); !m.isAfter(to); m = DateTime(m.year, m.month + 1)) {
    out.add(_ym(m));
  }
  return out;
}

/// Events for [league] between [from] and [to].
///
/// ESPN's scoreboard rejects date ranges (HTTP 400) but accepts a whole
/// month, so fetch each month in the window and keep the days we need.
Future<List<SportEvent>> fetchEvents(League league, DateTime from, DateTime to) async {
  final pages = await Future.wait([
    for (final month in monthsBetween(from, to))
      fetchText(
        '$espnBase/apis/site/v2/sports/${league.path}/scoreboard?dates=$month&limit=1000',
        timeout: const Duration(seconds: 25),
      ),
  ]);
  return Isolate.run(() {
    final byId = <String, SportEvent>{};
    for (final text in pages) {
      for (final e in parseScoreboard(league, text)) {
        if (!e.start.isBefore(from) && !e.start.isAfter(to)) byId[e.id] = e;
      }
    }
    return byId.values.toList();
  });
}

/// All teams in [league], for the team picker.
Future<List<Team>> fetchTeams(League league) async {
  final text = await fetchText('$espnBase/apis/site/v2/sports/${league.path}/teams?limit=500');
  return Isolate.run(() => parseTeams(league, text));
}

List<SportEvent> parseScoreboard(League league, String text) {
  final json = jsonDecode(text);
  final events = <SportEvent>[];
  for (final e in (json is Map ? json['events'] : null) as List? ?? const []) {
    if (e is! Map) continue;
    final comps = e['competitions'];
    final comp = comps is List && comps.isNotEmpty && comps.first is Map ? comps.first as Map : const {};
    final status = (comp['status'] ?? e['status']) as Map? ?? const {};
    final type = status['type'] as Map? ?? const {};
    final state = switch (type['state']) {
      'in' => EventState.live,
      'post' => EventState.finished,
      _ => EventState.upcoming,
    };
    final start = DateTime.tryParse('${comp['date'] ?? e['date']}')?.toLocal();
    if (start == null) continue;

    final competitors = <Competitor>[];
    for (final c in comp['competitors'] as List? ?? const []) {
      if (c is! Map) continue;
      final team = c['team'] as Map?;
      final athlete = c['athlete'] as Map?;
      final who = team ?? athlete ?? const {};
      final name = '${who['displayName'] ?? who['name'] ?? ''}'.trim();
      if (name.isEmpty) continue;
      final score = c['score'];
      competitors.add(
        Competitor(
          name: name,
          shortName: _s(who['shortDisplayName']),
          abbreviation: _s(who['abbreviation']),
          logo: _s(who['logo']) ?? _firstLogo(who['logos']) ?? _s((who['flag'] as Map?)?['href']),
          score: score is Map ? _s(score['displayValue']) : _s(score),
          teamId: team == null ? null : _s(team['id']),
          home: c['homeAway'] == 'home',
          winner: c['winner'] == true,
        ),
      );
    }
    competitors.sort((a, b) => (b.home ? 1 : 0) - (a.home ? 1 : 0));

    final broadcasts = <String>{};
    for (final b in comp['broadcasts'] as List? ?? const []) {
      if (b is Map) {
        for (final n in b['names'] as List? ?? const []) {
          if (n is String && n.isNotEmpty) broadcasts.add(n);
        }
      }
    }
    for (final b in comp['geoBroadcasts'] as List? ?? const []) {
      final n = b is Map ? _s((b['media'] as Map?)?['shortName']) : null;
      if (n != null) broadcasts.add(n);
    }

    events.add(
      SportEvent(
        id: '${e['id']}',
        league: league,
        name: '${e['name'] ?? e['shortName'] ?? ''}',
        start: start,
        state: state,
        status: _s(type['shortDetail']) ?? _s(type['description']) ?? '',
        competitors: competitors,
        venue: _s((comp['venue'] as Map?)?['fullName']),
        broadcasts: broadcasts.toList(),
      ),
    );
  }
  return events;
}

List<Team> parseTeams(League league, String text) {
  final json = jsonDecode(text);
  final out = <Team>[];
  final sports = json is Map ? json['sports'] as List? ?? const [] : const [];
  for (final s in sports) {
    for (final l in (s as Map)['leagues'] as List? ?? const []) {
      for (final t in (l as Map)['teams'] as List? ?? const []) {
        final team = (t as Map)['team'] as Map?;
        if (team == null || team['id'] == null) continue;
        out.add(
          Team(
            id: '${team['id']}',
            sportKey: league.sportKey,
            name: '${team['displayName'] ?? team['name']}',
            shortName: _s(team['shortDisplayName']),
            logo: _firstLogo(team['logos']),
          ),
        );
      }
    }
  }
  out.sort((a, b) => a.name.compareTo(b.name));
  return out;
}

String? _s(dynamic v) {
  final s = v?.toString().trim();
  return s == null || s.isEmpty || s == 'null' ? null : s;
}

String? _firstLogo(dynamic logos) =>
    logos is List && logos.isNotEmpty && logos.first is Map ? _s(logos.first['href']) : null;
